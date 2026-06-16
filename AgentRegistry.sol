// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title AgentRegistry
 * @notice Manages registration and lifecycle of AI agents in the Montty protocol
 *
 * AUDIT FIXES APPLIED:
 * - H-04: reactivateAgent() now only allows reactivation of SUSPENDED agents (not DEREGISTERED)
 * - M-01: Agent ID generation uses incrementing counter + abi.encode (not abi.encodePacked)
 * - L-05: Added paginated getter for allAgentIds
 */
contract AgentRegistry is Ownable {
    enum AgentClass {
        WORKER,
        AUDITOR,
        SANITIZER
    }

    enum AgentStatus {
        ACTIVE,
        SUSPENDED,
        DEREGISTERED
    }

    struct AgentRecord {
        bytes32 agentId;
        AgentClass agentClass;
        bytes32 manifestHash;
        address ownerAddress;
        address authorizedSafe;
        uint256 registeredAt;
        AgentStatus status;
    }

    mapping(bytes32 => AgentRecord) private agents;
    mapping(address => bytes32) private addressToAgentId;
    bytes32[] private allAgentIds;

    /// @notice M-01 FIX: Incrementing counter for deterministic, collision-free agent IDs
    uint256 private agentCounter;

    error NotOwner();
    error AgentAlreadyRegistered();
    error AgentNotFound();
    error AgentNotActive();
    error NotAnAuditor();
    /// @notice H-04 FIX: New error for invalid reactivation attempts
    error AgentNotSuspended();

    event AgentRegistered(
        bytes32 indexed agentId,
        AgentClass agentClass,
        address agentAddress,
        bytes32 manifestHash,
        uint256 timestamp
    );
    event AgentSuspended(bytes32 indexed agentId, uint256 timestamp);
    event AgentReactivated(bytes32 indexed agentId, uint256 timestamp);

    constructor() Ownable(msg.sender) {}

    function _checkOwner() internal view override {
        if (msg.sender != owner()) revert NotOwner();
    }

    /**
     * @notice Register a new agent
     * @dev M-01 FIX: Uses incrementing counter + abi.encode for collision-resistant IDs.
     *      abi.encode prevents hash collisions from packed variable-length encoding.
     */
    function registerAgent(
        address agentAddress,
        AgentClass agentClass,
        bytes32 manifestHash
    ) external onlyOwner returns (bytes32 agentId) {
        if (addressToAgentId[agentAddress] != bytes32(0))
            revert AgentAlreadyRegistered();

        agentCounter++;
        agentId = keccak256(
            abi.encode(agentAddress, manifestHash, agentCounter)
        );
        if (agents[agentId].registeredAt != 0) revert AgentAlreadyRegistered();

        agents[agentId] = AgentRecord({
            agentId: agentId,
            agentClass: agentClass,
            manifestHash: manifestHash,
            ownerAddress: agentAddress,
            authorizedSafe: address(0),
            registeredAt: block.timestamp,
            status: AgentStatus.ACTIVE
        });
        addressToAgentId[agentAddress] = agentId;
        allAgentIds.push(agentId);

        emit AgentRegistered(
            agentId,
            agentClass,
            agentAddress,
            manifestHash,
            block.timestamp
        );
    }

    function getAgent(
        bytes32 agentId
    ) external view returns (AgentRecord memory) {
        AgentRecord memory agent = agents[agentId];
        if (agent.registeredAt == 0) revert AgentNotFound();
        return agent;
    }

    function isRegistered(bytes32 agentId) external view returns (bool) {
        return agents[agentId].registeredAt != 0;
    }

    function isAuthorizedAuditor(address addr) external view returns (bool) {
        bytes32 agentId = addressToAgentId[addr];
        if (agentId == bytes32(0)) return false;

        AgentRecord memory agent = agents[agentId];
        return
            agent.status == AgentStatus.ACTIVE &&
            agent.agentClass == AgentClass.AUDITOR;
    }

    function getAgentByAddress(
        address addr
    ) external view returns (AgentRecord memory) {
        bytes32 agentId = addressToAgentId[addr];
        if (agentId == bytes32(0)) revert AgentNotFound();

        AgentRecord memory agent = agents[agentId];
        if (agent.registeredAt == 0) revert AgentNotFound();
        return agent;
    }

    function suspendAgent(bytes32 agentId) external onlyOwner {
        AgentRecord storage agent = agents[agentId];
        if (agent.registeredAt == 0) revert AgentNotFound();
        if (agent.status != AgentStatus.ACTIVE) revert AgentNotActive();

        agent.status = AgentStatus.SUSPENDED;
        emit AgentSuspended(agentId, block.timestamp);
    }

    /**
     * @notice Reactivate a suspended agent
     * @dev H-04 FIX: Only SUSPENDED agents can be reactivated. DEREGISTERED agents
     *      cannot be brought back — this was a critical state machine violation.
     */
    function reactivateAgent(bytes32 agentId) external onlyOwner {
        AgentRecord storage agent = agents[agentId];
        if (agent.registeredAt == 0) revert AgentNotFound();
        if (agent.status != AgentStatus.SUSPENDED) revert AgentNotSuspended();

        agent.status = AgentStatus.ACTIVE;
        emit AgentReactivated(agentId, block.timestamp);
    }

    // ============ View Functions ============

    /// @notice L-05 FIX: Get total number of registered agents
    function getAgentCount() external view returns (uint256) {
        return allAgentIds.length;
    }

    /// @notice L-05 FIX: Paginated getter for agent IDs (prevents unbounded gas)
    function getAgentIds(uint256 offset, uint256 limit) external view returns (bytes32[] memory) {
        uint256 end = offset + limit;
        if (end > allAgentIds.length) end = allAgentIds.length;
        if (offset >= allAgentIds.length) {
            return new bytes32[](0);
        }

        bytes32[] memory result = new bytes32[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = allAgentIds[i];
        }
        return result;
    }
}
