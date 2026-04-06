// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {ConfirmedOwner} from "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";

contract RewardResolverMock is ConfirmedOwner {
    enum State {
        OPEN,
        CALCULATING,
        WAITING
    }

    /**
     * @dev The interval between bonded tokens reward
     */
    uint256 private constant REWARD_INTERVAL = 24 hours;
    uint256 public s_lastTimestamp;
    State private s_state;

    string public s_source;

    bytes private donHostedSecret;
    address private s_winner;
    address private router = 0xb83E47C2bC239B3bf370bc41e1459A34b41238D0; //SEPOLIA ETH
    //Callback gas limit
    uint32 private gasLimit = 300000;
    uint64 private s_subscriptionId;
    // donID - Hardcoded for Sepolia
    bytes32 private donId =
        0x66756e2d657468657265756d2d7365706f6c69612d3100000000000000000000;
    bytes public s_lastResponse;
    bytes32 public s_lastRequestId;
    bytes public s_lastError;
    string[] public s_args;
    address public forwarder;
    address public feeAccount;

    // Custom error type
    error RewardResolver__NotAutomationForwarder();
    error RewardResolver__NotFeeAccount();
    error RewardResolver__UnexpectedRequestID(bytes32 requestId);
    error RewardResolver__UpkeepNotNeeded(uint256 timeElapsed, State state);
    event RequestSent(bytes32 indexed requestId, uint256 timestamp);
    // Event to log responses
    event Response(bytes32 indexed requestId, bytes response, bytes err);
    event WinnerPicked(address indexed winner, uint256 timestamp);

    modifier onlyForwarder() {
        if (msg.sender != forwarder) {
            revert RewardResolver__NotAutomationForwarder();
        }
        _;
    }
    modifier onlyFeeAccount() {
        if (msg.sender != feeAccount) {
            revert RewardResolver__NotFeeAccount();
        }
        _;
    }

    /**
     * @notice Initializes the contract with the Chainlink router address and sets the contract owner
     */
    constructor(uint64 _subscriptionId) ConfirmedOwner(msg.sender) {
        s_subscriptionId = _subscriptionId;
        s_lastTimestamp = block.timestamp;
        forwarder = msg.sender;
        s_state = State.OPEN;
    }

    function setFeeAccount(address _feeAccount) external {
        feeAccount = _feeAccount;
    }

    function setStateOpen() external onlyFeeAccount {
        s_state = State.OPEN;
    }

    function setForwarder(address _forwarder) external {
        forwarder = _forwarder;
    }

    function setResponse(bytes calldata response) external {
        s_lastResponse = response;
    }

    function setError(bytes calldata err) external {
        s_lastError = err;
    }

    function setRequestId(bytes32 requestId) external {
        s_lastRequestId = requestId;
    }

    function setGasLimit(uint32 _gasLimit) external {
        gasLimit = _gasLimit;
    }

    function setSource(string calldata source) external {
        s_source = source;
    }

    function setArgument(string calldata argument, uint256 index) external {
        s_args[index] = argument;
    }

    function addArgument(string calldata argument) external {
        s_args.push(argument);
    }

    function popArgument() external {
        s_args.pop();
    }

    function removeArgument(uint256 index) external {
        s_args[index] = s_args[s_args.length - 1];
        s_args.pop();
    }

    function setWinner(address winner) external {
        s_winner = winner;
    }

    function setState(State state) external {
        s_state = state;
    }

    function getWinners() external view returns (address[] memory) {
        address[] memory winners = new address[](1);
        winners[0] = s_winner;
        return winners;
    }

    function getState() external view returns (State state) {
        return s_state;
    }

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

        _sendFunctionRequest(
            donHostedSecret,
            s_args,
            s_subscriptionId,
            gasLimit
        );
    }

    function _sendFunctionRequest(
        bytes storage /*encryptedSecretsReference*/,
        string[] storage /*args*/,
        uint64 /*subscriptionId*/,
        uint32 /*callbackGasLimit*/
    ) internal {
        emit RequestSent(s_lastRequestId, block.timestamp);

        fulfillRequest(s_lastRequestId, s_lastResponse, s_lastError);
    }

    /**
     * @notice Store latest result/error
     * @param requestId The request ID, returned by sendRequest()
     * @param response Aggregated response from the user code
     * @param err Aggregated error from the user code or from the execution pipeline
     * Either response or error parameter will be set, but never both
     */
    function fulfillRequest(
        bytes32 requestId,
        bytes memory response,
        bytes memory err
    ) public {
        address winner = address(0);
        if (err.length == 0) {
            uint256 decodedResponse = abi.decode(response, (uint256));
            winner = address(uint160(decodedResponse));
        }

        s_lastResponse = response;
        s_winner = winner;
        s_lastError = err;
        s_lastTimestamp = block.timestamp;
        s_state = State.WAITING;

        emit Response(requestId, response, err);
        emit WinnerPicked(winner, block.timestamp);
    }
}
