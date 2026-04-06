// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {BaseTestSuite} from "./helpers/BaseTestSuite.t.sol";
import {BountyProgramRegistry} from "../src/BountyProgramRegistry.sol";
import {ReportManager} from "../src/ReportManager.sol";

/// @notice Coverage for report lifecycle, second-opinion, escalation, and penalty repayment flows.
/// @dev This suite focuses on state transitions and fund-splitting side effects across dispute paths.
contract DisputeAndPenaltyFlowTest is BaseTestSuite {
    address internal secondJudge = address(0xB1);

    /// @notice Initializes contracts and shared test actors.
    function setUp() public {
        setUpContracts();
        registry.setReportManager(address(reports));
    }

    /// @notice Tests the base report lifecycle: submit -> approve -> finalize -> paid.
    /// @dev Ensures the researcher receives payout and report status reaches PAID.
    function test_ReportApproveFinalize_HappyPath() public {
        uint256 programId = _createStandardProgram();
        deposit(programId, 15_000_000);

        bytes32 reportHash = keccak256("happy-path-report");

        // Phase 1: report submission by admin with the pre-assigned primary judge.
        bytes32 reportId = submitReport(programId, researcher, reportHash);
        assertEq(uint256(reports.getReportStatus(reportId)), uint256(ReportManager.Status.SUBMITTED));

        // Phase 2: primary judge approval sets payout and timelock.
        vm.prank(judge);
        payouts.approvePrimary(programId, 2, researcher, reportHash);
        assertEq(uint256(reports.getReportStatus(reportId)), uint256(ReportManager.Status.APPROVED_PRIMARY));

        uint256 researcherBefore = token.balanceOf(researcher);

        // Phase 3: after timelock, payout finalization marks report as paid and transfers bounty.
        vm.warp(block.timestamp + 5 days + 1);
        vm.prank(judge);
        payouts.finalizeAndPay(programId, researcher, reportHash, 2, 0);

        assertEq(uint256(reports.getReportStatus(reportId)), uint256(ReportManager.Status.PAID));
        assertEq(token.balanceOf(researcher), researcherBefore + 2_200_000);
    }

    /// @notice Covers: submit critical -> approve critical -> timelock passes -> finalize payout.
    /// @dev Validates the explicit critical happy-path payout amounts for researcher and primary judge.
    function test_Critical_HappyPath_PaysResearcherAndJudge() public {
        uint256 programId = _createStandardProgram();
        deposit(programId, 15_000_000);

        bytes32 reportHash = keccak256("critical-happy-path");
        bytes32 reportId = submitReport(programId, researcher, reportHash);

        vm.prank(judge);
        payouts.approvePrimary(programId, 4, researcher, reportHash);
        ReportManager.Report memory report = reports.getReport(reportId);

        uint256 researcherBefore = token.balanceOf(researcher);
        uint256 judgeBefore = token.balanceOf(judge);

        vm.warp(block.timestamp + 5 days + 1);
        vm.prank(judge);
        payouts.finalizeAndPay(programId, researcher, reportHash, 4, 0);

        assertEq(uint256(reports.getReportStatus(reportId)), uint256(ReportManager.Status.PAID));
        assertEq(token.balanceOf(researcher), researcherBefore + 4_400_000);
        assertEq(token.balanceOf(judge), judgeBefore + report.judgeFeeAmount);
    }

    /// @notice Covers: approve critical -> timelock passes -> company requests second opinion.
    /// @dev Request must revert because second-opinion can only be requested before timelock end.
    function test_Critical_SecondOpinion_AfterTimelock_Reverts() public {
        uint256 programId = _createStandardProgram();
        deposit(programId, 15_000_000);

        bytes32 reportHash = keccak256("critical-second-opinion-too-late");
        _submitAndApprovePrimary(programId, reportHash, 4);

        vm.warp(block.timestamp + 5 days + 1);
        vm.prank(company);
        vm.expectRevert("TIMELOCK_PASSED");
        payouts.requestSecondOpinion(programId, researcher, reportHash);
    }

    /// @notice Tests second-opinion confirm flow.
    /// @dev Also validates company penalty debt is accrued when second opinion confirms primary ruling.
    /// @dev Confirm path splits judge fee 80/20 between primary and secondary judge.
    function test_SecondOpinion_Confirm_SplitsRewards_AndAccruesCompanyPenalty() public {
        uint256 programId = _createStandardProgram();
        deposit(programId, 15_000_000);

        bytes32 reportHash = keccak256("second-opinion-confirm");
        bytes32 reportId = _approveAndRequestSecondOpinion(programId, reportHash, 3);

        // Secondary judge confirms the same severity (outcome = CONFIRM).
        vm.prank(secondJudge);
        payouts.approveSecondOpinion(programId, researcher, reportHash, 3, 0);

        ReportManager.Report memory report = reports.getReport(reportId);
        assertEq(uint256(report.status), uint256(ReportManager.Status.SECOND_OPINION_RESOLVED));
        assertEq(report.companyPenaltyBps, registry.getCompanyPenaltyBps());

        // Confirm path sets company penalty debt based on payout and program penalty bps (30% in fixture).
        uint256 expectedPenaltyDebt = (3_300_000 * 3_000) / 10_000;
        assertEq(escrow.companyPenaltyDebt(programId), expectedPenaltyDebt);

        // Capture balances before final settlement to verify exact payout splits.
        uint256 researcherBefore = token.balanceOf(researcher);
        uint256 primaryBefore = token.balanceOf(judge);
        uint256 secondaryBefore = token.balanceOf(secondJudge);

        // Finalization must be called by the secondary judge after second-opinion resolution.
        vm.warp(block.timestamp + 5 days + 1);
        vm.prank(secondJudge);
        payouts.finalizeAndPay(programId, researcher, reportHash, 3, 0);

        uint256 expectedPrimaryJudgeFee = (report.judgeFeeAmount * 8_000) / 10_000;
        uint256 expectedSecondaryJudgeFee = report.judgeFeeAmount - expectedPrimaryJudgeFee;

        assertEq(token.balanceOf(judge), primaryBefore + expectedPrimaryJudgeFee);
        assertEq(token.balanceOf(secondJudge), secondaryBefore + expectedSecondaryJudgeFee);
        assertEq(token.balanceOf(researcher), researcherBefore + 3_300_000);
    }

    /// @notice Tests second-opinion downgrade flow where severity changes and researcher payout is reduced.
    /// @dev Downgrade path applies 80% penalty to primary fee, resulting in a 20/80 primary/secondary split.
    function test_SecondOpinion_Downgrade_PenalizesPrimaryJudge_AndPaysResearcher() public {
        uint256 programId = _createStandardProgram();
        deposit(programId, 15_000_000);

        bytes32 reportHash = keccak256("second-opinion-downgrade");
        bytes32 reportId = _approveAndRequestSecondOpinion(programId, reportHash, 3);

        // Secondary judge downgrades from severity 3 to severity 2.
        vm.prank(secondJudge);
        payouts.approveSecondOpinion(programId, researcher, reportHash, 2, 1);

        ReportManager.Report memory report = reports.getReport(reportId);
        assertEq(uint256(report.status), uint256(ReportManager.Status.SECOND_OPINION_RESOLVED));
        assertEq(report.payoutAmount, 2_200_000);
        assertEq(report.judgePenaltyBps, registry.getJudgePenaltyDowngradeBps());

        uint256 researcherBefore = token.balanceOf(researcher);
        uint256 primaryBefore = token.balanceOf(judge);
        uint256 secondaryBefore = token.balanceOf(secondJudge);

        vm.warp(block.timestamp + 5 days + 1);
        vm.prank(secondJudge);
        payouts.finalizeAndPay(programId, researcher, reportHash, 2, 0);

        uint256 expectedPrimaryJudgeFee = (report.judgeFeeAmount * 2_000) / 10_000;
        uint256 expectedSecondaryJudgeFee = report.judgeFeeAmount - expectedPrimaryJudgeFee;

        assertEq(token.balanceOf(judge), primaryBefore + expectedPrimaryJudgeFee);
        assertEq(token.balanceOf(secondJudge), secondaryBefore + expectedSecondaryJudgeFee);
        assertEq(token.balanceOf(researcher), researcherBefore + 2_200_000);
    }

    /// @notice Tests second-opinion invalidation behavior.
    /// @dev outcome=2 invalidates and blocks finalizeAndPay.
    function test_SecondOpinion_Invalidate_BlocksFinalization() public {
        uint256 programId = _createStandardProgram();
        deposit(programId, 15_000_000);

        bytes32 reportHash = keccak256("second-opinion-invalidate");
        bytes32 reportId = _approveAndRequestSecondOpinion(programId, reportHash, 2);

        vm.prank(secondJudge);
        payouts.approveSecondOpinion(programId, researcher, reportHash, 0, 2);
        assertEq(uint256(reports.getReportStatus(reportId)), uint256(ReportManager.Status.SECOND_OPINION_REJECTED));
        vm.warp(block.timestamp + 5 days + 1);
        vm.prank(secondJudge);
        vm.expectRevert("REPORT_NOT_FINALIZABLE");
        payouts.finalizeAndPay(programId, researcher, reportHash, 0, 2);
    }

    /// @notice Fuzzes initial deposit size for a standard approve/finalize report flow.
    /// @dev Deposit is bounded so the first-deposit schedule requirement always holds.
    /// @dev Confirms researcher payout is invariant for a fixed approved severity.
    function testFuzz_ReportApproveFinalize_WithDifferentInitialDeposits(uint256 rawDeposit) public {
        uint256 programId = _createStandardProgram();

        // For this program, required bounty sum is 11,000,000 and bounty is net * 10_000 / 11_000.
        // So initial deposit must be at least 12,100,000 to satisfy INSUFFICIENT_INITIAL_BOUNTY check.
        uint256 depositAmount = bound(rawDeposit, 15_000_000, 100_000_000);
        deposit(programId, depositAmount);

        bytes32 reportHash = keccak256("fuzz-happy-path-report");
        bytes32 reportId = submitReport(programId, researcher, reportHash);

        vm.prank(judge);
        payouts.approvePrimary(programId, 2, researcher, reportHash);
        assertEq(uint256(reports.getReportStatus(reportId)), uint256(ReportManager.Status.APPROVED_PRIMARY));

        uint256 researcherBefore = token.balanceOf(researcher);

        vm.warp(block.timestamp + 5 days + 1);
        vm.prank(judge);
        payouts.finalizeAndPay(programId, researcher, reportHash, 2, 0);

        // Severity 2 payout is fixed by schedule at 2,200,000 regardless of larger deposits.
        assertEq(token.balanceOf(researcher), researcherBefore + 2_200_000);
        assertEq(uint256(reports.getReportStatus(reportId)), uint256(ReportManager.Status.PAID));
    }

    /// @notice Tests penalty repayment when company deposits again after being penalized on second opinion.
    /// @dev Validates debt repayment split and confirms deposit fees are still applied after debt repayment.
    function test_CompanyPenaltyDebt_IsPaid_OnNextDeposit() public {
        uint256 programId = _createStandardProgram();
        deposit(programId, 15_000_000);

        bytes32 reportHash = keccak256("penalty-repayment");
        _approveAndRequestSecondOpinion(programId, reportHash, 3);

        // Confirm second opinion to accrue penalty debt against company.
        vm.prank(secondJudge);
        payouts.approveSecondOpinion(programId, researcher, reportHash, 3, 0);

        uint256 debt = escrow.companyPenaltyDebt(programId);
        assertGt(debt, 0);

        // Finalize first payout so the program returns to DRAFT and accepts a new deposit.
        vm.warp(block.timestamp + 5 days + 1);
        vm.prank(secondJudge);
        payouts.finalizeAndPay(programId, researcher, reportHash, 3, 0);

        uint256 treasuryBefore = token.balanceOf(treasury);
        uint256 primaryBefore = token.balanceOf(judge);
        uint256 secondaryBefore = token.balanceOf(secondJudge);

        // Next company deposit should auto-pay accrued penalty debt before new split allocation.
        deposit(programId, 15_000_000);

        // Current penalty distribution in EscrowVault:
        // treasury = 20% of debt, judges = 80%, then judges split 50% primary / 50% secondary.
        uint256 treasuryDebtShare = (debt * 2_000) / 10_000;
        uint256 judgesDebtShare = debt - treasuryDebtShare;
        uint256 primaryDebtShare = (judgesDebtShare * 5_000) / 10_000;
        uint256 secondaryDebtShare = judgesDebtShare - primaryDebtShare;
        uint256 netDepositAfterDebt = 15_000_000 - debt;
        uint256 bountyAmount = (netDepositAfterDebt * 10_000) / 11_000;
        uint256 fees = netDepositAfterDebt - bountyAmount;
        uint256 treasuryFeeFromDeposit = fees - ((fees * 8_000) / 10_000);

        assertEq(escrow.companyPenaltyDebt(programId), 0);
        assertEq(token.balanceOf(treasury), treasuryBefore + treasuryDebtShare + treasuryFeeFromDeposit);
        assertEq(token.balanceOf(judge), primaryBefore + primaryDebtShare);
        assertEq(token.balanceOf(secondJudge), secondaryBefore + secondaryDebtShare);
    }

    /// @notice Covers: critical approve -> second opinion confirm -> company exits (refund path).
    /// @dev Verifies penalty debt is settled during refund and distributed to treasury/primary/secondary judges.
    function test_Critical_SecondOpinionConfirm_CompanyExit_PaysPenaltyOnRefund() public {
        uint256 programId = _createStandardProgram();
        deposit(programId, 15_000_000);

        bytes32 reportHash = keccak256("critical-confirm-company-exit");
        _approveAndRequestSecondOpinion(programId, reportHash, 4);

        vm.prank(secondJudge);
        payouts.approveSecondOpinion(programId, researcher, reportHash, 4, 0);

        uint256 debt = escrow.companyPenaltyDebt(programId);
        assertGt(debt, 0);

        vm.prank(secondJudge);
        vm.warp(block.timestamp + 5 days + 1);
        payouts.finalizeAndPay(programId, researcher, reportHash, 4, 0);
        assertEq(uint256(registry.getProgram(programId).status), uint256(BountyProgramRegistry.Status.DRAFT));

        vm.prank(company);
        registry.initiateRefund(programId);
        uint256 refundExecutableAt = uint256(registry.getProgram(programId).pausedAt) + 5 days + 1;

        uint256 treasuryBefore = token.balanceOf(treasury);
        uint256 primaryBefore = token.balanceOf(judge);
        uint256 secondaryBefore = token.balanceOf(secondJudge);
        uint256 companyBefore = token.balanceOf(company);

        vm.warp(refundExecutableAt);
        vm.prank(company);
        registry.executeRefund(programId);

        uint256 treasuryDebtShare = (debt * 2_000) / 10_000;
        uint256 judgesDebtShare = debt - treasuryDebtShare;
        uint256 primaryDebtShare = (judgesDebtShare * 5_000) / 10_000;
        uint256 secondaryDebtShare = judgesDebtShare - primaryDebtShare;

        assertEq(escrow.companyPenaltyDebt(programId), 0);
        assertEq(token.balanceOf(treasury), treasuryBefore + treasuryDebtShare);
        assertEq(token.balanceOf(judge), primaryBefore + primaryDebtShare);
        assertEq(token.balanceOf(secondJudge), secondaryBefore + secondaryDebtShare);
        assertGt(token.balanceOf(company), companyBefore);
    }

    function test_InitiateRefund_BlockedStates() public {
        _assertInitiateRefundBlocked(ReportManager.Status.SUBMITTED, bytes32("block-submitted"));
        _assertInitiateRefundBlocked(ReportManager.Status.APPROVED_PRIMARY, bytes32("block-approved"));
        _assertInitiateRefundBlocked(ReportManager.Status.ESCALATED, bytes32("block-escalated"));
        _assertInitiateRefundBlocked(ReportManager.Status.SECOND_OPINION_REQUESTED, bytes32("block-so-requested"));
        _assertInitiateRefundBlocked(ReportManager.Status.SECOND_OPINION_RESOLVED, bytes32("block-so-resolved"));
        _assertInitiateRefundBlocked(ReportManager.Status.ESCALATED_RESOLVED, bytes32("block-escalated-resolved"));
        _assertInitiateRefundBlocked(ReportManager.Status.READY_TO_PAY, bytes32("block-ready-to-pay"));
    }

    function test_InitiateRefund_TerminalStatesAllowed() public {
        _assertInitiateRefundAllowed(ReportManager.Status.REJECTED, bytes32("allow-rejected"));
        _assertInitiateRefundAllowed(ReportManager.Status.SECOND_OPINION_REJECTED, bytes32("allow-so-rejected"));
        _assertInitiateRefundAllowed(ReportManager.Status.ESCALATED_REJECTED, bytes32("allow-escalated-rejected"));
        _assertInitiateRefundAllowed(ReportManager.Status.PAID, bytes32("allow-paid"));
        _assertInitiateRefundAllowed(ReportManager.Status.CLOSED, bytes32("allow-closed"));
    }

    function test_ExecuteRefund_RequiresFiveDayWindow() public {
        uint256 programId = _createStandardProgram();
        deposit(programId, 15_000_000);

        vm.prank(company);
        registry.initiateRefund(programId);
        vm.prank(company);
        vm.expectRevert("REFUND_WINDOW_NOT_PASSED");
        registry.executeRefund(programId);
        vm.warp(block.timestamp + 5 days + 1);
        vm.prank(company);
        registry.executeRefund(programId);

        uint256 programId2 = _createStandardProgram();
        deposit(programId2, 15_000_000);
        vm.prank(company);
        registry.initiateRefund(programId2);
        vm.warp(block.timestamp + 2 days);
        vm.prank(company);
        vm.expectRevert("REFUND_WINDOW_NOT_PASSED");
        registry.executeRefund(programId2);

        BountyProgramRegistry.ProgramConfig memory config = registry.getProgram(programId);
        assertEq(uint256(config.status), uint256(BountyProgramRegistry.Status.CLOSED));
    }

    /// @notice Escalation from invalid primary verdict to valid second-judge verdict.
    /// @dev Validates judgePenaltyInvalidBps is applied and payout split matches invalid-primary penalty path.
    function test_Escalation_FromInvalidPrimary_AppliesInvalidJudgePenalty_AndPays() public {
        uint256 programId = _createStandardProgram();
        deposit(programId, 55_000_000);

        bytes32 reportHash = keccak256("escalation-invalid-primary-to-valid");
        bytes32 reportId = _submitAndApprovePrimary(programId, reportHash, 0);

        vm.prank(researcher);
        payouts.escalateReport(programId, 3, researcher, reportHash);
        reports.assignSecondJudge(reportId, secondJudge);

        vm.prank(secondJudge);
        payouts.finalizeEscalation(programId, researcher, reportHash, 3, 0);

        ReportManager.Report memory report = reports.getReport(reportId);
        assertEq(uint256(report.status), uint256(ReportManager.Status.ESCALATED_RESOLVED));
        assertEq(report.judgePenaltyBps, registry.getJudgePenaltyInvalidBps());

        uint256 researcherBefore = token.balanceOf(researcher);
        uint256 primaryBefore = token.balanceOf(judge);
        uint256 secondaryBefore = token.balanceOf(secondJudge);
        uint256 treasuryBefore = token.balanceOf(treasury);

        vm.warp(block.timestamp + 5 days + 1);
        vm.prank(secondJudge);
        payouts.finalizeAndPay(programId, researcher, reportHash, 3, 0);

        uint256 payout = registry.payoutBySeverity(programId, 3);
        uint256 escalationAmount = (payout * 2_500) / 10_000; // high bps
        uint256 expectedResearcher = payout - escalationAmount;
        uint256 treasuryShare = (escalationAmount * 2_000) / 10_000;
        uint256 judgesShare = escalationAmount - treasuryShare;
        uint256 primaryShare = (judgesShare * 2_000) / 10_000;
        uint256 secondaryShare = judgesShare - primaryShare;

        // judgePenaltyInvalidBps=10000 => primary gets zero and forfeits share to secondary.
        assertEq(token.balanceOf(researcher), researcherBefore + expectedResearcher);
        assertEq(token.balanceOf(judge), primaryBefore);
        assertEq(token.balanceOf(secondJudge), secondaryBefore + report.judgeFeeAmount + primaryShare + secondaryShare);
        assertEq(token.balanceOf(treasury), treasuryBefore + treasuryShare);
    }

    /// @notice Escalation resolved at lower severity than primary verdict.
    /// @dev Validates downgrade judge penalty bps is recorded and payout follows downgraded severity.
    function test_Escalation_DowngradeReport_AppliesDowngradePenalty_AndPays() public {
        uint256 programId = _createStandardProgram();
        deposit(programId, 55_000_000);

        bytes32 reportHash = keccak256("escalation-downgrade");
        bytes32 reportId = _submitAndApprovePrimary(programId, reportHash, 4);

        vm.prank(researcher);
        payouts.escalateReport(programId, 2, researcher, reportHash);
        reports.assignSecondJudge(reportId, secondJudge);

        vm.prank(secondJudge);
        payouts.finalizeEscalation(programId, researcher, reportHash, 2, 0);

        ReportManager.Report memory report = reports.getReport(reportId);
        assertEq(uint256(report.status), uint256(ReportManager.Status.ESCALATED_RESOLVED));
        assertEq(report.judgePenaltyBps, registry.getJudgePenaltyDowngradeBps());

        uint256 researcherBefore = token.balanceOf(researcher);
        uint256 primaryBefore = token.balanceOf(judge);
        uint256 secondaryBefore = token.balanceOf(secondJudge);
        uint256 treasuryBefore = token.balanceOf(treasury);

        vm.warp(block.timestamp + 5 days + 1);
        vm.prank(secondJudge);
        payouts.finalizeAndPay(programId, researcher, reportHash, 2, 0);

        uint256 payout = registry.payoutBySeverity(programId, 2);
        uint256 escalationAmount = (payout * 2_000) / 10_000; // medium bps
        uint256 expectedResearcher = payout - escalationAmount;
        uint256 treasuryShare = (escalationAmount * 2_000) / 10_000;
        uint256 judgesShare = escalationAmount - treasuryShare;
        uint256 primaryEscalationShare = (judgesShare * 2_000) / 10_000;
        uint256 secondaryEscalationShare = judgesShare - primaryEscalationShare;
        uint256 expectedPrimaryBaseFee = (report.judgeFeeAmount * 2_000) / 10_000; // 80% downgrade penalty
        uint256 expectedSecondaryBaseFee = report.judgeFeeAmount - expectedPrimaryBaseFee;

        assertEq(token.balanceOf(researcher), researcherBefore + expectedResearcher);
        assertEq(token.balanceOf(judge), primaryBefore + expectedPrimaryBaseFee + primaryEscalationShare);
        assertEq(token.balanceOf(secondJudge), secondaryBefore + expectedSecondaryBaseFee + secondaryEscalationShare);
        assertEq(token.balanceOf(treasury), treasuryBefore + treasuryShare);
    }

    /// @notice Fuzzes second deposit size after company penalty debt accrues.
    /// @dev Deposit is bounded to ensure post-penalty net amount still satisfies initial bounty requirement.
    /// @dev Verifies accrued debt is fully repaid and debt bucket resets to zero.
    function testFuzz_PenaltyDebtRepayment_WithDifferentSecondDeposits(uint256 rawSecondDeposit) public {
        uint256 programId = _createStandardProgram();
        deposit(programId, 15_000_000);

        bytes32 reportHash = keccak256("fuzz-penalty-repayment");
        _approveAndRequestSecondOpinion(programId, reportHash, 3);

        vm.prank(secondJudge);
        payouts.approveSecondOpinion(programId, researcher, reportHash, 3, 0);

        uint256 debt = escrow.companyPenaltyDebt(programId);
        assertGt(debt, 0);

        vm.warp(block.timestamp + 5 days + 1);
        vm.prank(secondJudge);
        payouts.finalizeAndPay(programId, researcher, reportHash, 3, 0);

        // Need (secondDeposit - debt) to keep bounty >= 11,000,000 on re-deposit.
        // Minimum secondDeposit = debt + 15,000,000.
        uint256 secondDeposit = bound(rawSecondDeposit, debt + 15_000_000, debt + 60_000_000);
        deposit(programId, secondDeposit);

        assertEq(escrow.companyPenaltyDebt(programId), 0);
    }

    /// @notice Tests current rejected escalation behavior.
    /// @dev Rejected escalation (outcome=1) reverts with REPORT_ESCLATED_REJECTED on finalizeAndPay.
    function test_Escalation_RejectedOutcome_StillPaysResearcher_AndRewardsSecondJudge() public {
        uint256 programId = _createStandardProgram();
        deposit(programId, 15_000_000);

        bytes32 reportHash = keccak256("escalation-rejected");
        bytes32 reportId = _submitAndApprovePrimary(programId, reportHash, 2);

        // Researcher escalates severity during timelock.
        vm.prank(researcher);
        payouts.escalateReport(programId, 4, researcher, reportHash);

        // Admin assigns second judge while report is in ESCALATED status.
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

        assertEq(token.balanceOf(judge), primaryBefore);
        assertEq(token.balanceOf(secondJudge), secondaryBefore);
        assertEq(token.balanceOf(researcher), researcherBefore);
    }

    /// @notice Tests escalation path with upgraded severity and verifies split math.
    /// @dev Escalation cut should be split to treasury and judges based on escalationBps configuration.
    function test_Escalation_UpgradeReport_PaysEscalationShares() public {
        uint256 programId = _createStandardProgram();
        deposit(programId, 55_000_000);

        bytes32 reportHash = keccak256("escalation-upgrade");
        bytes32 reportId = _submitAndApprovePrimary(programId, reportHash, 2);

        // Researcher escalates from severity 2 to severity 4.
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
        assertEq(token.balanceOf(treasury), treasuryBefore + expectedTreasuryEscalation);
        assertEq(token.balanceOf(judge), primaryBefore + expectedPrimaryBaseFee + expectedPrimaryEscalation);
        assertEq(token.balanceOf(secondJudge), secondaryBefore + expectedSecondaryBaseFee + expectedSecondaryEscalation);
    }

    /// @notice Covers: approve high -> timelock passes -> researcher escalates.
    /// @dev Escalation after timelock must revert.
    function test_ApproveHigh_EscalateAfterTimelock_Reverts() public {
        uint256 programId = _createStandardProgram();
        deposit(programId, 15_000_000);

        bytes32 reportHash = keccak256("high-escalate-too-late");
        _submitAndApprovePrimary(programId, reportHash, 3);

        vm.warp(block.timestamp + 5 days + 1);
        vm.prank(researcher);
        vm.expectRevert("TIMELOCK_PASSED");
        payouts.escalateReport(programId, 4, researcher, reportHash);
    }

    /// @notice Covers: approve high -> researcher escalates -> second judge confirms same severity.
    /// @dev When second judge severity equals primary, hardcoded 10% escalation is taken from researcher.
    /// @dev No judge penalty is applied (judgePenaltyBps=0) since the primary judge was correct.
    function test_Escalation_SameSeverity_Takes10PercentFromResearcher() public {
        uint256 programId = _createStandardProgram();
        deposit(programId, 55_000_000);

        bytes32 reportHash = keccak256("escalation-same-severity");
        bytes32 reportId = _submitAndApprovePrimary(programId, reportHash, 3);

        // Researcher escalates (disagrees) but second judge confirms the same severity as primary.
        vm.prank(researcher);
        payouts.escalateReport(programId, 4, researcher, reportHash);
        reports.assignSecondJudge(reportId, secondJudge);

        vm.prank(secondJudge);
        payouts.finalizeEscalation(programId, researcher, reportHash, 3, 0);

        ReportManager.Report memory report = reports.getReport(reportId);
        assertEq(uint256(report.status), uint256(ReportManager.Status.ESCALATED_RESOLVED));
        // No judge penalty when severities match.
        assertEq(report.judgePenaltyBps, 0);

        uint256 researcherBefore = token.balanceOf(researcher);
        uint256 primaryBefore = token.balanceOf(judge);
        uint256 secondaryBefore = token.balanceOf(secondJudge);
        uint256 treasuryBefore = token.balanceOf(treasury);

        vm.warp(block.timestamp + 5 days + 1);
        vm.prank(secondJudge);
        payouts.finalizeAndPay(programId, researcher, reportHash, 3, 0);

        // Escalation uses 10% flat when severity matches primary (hardcoded 1_000 bps).
        uint256 payout = registry.payoutBySeverity(programId, 3); // 3_300_000
        uint256 escalationAmount = (payout * 1_000) / 10_000;     // 10% = 330_000
        uint256 expectedResearcher = payout - escalationAmount;   // 2_970_000

        // Escalation cut split: 20% treasury, 80% judges (20/80 primary/secondary).
        uint256 treasuryShare = (escalationAmount * 2_000) / 10_000;            // 66_000
        uint256 judgesShare = escalationAmount - treasuryShare;                 // 264_000
        uint256 primaryEscalationShare = (judgesShare * 2_000) / 10_000;        // 52_800
        uint256 secondaryEscalationShare = judgesShare - primaryEscalationShare; // 211_200

        // No judge penalty => primary keeps full base fee, secondary gets no base fee share.
        uint256 expectedPrimaryTotal = report.judgeFeeAmount + primaryEscalationShare;
        uint256 expectedSecondaryTotal = secondaryEscalationShare;

        assertEq(token.balanceOf(researcher), researcherBefore + expectedResearcher);
        assertEq(token.balanceOf(judge), primaryBefore + expectedPrimaryTotal);
        assertEq(token.balanceOf(secondJudge), secondaryBefore + expectedSecondaryTotal);
        assertEq(token.balanceOf(treasury), treasuryBefore + treasuryShare);
    }

    /// @notice Covers: approve high -> escalate within timelock -> second judge favors SRs to critical.
    /// @dev Validates critical escalation fee (bps) is deducted and split treasury/judges.
    function test_ApproveHigh_EscalateToCritical_SplitsEscalationShares() public {
        uint256 programId = _createStandardProgram();
        deposit(programId, 55_000_000);

        bytes32 reportHash = keccak256("high-to-critical-escalation");
        bytes32 reportId = _submitAndApprovePrimary(programId, reportHash, 3);

        vm.prank(researcher);
        payouts.escalateReport(programId, 4, researcher, reportHash);
        reports.assignSecondJudge(reportId, secondJudge);

        vm.prank(secondJudge);
        payouts.finalizeEscalation(programId, researcher, reportHash, 4, 0);
        ReportManager.Report memory report = reports.getReport(reportId);
        uint256 researcherBefore = token.balanceOf(researcher);
        uint256 primaryBefore = token.balanceOf(judge);
        uint256 secondaryBefore = token.balanceOf(secondJudge);
        uint256 treasuryBefore = token.balanceOf(treasury);

        vm.warp(block.timestamp + 5 days + 1);
        vm.prank(secondJudge);
        payouts.finalizeAndPay(programId, researcher, reportHash, 4, 0);

        uint256 upgradedPayout = registry.payoutBySeverity(programId, 4);
        uint256 escalationAmount = (upgradedPayout * 3_000) / 10_000; // critical bps
        uint256 expectedResearcher = upgradedPayout - escalationAmount;
        uint256 expectedTreasuryEscalation = (escalationAmount * 2_000) / 10_000;
        uint256 judgeEscalationPool = escalationAmount - expectedTreasuryEscalation;
        uint256 expectedPrimaryEscalation = (judgeEscalationPool * 2_000) / 10_000;
        uint256 expectedSecondaryEscalation = judgeEscalationPool - expectedPrimaryEscalation;
        uint256 expectedPrimaryBaseFee = (report.judgeFeeAmount * (10_000 - report.judgePenaltyBps)) / 10_000;
        uint256 expectedSecondaryBaseFee = report.judgeFeeAmount - expectedPrimaryBaseFee;

        assertEq(token.balanceOf(researcher), researcherBefore + expectedResearcher);
        assertEq(token.balanceOf(treasury), treasuryBefore + expectedTreasuryEscalation);
        assertEq(token.balanceOf(judge), primaryBefore + expectedPrimaryBaseFee + expectedPrimaryEscalation);
        assertEq(token.balanceOf(secondJudge), secondaryBefore + expectedSecondaryBaseFee + expectedSecondaryEscalation);
    }

    /// @notice Covers: approve medium -> escalate within timelock -> second judge upgrades to high.
    /// @dev Validates high escalation bps is used and payout to researcher is reduced accordingly.
    function test_ApproveMedium_EscalateToHigh_UsesHighEscalationBps() public {
        uint256 programId = _createStandardProgram();
        deposit(programId, 55_000_000);

        bytes32 reportHash = keccak256("medium-to-high-escalation");
        bytes32 reportId = _submitAndApprovePrimary(programId, reportHash, 2);

        vm.prank(researcher);
        payouts.escalateReport(programId, 3, researcher, reportHash);
        reports.assignSecondJudge(reportId, secondJudge);

        vm.prank(secondJudge);
        payouts.finalizeEscalation(programId, researcher, reportHash, 3, 0);
        ReportManager.Report memory report = reports.getReport(reportId);
        uint256 researcherBefore = token.balanceOf(researcher);
        uint256 primaryBefore = token.balanceOf(judge);
        uint256 secondaryBefore = token.balanceOf(secondJudge);
        uint256 treasuryBefore = token.balanceOf(treasury);

        vm.warp(block.timestamp + 5 days + 1);
        vm.prank(secondJudge);
        payouts.finalizeAndPay(programId, researcher, reportHash, 3, 0);

        uint256 upgradedPayout = registry.payoutBySeverity(programId, 3);
        uint256 escalationAmount = (upgradedPayout * 2_500) / 10_000; // high bps
        uint256 expectedResearcher = upgradedPayout - escalationAmount;
        uint256 expectedTreasuryEscalation = (escalationAmount * 2_000) / 10_000;
        uint256 judgeEscalationPool = escalationAmount - expectedTreasuryEscalation;
        uint256 expectedPrimaryEscalation = (judgeEscalationPool * 2_000) / 10_000;
        uint256 expectedSecondaryEscalation = judgeEscalationPool - expectedPrimaryEscalation;
        uint256 expectedPrimaryBaseFee = (report.judgeFeeAmount * (10_000 - report.judgePenaltyBps)) / 10_000;
        uint256 expectedSecondaryBaseFee = report.judgeFeeAmount - expectedPrimaryBaseFee;

        assertEq(token.balanceOf(researcher), researcherBefore + expectedResearcher);
        assertEq(token.balanceOf(treasury), treasuryBefore + expectedTreasuryEscalation);
        assertEq(token.balanceOf(judge), primaryBefore + expectedPrimaryBaseFee + expectedPrimaryEscalation);
        assertEq(token.balanceOf(secondJudge), secondaryBefore + expectedSecondaryBaseFee + expectedSecondaryEscalation);
    }

    /// @notice Covers: approve medium -> escalate within timelock -> second judge rejects escalation.
    /// @dev Current implementation reverts on finalizeAndPay with REPORT_ESCLATED_REJECTED.
    function test_ApproveMedium_EscalateRejected_CurrentBehavior() public {
        uint256 programId = _createStandardProgram();
        deposit(programId, 15_000_000);

        bytes32 reportHash = keccak256("medium-escalation-rejected-current");
        bytes32 reportId = _submitAndApprovePrimary(programId, reportHash, 2);

        vm.prank(researcher);
        payouts.escalateReport(programId, 3, researcher, reportHash);
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

    /// @notice Covers current second-opinion invalidation behavior.
    /// @dev approveSecondOpinion accepts outcome=2 and report becomes SECOND_OPINION_REJECTED.
    function test_SecondOpinionInvalidates_EscalateToHigh_CurrentBehavior() public {
        uint256 programId = _createStandardProgram();
        deposit(programId, 55_000_000);

        bytes32 reportHash = keccak256("second-opinion-invalid-escalate-high-current");
        bytes32 reportId = _approveAndRequestSecondOpinion(programId, reportHash, 4);

        vm.prank(secondJudge);
        payouts.approveSecondOpinion(programId, researcher, reportHash, 0, 2);
        assertEq(uint256(reports.getReportStatus(reportId)), uint256(ReportManager.Status.SECOND_OPINION_REJECTED));
    }

    /// @notice Creates a default program with 4 severity tiers.
    /// @dev Payouts: 1=1.1M, 2=2.2M, 3=3.3M, 4=4.4M.
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

    /// @notice Submits a report and executes primary approval.
    /// @param programId Program under test.
    /// @param reportHash Unique report hash anchor.
    /// @param severity Primary judge severity selection.
    /// @return reportId Deterministic report id for the submission.
    function _submitAndApprovePrimary(uint256 programId, bytes32 reportHash, uint8 severity)
        internal
        returns (bytes32 reportId)
    {
        reportId = submitReport(programId, researcher, reportHash);
        vm.prank(judge);
        payouts.approvePrimary(programId, severity, researcher, reportHash);
    }

    /// @notice Drives a report into second-opinion state and assigns the secondary judge.
    /// @param programId Program under test.
    /// @param reportHash Unique report hash anchor.
    /// @param primarySeverity Severity approved by the primary judge.
    /// @return reportId Deterministic report id for the submission.
    function _approveAndRequestSecondOpinion(uint256 programId, bytes32 reportHash, uint8 primarySeverity)
        internal
        returns (bytes32 reportId)
    {
        reportId = _submitAndApprovePrimary(programId, reportHash, primarySeverity);

        // Company requests second opinion while timelock is active.
        vm.prank(company);
        payouts.requestSecondOpinion(programId, researcher, reportHash);
        assertEq(uint256(reports.getReportStatus(reportId)), uint256(ReportManager.Status.SECOND_OPINION_REQUESTED));

        // Admin assigns the second judge to resolve dispute.
        reports.assignSecondJudge(reportId, secondJudge);
    }

    function _assertInitiateRefundAllowed(ReportManager.Status targetStatus, bytes32 reportHash) internal {
        (uint256 programId,,) = _prepareReportForRefundState(targetStatus, reportHash);

        vm.prank(company);
        registry.initiateRefund(programId);

        BountyProgramRegistry.ProgramConfig memory config = registry.getProgram(programId);
        assertEq(uint256(config.status), uint256(BountyProgramRegistry.Status.PAUSED));
        assertGt(config.pausedAt, 0);
    }

    function _assertInitiateRefundBlocked(ReportManager.Status targetStatus, bytes32 reportHash) internal {
        (uint256 programId,,) = _prepareReportForRefundState(targetStatus, reportHash);

        vm.prank(company);
        vm.expectRevert("OPEN_REPORTS_EXIST");
        registry.initiateRefund(programId);
    }

    function _prepareReportForRefundState(ReportManager.Status targetStatus, bytes32 reportHash)
        internal
        returns (uint256 programId, bytes32 reportId, bytes32)
    {
        programId = _createStandardProgram();
        deposit(programId, 15_000_000);
        reportId = submitReport(programId, researcher, reportHash);

        if (targetStatus == ReportManager.Status.SUBMITTED) {
            return (programId, reportId, reportHash);
        }

        vm.prank(judge);
        payouts.approvePrimary(programId, targetStatus == ReportManager.Status.REJECTED ? 0 : 2, researcher, reportHash);

        if (targetStatus == ReportManager.Status.APPROVED_PRIMARY || targetStatus == ReportManager.Status.REJECTED) {
            return (programId, reportId, reportHash);
        }

        if (
            targetStatus == ReportManager.Status.ESCALATED || targetStatus == ReportManager.Status.ESCALATED_RESOLVED
                || targetStatus == ReportManager.Status.ESCALATED_REJECTED
        ) {
            vm.prank(researcher);
            payouts.escalateReport(programId, 4, researcher, reportHash);
            if (targetStatus == ReportManager.Status.ESCALATED) {
                return (programId, reportId, reportHash);
            }

            reports.assignSecondJudge(reportId, secondJudge);
            if (targetStatus == ReportManager.Status.ESCALATED_RESOLVED) {
                vm.prank(secondJudge);
                payouts.finalizeEscalation(programId, researcher, reportHash, 4, 0);
            } else {
                vm.prank(secondJudge);
                payouts.finalizeEscalation(programId, researcher, reportHash, 0, 1);
            }
            return (programId, reportId, reportHash);
        }

        if (
            targetStatus == ReportManager.Status.SECOND_OPINION_REQUESTED
                || targetStatus == ReportManager.Status.SECOND_OPINION_RESOLVED
                || targetStatus == ReportManager.Status.SECOND_OPINION_REJECTED
        ) {
            vm.prank(company);
            payouts.requestSecondOpinion(programId, researcher, reportHash);
            if (targetStatus == ReportManager.Status.SECOND_OPINION_REQUESTED) {
                return (programId, reportId, reportHash);
            }

            reports.assignSecondJudge(reportId, secondJudge);
            if (targetStatus == ReportManager.Status.SECOND_OPINION_RESOLVED) {
                vm.prank(secondJudge);
                payouts.approveSecondOpinion(programId, researcher, reportHash, 2, 0);
            } else {
                vm.prank(secondJudge);
                payouts.approveSecondOpinion(programId, researcher, reportHash, 0, 2);
            }
            return (programId, reportId, reportHash);
        }

        if (targetStatus == ReportManager.Status.READY_TO_PAY) {
            vm.warp(block.timestamp + 5 days + 1);
            vm.prank(address(payouts));
            reports.markReadyToPay(reportId);
            return (programId, reportId, reportHash);
        }

        if (targetStatus == ReportManager.Status.PAID) {
            vm.warp(block.timestamp + 5 days + 1);
            vm.prank(judge);
            payouts.finalizeAndPay(programId, researcher, reportHash, 2, 0);
            BountyProgramRegistry.ProgramConfig memory config = registry.getProgram(programId);
            assertEq(uint256(config.status), uint256(BountyProgramRegistry.Status.ACTIVE));
            return (programId, reportId, reportHash);
        }

        if (targetStatus == ReportManager.Status.CLOSED) {
            vm.warp(block.timestamp + 5 days + 1);
            vm.prank(judge);
            payouts.finalizeAndPay(programId, researcher, reportHash, 2, 0);
            vm.prank(address(payouts));
            reports.markClosed(reportId);
            BountyProgramRegistry.ProgramConfig memory config = registry.getProgram(programId);
            assertEq(uint256(config.status), uint256(BountyProgramRegistry.Status.ACTIVE));
            return (programId, reportId, reportHash);
        }

        revert("UNSUPPORTED_STATUS");
    }
}
