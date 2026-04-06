// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface IReportManager {
    // Must match ReportManager.Status order exactly
    enum ReportStatus {
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
    function getReportId(uint256 programId, address researcher, bytes32 reportHash) external pure returns (bytes32);
    function getReportStatus(bytes32 reportId) external view returns (ReportStatus);
    function hasBlockingReports(uint256 programId) external view returns (bool);
}

interface IEscrowVault {
    function refund(uint256 programId) external;
}

contract BountyProgramRegistry {
    enum Status {
        NONE,
        DRAFT,
        ACTIVE,
        PAUSED,
        CLOSED
    }

    struct ProgramConfig {
        address companyOwner;
        address payoutToken;
        uint16 judgeFeeBps;
        uint16 treasuryFeeBps;
        address treasury;
        uint16 companyPenaltyBps;
        uint16 judgePenaltyInvalidBps;
        uint16 judgePenaltyDowngradeBps;
        uint16 escalationCriticalBps;
        uint16 escalationHighBps;
        uint16 escalationMediumBps;
        uint16 escalationLowBps;
        Status status;
        uint64 createdAt;
        uint64 updatedAt;
        uint64 pausedAt;
    }

    struct ProgramConfigInput {
        address companyOwner;
        address payoutToken; // usdc
        uint16 judgeFeeBps; // deprecated
        uint16 treasuryFeeBps; // deprecated
        address treasury; // create a setter for this
        uint8[] severities;
        uint256[] payoutAmounts;
    }

    uint256 public constant MIN_DEPOSIT = 1e6;

    mapping(uint256 => ProgramConfig) internal programs;
    mapping(uint256 => mapping(uint8 => uint256)) public payoutBySeverity; // 1=Low,2=Medium,3=High,4=Critical
    mapping(uint256 => bool) public hasPayoutSchedule;
    mapping(uint256 => uint256) public totalPayoutByProgram;

    uint256 public nextProgramId = 1;
    address public admin;
    address public pendingAdmin;
    address public treasury;

    uint16 public treasuryFeeBps;
    uint16 public judgeFeeBps;

    uint16 public escalationCriticalBps;
    uint16 public escalationHighBps;
    uint16 public escalationMediumBps;
    uint16 public escalationLowBps;

    uint16 public companyPenaltyBps;
    uint16 public judgePenaltyInvalidBps;
    uint16 public judgePenaltyDowngradeBps;

    address public escrowVault;
    address public judgeRegistry;
    address public payoutController;
    address public reportManager;
    /// @notice The only ERC-20 token accepted as payoutToken when creating programs.
    address public allowedPayoutToken;

    uint256 public constant REFUND_WINDOW = 5 days;

    event ProgramCreated(
        uint256 indexed programId,
        address indexed companyOwner,
        address payoutToken,
        address treasury,
        bytes32 configHash
    );
    event ProgramStatusChanged(uint256 indexed programId, Status status, uint64 changedAt);
    event ProgramPayoutUpdated(uint256 indexed programId, uint8 severity, uint256 amount);
    event PenaltyConfigUpdated(
        uint16 companyPenaltyBps, uint16 judgePenaltyInvalidBps, uint16 judgePenaltyDowngradeBps
    );
    event ProgramPenaltyUpdated(
        uint256 indexed programId,
        uint16 companyPenaltyBps,
        uint16 judgePenaltyInvalidBps,
        uint16 judgePenaltyDowngradeBps
    );
    event EscalationConfigUpdated(
        uint16 escalationCriticalBps, uint16 escalationHighBps, uint16 escalationMediumBps, uint16 escalationLowBps
    );
    event RegistryAddressesUpdated(address escrowVault, address judgeRegistry, address payoutController);
    event EscrowVaultUpdated(address escrowVault);
    event JudgeRegistryUpdated(address judgeRegistry);
    event PayoutControllerRegistryUpdated(address payoutController);
    event AllowedPayoutTokenUpdated(address token);
    event AdminUpdated(address admin);
    event TreasuryUpdated(address treasury);
    event RefundInitiated(uint256 indexed programId, address indexed company, uint256 refundInitiatedAt);
    event RefundCancelled(uint256 indexed programId, address indexed researcher, bytes32 reportId);
    event ProgramClosed(uint256 indexed programId, address indexed company, uint256 refundedAt);

    error NoOpenReport();

    modifier onlyAdmin() {
        require(msg.sender == admin, "NOT_ADMIN");
        _;
    }

    modifier onlyProgramOwner(uint256 programId) {
        require(msg.sender == programs[programId].companyOwner, "NOT_PROGRAM_OWNER");
        _;
    }

    modifier onlyEscrowVault() {
        require(msg.sender == escrowVault, "NOT_ESCROW_VAULT");
        _;
    }

    modifier onlyPayoutController() {
        require(msg.sender == payoutController, "NOT_PAYOUT_CONTROLLER");
        _;
    }

    /// @notice Initializes the registry with the protocol admin.
    /// @dev The admin can update global registry references and act as an emergency operator.
    /// @param admin_ Address with admin privileges (multisig recommended).
    constructor(
        address admin_,
        address treasury_,
        uint16 treasuryFeeBps_,
        uint16 judgeFeeBps_,
        uint16 escalationCriticalBps_,
        uint16 escalationHighBps_,
        uint16 escalationMediumBps_,
        uint16 escalationLowBps_,
        uint16 companyPenaltyBps_,
        uint16 judgePenaltyInvalidBps_,
        uint16 judgePenaltyDowngradeBps_,
        address allowedPayoutToken_
    ) {
        require(admin_ != address(0), "ADMIN_ZERO");
        require(treasury_ != address(0), "TREASURY_ZERO");
        require(allowedPayoutToken_ != address(0), "TOKEN_ZERO");
        admin = admin_;
        treasury = treasury_;
        allowedPayoutToken = allowedPayoutToken_;
        _setGlobalFeesAndEscalations(
            treasuryFeeBps_,
            judgeFeeBps_,
            escalationCriticalBps_,
            escalationHighBps_,
            escalationMediumBps_,
            escalationLowBps_
        );
        _setGlobalPenalties(companyPenaltyBps_, judgePenaltyInvalidBps_, judgePenaltyDowngradeBps_);

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

    /// @notice Updates the protocol treasury receiver.
    /// @dev Newly created programs will use this treasury address.
    /// @param treasury_ New treasury recipient.
    function setTreasury(address treasury_) external onlyAdmin {
        require(treasury_ != address(0), "TREASURY_ZERO");
        require(treasury != treasury_, "ALREADY_TREASURY");
        treasury = treasury_;
        emit TreasuryUpdated(treasury);
    }

    /// @notice Updates the escrow vault address individually.
    /// @param escrowVault_ The new escrow vault address.
    function setEscrowVault(address escrowVault_) external onlyAdmin {
        require(escrowVault_ != address(0), "ESCROW_ZERO");
        require(escrowVault != escrowVault_, "ALREADY_ESCROW");
        escrowVault = escrowVault_;
        emit EscrowVaultUpdated(escrowVault_);
    }

    /// @notice Updates the judge registry address individually.
    /// @param judgeRegistry_ The new judge registry address.
    function setJudgeRegistry(address judgeRegistry_) external onlyAdmin {
        require(judgeRegistry_ != address(0), "JUDGE_ZERO");
        require(judgeRegistry != judgeRegistry_, "ALREADY_JUDGE");
        judgeRegistry = judgeRegistry_;
        emit JudgeRegistryUpdated(judgeRegistry_);
    }

    /// @notice Updates the payout controller address individually.
    /// @param payoutController_ The new payout controller address.
    function setPayoutController(address payoutController_) external onlyAdmin {
        require(payoutController_ != address(0), "PAYOUT_ZERO");
        require(payoutController != payoutController_, "ALREADY_PAYOUT");
        payoutController = payoutController_;
        emit PayoutControllerRegistryUpdated(payoutController_);
    }

    /// @notice Updates the allowed payout token.
    /// @param token_ The new allowed ERC-20 token address.
    function setAllowedPayoutToken(address token_) external onlyAdmin {
        require(token_ != address(0), "TOKEN_ZERO");
        require(allowedPayoutToken != token_, "ALREADY_TOKEN");
        allowedPayoutToken = token_;
        emit AllowedPayoutTokenUpdated(token_);
    }

    /// @notice Sets the report manager address used to validate open researcher reports.
    /// @param reportManager_ The ReportManager contract address.
    function setReportManager(address reportManager_) external onlyAdmin {
        require(reportManager_ != address(0), "REPORT_MANAGER_ZERO");
        require(reportManager != reportManager_, "ALREADY_REPORT_MANAGER");
        reportManager = reportManager_;
    }

    /// @notice Initiates a pause-and-refund sequence for a program.
    /// @dev Only the program owner can call this when the program is ACTIVE or DRAFT.
    /// @dev Refund initiation is blocked while unresolved reports still exist on the program.
    /// @param programId The program to pause.
    function initiateRefund(uint256 programId) external {
        ProgramConfig storage config = programs[programId];
        require(config.companyOwner != address(0), "PROGRAM_NOT_FOUND");
        require(msg.sender == config.companyOwner, "NOT_PROGRAM_OWNER");
        require(config.status == Status.ACTIVE || config.status == Status.DRAFT, "PROGRAM_NOT_REFUNDABLE");
        require(reportManager != address(0), "REPORT_MANAGER_ZERO");
        require(!IReportManager(reportManager).hasBlockingReports(programId), "OPEN_REPORTS_EXIST");

        config.status = Status.PAUSED;
        config.pausedAt = uint64(block.timestamp);
        config.updatedAt = uint64(block.timestamp);

        emit RefundInitiated(programId, msg.sender, block.timestamp);
    }

    /// @notice Executes the refund and permanently closes the program.
    /// @dev Only the program owner can call this after the 5-day cancellation window has passed.
    /// @dev Refund remains blocked while unresolved reports exist on the program.
    /// @dev Calls EscrowVault.refund to return remaining bounty funds to the company.
    /// @param programId The program to close and refund.
    function executeRefund(uint256 programId) external {
        ProgramConfig storage config = programs[programId];
        require(config.companyOwner != address(0), "PROGRAM_NOT_FOUND");
        require(msg.sender == config.companyOwner, "NOT_PROGRAM_OWNER");
        require(config.status == Status.PAUSED, "PROGRAM_NOT_REFUND_STATE");
        require(block.timestamp > uint256(config.pausedAt) + REFUND_WINDOW, "REFUND_WINDOW_NOT_PASSED");
        require(reportManager != address(0), "REPORT_MANAGER_ZERO");
        require(!IReportManager(reportManager).hasBlockingReports(programId), "OPEN_REPORTS_EXIST");

        config.status = Status.CLOSED;
        config.updatedAt = uint64(block.timestamp);

        IEscrowVault(escrowVault).refund(programId);

        emit ProgramClosed(programId, msg.sender, block.timestamp);
    }

    /// @notice Creates a new bounty program and returns its programId.
    /// @dev Program status is set to DRAFT until the first deposit activates it.
    /// @dev Fee bps must sum to <= 10_000. Optional severity payouts are stored onchain and
    /// @dev enforce strict payout matching if a schedule is provided. The total schedule sum
    /// @dev is tracked for deposit-based activation checks.
    /// @param input Program configuration input (owner, token, fee bps, treasury, optional severities).
    /// @return programId The newly created program identifier.
    function createProgram(ProgramConfigInput calldata input) external returns (uint256 programId) {
        require(input.companyOwner != address(0), "OWNER_ZERO");
        require(input.payoutToken != address(0), "TOKEN_ZERO");
        require(input.payoutToken == allowedPayoutToken, "TOKEN_NOT_ALLOWED");
        require(treasury != address(0), "TREASURY_ZERO");
        require(uint256(judgeFeeBps) + uint256(treasuryFeeBps) <= 1_000, "BPS_INVALID"); // 10%
        require(input.severities.length == input.payoutAmounts.length, "PAYOUT_LENGTH");

        programId = nextProgramId++;
        _storeProgramConfig(programId, input);
        _storePayoutSchedule(programId, input.severities, input.payoutAmounts);

        emit ProgramCreated(
            programId,
            input.companyOwner,
            input.payoutToken,
            treasury,
            _programConfigHash(input)
        );
    }

    function _storeProgramConfig(uint256 programId, ProgramConfigInput calldata input) internal {
        uint64 timestamp = uint64(block.timestamp);
        ProgramConfig storage config = programs[programId];
        config.companyOwner = input.companyOwner;
        config.payoutToken = input.payoutToken;
        config.judgeFeeBps = judgeFeeBps;
        config.treasuryFeeBps = treasuryFeeBps;
        config.treasury = treasury;
        config.companyPenaltyBps = 0;
        config.judgePenaltyInvalidBps = 0;
        config.judgePenaltyDowngradeBps = 0;
        config.escalationCriticalBps = escalationCriticalBps;
        config.escalationHighBps = escalationHighBps;
        config.escalationMediumBps = escalationMediumBps;
        config.escalationLowBps = escalationLowBps;
        config.status = Status.DRAFT;
        config.createdAt = timestamp;
        config.updatedAt = timestamp;
        config.pausedAt = 0;
    }

    function _storePayoutSchedule(
        uint256 programId,
        uint8[] calldata severities,
        uint256[] calldata payoutAmounts
    ) internal {
        uint256 severityCount = severities.length;
        if (severityCount > 0) {
            hasPayoutSchedule[programId] = true;
        }

        uint256 seenMask;
        for (uint256 i = 0; i < severityCount; i++) {
            uint8 severity = severities[i];
            require(severity != 0, "SEVERITY_ZERO");
            require(severity < 5, "INVALID_SEVERITY");

            uint256 severityBit = uint256(1) << severity;
            require((seenMask & severityBit) == 0, "DUPLICATE_SEVERITY");
            seenMask |= severityBit;

            uint256 payoutAmount = payoutAmounts[i];
            require(payoutAmount > MIN_DEPOSIT, "SEVERITY_AMOUNT_NOT_MIN_DEPOSIT");
            payoutBySeverity[programId][severity] = payoutAmount;
            totalPayoutByProgram[programId] += payoutAmount;

            emit ProgramPayoutUpdated(programId, severity, payoutAmount);
        }
    }

    function _programConfigHash(ProgramConfigInput calldata input) internal view returns (bytes32) {
        bytes32 payoutHash = keccak256(abi.encode(input.severities, input.payoutAmounts));
        return keccak256(
            abi.encode(input.companyOwner, input.payoutToken, judgeFeeBps, treasuryFeeBps, treasury, payoutHash)
        );
    }

    /// @notice Activates a program from a deposit.
    /// @dev Only the escrow vault can call this. No-op if already active.
    /// @param programId The program identifier.
    function activateFromDeposit(uint256 programId) external onlyEscrowVault {
        ProgramConfig storage config = programs[programId];
        require(config.companyOwner != address(0), "PROGRAM_NOT_FOUND");
        if (config.status == Status.DRAFT) {
            config.status = Status.ACTIVE;
            config.updatedAt = uint64(block.timestamp);
            emit ProgramStatusChanged(programId, Status.ACTIVE, uint64(block.timestamp));
        }
    }

    /// @notice Deactivates a funded program after bounty payout consumption.
    /// @dev Only escrow vault can call this transition. ACTIVE programs move back to DRAFT.
    /// @param programId The program identifier.
    function deactivateFromPaidBounty(uint256 programId) external onlyEscrowVault {
        ProgramConfig storage config = programs[programId];
        require(config.companyOwner != address(0), "PROGRAM_NOT_FOUND");
        if (config.status == Status.ACTIVE) {
            config.status = Status.DRAFT;
            config.updatedAt = uint64(block.timestamp);
            emit ProgramStatusChanged(programId, Status.DRAFT, uint64(block.timestamp));
        }
    }

    /// @notice Sets per-program company penalty basis points.
    /// @dev Called by payout controller when second-opinion/dispute rules enable penalties.
    /// @param programId The program identifier.
    /// @param companyPenaltyBps_ Company penalty in bps.
    function setCompanyPenalty(uint256 programId, uint16 companyPenaltyBps_) external onlyPayoutController {
        ProgramConfig storage config = programs[programId];
        require(config.companyOwner != address(0), "PROGRAM_NOT_FOUND");
        require(programs[programId].status != Status.CLOSED, "ALREADY_CLOSED");

        config.companyPenaltyBps = companyPenaltyBps_;
        config.updatedAt = uint64(block.timestamp);
        emit ProgramPenaltyUpdated(
            programId, config.companyPenaltyBps, config.judgePenaltyInvalidBps, config.judgePenaltyDowngradeBps
        );
    }

    /// @notice Sets per-program judge penalty basis points.
    /// @dev Called by payout controller for dispute flows (invalidations/downgrades).
    /// @param programId The program identifier.
    /// @param judgePenaltyInvalidBps_ Judge penalty bps for invalid outcomes.
    /// @param judgePenaltyDowngradeBps_ Judge penalty bps for downgraded outcomes.
    function setJudgePenalty(uint256 programId, uint16 judgePenaltyInvalidBps_, uint16 judgePenaltyDowngradeBps_)
        external
        onlyPayoutController
    {
        ProgramConfig storage config = programs[programId];
        require(config.companyOwner != address(0), "PROGRAM_NOT_FOUND");
        require(programs[programId].status != Status.CLOSED, "ALREADY_CLOSED");

        config.judgePenaltyInvalidBps = judgePenaltyInvalidBps_;
        config.judgePenaltyDowngradeBps = judgePenaltyDowngradeBps_;
        config.updatedAt = uint64(block.timestamp);
        emit ProgramPenaltyUpdated(
            programId, config.companyPenaltyBps, config.judgePenaltyInvalidBps, config.judgePenaltyDowngradeBps
        );
    }

    /// @notice Returns the full program configuration.
    /// @dev Use this for onchain reads and backend indexing; returns default values if not found.
    /// @param programId The program identifier.
    /// @return config The stored program configuration struct.
    function getProgram(uint256 programId) external view returns (ProgramConfig memory config) {
        return programs[programId];
    }

    /// @notice Returns global treasury fee in bps.
    /// @return Treasury fee basis points.
    function getTreasuryFeeBps() external view returns (uint16) {
        return treasuryFeeBps;
    }

    /// @notice Returns global judge fee in bps.
    /// @return Judge fee basis points.
    function getJudgeFeeBps() external view returns (uint16) {
        return judgeFeeBps;
    }

    /// @notice Returns escalation bps for critical severity.
    /// @return Escalation basis points for critical reports.
    function getEscalationCriticalBps() external view returns (uint16) {
        return escalationCriticalBps;
    }

    /// @notice Returns escalation bps for high severity.
    /// @return Escalation basis points for high reports.
    function getEscalationHighBps() external view returns (uint16) {
        return escalationHighBps;
    }

    /// @notice Returns escalation bps for medium severity.
    /// @return Escalation basis points for medium reports.
    function getEscalationMediumBps() external view returns (uint16) {
        return escalationMediumBps;
    }

    /// @notice Returns escalation bps for low severity.
    /// @return Escalation basis points for low reports.
    function getEscalationLowBps() external view returns (uint16) {
        return escalationLowBps;
    }

    /// @notice Returns global company penalty bps.
    /// @return Company penalty basis points.
    function getCompanyPenaltyBps() external view returns (uint16) {
        return companyPenaltyBps;
    }

    /// @notice Returns global invalidation penalty bps for judges.
    /// @return Judge invalidation penalty basis points.
    function getJudgePenaltyInvalidBps() external view returns (uint16) {
        return judgePenaltyInvalidBps;
    }

    /// @notice Returns global downgrade penalty bps for judges.
    /// @return Judge downgrade penalty basis points.
    function getJudgePenaltyDowngradeBps() external view returns (uint16) {
        return judgePenaltyDowngradeBps;
    }

    /// @notice This will probably be deleted after testnet
    /// @notice setters available to fine tune during testnet
    /// @notice Updates global fee and escalation configuration.
    /// @dev Restricted to admin. Total fee cap remains 10% (1,000 bps).
    /// @param treasuryFeeBps_ Treasury fee basis points.
    /// @param judgeFeeBps_ Judge fee basis points.
    /// @param escalationCriticalBps_ Escalation bps for critical severity.
    /// @param escalationHighBps_ Escalation bps for high severity.
    /// @param escalationMediumBps_ Escalation bps for medium severity.
    /// @param escalationLowBps_ Escalation bps for low severity.
    function updateFeesEscalations(
        uint16 treasuryFeeBps_,
        uint16 judgeFeeBps_,
        uint16 escalationCriticalBps_,
        uint16 escalationHighBps_,
        uint16 escalationMediumBps_,
        uint16 escalationLowBps_
    ) external onlyAdmin {
        require(uint256(treasuryFeeBps_) + uint256(judgeFeeBps_) <= 1_000, "BPS_INVALID"); // 10%
        _setGlobalFeesAndEscalations(
            treasuryFeeBps_,
            judgeFeeBps_,
            escalationCriticalBps_,
            escalationHighBps_,
            escalationMediumBps_,
            escalationLowBps_
        );

        emit EscalationConfigUpdated(escalationCriticalBps, escalationHighBps, escalationMediumBps, escalationLowBps);
    }

    function _setGlobalFeesAndEscalations(
        uint16 treasuryFeeBps_,
        uint16 judgeFeeBps_,
        uint16 escalationCriticalBps_,
        uint16 escalationHighBps_,
        uint16 escalationMediumBps_,
        uint16 escalationLowBps_
    ) internal {
        treasuryFeeBps = treasuryFeeBps_;
        judgeFeeBps = judgeFeeBps_;
        escalationCriticalBps = escalationCriticalBps_;
        escalationHighBps = escalationHighBps_;
        escalationMediumBps = escalationMediumBps_;
        escalationLowBps = escalationLowBps_;
    }

    function _setGlobalPenalties(
        uint16 companyPenaltyBps_,
        uint16 judgePenaltyInvalidBps_,
        uint16 judgePenaltyDowngradeBps_
    ) internal {
        companyPenaltyBps = companyPenaltyBps_;
        judgePenaltyInvalidBps = judgePenaltyInvalidBps_;
        judgePenaltyDowngradeBps = judgePenaltyDowngradeBps_;
    }
}
