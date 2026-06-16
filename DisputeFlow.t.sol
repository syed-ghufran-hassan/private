// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockMNTY} from "../src/MockMNTY.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {StakingVault} from "../src/StakingVault.sol";
import {SlashingController} from "../src/SlashingController.sol";
import {DisputeResolution} from "../src/DisputeResolution.sol";

contract DisputeFlowTest is Test {
    MockMNTY private mnty;
    AgentRegistry private registry;
    StakingVault private vault;
    SlashingController private slashingController;
    DisputeResolution private disputeResolution;

    address private workerOwner = address(0xA11CE);
    address private auditorOwner = address(0xB0B);
    address private randomUser = address(0xCAFE);

    bytes32 private workerAgentId;
    uint256 private constant DISPUTE_STAKE = 100 ether;

    function setUp() public {
        mnty = new MockMNTY();
        registry = new AgentRegistry();
        vault = new StakingVault(address(mnty), address(registry));
        slashingController = new SlashingController(address(registry), address(vault));
        disputeResolution = new DisputeResolution(
            address(registry),
            address(slashingController),
            address(vault),
            address(mnty),
            3 days
        );
        vault.setSlashingController(address(slashingController));
        vault.setDisputeResolution(address(disputeResolution));

        mnty.mint(workerOwner, 10_000 ether);
        mnty.mint(auditorOwner, 10_000 ether);
        mnty.transferOwnership(address(disputeResolution));

        workerAgentId = registry.registerAgent(workerOwner, AgentRegistry.AgentClass.WORKER, keccak256("worker"));
        registry.registerAgent(auditorOwner, AgentRegistry.AgentClass.AUDITOR, keccak256("auditor"));

        vm.startPrank(workerOwner);
        mnty.approve(address(vault), 1_000 ether);
        vault.deposit(workerAgentId, 1_000 ether);
        vm.stopPrank();
    }

    function test_OpenDispute_Success() public {
        bytes32 slashId = _slash();
        _approveDisputeStake();

        vm.prank(workerOwner);
        bytes32 disputeId = disputeResolution.openDispute(slashId, keccak256("counter"));

        DisputeResolution.Dispute memory dispute = disputeResolution.getDispute(disputeId);
        assertEq(uint256(dispute.status), uint256(DisputeResolution.DisputeStatus.OPEN));
    }

    function test_OpenDispute_Revert_WindowExpired() public {
        bytes32 slashId = _slash();
        _approveDisputeStake();
        vm.warp(block.timestamp + 3 days + 1);

        vm.expectRevert(DisputeResolution.DisputeWindowExpired.selector);
        vm.prank(workerOwner);
        disputeResolution.openDispute(slashId, keccak256("counter"));
    }

    function test_OpenDispute_Revert_AlreadyExists() public {
        bytes32 slashId = _slash();
        _approveDisputeStake();

        vm.prank(workerOwner);
        disputeResolution.openDispute(slashId, keccak256("counter"));

        vm.expectRevert(DisputeResolution.DisputeAlreadyExists.selector);
        vm.prank(workerOwner);
        disputeResolution.openDispute(slashId, keccak256("counter-2"));
    }

    /// @dev Updated for C-05 fix: 2-step resolution (proposeResolution → warp → executeResolution)
    function test_ResolveDispute_Upheld() public {
        bytes32 disputeId = _openDispute();
        uint256 balanceBefore = mnty.balanceOf(workerOwner);

        // Step 1: Owner proposes resolution
        disputeResolution.proposeResolution(disputeId, true, "valid counter evidence");

        // Step 2: Wait for timelock
        vm.warp(block.timestamp + 2 days + 1);

        // Step 3: Anyone can execute
        disputeResolution.executeResolution(disputeId);

        assertEq(vault.getStake(workerAgentId), 1_000 ether);
        assertFalse(vault.isUnderDispute(workerAgentId));
        assertEq(mnty.balanceOf(workerOwner), balanceBefore + DISPUTE_STAKE);
    }

    /// @dev Updated for C-05 fix: 2-step resolution
    function test_ResolveDispute_Overruled() public {
        bytes32 disputeId = _openDispute();
        uint256 totalSupplyBefore = mnty.totalSupply();

        // Step 1: Propose
        disputeResolution.proposeResolution(disputeId, false, "slash stands");

        // Step 2: Wait for timelock
        vm.warp(block.timestamp + 2 days + 1);

        // Step 3: Execute
        disputeResolution.executeResolution(disputeId);

        assertEq(vault.getStake(workerAgentId), 600 ether);
        assertEq(mnty.totalSupply(), totalSupplyBefore - DISPUTE_STAKE);
    }

    /// @dev Updated for C-05 fix: proposeResolution is onlyOwner
    function test_ResolveDispute_Revert_NotOwner() public {
        bytes32 disputeId = _openDispute();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, randomUser));
        vm.prank(randomUser);
        disputeResolution.proposeResolution(disputeId, true, "not owner");
    }

    /// @dev New test: timelock must be respected
    function test_ExecuteResolution_Revert_TimelockNotElapsed() public {
        bytes32 disputeId = _openDispute();

        disputeResolution.proposeResolution(disputeId, true, "valid");

        // Try to execute immediately — should fail
        vm.expectRevert(DisputeResolution.TimelockNotElapsed.selector);
        disputeResolution.executeResolution(disputeId);
    }

    /// @dev New test: owner can cancel a pending resolution
    function test_CancelResolution() public {
        bytes32 disputeId = _openDispute();

        disputeResolution.proposeResolution(disputeId, true, "valid");
        disputeResolution.cancelResolution(disputeId);

        assertFalse(disputeResolution.hasPendingResolution(disputeId));
    }

    function _openDispute() internal returns (bytes32 disputeId) {
        bytes32 slashId = _slash();
        _approveDisputeStake();
        vm.prank(workerOwner);
        disputeId = disputeResolution.openDispute(slashId, keccak256("counter"));
    }

    function _slash() internal returns (bytes32 slashId) {
        vm.prank(auditorOwner);
        slashId = slashingController.executeSlash(workerAgentId, keccak256("evidence"));
    }

    function _approveDisputeStake() internal {
        vm.prank(workerOwner);
        mnty.approve(address(disputeResolution), DISPUTE_STAKE);
    }
}
