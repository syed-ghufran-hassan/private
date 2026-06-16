// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockMNTY} from "../src/MockMNTY.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {StakingVault} from "../src/StakingVault.sol";
import {SlashingController} from "../src/SlashingController.sol";
import {GovernanceModule} from "../src/GovernanceModule.sol";

contract GovernanceFlowTest is Test {
    MockMNTY private mnty;
    AgentRegistry private registry;
    StakingVault private vault;
    SlashingController private slashingController;
    GovernanceModule private governance;

    address private proposer = address(0xA11CE);
    address private voterOne = address(0xB0B);
    address private voterTwo = address(0xCAFE);

    uint256 private constant VOTING_PERIOD = 3 days;
    uint256 private constant TIMELOCK_DELAY = 2 days;

    function setUp() public {
        mnty = new MockMNTY();
        registry = new AgentRegistry();
        vault = new StakingVault(address(mnty), address(registry));
        slashingController = new SlashingController(address(registry), address(vault));
        governance = new GovernanceModule(
            address(mnty),
            address(slashingController),
            address(registry),
            VOTING_PERIOD,
            TIMELOCK_DELAY,
            500
        );
        vault.setSlashingController(address(slashingController));
        slashingController.transferOwnership(address(governance));
    }

    function test_CreateProposal_Success() public {
        // H-03: Now requires proposalThreshold (1000 MNTY by default)
        mnty.mint(proposer, 1_000 ether);

        vm.prank(proposer);
        uint256 proposalId = governance.createProposal(
            GovernanceModule.ProposalType.SET_SLASH_RATE,
            25,
            "Set slash rate to 25"
        );

        GovernanceModule.Proposal memory proposal = governance.getProposal(proposalId);
        assertEq(uint256(proposal.status), uint256(GovernanceModule.ProposalStatus.ACTIVE));
        assertEq(proposal.votingEndsAt, block.timestamp + VOTING_PERIOD);
    }

    /// @dev C-03 FIX: Voters must approve governance contract before voting (token locking)
    function test_CastVote_Success() public {
        uint256 proposalId = _createProposal();
        mnty.mint(voterOne, 100 ether);
        mnty.mint(voterTwo, 250 ether);

        // C-03: Voters must approve governance contract for token locking
        vm.prank(voterOne);
        mnty.approve(address(governance), 100 ether);
        vm.prank(voterOne);
        governance.castVote(proposalId, true);

        vm.prank(voterTwo);
        mnty.approve(address(governance), 250 ether);
        vm.prank(voterTwo);
        governance.castVote(proposalId, true);

        GovernanceModule.Proposal memory proposal = governance.getProposal(proposalId);
        assertEq(proposal.forVotes, 350 ether);

        // Verify tokens are locked in governance contract
        assertEq(mnty.balanceOf(voterOne), 0);
        assertEq(mnty.balanceOf(voterTwo), 0);
    }

    function test_FinalizeProposal_Passed() public {
        uint256 proposalId = _createProposal();
        mnty.mint(voterOne, 1_000_000 ether);

        _approveAndVote(voterOne, proposalId, true);
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        uint256 finalizedAt = block.timestamp;
        governance.finalizeProposal(proposalId);

        GovernanceModule.Proposal memory proposal = governance.getProposal(proposalId);
        assertEq(uint256(proposal.status), uint256(GovernanceModule.ProposalStatus.PASSED));
        assertEq(proposal.executionAvailableAt, finalizedAt + TIMELOCK_DELAY);
    }

    function test_FinalizeProposal_Defeated_QuorumNotMet() public {
        uint256 proposalId = _createProposal();
        mnty.mint(voterOne, 1 ether);

        _approveAndVote(voterOne, proposalId, true);
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        governance.finalizeProposal(proposalId);

        assertEq(
            uint256(governance.getProposalStatus(proposalId)),
            uint256(GovernanceModule.ProposalStatus.DEFEATED)
        );
    }

    function test_ExecuteProposal_Success() public {
        uint256 proposalId = _createProposal();
        mnty.mint(voterOne, 1_000_000 ether);

        _approveAndVote(voterOne, proposalId, true);
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        governance.finalizeProposal(proposalId);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        governance.executeProposal(proposalId);

        assertEq(slashingController.slashRate(), 25);
    }

    function test_ExecuteProposal_Revert_TimelockNotElapsed() public {
        uint256 proposalId = _createProposal();
        mnty.mint(voterOne, 1_000_000 ether);

        _approveAndVote(voterOne, proposalId, true);
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        governance.finalizeProposal(proposalId);

        vm.expectRevert(GovernanceModule.TimelockNotElapsed.selector);
        governance.executeProposal(proposalId);
    }

    function test_CastVote_Revert_AlreadyVoted() public {
        uint256 proposalId = _createProposal();
        mnty.mint(voterOne, 100 ether);

        _approveAndVote(voterOne, proposalId, true);

        vm.expectRevert(GovernanceModule.AlreadyVoted.selector);
        vm.prank(voterOne);
        governance.castVote(proposalId, true);
    }

    /// @dev C-03: Test that voters can withdraw tokens after voting ends
    function test_WithdrawVoteTokens() public {
        uint256 proposalId = _createProposal();
        mnty.mint(voterOne, 500 ether);

        _approveAndVote(voterOne, proposalId, true);
        assertEq(mnty.balanceOf(voterOne), 0); // tokens locked

        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        vm.prank(voterOne);
        governance.withdrawVoteTokens(proposalId);
        assertEq(mnty.balanceOf(voterOne), 500 ether); // tokens returned
    }

    /// @dev C-03: Test that tokens cannot be withdrawn during voting
    function test_WithdrawVoteTokens_Revert_VotingStillActive() public {
        uint256 proposalId = _createProposal();
        mnty.mint(voterOne, 500 ether);

        _approveAndVote(voterOne, proposalId, true);

        vm.expectRevert(GovernanceModule.VotingStillActive.selector);
        vm.prank(voterOne);
        governance.withdrawVoteTokens(proposalId);
    }

    // ============ Helpers ============

    function _createProposal() internal returns (uint256 proposalId) {
        // H-03: proposalThreshold is 1000 MNTY
        mnty.mint(proposer, 1_000 ether);
        vm.prank(proposer);
        proposalId = governance.createProposal(
            GovernanceModule.ProposalType.SET_SLASH_RATE,
            25,
            "Set slash rate to 25"
        );
    }

    /// @dev Helper: approve tokens and cast vote in one flow
    function _approveAndVote(address voter, uint256 proposalId, bool support) internal {
        uint256 balance = mnty.balanceOf(voter);
        vm.startPrank(voter);
        mnty.approve(address(governance), balance);
        governance.castVote(proposalId, support);
        vm.stopPrank();
    }
}
