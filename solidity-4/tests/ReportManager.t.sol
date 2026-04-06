// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {BaseTestSuite} from "./helpers/BaseTestSuite.t.sol";
import {ReportManager} from "../src/ReportManager.sol";

/// @notice Unit tests for ReportManager.
/// @dev Verifies report anchoring and stored fields.
contract ReportManagerTest is BaseTestSuite {
    /// @notice Initializes the shared fixture.
    function setUp() public {
        setUpContracts();
        uint8[] memory severities = new uint8[](1);
        uint256[] memory payoutAmounts = new uint256[](1);
        severities[0] = 1;
        payoutAmounts[0] = 1_100_000;
        uint256 programId = createProgram(800, 200, severities, payoutAmounts);
        assertEq(programId, 1);
        deposit(programId, 2_000_000);
    }

    /// @notice Submits a report and checks stored hash and status.
    /// @dev Ensures anchoring records the researcher and hash.
    function test_SubmitReportAnchorsHash() public {
        bytes32 reportHash = keccak256("report");
        bytes32 reportId = reports.submitReport(1, researcher, judge, reportHash);
        ReportManager.Report memory report = reports.getReport(reportId);
        assertEq(report.reportHash, reportHash);
        assertEq(report.researcher, researcher);
        assertEq(uint256(report.status), uint256(ReportManager.Status.SUBMITTED));
    }

    /// @notice Prevents duplicate report submissions with the same reportId.
    /// @dev Second submission should revert with REPORT_EXISTS.
    function test_SubmitReportRejectsDuplicate() public {
        bytes32 reportHash = keccak256("report");
        reports.submitReport(1, researcher, judge, reportHash);
        vm.expectRevert("REPORT_EXISTS");
        reports.submitReport(1, researcher, judge, reportHash);
    }

    /// @notice Restricts markPaid to the payout controller.
    /// @dev Direct calls should revert with NOT_PAYOUT_CONTROLLER.
    function test_MarkPaidOnlyPayoutController() public {
        bytes32 reportHash = keccak256("report");
        bytes32 reportId = reports.submitReport(1, researcher, judge, reportHash);
        vm.expectRevert("NOT_PAYOUT_CONTROLLER");
        reports.markPaid(reportId);
    }

    /// @notice Allows payout controller to approve and then mark paid.
    /// @dev Validates state transitions and stored approval fields.
    function test_MarkApprovedAndPaidByController() public {
        bytes32 reportHash = keccak256("report");
        reports.submitReport(1, researcher, judge, reportHash);
        bytes32 reportId = reports.getReportId(1, researcher, reportHash);

        vm.prank(address(payouts));
        reports.markApprovedPrimary(
            reportId, 1, researcher, reportHash, judge, 2, 123_000, 1_000, block.timestamp + 5 days
        );

        ReportManager.Report memory report = reports.getReport(reportId);
        assertEq(report.researcher, researcher);
        assertEq(report.primaryJudge, judge);
        assertEq(report.primarySeverity, 2);
        assertEq(report.payoutAmount, 123_000);
        assertEq(report.judgeFeeAmount, 1_000);
        assertEq(uint256(report.status), uint256(ReportManager.Status.APPROVED_PRIMARY));

        vm.prank(address(payouts));
        reports.markReadyToPay(reportId);
        vm.prank(address(payouts));
        reports.markPaid(reportId);
        assertEq(uint256(reports.getReportStatus(reportId)), uint256(ReportManager.Status.PAID));
    }

    /// @notice Report IDs are deterministic for the same tuple and unique across tuple changes.
    function test_ReportIdUniquenessAndDeterminism() public view {
        bytes32 reportHash = keccak256("report");
        bytes32 reportId = reports.getReportId(1, researcher, reportHash);

        assertEq(reportId, reports.getReportId(1, researcher, reportHash));
        assertTrue(reportId != reports.getReportId(2, researcher, reportHash));
        assertTrue(reportId != reports.getReportId(1, address(0xD1), reportHash));
        assertTrue(reportId != reports.getReportId(1, researcher, keccak256("report-2")));
    }

    /// @notice Blocking report counts must stay aligned with refund-blocking lifecycle states.
    function test_BlockingReportCountTracksLifecycle() public {
        bytes32 reportHash = keccak256("blocking-report");
        bytes32 reportId = reports.submitReport(1, researcher, judge, reportHash);

        assertEq(reports.blockingReportCount(1), 1);

        vm.prank(address(payouts));
        reports.markApprovedPrimary(
            reportId, 1, researcher, reportHash, judge, 2, 123_000, 1_000, block.timestamp + 5 days
        );
        assertEq(reports.blockingReportCount(1), 1);

        vm.prank(address(payouts));
        reports.markReadyToPay(reportId);
        assertEq(reports.blockingReportCount(1), 1);

        vm.prank(address(payouts));
        reports.markPaid(reportId);
        assertEq(reports.blockingReportCount(1), 0);
    }
}
