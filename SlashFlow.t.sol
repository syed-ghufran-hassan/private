// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockMNTY} from "../src/MockMNTY.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {StakingVault} from "../src/StakingVault.sol";
import {SlashingController} from "../src/SlashingController.sol";

contract SlashFlowTest is Test {
    MockMNTY private mnty;
    AgentRegistry private registry;
    StakingVault private vault;
    SlashingController private slashingController;

    address private workerOwner = address(0xA11CE);
    address private auditorOwner = address(0xB0B);
    address private randomUser = address(0xCAFE);

    bytes32 private workerAgentId;
    bytes32 private auditorAgentId;

    event SlashingExecuted(
        bytes32 indexed slashId,
        bytes32 indexed agentId,
        address indexed auditorAddress,
        bytes32 evidenceHash,
        uint256 burnAmount,
        uint256 rewardAmount,
        uint256 timestamp
    );

    function setUp() public {
        mnty = new MockMNTY();
        registry = new AgentRegistry();
        vault = new StakingVault(address(mnty), address(registry));
        slashingController = new SlashingController(address(registry), address(vault));
        vault.setSlashingController(address(slashingController));

        mnty.mint(workerOwner, 10_000 ether);
        mnty.mint(auditorOwner, 10_000 ether);

        workerAgentId = registry.registerAgent(
            workerOwner,
            AgentRegistry.AgentClass.WORKER,
            keccak256("worker-manifest")
        );
        auditorAgentId = registry.registerAgent(
            auditorOwner,
            AgentRegistry.AgentClass.AUDITOR,
            keccak256("auditor-manifest")
        );
    }

    function test_RegisterAgent() public {
        address newWorker = address(0xD00D);
        bytes32 agentId = registry.registerAgent(
            newWorker,
            AgentRegistry.AgentClass.WORKER,
            keccak256("new-worker-manifest")
        );

        AgentRegistry.AgentRecord memory agent = registry.getAgent(agentId);

        assertTrue(registry.isRegistered(agentId));
        assertEq(uint256(agent.agentClass), uint256(AgentRegistry.AgentClass.WORKER));
        assertEq(agent.ownerAddress, newWorker);
    }

    function test_StakeDeposit() public {
        vm.startPrank(workerOwner);
        mnty.approve(address(vault), 1_000 ether);
        vault.deposit(workerAgentId, 1_000 ether);
        vm.stopPrank();

        assertEq(vault.getStake(workerAgentId), 1_000 ether);
    }

    function test_ExecuteSlash_Success() public {
        vm.startPrank(workerOwner);
        mnty.approve(address(vault), 1_000 ether);
        vault.deposit(workerAgentId, 1_000 ether);
        vm.stopPrank();

        bytes32 evidenceHash = keccak256("worker violation evidence");
        uint256 auditorBalanceBefore = mnty.balanceOf(auditorOwner);
        uint256 totalSupplyBefore = mnty.totalSupply();
        uint256 timestamp = block.timestamp;
        bytes32 expectedSlashId = keccak256(abi.encodePacked(workerAgentId, evidenceHash, timestamp, auditorOwner));

        vm.expectEmit(true, true, true, true, address(slashingController));
        emit SlashingExecuted(
            expectedSlashId,
            workerAgentId,
            auditorOwner,
            evidenceHash,
            300 ether,
            100 ether,
            timestamp
        );

        vm.prank(auditorOwner);
        bytes32 slashId = slashingController.executeSlash(workerAgentId, evidenceHash);

        assertEq(slashId, expectedSlashId);
        assertEq(vault.getStake(workerAgentId), 600 ether);
        assertEq(mnty.balanceOf(auditorOwner), auditorBalanceBefore + 100 ether);
        assertEq(mnty.totalSupply(), totalSupplyBefore - 300 ether);
    }

    function test_ExecuteSlash_Revert_NotAuditor() public {
        vm.expectRevert(SlashingController.NotAuthorizedAuditor.selector);
        vm.prank(randomUser);
        slashingController.executeSlash(workerAgentId, keccak256("evidence"));
    }

    function test_ExecuteSlash_Revert_InsufficientStake() public {
        vm.startPrank(workerOwner);
        mnty.approve(address(vault), 1 ether);
        vault.deposit(workerAgentId, 1 ether);
        vm.stopPrank();

        vm.expectRevert(SlashingController.InsufficientStakeForSlash.selector);
        vm.prank(auditorOwner);
        slashingController.executeSlash(workerAgentId, keccak256("evidence"));
    }

    function test_Withdraw_Revert_WhenUnderDispute() public {
        vm.startPrank(workerOwner);
        mnty.approve(address(vault), 1_000 ether);
        vault.deposit(workerAgentId, 1_000 ether);
        vm.stopPrank();

        vm.prank(auditorOwner);
        slashingController.executeSlash(workerAgentId, keccak256("evidence"));

        vm.expectRevert(StakingVault.StakeUnderDispute.selector);
        vm.prank(workerOwner);
        vault.withdraw(workerAgentId, 1 ether);
    }

    function test_SuspendAgent_BlocksSlash() public {
        registry.suspendAgent(workerAgentId);

        vm.expectRevert(SlashingController.AgentNotActive.selector);
        vm.prank(auditorOwner);
        slashingController.executeSlash(workerAgentId, keccak256("evidence"));
    }

    function test_SetupRegisteredAuditor() public view {
        assertTrue(registry.isRegistered(auditorAgentId));
        assertTrue(registry.isAuthorizedAuditor(auditorOwner));
    }
}
