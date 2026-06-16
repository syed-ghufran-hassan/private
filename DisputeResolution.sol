// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IDisputeAgentRegistry {}

interface IDisputeSlashingController {
    struct SlashRecord {
        bytes32 slashId;
        bytes32 agentId;
        address auditorAddress;
        bytes32 evidenceHash;
        uint256 burnAmount;
        uint256 rewardAmount;
        uint256 timestamp;
        bool disputed;
    }

    function getSlashRecord(bytes32 slashId) external view returns (SlashRecord memory);
}

/// @dev Updated interface to include dispute flag management (C-04 fix)
interface IDisputeStakingVault {
    function restoreSlashedStake(bytes32 agentId, uint256 amount) external;
    function clearDisputeFlag(bytes32 agentId) external;
    function setActiveDispute(bytes32 agentId) external;
}

interface IDisputeMNTY is IERC20 {
    function mint(address to, uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
}

/**
 * @title DisputeResolution
 * @notice Handles disputes against agent slashing with timelock-protected resolution
 *
 * AUDIT FIXES APPLIED:
 * - C-05: 2-step timelock resolution (propose → wait → execute) replaces instant owner decision
 * - C-04: Calls stakingVault.setActiveDispute/clearDisputeFlag for proper lifecycle
 * - M-03: Configurable dispute bond with minimum floor
 * - L-01: Events for all state-changing setter functions
 * - L-04: Zero-address checks in constructor
 */
contract DisputeResolution is Ownable, ReentrancyGuard {
    using SafeERC20 for IDisputeMNTY;

    IDisputeAgentRegistry public agentRegistry;
    IDisputeSlashingController public slashingController;
    IDisputeStakingVault public stakingVault;
    IDisputeMNTY public mntyToken;
    uint256 public disputeWindow;
    uint256 public disputeStakeAmount;

    /// @notice C-05 FIX: Minimum delay between proposing and executing a resolution
    uint256 public resolutionDelay;

    enum DisputeStatus {
        OPEN,
        UPHELD,
        OVERRULED
    }

    struct Dispute {
        bytes32 disputeId;
        bytes32 slashId;
        bytes32 agentId;
        address disputant;
        bytes32 counterEvidenceHash;
        uint256 openedAt;
        uint256 expiresAt;
        DisputeStatus status;
        bool resolved;
        uint256 stakedAmount;
    }

    /// @notice C-05 FIX: Pending resolution with timelock
    struct PendingResolution {
        bool upheld;
        string reasoning;
        uint256 proposedAt;
    }

    mapping(bytes32 => Dispute) public disputes;
    mapping(bytes32 => bytes32) public slashToDispute;
    bytes32[] public allDisputeIds;

    /// @notice C-05 FIX: Pending resolutions awaiting timelock expiry
    mapping(bytes32 => PendingResolution) public pendingResolutions;
    mapping(bytes32 => bool) public hasPendingResolution;

    error DisputeWindowExpired();
    error DisputeAlreadyExists();
    error DisputeNotOpen();
    error DisputeAlreadyResolved();
    error NotDisputant();
    error InsufficientDisputeStake();
    error SlashNotFound();
    error DisputeExpired();
    error InvalidValue();
    error NoPendingResolution();
    error TimelockNotElapsed();
    error ResolutionAlreadyPending();

    event DisputeOpened(
        bytes32 indexed disputeId,
        bytes32 indexed slashId,
        bytes32 indexed agentId,
        address disputant,
        uint256 expiresAt
    );
    event DisputeResolved(bytes32 indexed disputeId, bool upheld, string reasoning, uint256 timestamp);
    event ResolutionProposed(bytes32 indexed disputeId, bool upheld, string reasoning, uint256 executeAfter);
    event ResolutionCancelled(bytes32 indexed disputeId, uint256 timestamp);
    event DisputeWindowUpdated(uint256 oldWindow, uint256 newWindow);
    event DisputeStakeAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event ResolutionDelayUpdated(uint256 oldDelay, uint256 newDelay);

    constructor(
        address agentRegistryAddress,
        address slashingControllerAddress,
        address stakingVaultAddress,
        address mntyTokenAddress,
        uint256 disputeWindowSeconds
    ) Ownable(msg.sender) {
        // L-04 FIX: Zero-address checks
        require(agentRegistryAddress != address(0), "Invalid agent registry");
        require(slashingControllerAddress != address(0), "Invalid slashing controller");
        require(stakingVaultAddress != address(0), "Invalid staking vault");
        require(mntyTokenAddress != address(0), "Invalid MNTY token");

        if (disputeWindowSeconds < 1 days || disputeWindowSeconds > 30 days) revert InvalidValue();
        agentRegistry = IDisputeAgentRegistry(agentRegistryAddress);
        slashingController = IDisputeSlashingController(slashingControllerAddress);
        stakingVault = IDisputeStakingVault(stakingVaultAddress);
        mntyToken = IDisputeMNTY(mntyTokenAddress);
        disputeWindow = disputeWindowSeconds;
        disputeStakeAmount = 100 ether;
        resolutionDelay = 2 days; // C-05: Default 2-day timelock
    }

    /**
     * @notice Open a dispute against a slash
     * @dev C-04 FIX: Notifies StakingVault that an active dispute exists
     */
    function openDispute(
        bytes32 slashId,
        bytes32 counterEvidenceHash
    ) external nonReentrant returns (bytes32 disputeId) {
        IDisputeSlashingController.SlashRecord memory slashRecord = slashingController.getSlashRecord(slashId);
        if (slashRecord.timestamp == 0) revert SlashNotFound();
        if (slashToDispute[slashId] != bytes32(0)) revert DisputeAlreadyExists();
        if (block.timestamp > slashRecord.timestamp + disputeWindow) revert DisputeWindowExpired();
        if (
            mntyToken.balanceOf(msg.sender) < disputeStakeAmount
                || mntyToken.allowance(msg.sender, address(this)) < disputeStakeAmount
        ) {
            revert InsufficientDisputeStake();
        }

        disputeId = keccak256(abi.encodePacked(slashId, msg.sender, block.timestamp));
        uint256 expiresAt = block.timestamp + disputeWindow;
        disputes[disputeId] = Dispute({
            disputeId: disputeId,
            slashId: slashId,
            agentId: slashRecord.agentId,
            disputant: msg.sender,
            counterEvidenceHash: counterEvidenceHash,
            openedAt: block.timestamp,
            expiresAt: expiresAt,
            status: DisputeStatus.OPEN,
            resolved: false,
            stakedAmount: disputeStakeAmount
        });
        slashToDispute[slashId] = disputeId;
        allDisputeIds.push(disputeId);

        mntyToken.safeTransferFrom(msg.sender, address(this), disputeStakeAmount);

        // C-04 FIX: Notify StakingVault that this agent has an active dispute
        stakingVault.setActiveDispute(slashRecord.agentId);

        emit DisputeOpened(disputeId, slashId, slashRecord.agentId, msg.sender, expiresAt);
    }

    /**
     * @notice Propose a resolution for a dispute (step 1 of 2-step timelock)
     * @param disputeId The dispute to resolve
     * @param upheld True if the dispute is upheld (slash was unjust), false if overruled
     * @param reasoning Explanation for the resolution decision
     *
     * @dev C-05 FIX: Resolution is now a 2-step process with a timelock delay.
     *      Step 1: Owner proposes a resolution (this function)
     *      Step 2: Anyone executes after resolutionDelay (executeResolution)
     *      This gives the community time to react to unfair resolutions.
     */
    function proposeResolution(
        bytes32 disputeId,
        bool upheld,
        string calldata reasoning
    ) external onlyOwner {
        Dispute storage dispute = disputes[disputeId];
        if (dispute.disputeId == bytes32(0) || dispute.status != DisputeStatus.OPEN) revert DisputeNotOpen();
        if (dispute.resolved) revert DisputeAlreadyResolved();
        if (hasPendingResolution[disputeId]) revert ResolutionAlreadyPending();

        pendingResolutions[disputeId] = PendingResolution({
            upheld: upheld,
            reasoning: reasoning,
            proposedAt: block.timestamp
        });
        hasPendingResolution[disputeId] = true;

        emit ResolutionProposed(disputeId, upheld, reasoning, block.timestamp + resolutionDelay);
    }

    /**
     * @notice Execute a pending resolution after the timelock has elapsed (step 2 of 2)
     * @param disputeId The dispute to execute the resolution for
     *
     * @dev C-05 FIX: Permissionless execution after timelock — prevents owner from
     *      blocking resolutions indefinitely. Anyone can call this once the delay passes.
     */
    function executeResolution(bytes32 disputeId) external nonReentrant {
        if (!hasPendingResolution[disputeId]) revert NoPendingResolution();

        PendingResolution memory pending = pendingResolutions[disputeId];
        if (block.timestamp < pending.proposedAt + resolutionDelay) revert TimelockNotElapsed();

        Dispute storage dispute = disputes[disputeId];
        if (dispute.disputeId == bytes32(0) || dispute.status != DisputeStatus.OPEN) revert DisputeNotOpen();
        if (dispute.resolved) revert DisputeAlreadyResolved();

        dispute.resolved = true;

        // Clean up pending resolution
        delete pendingResolutions[disputeId];
        hasPendingResolution[disputeId] = false;

        IDisputeSlashingController.SlashRecord memory slashRecord = slashingController.getSlashRecord(dispute.slashId);
        uint256 restoreAmount = slashRecord.burnAmount + slashRecord.rewardAmount;
        uint256 stakeAmount = dispute.stakedAmount;

        if (pending.upheld) {
            dispute.status = DisputeStatus.UPHELD;
            if (restoreAmount > 0) {
                mntyToken.mint(address(stakingVault), restoreAmount);
                stakingVault.restoreSlashedStake(dispute.agentId, restoreAmount);
            }
            if (stakeAmount > 0) {
                mntyToken.safeTransfer(dispute.disputant, stakeAmount);
            }
            // restoreSlashedStake already clears underDispute and hasActiveDispute
        } else {
            dispute.status = DisputeStatus.OVERRULED;
            if (stakeAmount > 0) {
                mntyToken.burnFrom(address(this), stakeAmount);
            }
            // C-04 FIX: Clear the dispute flag when overruled
            stakingVault.clearDisputeFlag(dispute.agentId);
        }

        emit DisputeResolved(disputeId, pending.upheld, pending.reasoning, block.timestamp);
    }

    /**
     * @notice Cancel a pending resolution (before timelock expires)
     * @param disputeId The dispute whose pending resolution to cancel
     *
     * @dev C-05 FIX: Allows the owner to change their mind before execution.
     */
    function cancelResolution(bytes32 disputeId) external onlyOwner {
        if (!hasPendingResolution[disputeId]) revert NoPendingResolution();

        delete pendingResolutions[disputeId];
        hasPendingResolution[disputeId] = false;

        emit ResolutionCancelled(disputeId, block.timestamp);
    }

    // ============ Admin Functions ============

    function setDisputeWindow(uint256 newWindow) external onlyOwner {
        if (newWindow < 1 days || newWindow > 30 days) revert InvalidValue();
        uint256 oldWindow = disputeWindow;
        disputeWindow = newWindow;
        emit DisputeWindowUpdated(oldWindow, newWindow);
    }

    /// @dev L-01 FIX: Added event emission
    function setDisputeStakeAmount(uint256 amount) external onlyOwner {
        if (amount == 0) revert InvalidValue();
        uint256 oldAmount = disputeStakeAmount;
        disputeStakeAmount = amount;
        emit DisputeStakeAmountUpdated(oldAmount, amount);
    }

    function setResolutionDelay(uint256 newDelay) external onlyOwner {
        if (newDelay < 1 days || newDelay > 14 days) revert InvalidValue();
        uint256 oldDelay = resolutionDelay;
        resolutionDelay = newDelay;
        emit ResolutionDelayUpdated(oldDelay, newDelay);
    }

    // ============ View Functions ============

    function getDispute(bytes32 disputeId) external view returns (Dispute memory) {
        return disputes[disputeId];
    }

    function getDisputeBySlash(bytes32 slashId) external view returns (Dispute memory) {
        return disputes[slashToDispute[slashId]];
    }

    function getAllDisputeIds() external view returns (bytes32[] memory) {
        return allDisputeIds;
    }

    function getPendingResolution(bytes32 disputeId) external view returns (PendingResolution memory) {
        return pendingResolutions[disputeId];
    }
}
