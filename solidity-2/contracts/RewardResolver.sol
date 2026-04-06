// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import {IFunctionsRouter} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/interfaces/IFunctionsRouter.sol";
import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IRewardResolver} from "src/interfaces/IRewardResolver.sol";

contract RewardResolver is
    IRewardResolver,
    AutomationCompatibleInterface,
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable
{
    enum State {
        OPEN,
        CALCULATING,
        WAITING
    }

    using FunctionsRequest for FunctionsRequest.Request;
    using Strings for uint256;

    /**
     * @dev The interval between bonded tokens reward
     */
    uint256 private constant GRACE_PERIOD_TIME = 12 hours;
    uint256 private constant REWARD_INTERVAL = 24 hours;
    address private constant ROUTER_ADDRESS =
        0xb83E47C2bC239B3bf370bc41e1459A34b41238D0; //SEPOLIA ETH
    uint256 public s_lastTimestamp;
    State private s_state;

    string public s_source;

    bytes private s_donHostedSecret;
    address private s_winner;
    uint256 public s_lastWinnerTimestamp;
    //Callback gas limit
    uint32 private s_gasLimit;
    uint64 private s_subscriptionId;
    // donID - Hardcoded for Sepolia
    bytes32 private constant DON_ID =
        0x66756e2d657468657265756d2d7365706f6c69612d3100000000000000000000;
    IFunctionsRouter private s_router;
    bytes public s_lastResponse;
    bytes32 public s_lastRequestId;
    bytes public s_lastError;
    string[] public s_args;
    address public s_feeAccount;

    // Gap for future storage variables. If you add new variables, decrease the size of the gap.
    uint256[50] private __gap;

    // Custom error type
    error RewardResolver__NotFeeAccount();
    error RewardResolver__UnexpectedRequestID(bytes32 requestId);
    error RewardResolver__UpkeepNotNeeded(uint256 timeElapsed, State state);
    event RequestSent(bytes32 indexed requestId, uint256 timestamp);
    // Event to log responses
    event Response(bytes32 indexed requestId, bytes response, bytes err);
    event WinnerPicked(address indexed winner, uint256 timestamp);

    modifier onlyFeeAccount() {
        if (msg.sender != s_feeAccount) {
            revert RewardResolver__NotFeeAccount();
        }
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(uint64 subscriptionId) public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        s_subscriptionId = subscriptionId;
        s_lastTimestamp = block.timestamp;
        s_lastWinnerTimestamp = block.timestamp;
        s_state = State.OPEN;
        s_source = "const endpoint = `https://api.studio.thegraph.com/query/92662/test/version/latest`;"
        "const query = `{pools(where: {isRewarded: false, creationTimestamp_gte: ${args[0]}}, orderDirection: asc, orderBy: score, first: 1){tokenAddress}}`;"
        "const headers = {'Content-Type': 'application/json', 'Authorization': `Bearer ${secrets[0]}`};"
        "const body = { query,operationName: 'Subgraphs',variables: {}};"
        "const apiResponse = await Functions.makeHttpRequest({url: endpoint,method: 'POST',headers,data: body});"
        "const { data } = apiResponse.data;"
        "if (!data || !data.pools || data.pools.length === 0 || !data.pools[0].tokenAddress) return Functions.encodeUint256(BigInt(0));"
        "return Functions.encodeUint256(BigInt(data.pools[0]?.tokenAddress));";
        s_gasLimit = 300_000;
        s_router = IFunctionsRouter(ROUTER_ADDRESS);
        s_args.push("0");
    }

    function setDonHostedSecret(
        bytes calldata donHostedSecret
    ) external onlyOwner {
        s_donHostedSecret = donHostedSecret;
    }

    function setFeeAccount(address _feeAccount) external onlyOwner {
        s_feeAccount = _feeAccount;
    }

    function setSubscriptionId(uint64 _subscriptionId) external onlyOwner {
        s_subscriptionId = _subscriptionId;
    }

    function setStateOpen() external onlyFeeAccount {
        s_state = State.OPEN;
    }

    function setGasLimit(uint32 gasLimit) external onlyOwner {
        s_gasLimit = gasLimit;
    }

    function setSource(string calldata source) external onlyOwner {
        s_source = source;
    }

    function setArgument(
        string calldata argument,
        uint256 index
    ) external onlyOwner {
        s_args[index] = argument;
    }

    function addArgument(string calldata argument) external onlyOwner {
        s_args.push(argument);
    }

    function popArgument() external onlyOwner {
        s_args.pop();
    }

    function removeArgument(uint256 index) external onlyOwner {
        s_args[index] = s_args[s_args.length - 1];
        s_args.pop();
    }

    function getWinners() external view returns (address[] memory) {
        address[] memory winners = new address[](1);
        winners[0] = s_winner;
        return winners;
    }

    function getState() external view returns (State state) {
        return s_state;
    }

    /**
     * @dev This is the function that Chainlink nodes will call to check if the account is ready to pick the top 3 tokens that bonded. This is measured with Aerodrome Concentrated Liquidity TWGP (time weighed geometric mean price). Price = 1.0001 ^ T, where T is time weighted arithemetic mean tick, that is stored on a subgraph.
     * The following is needed in order for upkeepNeeded to be true:
     * 1. The time interval has passed since the last time top 3 tokens were picked
     * 2. The contest is open
     * 3. The contract has received ETH
     * 4. Implicitly, your subscription has received LINK
     * @param - ignored
     * @return upkeepNeeded - true if the contest is restarted
     * @return - ignored
     */
    function checkUpkeep(
        bytes memory /* checkData */
    ) public view returns (bool upkeepNeeded, bytes memory /* performData */) {
        bool timeHasPassed = (block.timestamp - s_lastTimestamp >=
            REWARD_INTERVAL);
        bool isOpen = s_state == State.OPEN;
        upkeepNeeded = timeHasPassed && isOpen;
        return (upkeepNeeded, "");
    }

    function performUpkeep(bytes calldata /* performData */) external {
        (bool upkeepNeeded, ) = checkUpkeep("");
        if (!upkeepNeeded) {
            revert RewardResolver__UpkeepNotNeeded(
                block.timestamp - s_lastTimestamp,
                s_state
            );
        }

        s_state = State.CALCULATING;
        s_args[0] = uint256(s_lastWinnerTimestamp - GRACE_PERIOD_TIME)
            .toString();

        _sendFunctionRequest(
            s_donHostedSecret,
            s_args,
            s_subscriptionId,
            s_gasLimit
        );
    }

    function handleOracleFulfillment(
        bytes32 requestId,
        bytes memory response,
        bytes memory err
    ) external override {
        if (msg.sender != ROUTER_ADDRESS) {
            revert IRewardResolver_OnlyRouterCanFulfill();
        }
        _fulfillRequest(requestId, response, err);
        emit RequestFulfilled(requestId);
    }

    /**
     * @notice Triggers an on-demand Functions request using remote encrypted secrets
     * @param encryptedSecretsReference Reference pointing to encrypted secrets
     * @param args String arguments passed into the source code and accessible via the global variable `args`
     * @param subscriptionId Subscription ID used to pay for request (FunctionsConsumer contract address must first be added to the subscription)
     * @param callbackGasLimit Maximum amount of gas used to call the inherited `handleOracleFulfillment` method
     */
    function _sendFunctionRequest(
        bytes storage encryptedSecretsReference,
        string[] storage args,
        uint64 subscriptionId,
        uint32 callbackGasLimit
    ) internal {
        FunctionsRequest.Request memory req; // Struct API reference: https://docs.chain.link/chainlink-functions/api-reference/functions-request
        req.initializeRequest(
            FunctionsRequest.Location.Inline,
            FunctionsRequest.CodeLanguage.JavaScript,
            s_source
        );
        req.secretsLocation = FunctionsRequest.Location.DONHosted;
        req.encryptedSecretsReference = encryptedSecretsReference;
        if (args.length > 0) {
            req.setArgs(args);
        }
        s_lastRequestId = _sendRequest(
            req.encodeCBOR(),
            subscriptionId,
            callbackGasLimit,
            DON_ID
        );

        emit RequestSent(s_lastRequestId, block.timestamp);
    }

    /**
     * @notice Store latest result/error
     * @param requestId The request ID, returned by sendRequest()
     * @param response Aggregated response from the user code
     * @param err Aggregated error from the user code or from the execution pipeline
     * Either response or error parameter will be set, but never both
     */
    function _fulfillRequest(
        bytes32 requestId,
        bytes memory response,
        bytes memory err
    ) internal {
        address winner = address(0);
        if (err.length == 0) {
            uint256 decodedResponse = abi.decode(response, (uint256));
            winner = address(uint160(decodedResponse));
        }

        s_lastResponse = response;
        s_winner = winner;
        if (winner != address(0)) {
            s_lastWinnerTimestamp = block.timestamp;
        }
        s_lastError = err;
        s_lastTimestamp = block.timestamp;
        s_state = State.WAITING;

        emit Response(requestId, response, err);
        emit WinnerPicked(winner, block.timestamp);
    }

    /// @notice Sends a Chainlink Functions request
    /// @param data The CBOR encoded bytes data for a Functions request
    /// @param subscriptionId The subscription ID that will be charged to service the request
    /// @param callbackGasLimit the amount of gas that will be available for the fulfillment callback
    /// @return requestId The generated request ID for this request
    function _sendRequest(
        bytes memory data,
        uint64 subscriptionId,
        uint32 callbackGasLimit,
        bytes32 donId
    ) internal returns (bytes32) {
        bytes32 requestId = s_router.sendRequest(
            subscriptionId,
            data,
            FunctionsRequest.REQUEST_DATA_VERSION,
            callbackGasLimit,
            donId
        );
        emit RequestSent(requestId);
        return requestId;
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
