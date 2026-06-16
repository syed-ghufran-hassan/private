// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IGovernanceMNTY is IERC20 {}

interface IGovernanceSlashingController {
    function setSlashRate(uint256 rate) external;
    function setAuditorRewardRate(uint256 rate) external;
}

interface IGovernanceAgentRegistry {}

/**
 * @title GovernanceModule
 * @notice On-chain governance for Montty protocol parameter changes
 *
 * AUDIT FIXES APPLIED:
 * - C-03: Token locking during voting to prevent flash-loan governance attacks
 * - H-03: Added minimum proposal threshold (proposalThreshold)
 * - M-06: Only owner can cancel PASSED proposals; proposer can only cancel ACTIVE
 * - L-04: Zero-address checks in constructor
 */
contract GovernanceModule is Ownable, ReentrancyGuard {
    using SafeERC20 for IGovernanceMNTY;

    IGovernanceMNTY public mntyToken;
    IGovernanceSlashingController public slashingController;
    IGovernanceAgentRegistry public agentRegistry;
    uint256 public votingPeriod;
    uint256 public timelockDelay;
    uint256 public quorumBps;
    uint256 public proposalCount;

    /// @notice H-03 FIX: Minimum MNTY balance required to create a proposal
    uint256 public proposalThreshold;

    enum ProposalStatus {
        PENDING,
        ACTIVE,
        PASSED,
        EXECUTED,
        DEFEATED,
        CANCELLED
    }

    enum ProposalType {
        SET_SLASH_RATE,
        SET_AUDITOR_REWARD_RATE,
        SET_VOTING_PERIOD,
        SET_TIMELOCK_DELAY,
        SET_QUORUM_BPS
    }

    struct Proposal {
        uint256 proposalId;
        address proposer;
        ProposalType proposalType;
        uint256 newValue;
        string description;
        uint256 createdAt;
        uint256 votingEndsAt;
        uint256 executionAvailableAt;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 snapshotTotalSupply;
        ProposalStatus status;
        bool executed;
    }

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    /// @dev Also tracks locked token amounts for withdrawal after voting ends (C-03 fix)
    mapping(uint256 => mapping(address => uint256)) public voteWeight;

    error ProposalNotActive();
    error AlreadyVoted();
    error ProposalNotPassed();
    error TimelockNotElapsed();
    error ProposalAlreadyExecuted();
    error ProposalDefeated();
    error InvalidValue();
    error QuorumNotReached();
    error NotProposer();
    error ProposalNotCancellable();
    error InsufficientBalance();
    error NoTokensToWithdraw();
    error VotingStillActive();

    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        ProposalType proposalType,
        uint256 newValue,
        uint256 votingEndsAt
    );
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight);
    event ProposalFinalized(
        uint256 indexed proposalId,
        ProposalStatus status,
        uint256 forVotes,
        uint256 againstVotes
    );
    event ProposalExecuted(uint256 indexed proposalId, uint256 timestamp);
    event ProposalCancelled(uint256 indexed proposalId, uint256 timestamp);
    event VoteTokensWithdrawn(uint256 indexed proposalId, address indexed voter, uint256 amount);
    event ProposalThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);

    constructor(
        address mntyTokenAddress,
        address slashingControllerAddress,
        address agentRegistryAddress,
        uint256 votingPeriod_,
        uint256 timelockDelay_,
        uint256 quorumBps_
    ) Ownable(msg.sender) {
        // L-04 FIX: Zero-address checks
        require(mntyTokenAddress != address(0), "Invalid token address");
        require(slashingControllerAddress != address(0), "Invalid slashing controller");
        require(agentRegistryAddress != address(0), "Invalid agent registry");

        mntyToken = IGovernanceMNTY(mntyTokenAddress);
        slashingController = IGovernanceSlashingController(slashingControllerAddress);
        agentRegistry = IGovernanceAgentRegistry(agentRegistryAddress);
        _validateValue(ProposalType.SET_VOTING_PERIOD, votingPeriod_);
        _validateValue(ProposalType.SET_TIMELOCK_DELAY, timelockDelay_);
        _validateValue(ProposalType.SET_QUORUM_BPS, quorumBps_);
        votingPeriod = votingPeriod_;
        timelockDelay = timelockDelay_;
        quorumBps = quorumBps_;
        proposalThreshold = 1000 ether; // H-03: Default minimum threshold
    }

    /**
     * @notice Create a governance proposal
     * @dev H-03 FIX: Requires proposalThreshold tokens instead of just 1 wei
     */
    function createProposal(
        ProposalType proposalType,
        uint256 newValue,
        string calldata description
    ) external returns (uint256 proposalId) {
        if (mntyToken.balanceOf(msg.sender) < proposalThreshold) revert InsufficientBalance();
        _validateValue(proposalType, newValue);

        proposalId = ++proposalCount;
        uint256 votingEndsAt = block.timestamp + votingPeriod;
        proposals[proposalId] = Proposal({
            proposalId: proposalId,
            proposer: msg.sender,
            proposalType: proposalType,
            newValue: newValue,
            description: description,
            createdAt: block.timestamp,
            votingEndsAt: votingEndsAt,
            executionAvailableAt: 0,
            forVotes: 0,
            againstVotes: 0,
            snapshotTotalSupply: mntyToken.totalSupply(),
            status: ProposalStatus.ACTIVE,
            executed: false
        });

        emit ProposalCreated(proposalId, msg.sender, proposalType, newValue, votingEndsAt);
    }

    /**
     * @notice Cast a vote on an active proposal
     * @param proposalId The proposal to vote on
     * @param support True for yes, false for no
     *
     * @dev C-03 FIX: Tokens are locked (transferred to this contract) during voting.
     *      This prevents flash-loan governance attacks because the tokens cannot be
     *      returned within the same transaction. Voters reclaim tokens after voting
     *      ends via withdrawVoteTokens().
     */
    function castVote(uint256 proposalId, bool support) external nonReentrant {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.status != ProposalStatus.ACTIVE || block.timestamp >= proposal.votingEndsAt) {
            revert ProposalNotActive();
        }
        if (hasVoted[proposalId][msg.sender]) revert AlreadyVoted();

        uint256 weight = mntyToken.balanceOf(msg.sender);
        if (weight == 0) revert InsufficientBalance();

        hasVoted[proposalId][msg.sender] = true;
        voteWeight[proposalId][msg.sender] = weight;

        // C-03 FIX: Lock tokens by transferring them to this contract
        // Voter must have approved this contract beforehand
        mntyToken.safeTransferFrom(msg.sender, address(this), weight);

        if (support) {
            proposal.forVotes += weight;
        } else {
            proposal.againstVotes += weight;
        }

        emit VoteCast(proposalId, msg.sender, support, weight);
    }

    /**
     * @notice Withdraw locked vote tokens after voting period ends
     * @param proposalId The proposal whose vote tokens to withdraw
     *
     * @dev C-03 FIX: Voters reclaim their locked tokens after voting ends.
     */
    function withdrawVoteTokens(uint256 proposalId) external nonReentrant {
        Proposal storage proposal = proposals[proposalId];
        if (block.timestamp < proposal.votingEndsAt) revert VotingStillActive();

        uint256 amount = voteWeight[proposalId][msg.sender];
        if (amount == 0) revert NoTokensToWithdraw();

        voteWeight[proposalId][msg.sender] = 0;
        mntyToken.safeTransfer(msg.sender, amount);

        emit VoteTokensWithdrawn(proposalId, msg.sender, amount);
    }

    function finalizeProposal(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.status != ProposalStatus.ACTIVE) revert ProposalNotActive();
        if (block.timestamp < proposal.votingEndsAt) revert ProposalNotActive();

        uint256 totalVotes = proposal.forVotes + proposal.againstVotes;
        uint256 quorum = (proposal.snapshotTotalSupply * quorumBps) / 10_000;
        if (totalVotes < quorum) {
            proposal.status = ProposalStatus.DEFEATED;
        } else if (proposal.forVotes > proposal.againstVotes) {
            proposal.status = ProposalStatus.PASSED;
            proposal.executionAvailableAt = block.timestamp + timelockDelay;
        } else {
            proposal.status = ProposalStatus.DEFEATED;
        }

        emit ProposalFinalized(proposalId, proposal.status, proposal.forVotes, proposal.againstVotes);
    }

    function executeProposal(uint256 proposalId) external nonReentrant {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.status != ProposalStatus.PASSED) revert ProposalNotPassed();
        if (block.timestamp < proposal.executionAvailableAt) revert TimelockNotElapsed();
        if (proposal.executed) revert ProposalAlreadyExecuted();

        proposal.executed = true;
        proposal.status = ProposalStatus.EXECUTED;

        if (proposal.proposalType == ProposalType.SET_SLASH_RATE) {
            slashingController.setSlashRate(proposal.newValue);
        } else if (proposal.proposalType == ProposalType.SET_AUDITOR_REWARD_RATE) {
            slashingController.setAuditorRewardRate(proposal.newValue);
        } else if (proposal.proposalType == ProposalType.SET_VOTING_PERIOD) {
            votingPeriod = proposal.newValue;
        } else if (proposal.proposalType == ProposalType.SET_TIMELOCK_DELAY) {
            timelockDelay = proposal.newValue;
        } else if (proposal.proposalType == ProposalType.SET_QUORUM_BPS) {
            quorumBps = proposal.newValue;
        }

        emit ProposalExecuted(proposalId, block.timestamp);
    }

    /**
     * @notice Cancel a proposal
     * @dev M-06 FIX: Only the proposer can cancel ACTIVE proposals.
     *      Only the owner (admin) can cancel PASSED proposals during timelock.
     */
    function cancelProposal(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];

        if (proposal.status == ProposalStatus.ACTIVE) {
            // Proposer or owner can cancel active proposals
            if (msg.sender != proposal.proposer && msg.sender != owner()) revert NotProposer();
        } else if (proposal.status == ProposalStatus.PASSED) {
            // Only owner can cancel passed proposals (emergency veto)
            if (msg.sender != owner()) revert NotProposer();
        } else {
            revert ProposalNotCancellable();
        }

        if (proposal.executed) revert ProposalAlreadyExecuted();

        proposal.status = ProposalStatus.CANCELLED;
        emit ProposalCancelled(proposalId, block.timestamp);
    }

    // ============ Admin Functions ============

    /**
     * @notice Update the minimum token balance required to create proposals
     * @param newThreshold The new proposal threshold in MNTY tokens
     */
    function setProposalThreshold(uint256 newThreshold) external onlyOwner {
        require(newThreshold > 0, "Threshold must be > 0");
        uint256 oldThreshold = proposalThreshold;
        proposalThreshold = newThreshold;
        emit ProposalThresholdUpdated(oldThreshold, newThreshold);
    }

    // ============ View Functions ============

    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        return proposals[proposalId];
    }

    function getProposalStatus(uint256 proposalId) external view returns (ProposalStatus) {
        return proposals[proposalId].status;
    }

    function _validateValue(ProposalType proposalType, uint256 newValue) internal pure {
        if (proposalType == ProposalType.SET_SLASH_RATE) {
            if (newValue < 1 || newValue > 50) revert InvalidValue();
        } else if (proposalType == ProposalType.SET_AUDITOR_REWARD_RATE) {
            if (newValue < 1 || newValue > 20) revert InvalidValue();
        } else if (proposalType == ProposalType.SET_VOTING_PERIOD) {
            if (newValue < 1 days || newValue > 30 days) revert InvalidValue();
        } else if (proposalType == ProposalType.SET_TIMELOCK_DELAY) {
            if (newValue < 1 days || newValue > 14 days) revert InvalidValue();
        } else if (proposalType == ProposalType.SET_QUORUM_BPS) {
            if (newValue < 100 || newValue > 5000) revert InvalidValue();
        }
    }
}
