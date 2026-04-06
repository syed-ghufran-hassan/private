// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {BaseTestSuite} from "./helpers/BaseTestSuite.t.sol";
import {BountyProgramRegistry} from "../src/BountyProgramRegistry.sol";

/// @notice Unit tests for EscrowVault.
/// @dev Validates deposit splitting and activation requirements.
contract EscrowVaultTest is BaseTestSuite {
    /// @notice Initializes the shared fixture.
    function setUp() public {
        setUpContracts();
        registry.setReportManager(address(reports));
    }

    /// @notice Deposits into a DRAFT program and checks split balances and activation.
    /// @dev Verifies treasury transfer and internal pool accounting.
    function test_DepositSplitsAndActivatesDraft() public {
        uint8[] memory severities = new uint8[](0);
        uint256[] memory payoutsBySeverity = new uint256[](0);
        uint256 programId = createProgram(800, 200, severities, payoutsBySeverity);

        deposit(programId, 1_000_000);

        BountyProgramRegistry.ProgramConfig memory config = registry.getProgram(programId);
        assertEq(uint256(config.status), uint256(BountyProgramRegistry.Status.ACTIVE));
        assertEq(escrow.bountyBalance(programId), 909_090);
        assertEq(escrow.judgeBalance(programId), 72_728);
        assertEq(token.balanceOf(treasury), 18_182);
        assertEq(token.balanceOf(address(escrow)), 981_818);
    }

    /// @notice Requires initial deposit to cover the full payout schedule sum.
    /// @dev Ensures activation does not occur if bounty is insufficient.
    function test_DepositRequiresScheduleCoverageToActivate() public {
        uint8[] memory severities = new uint8[](2);
        uint256[] memory payoutsBySeverity = new uint256[](2);
        severities[0] = 1;
        severities[1] = 2;
        payoutsBySeverity[0] = 1_100_000;
        payoutsBySeverity[1] = 1_100_000;

        uint256 programId = createProgram(800, 200, severities, payoutsBySeverity);

        // Total schedule = 2_200_000; min deposit = 2_200_000 × 11_000 / 10_000 = 2_420_000.
        // 1_000_000 is insufficient → INSUFFICIENT_INITIAL_BOUNTY expected.
        token.mint(company, 1_000_000);
        vm.startPrank(company);
        token.approve(address(escrow), 1_000_000);
        vm.expectRevert("INSUFFICIENT_INITIAL_BOUNTY");
        escrow.deposit(programId, 1_000_000);
        vm.stopPrank();
    }

    /// @notice Only the payout controller can call payoutBounty.
    /// @dev Direct calls from EOA should revert.
    function test_PayoutBountyOnlyController() public {
        uint8[] memory severities = new uint8[](0);
        uint256[] memory payoutsBySeverity = new uint256[](0);
        uint256 programId = createProgram(800, 200, severities, payoutsBySeverity);
        deposit(programId, 1_000_000);

        vm.expectRevert("NOT_PAYOUT_CONTROLLER");
        escrow.payoutBounty(programId, researcher, 10_000);
    }

    /// @notice Direct refund calls are restricted to the registry contract.
    function test_RefundRequiresRegistryCaller() public {
        uint8[] memory severities = new uint8[](0);
        uint256[] memory payoutsBySeverity = new uint256[](0);
        uint256 programId = createProgram(800, 200, severities, payoutsBySeverity);
        deposit(programId, 1_000_000);

        vm.expectRevert("NOT_REGISTRY");
        escrow.refund(programId);
    }

    /// @notice executeRefund requires the 5-day window to pass.
    function test_ExecuteRefundRequiresFiveDayWindow() public {
        uint8[] memory severities = new uint8[](0);
        uint256[] memory payoutsBySeverity = new uint256[](0);
        uint256 programId1 = createProgram(800, 200, severities, payoutsBySeverity);
        deposit(programId1, 1_000_000);

        vm.prank(company);
        registry.initiateRefund(programId1);

        vm.prank(company);
        vm.expectRevert("REFUND_WINDOW_NOT_PASSED");
        registry.executeRefund(programId1);

        vm.warp(block.timestamp + 5 days + 1);
        vm.prank(company);
        registry.executeRefund(programId1);

        uint256 programId2 = createProgram(800, 200, severities, payoutsBySeverity);
        deposit(programId2, 1_000_000);
        vm.prank(company);
        registry.initiateRefund(programId2);
        vm.warp(block.timestamp + 4 days);
        vm.prank(company);
        vm.expectRevert("REFUND_WINDOW_NOT_PASSED");
        registry.executeRefund(programId2);
    }

    /// @notice executeRefund closes the program and sends remaining bounty to the company.
    function test_ExecuteRefundTransfersRemainingBountyToCompany() public {
        uint8[] memory severities = new uint8[](0);
        uint256[] memory payoutsBySeverity = new uint256[](0);
        uint256 programId = createProgram(800, 200, severities, payoutsBySeverity);
        deposit(programId, 1_000_000);

        uint256 companyBefore = token.balanceOf(company);
        uint256 bountyBefore = escrow.getBountyBalance(programId);
        uint256 judgeBefore = escrow.judgeBalance(programId);

        vm.prank(company);
        registry.initiateRefund(programId);
        vm.warp(block.timestamp + 5 days + 1);
        vm.prank(company);
        registry.executeRefund(programId);

        assertEq(token.balanceOf(company), companyBefore + bountyBefore + judgeBefore);
        assertEq(escrow.getBountyBalance(programId), 0);
        assertEq(escrow.judgeBalance(programId), 0);

        BountyProgramRegistry.ProgramConfig memory config = registry.getProgram(programId);
        assertEq(uint256(config.status), uint256(BountyProgramRegistry.Status.CLOSED));
    }

    /// @notice Rejects deposits for closed programs.
    /// @dev Deposit should revert for CLOSED status.
    function test_DepositRejectedWhenClosed() public {
        uint8[] memory severities = new uint8[](0);
        uint256[] memory payoutsBySeverity = new uint256[](0);
        uint256 programId = createProgram(800, 200, severities, payoutsBySeverity);
        deposit(programId, 1_000_000);

        vm.prank(company);
        registry.initiateRefund(programId);
        vm.warp(block.timestamp + 5 days + 1);
        vm.prank(company);
        registry.executeRefund(programId);

        token.mint(company, 1_000_000);
        vm.startPrank(company);
        token.approve(address(escrow), 1_000_000);
        vm.expectRevert("PROGRAM_NOT_DEPOSITABLE");
        escrow.deposit(programId, 1_000_000);
        vm.stopPrank();
    }
}
