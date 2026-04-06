// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "./BountyProgramRegistry.sol";
import "./EscrowVault.sol";
import "./JudgeRegistry.sol";
import "./ReportManager.sol";

contract PayoutController is ReentrancyGuard {
    BountyProgramRegistry public registry;
    EscrowVault public escrow;
    JudgeRegistry public judges;
    ReportManager public reports;

    uint256 public immutable TIMELOCK;
    /// @notice Admin address with authority to update dependency addresses.
    address public admin;

    event AdminUpdated(address admin);
    event RegistryUpdated(address registry);
    event EscrowUpdated(address escrow);
    event JudgesUpdated(address judges);
    event ReportsUpdated(address reports);
    event PrimaryApprovalExecuted(bytes32 indexed reportId, address indexed judge, uint8 severity, uint256 payoutAmount, uint256 judgeFeeAmount, uint256 timelockEnd);
    event SecondOpinionExecuted(bytes32 indexed reportId, address indexed judge, uint8 severity, uint8 outcome);
    event ReportEscalatedExecuted(bytes32 indexed reportId, address indexed researcher, uint16 escalationBps);
    event ReportFinalizedEscalated(bytes32 indexed reportId, address indexed researcher,uint8 severity, uint8 outcome, uint256 escalationAmount);
    event ReportReadyToPay(bytes32 indexed reportId);
    event PayoutExecuted(bytes32 indexed reportId, address indexed researcher, uint256 payoutAmount, address indexed judge, uint256 judgeFeeAmount);

    modifier onlyAdmin() {
        require(msg.sender == admin, "NOT_ADMIN");
        _;
    }

    /// @notice Initializes the payout controller with its dependencies.
    /// @param registry_ The program registry for config/status lookups.
    /// @param escrow_ The escrow vault that holds funds.
    /// @param judges_ The judge registry used for allowlist checks.
    /// @param reports_ The report manager used for replay protection and state.
    /// @param timelock_ Timelock duration in seconds before a report can be finalized.
    /// @param admin_ Address with admin privileges for updating dependency addresses.
    constructor(
        BountyProgramRegistry registry_,
        EscrowVault escrow_,
        JudgeRegistry judges_,
        ReportManager reports_,
        uint256 timelock_,
        address admin_
    ) {
        require(address(registry_) != address(0), "REGISTRY_ZERO");
        require(address(escrow_) != address(0), "ESCROW_ZERO");
        require(address(judges_) != address(0), "JUDGES_ZERO");
        require(address(reports_) != address(0), "REPORTS_ZERO");
        require(admin_ != address(0), "ADMIN_ZERO");
        registry = registry_;
        escrow = escrow_;
        judges = judges_;
        reports = reports_;
        admin = admin_;
        TIMELOCK = timelock_;
    }

    /// @notice Updates the registry address.
    function setRegistry(address registry_) external onlyAdmin {
        require(registry_ != address(0), "REGISTRY_ZERO");
        require(registry_ != address(registry), "ALREADY_REGISTRY");
        registry = BountyProgramRegistry(registry_);
        emit RegistryUpdated(registry_);
    }

    /// @notice Updates the escrow vault address.
    function setEscrow(address escrow_) external onlyAdmin {
        require(escrow_ != address(0), "ESCROW_ZERO");
        require(escrow_ != address(escrow), "ALREADY_ESCROW");
        escrow = EscrowVault(escrow_);
        emit EscrowUpdated(escrow_);
    }

    /// @notice Updates the judge registry address.
    function setJudges(address judges_) external onlyAdmin {
        require(judges_ != address(0), "JUDGES_ZERO");
        require(judges_ != address(judges), "ALREADY_JUDGES");
        judges = JudgeRegistry(judges_);
        emit JudgesUpdated(judges_);
    }

    /// @notice Updates the report manager address.
    function setReports(address reports_) external onlyAdmin {
        require(reports_ != address(0), "REPORTS_ZERO");
        require(reports_ != address(reports), "ALREADY_REPORTS");
        reports = ReportManager(reports_);
        emit ReportsUpdated(reports_);
    }

    /// @notice Approves a report by the primary judge and starts the timelock window.
    /// @dev The caller must be an allowlisted judge and assigned as primary judge.
    /// @dev The bounty payout amount is derived from the program's severity schedule.
    /// @param programId The program identifier.
    /// @param severity The accepted severity tier set by the judge. 0=Invalidated,1=Low,2=Medium,3=High,4=Critical
    /// @param researcher The researcher payout address.
    /// @param reportHash The canonical report hash for anchoring.
    function approvePrimary(
        uint256 programId,
        uint8 severity,
        address researcher,
        bytes32 reportHash
    ) external {
        require(judges.isJudge(msg.sender), "NOT_JUDGE");
        require(researcher != address(0), "RESEARCHER_ZERO");
        require(reportHash != bytes32(0), "HASH_ZERO");
        require(severity < 5, "INVALID_SEVERITY");

        BountyProgramRegistry.ProgramConfig memory config = registry.getProgram(programId);
        require(config.companyOwner != address(0), "PROGRAM_NOT_FOUND");
        require(config.status == BountyProgramRegistry.Status.ACTIVE, "PROGRAM_NOT_ACTIVE");

        bytes32 reportId = reports.getReportId(programId, researcher, reportHash);
        ReportManager.Status status = reports.getReportStatus(reportId);
        require(status == ReportManager.Status.SUBMITTED, "REPORT_NOT_ELIGIBLE");

        ReportManager.Report memory report = reports.getReport(reportId);
        require(report.primaryJudge == msg.sender, "NOT_REPORT_JUDGE");

        require(registry.hasPayoutSchedule(programId), "SCHEDULE_REQUIRED");
        uint256 payoutAmount = 0;
        uint256 totalJudgeFeeAmount = 0;
        uint256 judgeFeeAmountForSeverity = 0;
        if (severity > 0) {
            payoutAmount = registry.payoutBySeverity(programId, severity);
            require(payoutAmount > 0, "SEVERITY_NOT_CONFIGURED");
            require(escrow.bountyBalance(programId) >= payoutAmount, "INSUFFICIENT_BOUNTY");
            totalJudgeFeeAmount = escrow.getJudgeFee(programId);
            judgeFeeAmountForSeverity = (payoutAmount * config.judgeFeeBps) / 10_000;
            if (judgeFeeAmountForSeverity > 0) {
                require(totalJudgeFeeAmount >= judgeFeeAmountForSeverity, "INSUFFICIENT_JUDGE");
            }
        }

        uint256 timelockEnd = block.timestamp + TIMELOCK;
        reports.markApprovedPrimary(
            reportId,
            programId,
            researcher,
            reportHash,
            msg.sender,
            severity,
            payoutAmount,
            judgeFeeAmountForSeverity,
            timelockEnd
        );

        emit PrimaryApprovalExecuted(
            reportId,
            msg.sender,
            severity,
            payoutAmount,
            judgeFeeAmountForSeverity,
            timelockEnd
        );
    }

    /// @notice Escalates a report during the timelock window.
    /// @dev The caller must be the report researcher.
    /// @param programId The program identifier.
    /// @param escalatedSeverity The escalated severity tier set by the researcher. 1=Low,2=Medium,3=High,4=Critical
    /// @param researcher The researcher payout address.
    /// @param reportHash The canonical report hash.
    function escalateReport(uint256 programId, uint8 escalatedSeverity, address researcher, bytes32 reportHash) external {
        require(researcher != address(0), "RESEARCHER_ZERO");
        require(reportHash != bytes32(0), "HASH_ZERO");
        bytes32 reportId = reports.getReportId(programId,  researcher, reportHash);
        ReportManager.Report memory report = reports.getReport(reportId);
        require(report.researcher == msg.sender, "NOT_RESEARCHER");
        require(report.primarySeverity != escalatedSeverity, "NO_REASON_FOR_ESCALATIONS");
        BountyProgramRegistry.ProgramConfig memory config = registry.getProgram(programId);
        require(
            config.status == BountyProgramRegistry.Status.ACTIVE,
            "PROGRAM_NOT_ACTIVE"
        );
        require(
            report.status == ReportManager.Status.APPROVED_PRIMARY ||
            report.status == ReportManager.Status.REJECTED,
            "REPORT_NOT_ESCALATABLE"
        );
        require(block.timestamp < report.timelockEnd, "TIMELOCK_PASSED");

        // SRs escalates based on its own severity perception. will be overruled by second judge
        uint16 escalationBps = _escalationBpsForSeverity(config, escalatedSeverity);
        require(escalationBps > 0, "ESCALATION_NOT_CONFIGURED");

        reports.markEscalated(reportId, escalationBps);
        registry.setJudgePenalty(
            programId,
            registry.getJudgePenaltyInvalidBps(),
            registry.getJudgePenaltyDowngradeBps()
        );
        emit ReportEscalatedExecuted(reportId, msg.sender, escalationBps);
    }

    /// @notice Requests a second opinion during the timelock window.
    /// @dev The caller must be the program company owner.
    /// @param programId The program identifier.
    /// @param researcher The researcher payout address.
    /// @param reportHash The canonical report hash.
    function requestSecondOpinion(
        uint256 programId,
        address researcher,
        bytes32 reportHash
    ) external {
        require(researcher != address(0), "RESEARCHER_ZERO");
        require(reportHash != bytes32(0), "HASH_ZERO");
        require(registry.getCompanyPenaltyBps() > 0, "COMPANY_PENALTY_NOT_SET");
        BountyProgramRegistry.ProgramConfig memory config = registry.getProgram(programId);
        require(config.companyOwner == msg.sender, "NOT_PROGRAM_OWNER");

        bytes32 reportId = reports.getReportId(programId, researcher, reportHash);
        ReportManager.Report memory report = reports.getReport(reportId);
        require(
            report.status == ReportManager.Status.APPROVED_PRIMARY,
            "REPORT_NOT_REQUESTABLE"
        );
        require(block.timestamp < report.timelockEnd, "TIMELOCK_PASSED");

        bool hasAlternateTier = false;
        for (uint8 s = 1; s <= 4; s++) {
            if (s == report.primarySeverity) {
                continue;
            }
            if (registry.payoutBySeverity(programId, s) > 0) {
                hasAlternateTier = true;
                break;
            }
        }
        require(hasAlternateTier, "NO_ALTERNATE_PAYOUT_TIER");

        reports.markSecondOpinionRequested(reportId, msg.sender);

        // set company penalty on second opinion
        registry.setCompanyPenalty(programId, registry.getCompanyPenaltyBps());
        registry.setJudgePenalty(programId, registry.getJudgePenaltyInvalidBps(), registry.getJudgePenaltyDowngradeBps());
    }

    /// @notice Approves a report as the secondary judge (second opinion).
    /// @dev The caller must be an allowlisted judge and assigned as secondary judge.
    /// @param programId The program identifier.
    /// @param researcher The researcher payout address.
    /// @param reportHash The canonical report hash.
    /// @param severity The secondary severity tier set by the judge. 0=invalidated,1=Low,2=Medium,3=High,4=Critical
    /// @param outcome The outcome enum value (0=CONFIRM,1=DOWNGRADE,2=INVALIDATE).
    function approveSecondOpinion(
        uint256 programId,
        address researcher,
        bytes32 reportHash,
        uint8 severity,
        uint8 outcome
    ) external nonReentrant {
        require(judges.isJudge(msg.sender), "NOT_JUDGE");
        require(researcher != address(0), "RESEARCHER_ZERO");
        require(reportHash != bytes32(0), "HASH_ZERO");
        require(outcome == 0 || outcome == 1 || outcome == 2, "INVALID_OUTCOME");

        BountyProgramRegistry.ProgramConfig memory config = registry.getProgram(programId);
        require(config.companyOwner != address(0), "PROGRAM_NOT_FOUND");
        require(
            config.status == BountyProgramRegistry.Status.ACTIVE ||
            config.status == BountyProgramRegistry.Status.PAUSED,
            "PROGRAM_NOT_ACTIVE"
        );

        bytes32 reportId = reports.getReportId(programId, researcher, reportHash);
        ReportManager.Report memory report = reports.getReport(reportId);
        require(report.status == ReportManager.Status.SECOND_OPINION_REQUESTED, "REPORT_NOT_IN_SECOND_OPINION");
        require(report.primaryJudge != msg.sender, "PRIMARY_JUDGE_CANT_APPROVE_SECOND_OPINION");
        require(report.secondaryJudge == msg.sender, "NOT_SECOND_JUDGE");

        uint256 payoutAmount = 0;
        uint16 judgePenaltyBps = 0;
        uint16 companyPenaltyBps = 0;
        // Confirm
        if (outcome == 0) {
            require(severity == report.primarySeverity, "SEVERITY_MISMATCH");
            payoutAmount = report.payoutAmount;
            companyPenaltyBps = config.companyPenaltyBps;
        } // Downgrade
        else if (outcome == 1) {
            require(severity > 0, "INVALID_SEVERITY");
            payoutAmount = registry.payoutBySeverity(programId, severity);
            if (payoutAmount == 0) {
                uint8 lowest = 0;
                for (uint8 s = 1; s <= 4; s++) {
                    if (registry.payoutBySeverity(programId, s) > 0) {
                        lowest = s;
                        break;
                    }
                }
                require(lowest != 0, "SEVERITY_NOT_CONFIGURED");
                // severity not available, downgrade to lowest severity possible.
                // this is company responsibility to proper set their bounties
                severity = lowest;
                payoutAmount = registry.payoutBySeverity(programId, severity);
            }
            require(severity < report.primarySeverity, "SEVERITY_NOT_DOWNGRADE");
            judgePenaltyBps = config.judgePenaltyDowngradeBps;
        } // Invalidate
        else if (outcome == 2) {
            require(severity == 0, "INVALIDATE_SEVERITY");
            judgePenaltyBps = config.judgePenaltyInvalidBps;
            payoutAmount = 0;
        }

        uint256 totalJudgeFeeAmount = escrow.getJudgeFee(programId);
        uint256 judgeFeeAmountForSeverity = 0;
        if (payoutAmount > 0){
            judgeFeeAmountForSeverity = (payoutAmount * config.judgeFeeBps) / 10_000;
        }
        if (judgeFeeAmountForSeverity > 0) {
            require(totalJudgeFeeAmount >= judgeFeeAmountForSeverity, "INSUFFICIENT_JUDGE");
        }
        reports.markSecondOpinion(
            reportId,
            msg.sender,
            severity,
            outcome,
            payoutAmount,
        judgeFeeAmountForSeverity,
            judgePenaltyBps,
            companyPenaltyBps
        );

        if (companyPenaltyBps > 0 && payoutAmount > 0) {
            uint256 penaltyAmount = (payoutAmount * companyPenaltyBps) / 10_000;
            if (penaltyAmount > 0) {
                // pass reportId so penalty is tracked per-report.
                escrow.accrueCompanyPenalty(programId, reportId, penaltyAmount, report.primaryJudge, report.secondaryJudge);
            }
        }

        // Pay secondary judge for performing an invalidation (outcome == 2).
        // Fee is based on the primary severity's payout so the judge is compensated for the work.
        if (outcome == 2) {
            uint256 secondaryInvalidationFee = (registry.payoutBySeverity(programId, report.primarySeverity)
                * config.judgeFeeBps) / 10_000;
            if (secondaryInvalidationFee > 0) {
                require(totalJudgeFeeAmount >= secondaryInvalidationFee, "INSUFFICIENT_JUDGE_BALANCE");
                escrow.payoutJudge(programId, msg.sender, secondaryInvalidationFee);
            }
        }

        emit SecondOpinionExecuted(reportId, msg.sender, severity, outcome);
    }

    /// @notice Finalizes a report after timelock/dispute resolution and pays out.
    /// @param programId The program identifier.
    /// @param researcher The researcher payout address.
    /// @param reportHash The canonical report hash.
    /// @param severity The accepted severity tier set by the judge. 0=invalidated,1=Low,2=Medium,3=High,4=Critical
    /// @param outcome The outcome enum value (0=CONFIRM,1=REJECTED).
    function finalizeEscalation(
        uint256 programId,
        address researcher,
        bytes32 reportHash,
        uint8 severity,
        uint8 outcome
    ) external nonReentrant {
        require(judges.isJudge(msg.sender), "NOT_JUDGE");
        require(researcher != address(0), "RESEARCHER_ZERO");
        require(reportHash != bytes32(0), "HASH_ZERO");
        bytes32 reportId = reports.getReportId(programId,  researcher, reportHash);
        ReportManager.Report memory report = reports.getReport(reportId);
        require(report.primaryJudge != msg.sender, "PRIMARY_JUDGE_CANT_APPROVE_SECOND_OPINION");
        require(report.secondaryJudge == msg.sender, "NOT_SECOND_JUDGE");
        require(report.status != ReportManager.Status.CLOSED, "REPORT_CLOSED"); // closed
        require(report.escalated, "REPORT_NOT_ESCALATED");
        BountyProgramRegistry.ProgramConfig memory config = registry.getProgram(programId);
        require(
            config.status == BountyProgramRegistry.Status.ACTIVE ||
            config.status == BountyProgramRegistry.Status.PAUSED,
            "PROGRAM_NOT_ACTIVE"
        );
        require(report.escalationBps > 0, "NO_ESCALATION_FEE_SET");
        require(outcome == 0 || outcome == 1, "INVALID_OUTCOME");

//        ReportManager.Status reportStatusBefore = report.status;
        uint256 payoutAmount = report.payoutAmount; // 0 when rejected
        uint256 judgeFeeAmount = report.judgeFeeAmount; // 0 when rejected
//        uint256 secondaryFeeAmount = 0;
//        uint8 firstJudgePaid = 0;
//        uint8 secondJudgePaid = 0;
        uint16 judgePenaltyBps = 0;
        uint256 escalationAmount = 0;
        if (outcome == 0) { // second judge confirms valid finding, configure payouts
            require(severity > 0, "INVALID_SEVERITY_FOR_OUTCOME");
            // only penalize first judge if severity mismatch
            if (report.primarySeverity == 0 && severity > 0) {
                judgePenaltyBps = config.judgePenaltyInvalidBps;
            } else if (severity != report.primarySeverity) {
                judgePenaltyBps = config.judgePenaltyDowngradeBps;
            }

            uint16 escalationBps = 0;
            // take 10% when severity equals first judgement
            if (severity == report.primarySeverity) {
                escalationBps = 1_000; // 10%
            } else {
                escalationBps = _escalationBpsForSeverity(config, severity); // based on second judge severity
            }
            require(escalationBps > 0, "ESCALATION_NOT_CONFIGURED");
            // researcher marked escalated and judge rules in his favor for a piece of the bounty
            payoutAmount = registry.payoutBySeverity(programId, severity);
            require(payoutAmount > 0, "SEVERITY_NOT_CONFIGURED");
            require(escrow.bountyBalance(programId) >= payoutAmount, "INSUFFICIENT_BOUNTY");
            uint256 totalJudgeFeeAmount = escrow.getJudgeFee(programId);
            judgeFeeAmount = (payoutAmount * config.judgeFeeBps) / 10_000;
            if (judgeFeeAmount > 0) {
                require(totalJudgeFeeAmount >= judgeFeeAmount, "INSUFFICIENT_JUDGE");
            }
            escalationAmount = (payoutAmount * escalationBps) / 10_000;
            require(payoutAmount >= escalationAmount, "UNDERFLOW_CHECK");
            payoutAmount -= escalationAmount;
        } else if (outcome == 1) {
            require(severity == 0, "INVALID_SEVERITY_FOR_OUTCOME");
            escalationAmount = 0;
            payoutAmount = 0;
            judgeFeeAmount = 0;
            judgePenaltyBps= 0;
            outcome = 2;
        }

        reports.markEscalatedResult(
            reportId,
            msg.sender,
            severity,
            outcome,
            payoutAmount, // payout amount is set
            judgeFeeAmount, // judge fee is set, penalty needs to be calculated in payouts
            escalationAmount, // escalation amount is set
            judgePenaltyBps // only penalty bps is set still need to be calculated in payouts
        );

        emit ReportFinalizedEscalated(reportId, msg.sender, severity, outcome, escalationAmount);
    }

    /// @notice Finalizes a report after timelock/dispute resolution and pays out.
    /// @param programId The program identifier.
    /// @param researcher The researcher payout address.
    /// @param reportHash The canonical report hash.
    /// @param severity The accepted severity tier set by the judge. 0=invalidated,1=Low,2=Medium,3=High,4=Critical
    /// @param outcome The outcome enum value (0=CONFIRM,1=REJECTED).
    function finalizeAndPay(uint256 programId, address researcher, bytes32 reportHash, uint8 severity, uint8 outcome) external nonReentrant {
        require(researcher != address(0), "RESEARCHER_ZERO");
        require(reportHash != bytes32(0), "HASH_ZERO");
        bytes32 reportId = reports.getReportId(programId,  researcher, reportHash);
        ReportManager.Report memory report = reports.getReport(reportId);
        require(
            report.status == ReportManager.Status.APPROVED_PRIMARY ||
            report.status == ReportManager.Status.ESCALATED_RESOLVED ||
            report.status == ReportManager.Status.SECOND_OPINION_RESOLVED ||
            report.status == ReportManager.Status.READY_TO_PAY,
            "REPORT_NOT_FINALIZABLE"
        );

        if (report.status == ReportManager.Status.ESCALATED_RESOLVED ||
            report.status == ReportManager.Status.SECOND_OPINION_RESOLVED
        ) {
            require(report.secondaryJudge == msg.sender, "NOT_SECOND_JUDGE");
        } else {
            require(report.primaryJudge == msg.sender, "NOT_FIRST_JUDGE");
        }

        ReportManager.Status reportStatusBefore = report.status;
        if (
            report.status == ReportManager.Status.APPROVED_PRIMARY ||
            report.status == ReportManager.Status.ESCALATED_RESOLVED ||
            report.status == ReportManager.Status.SECOND_OPINION_RESOLVED
        ) {
            require(block.timestamp >= report.timelockEnd, "TIMELOCK_ACTIVE");
            reports.markReadyToPay(reportId);
            emit ReportReadyToPay(reportId);
            report = reports.getReport(reportId);
        }

        uint256 payoutAmount = report.payoutAmount;
        uint256 judgeFeeAmount = report.judgeFeeAmount;
        uint256 secondaryFeeAmount = 0;
        uint256 judgePenaltyBps = 0;
        uint8 firstJudgePaid = 0;
        uint8 secondJudgePaid = 0;
        BountyProgramRegistry.ProgramConfig memory config = registry.getProgram(programId);
        // DRAFT status to process remaining reports
        require(
            config.status == BountyProgramRegistry.Status.ACTIVE ||
            config.status == BountyProgramRegistry.Status.PAUSED ||
            config.status == BountyProgramRegistry.Status.DRAFT,
            "PROGRAM_NOT_ACTIVE"
        );
        if (reportStatusBefore == ReportManager.Status.ESCALATED_RESOLVED) {
            require(report.escalationAmount > 0, "INVALID_ESCALATION_RESULT");
            uint256 escalationAmount = report.escalationAmount;
            judgePenaltyBps = uint256(report.judgePenaltyBps);
            if (judgePenaltyBps > 0 && judgeFeeAmount > 0) {
                judgeFeeAmount = (judgeFeeAmount * (10_000 - judgePenaltyBps)) / 10_000;
                require(report.judgeFeeAmount >= judgeFeeAmount, "UNDERFLOW_CHECK");
                secondaryFeeAmount = report.judgeFeeAmount - judgeFeeAmount;
                require(report.judgeFeeAmount >= secondaryFeeAmount, "UNDERFLOW_CHECK");
            }
            // split 20/80 first/second judge
            uint256 treasuryShare = (escalationAmount * 2_000) / 10_000;
            uint256 judgesShare = escalationAmount - treasuryShare;
            uint256 primaryShare = (judgesShare * 2_000) / 10_000;
            uint256 secondaryShare = judgesShare - primaryShare;

            if (judgesShare > 0) {
                // Escalation reward for judges is sourced from the bounty pool.
                escrow.allocateEscalationJudgeBalance(programId, judgesShare);
            }
            judgeFeeAmount += primaryShare;
            secondaryFeeAmount += secondaryShare;

            // penalize first judge in full.
            if (judgePenaltyBps == 10_000) {
                judgeFeeAmount = 0;
                secondaryFeeAmount += primaryShare;
            }

            if (treasuryShare > 0) {
                require(escrow.payoutTreasuryFee(programId, config.treasury, treasuryShare), "PENALTY_TREASURY_TRANSFER_FAILED");
            }
            if (judgeFeeAmount > 0) {
                firstJudgePaid = 1;
                escrow.payoutJudge(programId, report.primaryJudge, judgeFeeAmount);
                judgeFeeAmount = 0;
            }
            if (secondaryFeeAmount > 0) {
                secondJudgePaid = 1;
                escrow.payoutJudge(programId, report.secondaryJudge, secondaryFeeAmount);
                secondaryFeeAmount= 0;
            }
        } else if (reportStatusBefore == ReportManager.Status.SECOND_OPINION_RESOLVED) {
            require(severity == report.secondarySeverity, "SEVERITY_MISMATCH");
            // check if severity is the same, split 80/20 first second
            if (severity == report.primarySeverity) {
                uint256 primaryShare = (judgeFeeAmount * 8_000) / 10_000;
                uint256 secondaryShare = judgeFeeAmount - primaryShare;

                judgeFeeAmount = primaryShare;
                secondaryFeeAmount = secondaryShare;
            } else if (severity < report.primarySeverity) {
                secondaryFeeAmount = judgeFeeAmount;
                // downgraded
                judgePenaltyBps = uint256(report.judgePenaltyBps);
                if (judgePenaltyBps == 10_000) {
                    judgeFeeAmount = 0;
                } else {
                    judgeFeeAmount = (judgeFeeAmount * (10_000 - judgePenaltyBps)) / 10_000;
                    secondaryFeeAmount = secondaryFeeAmount - judgeFeeAmount;
                }
            }
        }

        if (payoutAmount > 0) {
            require(escrow.bountyBalance(programId) >= payoutAmount, "INSUFFICIENT_BOUNTY");
        }
        if (judgeFeeAmount > 0 && firstJudgePaid == 0) {
            require(escrow.judgeBalance(programId) >= judgeFeeAmount, "INSUFFICIENT_JUDGE");
            escrow.payoutJudge(programId, report.primaryJudge, judgeFeeAmount);
        }
        if (secondaryFeeAmount > 0 && secondJudgePaid == 0) {
            require(report.secondaryJudge != address(0), "SECONDARY_JUDGE_NOT_SET");
            require(escrow.judgeBalance(programId) >= secondaryFeeAmount, "INSUFFICIENT_JUDGE");
            escrow.payoutJudge(programId, report.secondaryJudge, secondaryFeeAmount);
        }

        if (report.status == ReportManager.Status.READY_TO_PAY) {
            reports.markPaid(reportId);
            escrow.payoutBounty(programId, researcher, payoutAmount);
            emit PayoutExecuted(reportId, researcher, payoutAmount, report.primaryJudge, judgeFeeAmount);
        } else {
            reports.markClosed(reportId);
        }
    }

    /// @notice Emergency admin function to close a READY_TO_PAY report when normal payout is permanently blocked.
    /// @dev Use alongside EscrowVault.emergencyBountyPayout to handle blacklisted researchers.
    /// @param reportId The stuck report identifier.
    function emergencyCloseReport(bytes32 reportId) external {
        require(msg.sender == registry.admin(), "NOT_ADMIN");
        ReportManager.Report memory report = reports.getReport(reportId);
        require(report.status == ReportManager.Status.READY_TO_PAY, "NOT_READY_TO_PAY");
        reports.markClosed(reportId);
    }

    /// @notice Resolves escalation basis points for a severity tier.
    /// @dev Severity 1 currently maps to medium escalation bps in this MVP.
    /// @param config Program configuration containing escalation settings.
    /// @param severity Severity tier (1..4).
    /// @return Escalation bps for the tier, or 0 when unsupported.
    function _escalationBpsForSeverity(
        BountyProgramRegistry.ProgramConfig memory config,
        uint8 severity
    ) internal pure returns (uint16) {
        if (severity == 4) {
            return config.escalationCriticalBps;
        }
        if (severity == 3) {
            return config.escalationHighBps;
        }
        if (severity == 2) {
            return config.escalationMediumBps;
        }
        if (severity == 1) {
            return config.escalationLowBps;
        }
        return 0;
    }
}
