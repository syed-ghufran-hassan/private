// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {BaseTestSuite} from "./helpers/BaseTestSuite.t.sol";
import {ReportManager} from "../src/ReportManager.sol";

/// @notice Unit tests for PayoutController.
/// @dev Validates judge-only approvals, replay protection, and schedule enforcement.
contract PayoutControllerTest is BaseTestSuite {
    address internal secondJudge = address(0xB1);

    /// @notice Initializes the shared fixture.
    function setUp() public {
        setUpContracts();
    }

    /// @notice Ensures non-judges cannot approve and pay.
    /// @dev Expects NOT_JUDGE revert.
    function test_JudgeOnlyApproval() public {
        uint8[] memory severities = new uint8[](1);
        uint256[] memory payoutsBySeverity = new uint256[](1);
        severities[0] = 2;
        payoutsBySeverity[0] = 1_100_000;
        uint256 programId = createProgram(800, 200, severities, payoutsBySeverity);
        deposit(programId, 2_000_000);

        bytes32 reportHash = keccak256("report");
        submitReport(programId, researcher, reportHash);
        vm.expectRevert("NOT_JUDGE");
        payouts.approvePrimary(programId, 2, researcher, reportHash);
    }

    /// @notice Ensures a report cannot be paid twice.
    /// @dev Second approval should revert with REPORT_NOT_ELIGIBLE.
    function test_ReplayPrevention() public {
        uint8[] memory severities = new uint8[](1);
        uint256[] memory payoutsBySeverity = new uint256[](1);
        severities[0] = 2;
        payoutsBySeverity[0] = 1_100_000;
        uint256 programId = createProgram(800, 200, severities, payoutsBySeverity);
        deposit(programId, 2_000_000);

        bytes32 reportHash = keccak256("report");
        submitReport(programId, researcher, reportHash);
        vm.prank(judge);
        payouts.approvePrimary(programId, 2, researcher, reportHash);

        vm.prank(judge);
        vm.expectRevert("REPORT_NOT_ELIGIBLE");
        payouts.approvePrimary(programId, 2, researcher, reportHash);
    }

    /// @notice Reverts new report submission when program is deactivated after a payout.
    /// @dev After payout, escrow deactivates program to DRAFT and submitReport requires ACTIVE.
    function test_InsufficientBountyReverts() public {
        uint8[] memory severities = new uint8[](1);
        uint256[] memory payoutsBySeverity = new uint256[](1);
        severities[0] = 1;
        payoutsBySeverity[0] = 1_100_000;
        uint256 programId = createProgram(800, 200, severities, payoutsBySeverity);
        deposit(programId, 2_000_000);

        bytes32 reportHash = keccak256("report");
        submitReport(programId, researcher, reportHash);
        vm.prank(judge);
        payouts.approvePrimary(programId, 1, researcher, reportHash);
        vm.warp(block.timestamp + 5 days + 1);
        vm.prank(judge);
        payouts.finalizeAndPay(programId, researcher, reportHash, 1, 0);

        bytes32 reportHash2 = keccak256("report-2");
        vm.expectRevert("PROGRAM_NOT_ACTIVE");
        submitReport(programId, researcher, reportHash2);
    }

    /// @notice Uses the onchain payout schedule for severity tier.
    /// @dev Ensures configured payout is applied and report is marked paid.
    function test_UsesFixedPayoutSchedule() public {
        uint8[] memory severities = new uint8[](1);
        uint256[] memory payoutsBySeverity = new uint256[](1);
        severities[0] = 2;
        payoutsBySeverity[0] = 1_100_000;

        uint256 programId = createProgram(800, 200, severities, payoutsBySeverity);
        deposit(programId, 2_000_000);

        bytes32 reportHash = keccak256("report");
        submitReport(programId, researcher, reportHash);
        vm.prank(judge);
        payouts.approvePrimary(programId, 2, researcher, reportHash);
        vm.warp(block.timestamp + 5 days + 1);
        vm.prank(judge);
        payouts.finalizeAndPay(programId, researcher, reportHash, 2, 0);

        bytes32 reportId = reports.getReportId(programId, researcher, reportHash);
        assertEq(uint256(reports.getReportStatus(reportId)), uint256(ReportManager.Status.PAID));
    }

    /// @notice Requires a schedule to be set before approvals are allowed.
    /// @dev Expects SCHEDULE_REQUIRED revert when none exists.
    function test_RequiresSchedule() public {
        uint8[] memory severities = new uint8[](0);
        uint256[] memory payoutsBySeverity = new uint256[](0);
        uint256 programId = createProgram(800, 200, severities, payoutsBySeverity);
        deposit(programId, 1_000_000);

        bytes32 reportHash = keccak256("report");
        submitReport(programId, researcher, reportHash);
        vm.prank(judge);
        vm.expectRevert("SCHEDULE_REQUIRED");
        payouts.approvePrimary(programId, 2, researcher, reportHash);
    }

    /// @notice Rejects approvals for severities not configured in schedule.
    /// @dev Expects SEVERITY_NOT_CONFIGURED revert.
    function test_RejectsUnconfiguredSeverityWhenScheduleSet() public {
        uint8[] memory severities = new uint8[](1);
        uint256[] memory payoutsBySeverity = new uint256[](1);
        severities[0] = 2;
        payoutsBySeverity[0] = 1_100_000;

        uint256 programId = createProgram(800, 200, severities, payoutsBySeverity);
        deposit(programId, 2_000_000);

        bytes32 reportHash = keccak256("report");
        submitReport(programId, researcher, reportHash);
        vm.prank(judge);
        vm.expectRevert("SEVERITY_NOT_CONFIGURED");
        payouts.approvePrimary(programId, 3, researcher, reportHash);
    }

    /// @notice Fails payout when judge fee exceeds the judge pool.
    /// @dev Expects INSUFFICIENT_JUDGE revert.
    function test_InsufficientJudgeFeeReverts() public {
        uint8[] memory severities = new uint8[](1);
        uint256[] memory payoutsBySeverity = new uint256[](1);
        severities[0] = 1;
        payoutsBySeverity[0] = 1_100_000;

        uint256 programId = createProgram(800, 200, severities, payoutsBySeverity);
        deposit(programId, 2_000_000);

        bytes32 reportHash = keccak256("report");
        submitReport(programId, researcher, reportHash);
        vm.prank(judge);
        payouts.approvePrimary(programId, 1, researcher, reportHash);
    }

    /// @notice Verifies balances after happy-path finalization.
    /// @dev Confirms researcher gets bounty and primary judge gets report judge fee.
    function test_BalancesAfterHappyPathPayout() public {
        uint256 programId = _createStandardProgram();
        deposit(programId, 15_000_000);

        bytes32 reportHash = keccak256("balance-happy-path");
        bytes32 reportId = submitReport(programId, researcher, reportHash);

        vm.prank(judge);
        payouts.approvePrimary(programId, 2, researcher, reportHash);

        ReportManager.Report memory report = reports.getReport(reportId);
        uint256 researcherBefore = token.balanceOf(researcher);
        uint256 primaryBefore = token.balanceOf(judge);

        vm.warp(block.timestamp + 5 days + 1);
        vm.prank(judge);
        payouts.finalizeAndPay(programId, researcher, reportHash, 2, 0);

        assertEq(token.balanceOf(researcher), researcherBefore + report.payoutAmount);
        assertEq(token.balanceOf(judge), primaryBefore + report.judgeFeeAmount);
        assertEq(uint256(reports.getReportStatus(reportId)), uint256(ReportManager.Status.PAID));
    }

    /// @notice Verifies balances after second-opinion confirm flow.
    /// @dev Confirm path splits judge fee 80/20 between primary and secondary judge.
    function test_BalancesAfterSecondOpinionConfirm() public {
        uint256 programId = _createStandardProgram();
        deposit(programId, 15_000_000);

        bytes32 reportHash = keccak256("balance-second-confirm");
        bytes32 reportId = _approveAndAssignSecond(programId, reportHash, 3);

        vm.prank(secondJudge);
        payouts.approveSecondOpinion(programId, researcher, reportHash, 3, 0);

        ReportManager.Report memory report = reports.getReport(reportId);
        uint256 researcherBefore = token.balanceOf(researcher);
        uint256 primaryBefore = token.balanceOf(judge);
        uint256 secondaryBefore = token.balanceOf(secondJudge);

        vm.warp(block.timestamp + 5 days + 1);
        vm.prank(secondJudge);
        payouts.finalizeAndPay(programId, researcher, reportHash, 3, 0);

        uint256 expectedPrimaryFee = (report.judgeFeeAmount * 8_000) / 10_000;
        uint256 expectedSecondaryFee = report.judgeFeeAmount - expectedPrimaryFee;
        assertEq(token.balanceOf(researcher), researcherBefore + report.payoutAmount);
        assertEq(token.balanceOf(judge), primaryBefore + expectedPrimaryFee);
        assertEq(token.balanceOf(secondJudge), secondaryBefore + expectedSecondaryFee);
    }

    /// @notice Verifies balances after second-opinion downgrade flow.
    /// @dev Researcher receives downgraded payout and judge fee is split 20/80 primary/secondary.
    function test_BalancesAfterSecondOpinionDowngrade() public {
        uint256 programId = _createStandardProgram();
        deposit(programId, 15_000_000);

        bytes32 reportHash = keccak256("balance-second-downgrade");
        bytes32 reportId = _approveAndAssignSecond(programId, reportHash, 3);

        vm.prank(secondJudge);
        payouts.approveSecondOpinion(programId, researcher, reportHash, 2, 1);

        ReportManager.Report memory report = reports.getReport(reportId);
        uint256 researcherBefore = token.balanceOf(researcher);
        uint256 primaryBefore = token.balanceOf(judge);
        uint256 secondaryBefore = token.balanceOf(secondJudge);

        vm.warp(block.timestamp + 5 days + 1);
        vm.prank(secondJudge);
        payouts.finalizeAndPay(programId, researcher, reportHash, 2, 0);

        uint256 expectedPrimaryFee = (report.judgeFeeAmount * 2_000) / 10_000;
        uint256 expectedSecondaryFee = report.judgeFeeAmount - expectedPrimaryFee;
        assertEq(token.balanceOf(researcher), researcherBefore + report.payoutAmount);
        assertEq(token.balanceOf(judge), primaryBefore + expectedPrimaryFee);
        assertEq(token.balanceOf(secondJudge), secondaryBefore + expectedSecondaryFee);
        assertEq(report.payoutAmount, 2_200_000);
    }

    /// @notice Verifies second-opinion invalidation behavior.
    /// @dev outcome=2 invalidates the report, pays the secondary judge for their work,
    /// @dev and permanently blocks payout finalization.
    function test_BalancesAfterSecondOpinionInvalidate() public {
        uint256 programId = _createStandardProgram();
        deposit(programId, 15_000_000);

        bytes32 reportHash = keccak256("balance-second-invalidate");
        bytes32 reportId = _approveAndAssignSecond(programId, reportHash, 2);

        uint256 researcherBefore = token.balanceOf(researcher);
        uint256 primaryBefore = token.balanceOf(judge);
        uint256 secondaryBefore = token.balanceOf(secondJudge);

        // Secondary judge fee = payout(severity=2) * judgeFeeBps / 10_000 = 200_000 * 800 / 10_000
        uint256 expectedSecondaryFee = (registry.payoutBySeverity(programId, 2) * 800) / 10_000;

        vm.prank(secondJudge);
        payouts.approveSecondOpinion(programId, researcher, reportHash, 0, 2);

        assertEq(uint256(reports.getReportStatus(reportId)), uint256(ReportManager.Status.SECOND_OPINION_REJECTED));
        vm.warp(block.timestamp + 5 days + 1);
        vm.prank(secondJudge);
        vm.expectRevert("REPORT_NOT_FINALIZABLE");
        payouts.finalizeAndPay(programId, researcher, reportHash, 0, 2);
        assertEq(token.balanceOf(researcher), researcherBefore);
        assertEq(token.balanceOf(judge), primaryBefore);
        assertEq(token.balanceOf(secondJudge), secondaryBefore + expectedSecondaryFee);
    }

    /// @notice Verifies current rejected escalation behavior.
    /// @dev outcome=1 causes finalizeAndPay to revert with REPORT_ESCLATED_REJECTED.
    function test_BalancesAfterEscalationRejectedOutcome() public {
        uint256 programId = _createStandardProgram();
        deposit(programId, 15_000_000);

        bytes32 reportHash = keccak256("balance-escalation-rejected");
        bytes32 reportId = _submitAndApprovePrimary(programId, reportHash, 2);

        uint8 upgradedSeverity = 4;
        vm.prank(researcher);
        payouts.escalateReport(programId, upgradedSeverity, researcher, reportHash);
        reports.assignSecondJudge(reportId, secondJudge);

        uint256 researcherBefore = token.balanceOf(researcher);
        uint256 primaryBefore = token.balanceOf(judge);
        uint256 secondaryBefore = token.balanceOf(secondJudge);

        vm.prank(secondJudge);
        payouts.finalizeEscalation(programId, researcher, reportHash, 0, 1);
        vm.warp(block.timestamp + 5 days + 1);
        vm.prank(secondJudge);
        vm.expectRevert("REPORT_NOT_FINALIZABLE");
        payouts.finalizeAndPay(programId, researcher, reportHash, 0, 1);

        assertEq(token.balanceOf(researcher), researcherBefore);
        assertEq(token.balanceOf(judge), primaryBefore);
        assertEq(token.balanceOf(secondJudge), secondaryBefore);
    }

    /// @notice Verifies balances for escalation-upgrade outcome.
    /// @dev Escalation percentage is removed from researcher payout and split across treasury/judges.
    function test_BalancesAfterEscalationUpgrade() public {
        uint256 programId = _createStandardProgram();
        deposit(programId, 55_000_000);

        bytes32 reportHash = keccak256("balance-escalation-upgrade");
        bytes32 reportId = _submitAndApprovePrimary(programId, reportHash, 2);

        uint8 upgradedSeverity = 4;
        vm.prank(researcher);
        payouts.escalateReport(programId, upgradedSeverity, researcher, reportHash);
        reports.assignSecondJudge(reportId, secondJudge);

        uint256 researcherBefore = token.balanceOf(researcher);
        uint256 primaryBefore = token.balanceOf(judge);
        uint256 secondaryBefore = token.balanceOf(secondJudge);
        uint256 treasuryBefore = token.balanceOf(treasury);

        vm.prank(secondJudge);
        payouts.finalizeEscalation(programId, researcher, reportHash, upgradedSeverity, 0);
        ReportManager.Report memory report = reports.getReport(reportId);

        vm.warp(block.timestamp + 5 days + 1);
        vm.prank(secondJudge);
        payouts.finalizeAndPay(programId, researcher, reportHash, upgradedSeverity, 0);

        uint256 upgradedPayout = registry.payoutBySeverity(programId, upgradedSeverity);
        uint256 escalationAmount = (upgradedPayout * 3_000) / 10_000;
        uint256 expectedResearcher = upgradedPayout - escalationAmount;
        uint256 expectedTreasuryEscalation = (escalationAmount * 2_000) / 10_000;
        uint256 judgeEscalationPool = escalationAmount - expectedTreasuryEscalation;
        uint256 expectedPrimaryEscalation = (judgeEscalationPool * 2_000) / 10_000;
        uint256 expectedSecondaryEscalation = judgeEscalationPool - expectedPrimaryEscalation;
        uint256 expectedPrimaryBaseFee = (report.judgeFeeAmount * (10_000 - report.judgePenaltyBps)) / 10_000;
        uint256 expectedSecondaryBaseFee = report.judgeFeeAmount - expectedPrimaryBaseFee;

        assertEq(token.balanceOf(researcher), researcherBefore + expectedResearcher);
        assertEq(token.balanceOf(judge), primaryBefore + expectedPrimaryBaseFee + expectedPrimaryEscalation);
        assertEq(token.balanceOf(secondJudge), secondaryBefore + expectedSecondaryBaseFee + expectedSecondaryEscalation);
        assertEq(token.balanceOf(treasury), treasuryBefore + expectedTreasuryEscalation);
    }

    /// @notice Primary approval must set timelock end to approval time plus configured duration.
    function test_ApprovePrimary_UsesDurationBasedTimelock() public {
        uint256 programId = _createStandardProgram();
        deposit(programId, 15_000_000);

        bytes32 reportHash = keccak256("duration-based-timelock");
        bytes32 reportId = submitReport(programId, researcher, reportHash);

        vm.warp(block.timestamp + 3 days);
        uint256 approvalTime = block.timestamp;

        vm.prank(judge);
        payouts.approvePrimary(programId, 2, researcher, reportHash);

        ReportManager.Report memory report = reports.getReport(reportId);
        assertEq(report.approvedAt, approvalTime);
        assertEq(report.timelockEnd, approvalTime + payouts.TIMELOCK());
    }

    /// @notice Creates a standard 4-tier payout schedule for balance-oriented tests.
    /// @dev Tiers: 1=1.1M, 2=2.2M, 3=3.3M, 4=4.4M.
    /// @return programId Newly created program id.
    function _createStandardProgram() internal returns (uint256 programId) {
        uint8[] memory severities = new uint8[](4);
        uint256[] memory payoutsBySeverity = new uint256[](4);
        severities[0] = 1;
        severities[1] = 2;
        severities[2] = 3;
        severities[3] = 4;
        payoutsBySeverity[0] = 1_100_000;
        payoutsBySeverity[1] = 2_200_000;
        payoutsBySeverity[2] = 3_300_000;
        payoutsBySeverity[3] = 4_400_000;
        programId = createProgram(800, 200, severities, payoutsBySeverity);
    }

    /// @notice Submits a report and processes primary approval as the assigned judge.
    /// @param programId Program under test.
    /// @param reportHash Unique report hash anchor.
    /// @param severity Approved primary severity.
    /// @return reportId Deterministic report id.
    function _submitAndApprovePrimary(uint256 programId, bytes32 reportHash, uint8 severity)
        internal
        returns (bytes32 reportId)
    {
        reportId = submitReport(programId, researcher, reportHash);
        vm.prank(judge);
        payouts.approvePrimary(programId, severity, researcher, reportHash);
    }

    /// @notice Moves report into second-opinion state and assigns secondary judge.
    /// @param programId Program under test.
    /// @param reportHash Unique report hash anchor.
    /// @param severity Primary severity used before second-opinion.
    /// @return reportId Deterministic report id.
    function _approveAndAssignSecond(uint256 programId, bytes32 reportHash, uint8 severity)
        internal
        returns (bytes32 reportId)
    {
        reportId = _submitAndApprovePrimary(programId, reportHash, severity);
        vm.prank(company);
        payouts.requestSecondOpinion(programId, researcher, reportHash);
        reports.assignSecondJudge(reportId, secondJudge);
    }
}
