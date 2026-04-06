// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {BaseTestSuite} from "./helpers/BaseTestSuite.t.sol";
import {BountyProgramRegistry} from "../src/BountyProgramRegistry.sol";
import {ReportManager} from "../src/ReportManager.sol";

/// @notice End-to-end flow test for the MVP bounty lifecycle.
/// @dev Covers create -> deposit -> approve -> pay -> balances.
contract BountyFlowTest is BaseTestSuite {
    /// @notice Initializes the shared fixture.
    function setUp() public {
        setUpContracts();
    }

    /// @notice Executes a full happy-path bounty flow.
    /// @dev Validates activation, payout transfers, and report status.
    function test_BountyFlow_EndToEnd() public {
        uint8[] memory severities = new uint8[](3);
        uint256[] memory payoutsBySeverity = new uint256[](3);
        severities[0] = 1;
        severities[1] = 2;
        severities[2] = 3;
        payoutsBySeverity[0] = 1_100_000;
        payoutsBySeverity[1] = 2_000_000;
        payoutsBySeverity[2] = 3_000_000;

        uint256 programId = createProgram(800, 200, severities, payoutsBySeverity);

        deposit(programId, 7_000_000);
        BountyProgramRegistry.ProgramConfig memory config = registry.getProgram(programId);
        assertEq(uint256(config.status), uint256(BountyProgramRegistry.Status.ACTIVE));

        bytes32 reportHash = keccak256("report");
        submitReport(programId, researcher, reportHash);

        uint256 researcherBefore = token.balanceOf(researcher);
        uint256 judgeBefore = token.balanceOf(judge);
        uint256 bountyBefore = escrow.bountyBalance(programId);
        uint256 judgePoolBefore = escrow.judgeBalance(programId);

        vm.prank(judge);
        payouts.approvePrimary(programId, 2, researcher, reportHash);
        vm.warp(block.timestamp + 5 days + 1);
        vm.prank(judge);
        payouts.finalizeAndPay(programId, researcher, reportHash, 2, 0);

        bytes32 reportId = reports.getReportId(programId, researcher, reportHash);
        ReportManager.Report memory paidReport = reports.getReport(reportId);
        uint256 expectedJudgeFee = paidReport.judgeFeeAmount;
        assertEq(uint256(reports.getReportStatus(reportId)), uint256(ReportManager.Status.PAID));
        assertEq(token.balanceOf(researcher), researcherBefore + 2_000_000);
        assertEq(token.balanceOf(judge), judgeBefore + expectedJudgeFee);
        assertEq(escrow.bountyBalance(programId), bountyBefore - 2_000_000);
        assertEq(escrow.judgeBalance(programId) + expectedJudgeFee, judgePoolBefore);
    }
}
