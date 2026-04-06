// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "./JudgeRegistry.sol";
import {BountyProgramRegistry} from "./BountyProgramRegistry.sol";

contract ReportManager {
    enum Status {
        NONE,
        SUBMITTED,
        APPROVED_PRIMARY,
        ESCALATED,
        SECOND_OPINION_REQUESTED,
        SECOND_OPINION_RESOLVED,
        SECOND_OPINION_REJECTED,
        ESCALATED_RESOLVED,
        ESCALATED_REJECTED,
        READY_TO_PAY,
        REJECTED,
        PAID,
        CLOSED
    }

    struct Report {
        uint256 programId;
        address researcher;
        bytes32 reportHash;
        uint8 primarySeverity;
        uint8 secondarySeverity;
        Status status;
        address primaryJudge;
        address secondaryJudge;
        uint256 payoutAmount;
        uint256 judgeFeeAmount;
        uint256 escalationAmount;
        uint256 createdAt;
        uint256 approvedAt;
        uint256 timelockEnd;
        uint256 paidAt;
        bool secondOpinionRequested;
        bool escalated;
        uint16 escalationBps;
        uint16 judgePenaltyBps;
        uint16 companyPenaltyBps;
    }

    mapping(bytes32 => Report) internal reports;
    mapping(uint256 => uint256) public blockingReportCount;

    address public payoutController;
    address public admin;
    address public pendingAdmin;
    JudgeRegistry public judgeRegistry;
    BountyProgramRegistry public programRegistry;

    event ReportSubmitted(bytes32 indexed reportId, uint256 indexed programId, address indexed researcher, bytes32 reportHash);
    event ReportApprovedPrimary(
        bytes32 indexed reportId,
        uint256 indexed programId,
        address indexed judge,
        uint8 severity,
        uint256 payoutAmount,
        uint256 judgeFeeAmount,
        uint256 timelockEnd
    );
    event ReportRejected(
        bytes32 indexed reportId,
        uint256 indexed programId,
        address indexed judge,
        uint8 severity,
        uint256 payoutAmount,
        uint256 judgeFeeAmount,
        uint256 timelockEnd
    );
    event ReportEscalated(bytes32 indexed reportId, address indexed researcher, uint16 escalationBps);
    event SecondOpinionRequested(bytes32 indexed reportId, address indexed companyOwner);
    event SecondJudgeAssigned(bytes32 indexed reportId, address indexed judge);
    event SecondOpinionResolved(bytes32 indexed reportId, address indexed judge, uint8 severity, uint8 outcome);
    event EscalationResolved(bytes32 indexed reportId, address indexed judge, uint8 severity, uint8 outcome, uint256 payoutAmount, uint256 judgeAmount);
    event ReportReadyToPay(bytes32 indexed reportId);
    event ReportPaid(bytes32 indexed reportId, uint256 indexed programId, address indexed researcher, uint256 payoutAmount);
    event ReportClosed(bytes32 indexed reportId, uint256 indexed programId, address indexed researcher, uint256 payoutAmount);
    event PayoutControllerUpdated(address payoutController);
    event AdminUpdated(address admin);

    modifier onlyAdmin() {
        require(msg.sender == admin, "NOT_ADMIN");
        _;
    }

    modifier onlyPayoutController() {
        require(msg.sender == payoutController, "NOT_PAYOUT_CONTROLLER");
        _;
    }

    /// @notice Initializes the report manager with an admin.
    /// @dev The admin sets the payout controller that can write approval/paid state.
    /// @param admin_ The admin address.
    constructor(address admin_, address judgeRegistry_, address programRegistry_) {
        require(admin_ != address(0), "ADMIN_ZERO");
        require(judgeRegistry_ != address(0), "JUDGE_REGISTRY_ZERO");
        require(programRegistry_ != address(0), "PROGRAM_REGISTRY_ZERO");
        admin = admin_;
        judgeRegistry = JudgeRegistry(judgeRegistry_);
        programRegistry = BountyProgramRegistry(programRegistry_);
        emit AdminUpdated(admin_);
    }

    /// @notice Initiates a two-step admin transfer by setting the pending admin.
    /// @dev The new admin must call acceptAdmin() to finalize.
    /// @param newAdmin The address to assign as the new admin.
    function setAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "ADMIN_ZERO");
        require(admin != newAdmin, "ALREADY_ADMIN");
        pendingAdmin = newAdmin;
    }

    /// @notice Finalizes admin transfer; must be called by the pending admin.
    function acceptAdmin() external {
        require(msg.sender == pendingAdmin, "NOT_PENDING_ADMIN");
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit AdminUpdated(admin);
    }

    /// @notice Sets the only contract allowed to approve/pay reports.
    /// @dev Must be set to the PayoutController before approvals can occur.
    /// @param payoutController_ The authorized payout controller address.
    function setPayoutController(address payoutController_) external onlyAdmin {
        require(payoutController_ != address(0), "PAYOUT_ZERO");
        require(payoutController != payoutController_, "ALREADY_PAYOUT");
        payoutController = payoutController_;
        emit PayoutControllerUpdated(payoutController_);
    }

    /// @notice Computes the reportId used for replay protection.
    /// @dev reportId = keccak256(abi.encode(programId, researcher, reportHash)).
    /// @param programId The program identifier.
    /// @param researcher The researcher payout address.
    /// @param reportHash The offchain report hash/canonical payload hash.
    /// @return reportId The derived report identifier.
    function getReportId(uint256 programId, address researcher, bytes32 reportHash) public pure returns (bytes32) {
        return keccak256(abi.encode(programId, researcher, reportHash));
    }

    /// @notice Anchors a report hash onchain with an assigned primary judge.
    /// @dev MVP Admin submits reports to start the onchain workflow.
    /// @param programId The program identifier.
    /// @param researcher The researcher payout address to lock for the report.
    /// @param judge The primary judge assigned to approve the report.
    /// @param reportHash The canonical report hash.
    /// @return reportId The derived report identifier.
    function submitReport(uint256 programId, address researcher, address judge, bytes32 reportHash) external onlyAdmin returns (bytes32 reportId) {
        require(researcher != address(0), "RESEARCHER_ZERO");
        require(judge != address(0), "JUDGE_ZERO");
        require(reportHash != bytes32(0), "HASH_ZERO");
        BountyProgramRegistry.ProgramConfig memory config = programRegistry.getProgram(programId);
        require(config.status == BountyProgramRegistry.Status.ACTIVE, "PROGRAM_NOT_ACTIVE");

        reportId = getReportId(programId,  researcher, reportHash);
        Report storage report = reports[reportId];
        require(report.status == Status.NONE, "REPORT_EXISTS");

        judgeRegistry.setJudge(judge, true);

        report.programId = programId;
        report.researcher = researcher;
        report.primaryJudge = judge;
        report.reportHash = reportHash;
        _transitionStatus(report, Status.SUBMITTED);
        report.createdAt = block.timestamp;

        emit ReportSubmitted(reportId, programId, researcher, reportHash);
    }

    /// @notice Marks a report approved by the primary judge and starts the timelock (payout controller only).
    /// @dev Report must already be submitted with a matching program/researcher/hash/primary judge.
    /// @param reportId The report identifier.
    /// @param programId The program identifier.
    /// @param researcher The researcher payout address.
    /// @param reportHash The canonical report hash.
    /// @param judge The approving judge address.
    /// @param severity The accepted severity tier. 1=Low,2=Medium,3=High,4=Critical
    /// @param payoutAmount The bounty payout amount.
    /// @param judgeFeeAmount The judge fee payout amount.
    /// @param timelockEnd The unix timestamp when the second-opinion window ends.
    function markApprovedPrimary(
        bytes32 reportId,
        uint256 programId,
        address researcher,
        bytes32 reportHash,
        address judge,
        uint8 severity,
        uint256 payoutAmount,
        uint256 judgeFeeAmount,
        uint256 timelockEnd
    ) external onlyPayoutController {
        Report storage report = reports[reportId];
        require(report.status == Status.SUBMITTED, "REPORT_NOT_SUBMITTED");
        require(report.programId == programId, "PROGRAM_MISMATCH");
        require(report.researcher == researcher, "RESEARCHER_MISMATCH");
        require(report.primaryJudge == judge, "JUDGE_MISMATCH");
        require(report.reportHash == reportHash, "HASH_MISMATCH");
        require(severity < 5, "INVALID_SEVERITY");
        if (severity == 0) {
            _transitionStatus(report, Status.REJECTED);
            emit ReportRejected(reportId, report.programId, judge, severity, payoutAmount, judgeFeeAmount, timelockEnd);
        } else {
            _transitionStatus(report, Status.APPROVED_PRIMARY);
            emit ReportApprovedPrimary(reportId, report.programId, judge, severity, payoutAmount, judgeFeeAmount, timelockEnd);
        }
        report.primarySeverity = severity;
        report.payoutAmount = payoutAmount;
        report.judgeFeeAmount = judgeFeeAmount;
        report.approvedAt = block.timestamp;
        report.timelockEnd = timelockEnd;
    }

    /// @notice Marks a report as escalated by the researcher (payout controller only).
    /// @param reportId The report identifier.
    /// @param escalationBps The escalation percent in bps.
    function markEscalated(bytes32 reportId, uint16 escalationBps) external onlyPayoutController {
        Report storage report = reports[reportId];
        require(report.status == Status.APPROVED_PRIMARY || report.status == Status.REJECTED, "REPORT_NOT_ESCALATABLE");
        report.escalated = true;
        report.escalationBps = escalationBps;
        _transitionStatus(report, Status.ESCALATED);
        emit ReportEscalated(reportId, report.researcher, escalationBps);
    }

    /// @notice Marks a report as requested for second opinion (payout controller only).
    /// @param reportId The report identifier.
    /// @param companyOwner The company owner requesting the second opinion (for event indexing).
    function markSecondOpinionRequested(bytes32 reportId, address companyOwner) external onlyPayoutController {
        Report storage report = reports[reportId];
        require(report.status == Status.APPROVED_PRIMARY || report.status == Status.ESCALATED, "REPORT_NOT_REQUESTABLE");
        report.secondOpinionRequested = true;
        _transitionStatus(report, Status.SECOND_OPINION_REQUESTED);
        emit SecondOpinionRequested(reportId, companyOwner);
    }

    /// @notice Assigns a secondary judge (admin only).
    /// @param reportId The report identifier.
    /// @param judge The judge to assign.
    function assignSecondJudge(bytes32 reportId, address judge) external onlyAdmin {
        require(judge != address(0), "JUDGE_ZERO");
        Report storage report = reports[reportId];
        require(report.primaryJudge != judge, "FIRST_JUDGE_CANT_BE_SECOND_JUDGE");
        require(report.status == Status.SECOND_OPINION_REQUESTED || report.status == Status.ESCALATED, "REPORT_NOT_IN_RIGHT_STATE");
        judgeRegistry.setJudge(judge, true);
        report.secondaryJudge = judge;
        emit SecondJudgeAssigned(reportId, judge);
    }

    /// @notice Records the secondary judge outcome (payout controller only).
    /// @param reportId The report identifier.
    /// @param judge The secondary judge address.
    /// @param severity The secondary severity tier (0 if invalidated).
    /// @param outcome The outcome enum value (0=CONFIRM,1=DOWNGRADE,2=INVALIDATE).
    /// @param payoutAmount The updated payout amount (0 if invalidated).
    /// @param judgePenaltyBps The judge penalty percent in bps.
    /// @param companyPenaltyBps The company penalty percent in bps.
    function markSecondOpinion(
        bytes32 reportId,
        address judge,
        uint8 severity,
        uint8 outcome,
        uint256 payoutAmount,
        uint256 judgeAmount,
        uint16 judgePenaltyBps,
        uint16 companyPenaltyBps
    ) external onlyPayoutController {
        Report storage report = reports[reportId];
        require(report.status == Status.SECOND_OPINION_REQUESTED, "REPORT_NOT_IN_SECOND_OPINION");
        require(report.secondaryJudge == judge, "SECOND_JUDGE_MISMATCH");
        report.secondarySeverity = severity;

        report.payoutAmount = payoutAmount;
        if (outcome == 2) {
            _transitionStatus(report, Status.SECOND_OPINION_REJECTED); // finalize and pay can be skipped if second judge invalidates the report.
            report.judgePenaltyBps = judgePenaltyBps;
            report.judgeFeeAmount = judgeAmount;
        } else {
            _transitionStatus(report, Status.SECOND_OPINION_RESOLVED);
            report.judgePenaltyBps = judgePenaltyBps;
            report.judgeFeeAmount = judgeAmount;
            report.companyPenaltyBps = companyPenaltyBps;
        }
        emit SecondOpinionResolved(reportId, judge, severity, outcome);
    }

    function markEscalatedResult(
        bytes32 reportId,
        address judge,
        uint8 severity,
        uint8 outcome,
        uint256 payoutAmount,
        uint256 judgeAmount,
        uint256 escalationAmount,
        uint16 judgePenaltyBps
    ) external onlyPayoutController {
        Report storage report = reports[reportId];
        require(report.status == Status.ESCALATED, "REPORT_NOT_ESCALATED");
        require(report.secondaryJudge == judge, "SECOND_JUDGE_MISMATCH");
        report.secondarySeverity = severity;
        report.payoutAmount = payoutAmount;
        report.escalationAmount = escalationAmount;
        report.judgeFeeAmount = judgeAmount;
        if (outcome == 2) {
            _transitionStatus(report, Status.ESCALATED_REJECTED); // No payouts
        } else {
            _transitionStatus(report, Status.ESCALATED_RESOLVED);
            if (severity != report.primarySeverity) {
                report.judgePenaltyBps = judgePenaltyBps;
            }
        }

        emit EscalationResolved(reportId, judge, severity, outcome, payoutAmount, judgeAmount);
    }

    /// @notice Marks a report ready to pay after timelock/dispute resolution (payout controller only).
    /// @param reportId The report identifier.
    function markReadyToPay(bytes32 reportId) external onlyPayoutController {
        Report storage report = reports[reportId];
        require(
            report.status == Status.APPROVED_PRIMARY ||
            report.status == Status.ESCALATED_RESOLVED ||
            report.status == Status.SECOND_OPINION_RESOLVED,
            "REPORT_NOT_READYABLE"
        );
        _transitionStatus(report, Status.READY_TO_PAY);
        emit ReportReadyToPay(reportId);
    }

    /// @notice Marks a ready report as paid (payout controller only).
    /// @dev Moves status from READY_TO_PAY to PAID and records paid timestamp.
    /// @param reportId The report identifier.
    function markPaid(bytes32 reportId) external onlyPayoutController {
        Report storage report = reports[reportId];
        require(report.status == Status.READY_TO_PAY, "REPORT_NOT_READY");
        _transitionStatus(report, Status.PAID);
        report.paidAt = block.timestamp;
        emit ReportPaid(reportId, report.programId, report.researcher, report.payoutAmount);
    }

    /// @notice Marks a report as closed (payout controller only).
    /// @param reportId The report identifier.
    function markClosed(bytes32 reportId) external onlyPayoutController {
        Report storage report = reports[reportId];
        require(report.status != Status.CLOSED, "ALREADY_CLOSED");
        _transitionStatus(report, Status.CLOSED);
        emit ReportClosed(reportId, report.programId, report.researcher, 0);
    }

    /// @notice Returns true when a program has at least one unresolved report that blocks refund.
    function hasBlockingReports(uint256 programId) external view returns (bool) {
        return blockingReportCount[programId] > 0;
    }

    /// @notice Returns the current report status.
    /// @dev Returns NONE for unknown reports.
    /// @param reportId The report identifier.
    /// @return status The report status enum value.
    function getReportStatus(bytes32 reportId) external view returns (Status status) {
        return reports[reportId].status;
    }

    /// @notice Returns the full report struct for a reportId.
    /// @param reportId The report identifier.
    /// @return report The stored report struct.
    function getReport(bytes32 reportId) external view returns (Report memory report) {
        return reports[reportId];
    }

    function _transitionStatus(Report storage report, Status newStatus) internal {
        Status oldStatus = report.status;
        if (oldStatus == newStatus) {
            return;
        }

        bool wasBlocking = _isBlockingStatus(oldStatus);
        bool isBlocking = _isBlockingStatus(newStatus);

        if (!wasBlocking && isBlocking) {
            blockingReportCount[report.programId] += 1;
        } else if (wasBlocking && !isBlocking) {
            blockingReportCount[report.programId] -= 1;
        }

        report.status = newStatus;
    }

    function _isBlockingStatus(Status status) internal pure returns (bool) {
        return status == Status.SUBMITTED
            || status == Status.APPROVED_PRIMARY
            || status == Status.ESCALATED
            || status == Status.SECOND_OPINION_REQUESTED
            || status == Status.SECOND_OPINION_RESOLVED
            || status == Status.ESCALATED_RESOLVED
            || status == Status.READY_TO_PAY;
    }
}
