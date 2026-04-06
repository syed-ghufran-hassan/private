// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {BaseTestSuite} from "./helpers/BaseTestSuite.t.sol";
import {BountyProgramRegistry} from "../src/BountyProgramRegistry.sol";
import {EscrowVault} from "../src/EscrowVault.sol";
import {JudgeRegistry} from "../src/JudgeRegistry.sol";
import {ReportManager} from "../src/ReportManager.sol";
import {PayoutController} from "../src/PayoutController.sol";

/// @notice Unit tests validating fixes for Bube audit High and Medium findings.
contract BubeFindingsTest is BaseTestSuite {
    // Second judge used across several tests — registered via assignSecondJudge.
    address internal secondJudge = address(0xB1);

    function setUp() public {
        setUpContracts();
        registry.setReportManager(address(reports));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // High-01: Individual dependency setters on PayoutController and Registry
    // ─────────────────────────────────────────────────────────────────────────

    function test_High01_PayoutController_SetRegistry_UpdatesAddress() public {
        BountyProgramRegistry newRegistry = new BountyProgramRegistry(
            admin, treasury, 200, 800, 3000, 2500, 2000, 1750, 3000, 10000, 8000, address(token)
        );
        payouts.setRegistry(address(newRegistry));
        assertEq(address(payouts.registry()), address(newRegistry));
    }

    function test_High01_PayoutController_SetEscrow_UpdatesAddress() public {
        EscrowVault newEscrow = new EscrowVault(registry, admin);
        payouts.setEscrow(address(newEscrow));
        assertEq(address(payouts.escrow()), address(newEscrow));
    }

    function test_High01_PayoutController_SetJudges_UpdatesAddress() public {
        JudgeRegistry newJudges = new JudgeRegistry(admin);
        payouts.setJudges(address(newJudges));
        assertEq(address(payouts.judges()), address(newJudges));
    }

    function test_High01_PayoutController_SetReports_UpdatesAddress() public {
        ReportManager newReports = new ReportManager(admin, address(judges), address(registry));
        payouts.setReports(address(newReports));
        assertEq(address(payouts.reports()), address(newReports));
    }

    function test_High01_PayoutController_Setters_RevertForNonAdmin() public {
        vm.startPrank(address(0xDEAD));
        vm.expectRevert("NOT_ADMIN");
        payouts.setRegistry(address(0x1));
        vm.expectRevert("NOT_ADMIN");
        payouts.setEscrow(address(0x1));
        vm.expectRevert("NOT_ADMIN");
        payouts.setJudges(address(0x1));
        vm.expectRevert("NOT_ADMIN");
        payouts.setReports(address(0x1));
        vm.stopPrank();
    }

    function test_High01_Registry_IndividualSetters_UpdateAddresses() public {
        EscrowVault newEscrow = new EscrowVault(registry, admin);
        JudgeRegistry newJudges = new JudgeRegistry(admin);
        PayoutController newPayouts = new PayoutController(registry, escrow, judges, reports, 5 days, admin);

        address newToken = address(0xF00D);

        // setEscrowVault
        registry.setEscrowVault(address(newEscrow));
        assertEq(registry.escrowVault(), address(newEscrow));

        // setJudgeRegistry
        registry.setJudgeRegistry(address(newJudges));
        assertEq(registry.judgeRegistry(), address(newJudges));

        // setPayoutController
        registry.setPayoutController(address(newPayouts));
        assertEq(registry.payoutController(), address(newPayouts));

        // setAllowedPayoutToken
        registry.setAllowedPayoutToken(newToken);
        assertEq(registry.allowedPayoutToken(), newToken);
    }

    function test_High01_Registry_Setters_RevertForNonAdmin() public {
        vm.startPrank(address(0xDEAD));
        vm.expectRevert("NOT_ADMIN");
        registry.setEscrowVault(address(0x1));
        vm.expectRevert("NOT_ADMIN");
        registry.setJudgeRegistry(address(0x1));
        vm.expectRevert("NOT_ADMIN");
        registry.setPayoutController(address(0x1));
        vm.expectRevert("NOT_ADMIN");
        registry.setAllowedPayoutToken(address(0x1));
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // High-02: Per-report penalty tracking for multiple escalated reports
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Two reports on the same program — same report ID cannot accrue twice.
    function test_High02_SameReport_CannotAccruePenaltyTwice() public {
        uint256 programId = _createStandardProgram();
        deposit(programId, 15_000_000);

        bytes32 reportHash = keccak256("penalty-twice");
        bytes32 reportId = _approveAndRequestSecondOpinion(programId, researcher, reportHash, 3, judge, secondJudge);

        vm.prank(secondJudge);
        payouts.approveSecondOpinion(programId, researcher, reportHash, 3, 0);

        assertGt(escrow.companyPenaltyDebt(programId), 0);
        assertGt(escrow.reportPenaltyDebt(reportId), 0);

        // Only one report entry is recorded.
        assertEq(escrow.getProgramPenaltyReportsLength(programId), 1);
    }

    /// @notice Two reports with distinct judge pairs each accrue their own penalty.
    function test_High02_TwoReports_DifferentJudgePairs_BothAccrue() public {
        uint256 programId = _createStandardProgram();
        deposit(programId, 15_000_000);

        address judge2 = address(0xB2);
        address secondJudge2 = address(0xB3);
        address researcher2 = address(0xD1);

        judges.setJudge(judge2, true);

        bytes32 hashA = keccak256("report-a");
        bytes32 hashB = keccak256("report-b");

        // Report A: judge / secondJudge
        bytes32 reportIdA = _approveAndRequestSecondOpinion(programId, researcher, hashA, 3, judge, secondJudge);
        // Report B: judge2 / secondJudge2
        bytes32 reportIdB = _approveAndRequestSecondOpinion(programId, researcher2, hashB, 3, judge2, secondJudge2);

        vm.prank(secondJudge);
        payouts.approveSecondOpinion(programId, researcher, hashA, 3, 0);

        vm.prank(secondJudge2);
        payouts.approveSecondOpinion(programId, researcher2, hashB, 3, 0);

        // Both reports recorded independently.
        assertEq(escrow.getProgramPenaltyReportsLength(programId), 2);
        assertGt(escrow.reportPenaltyDebt(reportIdA), 0);
        assertGt(escrow.reportPenaltyDebt(reportIdB), 0);

        // Aggregate equals sum of per-report debts.
        uint256 total = escrow.companyPenaltyDebt(programId);
        uint256 sumPerReport = escrow.sumReportPenaltyDebts(programId);
        assertEq(total, sumPerReport);
        assertEq(total, escrow.reportPenaltyDebt(reportIdA) + escrow.reportPenaltyDebt(reportIdB));
    }

    /// @notice Once the first payout drops the program to DRAFT, the reactivation deposit
    ///         repays both outstanding report penalties proportionally.
    function test_High02_TwoReports_PenaltyPaidProportionally_OnDeposit() public {
        uint256 programId = _createStandardProgram();
        deposit(programId, 15_000_000);

        address judge2 = address(0xB2);
        address secondJudge2 = address(0xB3);
        address researcher2 = address(0xD1);

        judges.setJudge(judge2, true);

        bytes32 hashA = keccak256("high02-deposit-a");
        bytes32 hashB = keccak256("high02-deposit-b");

        _approveAndRequestSecondOpinion(programId, researcher, hashA, 3, judge, secondJudge);
        _approveAndRequestSecondOpinion(programId, researcher2, hashB, 3, judge2, secondJudge2);

        vm.prank(secondJudge);
        payouts.approveSecondOpinion(programId, researcher, hashA, 3, 0);
        vm.prank(secondJudge2);
        payouts.approveSecondOpinion(programId, researcher2, hashB, 3, 0);

        uint256 debt = escrow.companyPenaltyDebt(programId);
        assertGt(debt, 0);

        // The first payout drops bountyBalance below the schedule, so the program becomes DRAFT.
        vm.warp(block.timestamp + 5 days + 1);
        vm.prank(secondJudge);
        payouts.finalizeAndPay(programId, researcher, hashA, 3, 0);
        assertEq(uint256(registry.getProgram(programId).status), uint256(BountyProgramRegistry.Status.DRAFT));

        // Both are symmetric (same severity), so each report penalty = debt/2.
        uint256 penaltyPerReport = debt / 2;
        uint256 treasuryShare = (penaltyPerReport * 2_000) / 10_000;
        uint256 judgeShare = penaltyPerReport - treasuryShare;
        uint256 primaryShare = (judgeShare * 5_000) / 10_000;
        uint256 secondaryShare = judgeShare - primaryShare;
        uint256 treasuryBefore = token.balanceOf(treasury);
        uint256 judge1Before = token.balanceOf(judge);
        uint256 secondJudge1Before = token.balanceOf(secondJudge);
        uint256 judge2Before = token.balanceOf(judge2);
        uint256 secondJudge2Before = token.balanceOf(secondJudge2);

        // New deposit covers the outstanding debt and then some.
        uint256 netExtra = 15_000_000;
        uint256 depositAmount = debt + netExtra;
        deposit(programId, depositAmount);
        assertEq(uint256(registry.getProgram(programId).status), uint256(BountyProgramRegistry.Status.ACTIVE));

        // Treasury also receives the treasury fee from the deposit split (not just the penalty).
        uint256 netAfterDebt = netExtra;
        uint256 bountyFromDeposit = netAfterDebt * 10_000 / 11_000; // 800+200 bps
        uint256 feesFromDeposit = netAfterDebt - bountyFromDeposit;
        uint256 judgeFeeFromDeposit = (feesFromDeposit * 800) / 1_000;
        uint256 treasuryFeeFromDeposit = feesFromDeposit - judgeFeeFromDeposit;

        // Debt fully cleared.
        assertEq(escrow.companyPenaltyDebt(programId), 0);

        // Both judge pairs received their proportional shares (within rounding of 1 wei).
        assertApproxEqAbs(token.balanceOf(judge), judge1Before + primaryShare, 1);
        assertApproxEqAbs(token.balanceOf(secondJudge), secondJudge1Before + secondaryShare, 1);
        assertApproxEqAbs(token.balanceOf(judge2), judge2Before + primaryShare, 1);
        assertApproxEqAbs(token.balanceOf(secondJudge2), secondJudge2Before + secondaryShare, 1);
        assertApproxEqAbs(token.balanceOf(treasury), treasuryBefore + treasuryShare * 2 + treasuryFeeFromDeposit, 2);
    }

    /// @notice With enough initial funding, both reports can be paid before the program drops back to DRAFT.
    /// @dev The reactivation deposit then repays the combined per-report penalty debt proportionally.
    function test_High02_TwoReports_BothFinalizeBeforeDeactivation_PenaltyPaidProportionally_OnDeposit() public {
        uint256 programId = _createStandardProgram();
        deposit(programId, 16_000_000);

        address judge2 = address(0xB2);
        address secondJudge2 = address(0xB3);
        address researcher2 = address(0xD1);

        judges.setJudge(judge2, true);

        bytes32 hashA = keccak256("high02-both-finalize-a");
        bytes32 hashB = keccak256("high02-both-finalize-b");

        _approveAndRequestSecondOpinion(programId, researcher, hashA, 3, judge, secondJudge);
        _approveAndRequestSecondOpinion(programId, researcher2, hashB, 3, judge2, secondJudge2);

        vm.prank(secondJudge);
        payouts.approveSecondOpinion(programId, researcher, hashA, 3, 0);
        vm.prank(secondJudge2);
        payouts.approveSecondOpinion(programId, researcher2, hashB, 3, 0);

        uint256 debt = escrow.companyPenaltyDebt(programId);
        assertGt(debt, 0);

        vm.warp(block.timestamp + 5 days + 1);

        vm.prank(secondJudge);
        payouts.finalizeAndPay(programId, researcher, hashA, 3, 0);
        assertEq(uint256(registry.getProgram(programId).status), uint256(BountyProgramRegistry.Status.ACTIVE));

        vm.prank(secondJudge2);
        payouts.finalizeAndPay(programId, researcher2, hashB, 3, 0);
        assertEq(uint256(registry.getProgram(programId).status), uint256(BountyProgramRegistry.Status.DRAFT));

        uint256 penaltyPerReport = debt / 2;
        uint256 treasuryShare = (penaltyPerReport * 2_000) / 10_000;
        uint256 judgeShare = penaltyPerReport - treasuryShare;
        uint256 primaryShare = (judgeShare * 5_000) / 10_000;
        uint256 secondaryShare = judgeShare - primaryShare;

        uint256 treasuryBefore = token.balanceOf(treasury);
        uint256 judge1Before = token.balanceOf(judge);
        uint256 secondJudge1Before = token.balanceOf(secondJudge);
        uint256 judge2Before = token.balanceOf(judge2);
        uint256 secondJudge2Before = token.balanceOf(secondJudge2);
        uint256 judgeBalanceBeforeDeposit = escrow.getJudgeFee(programId);

        uint256 netExtra = 15_000_000;
        uint256 depositAmount = debt + netExtra;
        deposit(programId, depositAmount);
        assertEq(uint256(registry.getProgram(programId).status), uint256(BountyProgramRegistry.Status.ACTIVE));

        uint256 bountyFromDeposit = netExtra * 10_000 / 11_000; // 800+200 bps
        uint256 feesFromDeposit = netExtra - bountyFromDeposit;
        uint256 judgeFeeFromDeposit = (feesFromDeposit * 800) / 1_000;
        uint256 treasuryFeeFromDeposit = feesFromDeposit - judgeFeeFromDeposit;

        assertEq(escrow.companyPenaltyDebt(programId), 0);

        assertApproxEqAbs(token.balanceOf(judge), judge1Before + primaryShare, 1);
        assertApproxEqAbs(token.balanceOf(secondJudge), secondJudge1Before + secondaryShare, 1);
        assertApproxEqAbs(token.balanceOf(judge2), judge2Before + primaryShare, 1);
        assertApproxEqAbs(token.balanceOf(secondJudge2), secondJudge2Before + secondaryShare, 1);
        assertApproxEqAbs(token.balanceOf(treasury), treasuryBefore + treasuryShare * 2 + treasuryFeeFromDeposit, 2);
        assertEq(escrow.getJudgeFee(programId), judgeBalanceBeforeDeposit + judgeFeeFromDeposit);
    }

    /// @notice On refund, outstanding per-report penalty is paid to all judge pairs.
    function test_High02_TwoReports_PenaltyPaidProportionally_OnRefund() public {
        uint256 programId = _createStandardProgram();
        deposit(programId, 16_000_000);

        address judge2 = address(0xB2);
        address secondJudge2 = address(0xB3);
        address researcher2 = address(0xD1);

        judges.setJudge(judge2, true);

        bytes32 hashA = keccak256("high02-refund-a");
        bytes32 hashB = keccak256("high02-refund-b");

        _approveAndRequestSecondOpinion(programId, researcher, hashA, 3, judge, secondJudge);
        _approveAndRequestSecondOpinion(programId, researcher2, hashB, 3, judge2, secondJudge2);

        vm.prank(secondJudge);
        payouts.approveSecondOpinion(programId, researcher, hashA, 3, 0);
        vm.prank(secondJudge2);
        payouts.approveSecondOpinion(programId, researcher2, hashB, 3, 0);

        uint256 debt = escrow.companyPenaltyDebt(programId);
        assertGt(debt, 0);

        vm.warp(block.timestamp + 5 days + 1);
        vm.prank(secondJudge);
        payouts.finalizeAndPay(programId, researcher, hashA, 3, 0);
        vm.prank(secondJudge2);
        payouts.finalizeAndPay(programId, researcher2, hashB, 3, 0);
        assertEq(uint256(registry.getProgram(programId).status), uint256(BountyProgramRegistry.Status.DRAFT));

        uint256 penaltyPerReport = debt / 2;
        uint256 treasuryShare = (penaltyPerReport * 2_000) / 10_000;
        uint256 judgeShare = penaltyPerReport - treasuryShare;
        uint256 primaryShare = (judgeShare * 5_000) / 10_000;
        uint256 secondaryShare = judgeShare - primaryShare;

        uint256 treasuryBefore = token.balanceOf(treasury);
        uint256 judge1Before = token.balanceOf(judge);
        uint256 secondJudge1Before = token.balanceOf(secondJudge);
        uint256 judge2Before = token.balanceOf(judge2);
        uint256 secondJudge2Before = token.balanceOf(secondJudge2);

        vm.prank(company);
        registry.initiateRefund(programId);

        uint256 refundAt = uint256(registry.getProgram(programId).pausedAt) + 5 days + 1;
        vm.warp(refundAt);
        vm.prank(company);
        registry.executeRefund(programId);

        // Debt cleared.
        assertEq(escrow.companyPenaltyDebt(programId), 0);

        // Each judge pair paid their proportional share (within rounding).
        assertApproxEqAbs(token.balanceOf(judge), judge1Before + primaryShare, 1);
        assertApproxEqAbs(token.balanceOf(secondJudge), secondJudge1Before + secondaryShare, 1);
        assertApproxEqAbs(token.balanceOf(judge2), judge2Before + primaryShare, 1);
        assertApproxEqAbs(token.balanceOf(secondJudge2), secondJudge2Before + secondaryShare, 1);
        assertApproxEqAbs(token.balanceOf(treasury), treasuryBefore + treasuryShare * 2, 2);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Medium-01: Token allowlist enforced on createProgram
    // ─────────────────────────────────────────────────────────────────────────

    function test_Medium01_CreateProgram_WithAllowedToken_Succeeds() public {
        uint8[] memory sevs = new uint8[](1);
        sevs[0] = 1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1_100_000;

        BountyProgramRegistry.ProgramConfigInput memory input = BountyProgramRegistry.ProgramConfigInput({
            companyOwner: company,
            payoutToken: address(token), // allowed token
            judgeFeeBps: 800,
            treasuryFeeBps: 200,
            treasury: treasury,
            severities: sevs,
            payoutAmounts: amounts
        });
        uint256 programId = registry.createProgram(input);
        assertGt(programId, 0);
    }

    function test_Medium01_CreateProgram_WithUnallowedToken_Reverts() public {
        address badToken = address(0xBAD);

        uint8[] memory sevs = new uint8[](1);
        sevs[0] = 1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1_100_000;

        BountyProgramRegistry.ProgramConfigInput memory input = BountyProgramRegistry.ProgramConfigInput({
            companyOwner: company,
            payoutToken: badToken,
            judgeFeeBps: 800,
            treasuryFeeBps: 200,
            treasury: treasury,
            severities: sevs,
            payoutAmounts: amounts
        });

        vm.expectRevert("TOKEN_NOT_ALLOWED");
        registry.createProgram(input);
    }

    function test_Medium01_SetAllowedPayoutToken_UpdatesCheck() public {
        address newToken = address(0xCAFE);
        registry.setAllowedPayoutToken(newToken);
        assertEq(registry.allowedPayoutToken(), newToken);

        // Old token is now rejected.
        uint8[] memory sevs = new uint8[](1);
        sevs[0] = 1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1_100_000;

        BountyProgramRegistry.ProgramConfigInput memory input = BountyProgramRegistry.ProgramConfigInput({
            companyOwner: company,
            payoutToken: address(token),
            judgeFeeBps: 800,
            treasuryFeeBps: 200,
            treasury: treasury,
            severities: sevs,
            payoutAmounts: amounts
        });

        vm.expectRevert("TOKEN_NOT_ALLOWED");
        registry.createProgram(input);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Medium-02: emergencyBountyPayout calls deactivateFromPaidBounty
    // ─────────────────────────────────────────────────────────────────────────

    function test_Medium02_EmergencyBountyPayout_DeactivatesProgramToDraft() public {
        uint256 programId = _createStandardProgram();
        deposit(programId, 15_000_000);

        // Program must be ACTIVE after deposit.
        assertEq(uint256(registry.getProgram(programId).status), uint256(BountyProgramRegistry.Status.ACTIVE));

        uint256 bounty = escrow.bountyBalance(programId);
        // Admin calls emergencyBountyPayout to redirect a stuck bounty.
        escrow.emergencyBountyPayout(programId, address(0xABCD), bounty / 2);

        // deactivateFromPaidBounty must have been called → status back to DRAFT.
        assertEq(uint256(registry.getProgram(programId).status), uint256(BountyProgramRegistry.Status.DRAFT));
    }

    function test_Medium02_EmergencyBountyPayout_NonAdmin_Reverts() public {
        uint256 programId = _createStandardProgram();
        deposit(programId, 15_000_000);

        vm.prank(address(0xDEAD));
        vm.expectRevert("NOT_ADMIN");
        escrow.emergencyBountyPayout(programId, address(0xABCD), 100);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Medium-03: Pure debt payment deposit path
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice A debt-only deposit is rejected while the program still remains ACTIVE.
    /// @dev When bountyBalance still covers the schedule after payout, the program never goes back
    ///      to DRAFT, so EscrowVault.deposit() reverts before reaching the debt-only branch.
    function test_Medium03_PureDebtPayment_WhenBalanceCoversSchedule_RevertsWhileActive() public {
        // severity 1 = 1.1M, severity 3 = 5M → total schedule = 6_100_000.
        // debt = (5M * 30%) = 1_500_000 >= MIN_DEPOSIT ✓
        uint256 programId = _createLargeProgram();

        // Initial deposit = ~2× schedule to leave bountyBalance above schedule after payout.
        // bountyAmount ≈ 14M × 10/11 = 12_727_272 → after paying 5M: ~7_727_272 ≥ 6_100_000 ✓
        deposit(programId, 14_000_000);

        bytes32 reportHash = keccak256("medium03-pure-debt");
        _approveAndRequestSecondOpinion(programId, researcher, reportHash, 3, judge, secondJudge);
        vm.prank(secondJudge);
        payouts.approveSecondOpinion(programId, researcher, reportHash, 3, 0);

        uint256 debt = escrow.companyPenaltyDebt(programId);
        assertGe(debt, 1_000_000); // debt must exceed MIN_DEPOSIT

        // Finalize keeps the program ACTIVE because bountyBalance still covers the schedule.
        vm.warp(block.timestamp + 5 days + 1);
        vm.prank(secondJudge);
        payouts.finalizeAndPay(programId, researcher, reportHash, 3, 0);

        uint256 requiredBounty = registry.totalPayoutByProgram(programId);
        assertGe(escrow.bountyBalance(programId), requiredBounty);
        assertEq(uint256(registry.getProgram(programId).status), uint256(BountyProgramRegistry.Status.ACTIVE));

        // A new deposit is rejected because deposits are only allowed while the program is DRAFT.
        token.mint(company, debt);
        vm.startPrank(company);
        token.approve(address(escrow), debt);
        vm.expectRevert("PROGRAM_NOT_DEPOSITABLE");
        escrow.deposit(programId, debt);
        vm.stopPrank();

        assertEq(escrow.companyPenaltyDebt(programId), debt);
    }

    /// @notice A debt-only deposit succeeds when the program is DRAFT and existing bounty already covers the schedule.
    /// @dev This targets the pure-debt branch directly by forcing the registry into DRAFT without changing balances.
    function test_Medium03_PureDebtPayment_WhenDraftAndBalanceCoversSchedule_Succeeds() public {
        uint256 programId = _createLargeProgram();
        deposit(programId, 14_000_000);

        bytes32 reportHash = keccak256("medium03-pure-debt-draft-success");
        _approveAndRequestSecondOpinion(programId, researcher, reportHash, 3, judge, secondJudge);
        vm.prank(secondJudge);
        payouts.approveSecondOpinion(programId, researcher, reportHash, 3, 0);

        uint256 debt = escrow.companyPenaltyDebt(programId);
        assertGe(debt, 1_000_000);
        assertGe(escrow.bountyBalance(programId), registry.totalPayoutByProgram(programId));
        assertEq(uint256(registry.getProgram(programId).status), uint256(BountyProgramRegistry.Status.ACTIVE));

        // Directly target EscrowVault.deposit()'s pure-debt branch: DRAFT status with sufficient bounty.
        vm.prank(address(escrow));
        registry.deactivateFromPaidBounty(programId);
        assertEq(uint256(registry.getProgram(programId).status), uint256(BountyProgramRegistry.Status.DRAFT));

        token.mint(company, debt);
        vm.startPrank(company);
        token.approve(address(escrow), debt);
        escrow.deposit(programId, debt);
        vm.stopPrank();

        assertEq(escrow.companyPenaltyDebt(programId), 0);
        assertGe(escrow.bountyBalance(programId), registry.totalPayoutByProgram(programId));
        assertEq(uint256(registry.getProgram(programId).status), uint256(BountyProgramRegistry.Status.ACTIVE));
    }

    /// @notice When deposit amount equals debt but bountyBalance is insufficient for the schedule,
    ///         deposit reverts with INSUFFICIENT_INITIAL_BOUNTY.
    function test_Medium03_PureDebtPayment_WhenBalanceInsufficientForSchedule_Reverts() public {
        // Same high-payout program but minimal initial deposit.
        uint256 programId = _createLargeProgram();

        // Minimal deposit (just enough to hit bountyBalance >= schedule).
        // totalPayoutByProgram = 6_100_000; deposit * 10000/11000 >= 6_100_000 → deposit >= 6_710_000
        deposit(programId, 7_000_000);

        bytes32 reportHash = keccak256("medium03-insufficient");
        _approveAndRequestSecondOpinion(programId, researcher, reportHash, 3, judge, secondJudge);
        vm.prank(secondJudge);
        payouts.approveSecondOpinion(programId, researcher, reportHash, 3, 0);

        uint256 debt = escrow.companyPenaltyDebt(programId);
        assertGe(debt, 1_000_000);

        // Finalize drains bountyBalance below schedule (bounty after pay < 6_100_000 schedule).
        vm.warp(block.timestamp + 5 days + 1);
        vm.prank(secondJudge);
        payouts.finalizeAndPay(programId, researcher, reportHash, 3, 0);

        assertLt(escrow.bountyBalance(programId), registry.totalPayoutByProgram(programId));

        token.mint(company, debt);
        vm.startPrank(company);
        token.approve(address(escrow), debt);
        vm.expectRevert("INSUFFICIENT_INITIAL_BOUNTY");
        escrow.deposit(programId, debt);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Medium-04: refund() enforces balance >= debt; payPenaltyDebt() unblocks it
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice refund() reverts when bountyBalance < companyPenaltyDebt.
    /// @dev Uses a high-payout program so the bounty payout drains most of the balance,
    ///      leaving bountyBalance below the accrued debt.
    function test_Medium04_Refund_RevertsWhenBalanceInsufficientForDebt() public {
        uint256 programId = _createLargeProgram();
        deposit(programId, 7_000_000); // minimal activation deposit

        bytes32 reportHash = keccak256("medium04-insufficient-refund");
        _approveAndRequestSecondOpinion(programId, researcher, reportHash, 3, judge, secondJudge);
        vm.prank(secondJudge);
        payouts.approveSecondOpinion(programId, researcher, reportHash, 3, 0);

        uint256 debt = escrow.companyPenaltyDebt(programId);
        assertGt(debt, 0);

        vm.warp(block.timestamp + 5 days + 1);
        vm.prank(secondJudge);
        payouts.finalizeAndPay(programId, researcher, reportHash, 3, 0);
        vm.prank(company);
        registry.initiateRefund(programId);

        // After paying 5M payout, bountyBalance is ~1.36M; debt is 1_500_000.
        assertLt(escrow.bountyBalance(programId), debt);

        uint256 refundAt = uint256(registry.getProgram(programId).pausedAt) + 5 days + 1;
        vm.warp(refundAt);
        vm.prank(company);
        vm.expectRevert("BALANCE_INSUFFICIENT_FOR_DEBT");
        registry.executeRefund(programId);
    }

    /// @notice payPenaltyDebt() allows company to top up while PAUSED, then executeRefund succeeds.
    function test_Medium04_PayPenaltyDebt_ThenRefund_Succeeds() public {
        uint256 programId = _createLargeProgram();
        deposit(programId, 7_000_000);

        bytes32 reportHash = keccak256("medium04-pay-penalty-then-refund");
        _approveAndRequestSecondOpinion(programId, researcher, reportHash, 3, judge, secondJudge);
        vm.prank(secondJudge);
        payouts.approveSecondOpinion(programId, researcher, reportHash, 3, 0);

        uint256 debt = escrow.companyPenaltyDebt(programId);
        assertGt(debt, 0);

        vm.warp(block.timestamp + 5 days + 1);
        vm.prank(secondJudge);
        payouts.finalizeAndPay(programId, researcher, reportHash, 3, 0);
        vm.prank(company);
        registry.initiateRefund(programId);

        assertLt(escrow.bountyBalance(programId), debt);

        // Company pays remaining penalty debt directly while PAUSED.
        uint256 remaining = escrow.companyPenaltyDebt(programId);
        token.mint(company, remaining);
        vm.startPrank(company);
        token.approve(address(escrow), remaining);
        escrow.payPenaltyDebt(programId, remaining);
        vm.stopPrank();

        assertEq(escrow.companyPenaltyDebt(programId), 0);

        uint256 refundAt = uint256(registry.getProgram(programId).pausedAt) + 5 days + 1;
        vm.warp(refundAt);
        vm.prank(company);
        registry.executeRefund(programId); // must not revert
    }

    function test_Medium04_PayPenaltyDebt_RevertsForNonOwner() public {
        uint256 programId = _createStandardProgram();
        deposit(programId, 15_000_000);

        bytes32 reportHash = keccak256("medium04-non-owner");
        _approveAndRequestSecondOpinion(programId, researcher, reportHash, 3, judge, secondJudge);
        vm.prank(secondJudge);
        payouts.approveSecondOpinion(programId, researcher, reportHash, 3, 0);

        vm.warp(block.timestamp + 5 days + 1);
        vm.prank(secondJudge);
        payouts.finalizeAndPay(programId, researcher, reportHash, 3, 0);
        vm.prank(company);
        registry.initiateRefund(programId);

        uint256 debt = escrow.companyPenaltyDebt(programId);
        token.mint(address(0xBAD), debt);
        vm.startPrank(address(0xBAD));
        token.approve(address(escrow), debt);
        vm.expectRevert("NOT_PROGRAM_OWNER");
        escrow.payPenaltyDebt(programId, debt);
        vm.stopPrank();
    }

    function test_Medium04_PayPenaltyDebt_RevertsWhenNotPaused() public {
        uint256 programId = _createStandardProgram();
        deposit(programId, 15_000_000);

        bytes32 reportHash = keccak256("medium04-not-paused");
        _approveAndRequestSecondOpinion(programId, researcher, reportHash, 3, judge, secondJudge);
        vm.prank(secondJudge);
        payouts.approveSecondOpinion(programId, researcher, reportHash, 3, 0);

        uint256 debt = escrow.companyPenaltyDebt(programId);
        // Program is ACTIVE at this point, not PAUSED.
        token.mint(company, debt);
        vm.startPrank(company);
        token.approve(address(escrow), debt);
        vm.expectRevert("PROGRAM_NOT_PAUSED");
        escrow.payPenaltyDebt(programId, debt);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Creates a standard 4-tier bounty program (1.1M/2.2M/3.3M/4.4M).
    function _createStandardProgram() internal returns (uint256 programId) {
        uint8[] memory sevs = new uint8[](4);
        uint256[] memory amounts = new uint256[](4);
        sevs[0] = 1; sevs[1] = 2; sevs[2] = 3; sevs[3] = 4;
        amounts[0] = 1_100_000; amounts[1] = 2_200_000; amounts[2] = 3_300_000; amounts[3] = 4_400_000;
        programId = createProgram(800, 200, sevs, amounts);
    }

    /// @notice Creates a high-payout 2-tier program: severity 1 = 1.1M, severity 3 = 5M.
    /// @dev Designed so that debt (5M × 30% = 1.5M) >= MIN_DEPOSIT and a minimal-activation deposit
    ///      leaves almost no bountyBalance after a severity-3 payout (bountyBalance ≈ 1.1M < debt).
    /// @dev Total schedule = 6_100_000; min deposit = 6_100_000 × 11_000 / 10_000 = 6_710_000.
    function _createLargeProgram() internal returns (uint256 programId) {
        uint8[] memory sevs = new uint8[](2);
        uint256[] memory amounts = new uint256[](2);
        sevs[0] = 1; sevs[1] = 3;
        amounts[0] = 1_100_000; amounts[1] = 5_000_000;
        programId = createProgram(800, 200, sevs, amounts);
    }

    /// @notice Drives a report to SECOND_OPINION_REQUESTED using the provided judge pair.
    /// @dev Registers primaryJudge in JudgeRegistry if needed. secondaryJudge is registered
    ///      via reports.assignSecondJudge().
    function _approveAndRequestSecondOpinion(
        uint256 programId,
        address _researcher,
        bytes32 reportHash,
        uint8 severity,
        address primaryJudge,
        address secondaryJudge_
    ) internal returns (bytes32 reportId) {
        reportId = reports.submitReport(programId, _researcher, primaryJudge, reportHash);

        vm.prank(primaryJudge);
        payouts.approvePrimary(programId, severity, _researcher, reportHash);

        vm.prank(company);
        payouts.requestSecondOpinion(programId, _researcher, reportHash);

        reports.assignSecondJudge(reportId, secondaryJudge_);
    }
}
