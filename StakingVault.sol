// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMNTY is IERC20 {
    function burnFrom(address account, uint256 amount) external;
}

interface IAgentRegistryForVault {
    struct AgentRecord {
        bytes32 agentId;
        uint8 agentClass;
        bytes32 manifestHash;
        address ownerAddress;
        address authorizedSafe;
        uint256 registeredAt;
        uint8 status;
    }

    function getAgent(bytes32 agentId) external view returns (AgentRecord memory);
}

/**
 * @title StakingVault
 * @notice Manages MNTY token staking, locking, slashing, and dispute lifecycle
 *
 * AUDIT FIXES APPLIED:
 * - C-04: Fixed underDispute lifecycle — auto-clears after dispute window expires,
 *         explicit clear from DisputeResolution for both upheld/overruled outcomes
 * - H-05: Removed one-shot restriction on setSlashingController/setDisputeResolution
 * - L-04: Zero-address checks in constructor
 */
contract StakingVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IMNTY;

    IMNTY public mntyToken;
    IAgentRegistryForVault public agentRegistry;
    address public slashingController;
    address public disputeResolution;

    /// @notice C-04 FIX: Duration after which a dispute flag auto-clears if no dispute was opened
    uint256 public disputeWindowDuration = 7 days;

    struct StakeRecord {
        uint256 amount;
        bool locked;
        bool underDispute;
        uint256 lockedAt;
    }

    mapping(bytes32 => StakeRecord) private stakes;

    /// @notice C-04 FIX: Tracks the timestamp of the last slash per agent
    mapping(bytes32 => uint256) public lastSlashedAt;

    /// @notice C-04 FIX: Tracks whether DisputeResolution has flagged an active dispute
    mapping(bytes32 => bool) public hasActiveDispute;

    error InsufficientStake();
    error StakeIsLocked();
    error StakeUnderDispute();
    error NotSlashingController();
    error NotDisputeResolution();
    error NotAgentOwner();
    error ZeroAmount();
    error InvalidAddress();
    error InvalidDuration();
    error NotUnderDispute();
    error DisputeWindowNotExpired();

    event Deposited(bytes32 indexed agentId, uint256 amount, uint256 timestamp);
    event Slashed(
        bytes32 indexed agentId,
        uint256 burnAmount,
        uint256 rewardAmount,
        address auditorAddress,
        uint256 timestamp
    );
    event StakeLocked(bytes32 indexed agentId, uint256 timestamp);
    event StakeReleased(bytes32 indexed agentId, uint256 timestamp);
    event Withdrawn(bytes32 indexed agentId, uint256 amount, uint256 timestamp);
    event SlashingControllerUpdated(address indexed oldController, address indexed newController, uint256 timestamp);
    event DisputeResolutionUpdated(address indexed oldResolver, address indexed newResolver, uint256 timestamp);
    event StakeRestored(bytes32 indexed agentId, uint256 amount, uint256 timestamp);
    event DisputeFlagSet(bytes32 indexed agentId, uint256 timestamp);
    event DisputeFlagCleared(bytes32 indexed agentId, uint256 timestamp);
    event DisputeFlagAutoCleared(bytes32 indexed agentId, uint256 timestamp);
    event DisputeWindowDurationUpdated(uint256 oldDuration, uint256 newDuration);

    modifier onlySlashingController() {
        if (msg.sender != slashingController) revert NotSlashingController();
        _;
    }

    modifier onlyDisputeResolution() {
        if (msg.sender != disputeResolution) revert NotDisputeResolution();
        _;
    }

    constructor(address mntyTokenAddress, address agentRegistryAddress) Ownable(msg.sender) {
        // L-04 FIX: Zero-address checks
        require(mntyTokenAddress != address(0), "Invalid MNTY token");
        require(agentRegistryAddress != address(0), "Invalid agent registry");
        mntyToken = IMNTY(mntyTokenAddress);
        agentRegistry = IAgentRegistryForVault(agentRegistryAddress);
    }

    /**
     * @notice Set the slashing controller address
     * @dev H-05 FIX: Removed one-shot restriction — allows updates for upgrades/fixes
     */
    function setSlashingController(address sc) external onlyOwner {
        if (sc == address(0)) revert InvalidAddress();
        address old = slashingController;
        slashingController = sc;
        emit SlashingControllerUpdated(old, sc, block.timestamp);
    }

    /**
     * @notice Set the dispute resolution address
     * @dev H-05 FIX: Removed one-shot restriction — allows updates for upgrades/fixes
     */
    function setDisputeResolution(address dr) external onlyOwner {
        if (dr == address(0)) revert InvalidAddress();
        address old = disputeResolution;
        disputeResolution = dr;
        emit DisputeResolutionUpdated(old, dr, block.timestamp);
    }

    /**
     * @notice Set the dispute window duration for auto-clearing dispute flags
     * @param duration The new dispute window duration in seconds
     */
    function setDisputeWindowDuration(uint256 duration) external onlyOwner {
        if (duration < 1 days || duration > 30 days) revert InvalidDuration();
        uint256 old = disputeWindowDuration;
        disputeWindowDuration = duration;
        emit DisputeWindowDurationUpdated(old, duration);
    }

    function deposit(bytes32 agentId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        IAgentRegistryForVault.AgentRecord memory agent = agentRegistry.getAgent(agentId);
        if (agent.ownerAddress != msg.sender) revert NotAgentOwner();

        stakes[agentId].amount += amount;
        emit Deposited(agentId, amount, block.timestamp);

        mntyToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    function lockStake(bytes32 agentId) external onlyOwner {
        StakeRecord storage stake = stakes[agentId];

        stake.locked = true;
        stake.lockedAt = block.timestamp;

        emit StakeLocked(agentId, block.timestamp);
    }

    function releaseStake(bytes32 agentId) external onlyOwner {
        StakeRecord storage stake = stakes[agentId];
        if (stake.underDispute) revert StakeUnderDispute();

        stake.locked = false;
        emit StakeReleased(agentId, block.timestamp);
    }

    /**
     * @notice Execute a slash against an agent's stake
     * @dev C-04 FIX: Records lastSlashedAt timestamp for auto-clear mechanism.
     *      underDispute is set to protect funds during the dispute window.
     */
    function slash(
        bytes32 agentId,
        uint256 burnAmount,
        uint256 rewardAmount,
        address auditorAddress
    ) external onlySlashingController nonReentrant {
        uint256 totalPenalty = burnAmount + rewardAmount;
        StakeRecord storage stake = stakes[agentId];
        if (stake.amount < totalPenalty) revert InsufficientStake();

        stake.amount -= totalPenalty;
        stake.underDispute = true;
        lastSlashedAt[agentId] = block.timestamp; // C-04 FIX: Track slash time

        emit Slashed(agentId, burnAmount, rewardAmount, auditorAddress, block.timestamp);

        if (burnAmount > 0) {
            mntyToken.burnFrom(address(this), burnAmount);
        }
        if (rewardAmount > 0) {
            mntyToken.safeTransfer(auditorAddress, rewardAmount);
        }
    }

    /**
     * @notice Called by DisputeResolution when a dispute is opened
     * @dev C-04 FIX: Marks that an active dispute exists, preventing auto-clear
     */
    function setActiveDispute(bytes32 agentId) external onlyDisputeResolution {
        hasActiveDispute[agentId] = true;
        stakes[agentId].underDispute = true;
        emit DisputeFlagSet(agentId, block.timestamp);
    }

    /**
     * @notice Called by DisputeResolution when a dispute is resolved (overruled)
     * @dev C-04 FIX: Clears both the underDispute flag and the active dispute marker
     */
    function clearDisputeFlag(bytes32 agentId) external onlyDisputeResolution {
        stakes[agentId].underDispute = false;
        hasActiveDispute[agentId] = false;
        emit DisputeFlagCleared(agentId, block.timestamp);
    }

    /**
     * @notice Restore slashed stake when a dispute is upheld
     * @dev C-04 FIX: Also clears hasActiveDispute flag
     */
    function restoreSlashedStake(bytes32 agentId, uint256 amount) external onlyDisputeResolution {
        stakes[agentId].amount += amount;
        stakes[agentId].underDispute = false;
        hasActiveDispute[agentId] = false; // C-04 FIX

        emit StakeRestored(agentId, amount, block.timestamp);
    }

    /**
     * @notice Withdraw staked tokens
     * @dev C-04 FIX: Auto-clears expired dispute flags when no active dispute exists.
     *      If a slash occurred but no dispute was opened within disputeWindowDuration,
     *      the underDispute flag is automatically cleared, allowing withdrawals.
     */
    function withdraw(bytes32 agentId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        IAgentRegistryForVault.AgentRecord memory agent = agentRegistry.getAgent(agentId);
        if (agent.ownerAddress != msg.sender) revert NotAgentOwner();

        StakeRecord storage stake = stakes[agentId];
        if (stake.locked) revert StakeIsLocked();

        // C-04 FIX: Auto-clear expired dispute flag if no active dispute was opened
        if (stake.underDispute && !hasActiveDispute[agentId]) {
            if (lastSlashedAt[agentId] > 0
                && block.timestamp > lastSlashedAt[agentId] + disputeWindowDuration) {
                stake.underDispute = false;
                emit DisputeFlagAutoCleared(agentId, block.timestamp);
            }
        }

        if (stake.underDispute) revert StakeUnderDispute();
        if (amount > stake.amount) revert InsufficientStake();

        stake.amount -= amount;
        emit Withdrawn(agentId, amount, block.timestamp);

        mntyToken.safeTransfer(msg.sender, amount);
    }

    /**
     * @notice Permissionless auto-clear of expired dispute flags
     * @dev C-04 FIX: Anyone can call this to clear a dispute flag after the window expires,
     *      as long as no active dispute was opened via DisputeResolution.
     */
    function clearExpiredDispute(bytes32 agentId) external {
        StakeRecord storage stake = stakes[agentId];
        if (!stake.underDispute) revert NotUnderDispute();
        if (hasActiveDispute[agentId]) revert StakeUnderDispute();
        if (lastSlashedAt[agentId] == 0 ||
            block.timestamp <= lastSlashedAt[agentId] + disputeWindowDuration) {
            revert DisputeWindowNotExpired();
        }

        stake.underDispute = false;
        emit DisputeFlagAutoCleared(agentId, block.timestamp);
    }

    // ============ View Functions ============

    function getStake(bytes32 agentId) external view returns (uint256) {
        return stakes[agentId].amount;
    }

    function isLocked(bytes32 agentId) external view returns (bool) {
        return stakes[agentId].locked;
    }

    function isUnderDispute(bytes32 agentId) external view returns (bool) {
        return stakes[agentId].underDispute;
    }
}
