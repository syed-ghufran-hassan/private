// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {OApp, Origin, MessagingFee} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {OAppOptionsType3} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OAppOptionsType3.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IFHERC20} from "./token/interfaces/IFHERC20.sol";

error MsgValueDoesNotMatchInputAmount();
error UnauthorizedRelayer();
error IntentNotFound();
error IntentAlreadyFilled();
error SolverAlreadyPaid();
error InvalidAddress();
error InvalidToken();
error InvalidChainId();

contract CoFHEBridge is
    Ownable,
    ReentrancyGuard,
    Pausable,
    OApp,
    OAppOptionsType3
{
    /// @notice Msg type for sending a string, for use in OAppOptionsType3 as an enforced option
    uint16 public constant SEND = 1;

    uint256 public fee = 100; // 1%
    address public feeReceiver = 0xBdc3f1A02e56CD349d10bA8D2B038F774ae22731;

    enum FilledStatus {
        NOT_FILLED,
        FILLED
    }

    struct Intent {
        address sender;
        address receiver;
        address relayer;
        address inputToken;
        address outputToken;
        euint64 inputAmount;
        euint64 outputAmount;
        uint256 id;
        uint32 originChainId;
        euint32 destinationChainId;
        FilledStatus filledStatus;
        bool solverPaid;
        uint256 timeout;
    }

    // Store the original InEuint64 values for transfers
    mapping(uint256 intentId => InEuint64) public inputAmountTransfer;
    mapping(uint256 intentId => InEuint64) public outputAmountTransfer;

    mapping(uint256 intentId => Intent) public intents;
    mapping(uint256 intentId => bool exists) public doesIntentExist;

    mapping(uint32 chainId => uint32 eid) public chainIdToEid;

    event IntentCreated(
        address indexed sender,
        address indexed relayer,
        Intent intent
    );
    event IntentFulfilled(
        address indexed sender,
        address indexed relayer,
        Intent intent
    );
    event IntentRepaid(
        address indexed sender,
        address indexed relayer,
        Intent intent
    );
    event RelayerAuthorizationChanged(address indexed relayer, bool authorized);

    constructor(
        address _endpoint
    ) OApp(_endpoint, msg.sender) Ownable(msg.sender) {}

    function quote(
        uint32 _dstEid,
        string calldata _string,
        bytes calldata _options,
        bool _payInLzToken
    ) public view returns (MessagingFee memory fee) {
        bytes memory _message = abi.encode(_string);
        // combineOptions (from OAppOptionsType3) merges enforced options set by the contract owner
        // with any additional execution options provided by the caller
        fee = _quote(
            _dstEid,
            _message,
            combineOptions(_dstEid, SEND, _options),
            _payInLzToken
        );
    }

    function bridge(
        address _sender,
        address _receiver,
        address _relayer,
        address _inputToken,
        address _outputToken,
        InEuint64 calldata _encInputAmount,
        InEuint64 calldata _encOutputAmount,
        InEuint32 calldata _destinationChainId
    ) public nonReentrant whenNotPaused {
        // Input validation
        if (
            _sender == address(0) ||
            _receiver == address(0) ||
            _relayer == address(0)
        ) {
            revert InvalidAddress();
        }
        if (_inputToken == address(0) || _outputToken == address(0)) {
            revert InvalidToken();
        }

        euint64 encInputAmount = FHE.asEuint64(_encInputAmount);
        euint64 encOutputAmount = FHE.asEuint64(_encOutputAmount);
        euint32 destinationChainId = FHE.asEuint32(_destinationChainId);

        // Allow relayer to decrypt the amounts
        FHE.allow(encInputAmount, _relayer);
        FHE.allow(encOutputAmount, _relayer);
        FHE.allow(destinationChainId, _relayer);

        // Allow the sender to decrypt the amounts
        FHE.allow(encInputAmount, _sender);
        FHE.allow(encOutputAmount, _sender);
        FHE.allow(destinationChainId, _sender);

        // Allow the bridge contract to decrypt the input amount for transfer
        FHE.allowThis(encInputAmount);
        FHE.allowThis(encOutputAmount);
        FHE.allowThis(destinationChainId);

        FHE.allow(encInputAmount, _inputToken);

        // Transfer input amount from user to bridge contract using permit
        IFHERC20(_inputToken).confidentialTransferFrom(
            msg.sender,
            address(this),
            encInputAmount
        );

        uint256 id = uint256(
            keccak256(
                abi.encodePacked(
                    _sender,
                    _receiver,
                    _relayer,
                    _inputToken,
                    _outputToken,
                    destinationChainId,
                    block.timestamp,
                    block.number // Add block number for better uniqueness
                )
            )
        );

        Intent memory intent = Intent({
            sender: _sender,
            receiver: _receiver,
            relayer: _relayer,
            inputToken: _inputToken,
            outputToken: _outputToken,
            inputAmount: encInputAmount,
            outputAmount: encOutputAmount,
            id: id,
            originChainId: uint32(block.chainid),
            destinationChainId: destinationChainId,
            filledStatus: FilledStatus.NOT_FILLED,
            solverPaid: false,
            timeout: block.timestamp + 24 hours
        });

        intents[id] = intent;
        doesIntentExist[id] = true;

        // Store original amounts for transfers
        inputAmountTransfer[id] = _encInputAmount;
        outputAmountTransfer[id] = _encOutputAmount;

        emit IntentCreated(_sender, _relayer, intent);
    }

    function fulfill(
        Intent memory intent,
        InEuint64 calldata _outputAmount,
        bytes memory _options
    ) public payable whenNotPaused {
        euint64 encOutputAmount = FHE.asEuint64(_outputAmount);

        fulfill(intent, encOutputAmount, _options);
    }

    function fulfill(
        Intent memory intent,
        euint64 _outputAmount,
        bytes memory _options
    ) public payable whenNotPaused {
        if (intent.relayer != msg.sender) {
            revert UnauthorizedRelayer();
        }

        // Check if this intent already exists and is filled on THIS chain
        if (
            doesIntentExist[intent.id] &&
            intents[intent.id].filledStatus == FilledStatus.FILLED
        ) {
            revert IntentAlreadyFilled();
        }

        FHE.allowTransient(_outputAmount, intent.relayer);
        FHE.allow(_outputAmount, intent.outputToken);

        IFHERC20(intent.outputToken).confidentialTransferFrom(
            intent.relayer, // solver
            intent.receiver, // user's receiver address
            _outputAmount // Use provided InEuint64 for transfer
        );

        intents[intent.id] = intent;
        intents[intent.id].filledStatus = FilledStatus.FILLED;
        doesIntentExist[intent.id] = true;

        // Send message back to origin chain to pay the solver
        uint32 _dstEid = chainIdToEid[intent.originChainId];
        bytes memory _message = abi.encode(intent.id);

        _lzSend(
            _dstEid,
            _message,
            _options,
            MessagingFee(msg.value, 0),
            payable(msg.sender)
        );

        emit IntentFulfilled(intent.sender, intent.relayer, intent);
    }

    function getIntent(uint256 intentId) external view returns (Intent memory) {
        return intents[intentId];
    }

    // Emergency pause functions
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setChainIdToEid(uint32 _chainId, uint32 _eid) external onlyOwner {
        if (_chainId == 0 || _eid == 0) {
            revert InvalidChainId();
        }
        chainIdToEid[_chainId] = _eid;
    }

    function _lzReceive(
        Origin calldata /*_origin*/,
        bytes32 /*_guid*/,
        bytes calldata _message,
        address /*_executor*/,
        bytes calldata /*_extraData*/
    ) internal override {
        uint256 intentId = abi.decode(_message, (uint256));

        if (!doesIntentExist[intentId]) {
            revert IntentNotFound();
        }

        Intent storage intent = intents[intentId];

        if (intent.solverPaid) {
            revert SolverAlreadyPaid();
        }

        IFHERC20(intent.inputToken).confidentialTransfer(
            intent.relayer,
            intent.inputAmount
        );

        intent.solverPaid = true;
        emit IntentRepaid(intent.sender, intent.relayer, intent);
    }
}