// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IAgentRegistryForSlashing {
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
    function getAgentByAddress(address addr) external view returns (AgentRecord memory);
    function isAuthorizedAuditor(address addr) external view returns (bool);
    function isRegistered(bytes32 agentId) external view returns (bool);
}

interface IStakingVault {
    function getStake(bytes32 agentId) external view returns (uint256);
    function slash(bytes32 agentId, uint256 burnAmount, uint256 rewardAmount, address auditorAddress) external;
}

/**
 * @title SlashingController
 * @notice Executes slashing of misbehaving agents' stakes
 *
 * AUDIT FIXES APPLIED:
 * - H-01: Removed unused third constructor parameter
 * - M-05: Added per-agent cooldown between slashes to prevent rapid drain
 * - L-04: Zero-address checks in constructor
 */
contract SlashingController is Ownable, ReentrancyGuard {
    IAgentRegistryForSlashing public agentRegistry;
    IStakingVault public stakingVault;
    uint256 public slashRate = 30;
    uint256 public auditorRewardRate = 10;
    uint256 public constant MINIMUM_STAKE_FOR_SLASH = 10 ether;

    /// @notice M-05 FIX: Cooldown period between slashes on the same agent
    uint256 public slashCooldown = 7 days;

    /// @notice M-05 FIX: Last slash timestamp per agent
    mapping(bytes32 => uint256) public lastSlashTime;

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

    mapping(bytes32 => SlashRecord) public slashRecords;
    mapping(bytes32 => bytes32[]) public agentSlashHistory;

    error NotAuthorizedAuditor();
    error AgentNotFound();
    error AgentNotActive();
    error InsufficientStakeForSlash();
    error InvalidSlashRate();
    error SelfSlashNotAllowed();
    error SlashCooldownActive();
    error InvalidCooldown();

    event SlashingExecuted(
        bytes32 indexed slashId,
        bytes32 indexed agentId,
        address indexed auditorAddress,
        bytes32 evidenceHash,
        uint256 burnAmount,
        uint256 rewardAmount,
        uint256 timestamp
    );
    event SlashRateUpdated(uint256 oldRate, uint256 newRate);
    event AuditorRewardRateUpdated(uint256 oldRate, uint256 newRate);
    event SlashCooldownUpdated(uint256 oldCooldown, uint256 newCooldown);

    modifier onlyRegisteredAuditor() {
        if (!agentRegistry.isAuthorizedAuditor(msg.sender)) revert NotAuthorizedAuditor();
        _;
    }

    /**
     * @dev H-01 FIX: Removed unused third parameter from constructor.
     *      L-04 FIX: Added zero-address checks.
     */
    constructor(address agentRegistryAddress, address stakingVaultAddress) Ownable(msg.sender) {
        require(agentRegistryAddress != address(0), "Invalid agent registry");
        require(stakingVaultAddress != address(0), "Invalid staking vault");
        agentRegistry = IAgentRegistryForSlashing(agentRegistryAddress);
        stakingVault = IStakingVault(stakingVaultAddress);
    }

    /**
     * @notice Execute a slash against a misbehaving agent
     * @dev M-05 FIX: Enforces cooldown between slashes on the same agent.
     *      Prevents a single auditor from draining an agent's entire stake
     *      in rapid succession within the same block/day.
     */
    function executeSlash(
        bytes32 agentId,
        bytes32 evidenceHash
    ) external onlyRegisteredAuditor nonReentrant returns (bytes32 slashId) {
        IAgentRegistryForSlashing.AgentRecord memory auditorAgent = agentRegistry.getAgentByAddress(msg.sender);
        if (auditorAgent.agentId == agentId) revert SelfSlashNotAllowed();

        if (!agentRegistry.isRegistered(agentId)) revert AgentNotFound();

        IAgentRegistryForSlashing.AgentRecord memory targetAgent = agentRegistry.getAgent(agentId);
        if (targetAgent.status != 0) revert AgentNotActive();

        // M-05 FIX: Enforce per-agent cooldown between slashes
        if (lastSlashTime[agentId] > 0 && block.timestamp < lastSlashTime[agentId] + slashCooldown) {
            revert SlashCooldownActive();
        }

        uint256 currentStake = stakingVault.getStake(agentId);
        uint256 burnAmount = (currentStake * slashRate) / 100;
        uint256 rewardAmount = (currentStake * auditorRewardRate) / 100;
        if (
            currentStake < MINIMUM_STAKE_FOR_SLASH
                || burnAmount == 0
                || rewardAmount == 0
                || currentStake < burnAmount + rewardAmount
        ) {
            revert InsufficientStakeForSlash();
        }

        slashId = keccak256(abi.encodePacked(agentId, evidenceHash, block.timestamp, msg.sender));

        slashRecords[slashId] = SlashRecord({
            slashId: slashId,
            agentId: agentId,
            auditorAddress: msg.sender,
            evidenceHash: evidenceHash,
            burnAmount: burnAmount,
            rewardAmount: rewardAmount,
            timestamp: block.timestamp,
            disputed: false
        });
        agentSlashHistory[agentId].push(slashId);

        // M-05 FIX: Record slash time for cooldown
        lastSlashTime[agentId] = block.timestamp;

        stakingVault.slash(agentId, burnAmount, rewardAmount, msg.sender);

        emit SlashingExecuted(
            slashId,
            agentId,
            msg.sender,
            evidenceHash,
            burnAmount,
            rewardAmount,
            block.timestamp
        );
    }

    function setSlashRate(uint256 rate) external onlyOwner {
        if (rate < 1 || rate > 50) revert InvalidSlashRate();

        uint256 oldRate = slashRate;
        slashRate = rate;

        emit SlashRateUpdated(oldRate, rate);
    }

    function setAuditorRewardRate(uint256 rate) external onlyOwner {
        if (rate < 1 || rate > 20) revert InvalidSlashRate();

        uint256 oldRate = auditorRewardRate;
        auditorRewardRate = rate;

        emit AuditorRewardRateUpdated(oldRate, rate);
    }

    /**
     * @notice Update the slash cooldown period
     * @param cooldown New cooldown in seconds (min 1 day, max 30 days)
     */
    function setSlashCooldown(uint256 cooldown) external onlyOwner {
        if (cooldown < 1 days || cooldown > 30 days) revert InvalidCooldown();
        uint256 old = slashCooldown;
        slashCooldown = cooldown;
        emit SlashCooldownUpdated(old, cooldown);
    }

    function getSlashRecord(bytes32 slashId) external view returns (SlashRecord memory) {
        return slashRecords[slashId];
    }

    function getAgentSlashHistory(bytes32 agentId) external view returns (bytes32[] memory) {
        return agentSlashHistory[agentId];
    }
}
