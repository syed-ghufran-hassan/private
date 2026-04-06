// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "./BountyProgramRegistry.sol";
import "./utils/ReentrancyGuard.sol";

interface IERC20 {
    /// @notice Transfers tokens to a recipient.
    /// @param to Recipient address.
    /// @param value Amount to transfer.
    /// @return success True if transfer succeeded.
    function transfer(address to, uint256 value) external returns (bool);
    /// @notice Transfers tokens from a holder using allowance.
    /// @param from Token holder address.
    /// @param to Recipient address.
    /// @param value Amount to transfer.
    /// @return success True if transfer succeeded.
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    /// @notice Returns token balance for an account.
    /// @param spender Account address to query.
    /// @return amount Current token balance.
    function balanceOf(address spender) external view returns (uint256 amount);
}

contract EscrowVault is ReentrancyGuard {
    BountyProgramRegistry public registry;

    uint256 public constant MIN_DEPOSIT = 1e6;

    mapping(uint256 => uint256) public bountyBalance;
    mapping(uint256 => uint256) public judgeBalance;
    /// @notice Aggregate outstanding penalty debt per program.
    mapping(uint256 => uint256) public companyPenaltyDebt;

    // This allows multiple escalated reports with different judge pairs on the same program.
    mapping(bytes32 => uint256) public reportPenaltyDebt;
    mapping(bytes32 => uint256) public reportPenaltyTreasuryDebt;
    mapping(bytes32 => uint256) public reportPenaltyPrimaryDebt;
    mapping(bytes32 => uint256) public reportPenaltySecondaryDebt;
    mapping(bytes32 => address) public reportPenaltyPrimaryJudge;
    mapping(bytes32 => address) public reportPenaltySecondaryJudge;
    /// @notice List of report IDs with outstanding penalty for each program.
    mapping(uint256 => bytes32[]) public programPenaltyReports;

    address public admin;
    address public pendingAdmin;
    address public payoutController;

    event Deposited(
        uint256 indexed programId,
        address indexed from,
        uint256 amount,
        uint256 bountyAmount,
        uint256 judgeFee,
        uint256 treasuryFee
    );
    event BountyPaid(uint256 indexed programId, address indexed to, uint256 amount);
    event JudgePaid(uint256 indexed programId, address indexed to, uint256 amount);
    event TreasuryFeePaid(uint256 indexed programId, address indexed to, uint256 amount);
    event CompanyRefunded(uint256 indexed programId, address indexed to, uint256 amount);
    event CompanyPenaltyAccrued(uint256 indexed programId, uint256 amount);
    event CompanyPenaltyPaid(uint256 indexed programId, uint256 amount);
    event EscalationJudgeBalanceAllocated(uint256 indexed programId, uint256 amount);
    event PayoutControllerUpdated(address payoutController);
    event ProgramRegistryUpdated(address registry);
    event AdminUpdated(address admin);

    modifier onlyAdmin() {
        require(msg.sender == admin, "NOT_ADMIN");
        _;
    }

    modifier onlyPayoutController() {
        require(msg.sender == payoutController, "NOT_PAYOUT_CONTROLLER");
        _;
    }

    /// @notice Initializes the escrow vault with the program registry and admin.
    /// @dev The registry is immutable and used for program config lookups (token, fees, treasury, status).
    /// @param registry_ The BountyProgramRegistry contract.
    /// @param admin_ Address with admin privileges (multisig recommended).
    constructor(BountyProgramRegistry registry_, address admin_) {
        require(address(registry_) != address(0), "REGISTRY_ZERO");
        require(admin_ != address(0), "ADMIN_ZERO");
        registry = registry_;
        admin = admin_;
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

    /// @notice Sets the only contract allowed to release funds from the vault.
    /// @dev Should be set to the PayoutController after deployment.
    /// @param payoutController_ The authorized payout controller address.
    function setPayoutController(address payoutController_) external onlyAdmin {
        require(payoutController_ != address(0), "PAYOUT_ZERO");
        require(payoutController != payoutController_, "ALREADY_PAYOUT");
        payoutController = payoutController_;
        emit PayoutControllerUpdated(payoutController_);
    }

    /// @param registry_ The new bounty program registry address
    function setProgramRegistry(BountyProgramRegistry registry_) external onlyAdmin {
        require(address(registry_) != address(0), "REGISTRY_ZERO");
        require(address(registry) != address(registry_), "ALREADY_REGISTRY");
        registry = registry_;
        emit ProgramRegistryUpdated(address(registry));
    }

    /// @notice Deposits funds for a program and splits into bounty/judge/treasury.
    /// @dev Pulls funds via transferFrom, so the caller must pre-approve the vault.
    /// @dev A DRAFT program is activated after the first successful deposit that funds the
    /// @dev full schedule sum when a payout schedule is configured.
    /// @param programId The target program identifier.
    /// @param amount The deposit amount of the program payout token.
    function deposit(uint256 programId, uint256 amount) external nonReentrant {
        require(amount > 0, "AMOUNT_ZERO");
        require(amount >= MIN_DEPOSIT, "AMOUNT_TOO_SMALL");
        BountyProgramRegistry.ProgramConfig memory config = registry.getProgram(programId);
        require(config.companyOwner != address(0), "PROGRAM_NOT_FOUND");
        require(msg.sender == config.companyOwner, "NOT_PROGRAM_OWNER");
        require(
            config.status == BountyProgramRegistry.Status.DRAFT,
            "PROGRAM_NOT_DEPOSITABLE"
        );
        require(
            config.judgeFeeBps + config.treasuryFeeBps <= 1_000,
            "INVALID_FEE_CONFIGURATION"
        );
        uint256 totalFeeBps = config.judgeFeeBps + config.treasuryFeeBps;
        uint256 totalFeeBpsPs = 10_000 + totalFeeBps;

        IERC20 token = IERC20(config.payoutToken);
        require(token.transferFrom(msg.sender, address(this), amount), "TRANSFER_FAILED");

        // Apply any outstanding penalty debt before computing the bounty split.
        uint256 penaltyPaid = 0;
        uint256 debt = companyPenaltyDebt[programId];
        if (debt > 0) {
            uint256 toPay = amount < debt ? amount : debt;
            if (toPay > 0) {
                penaltyPaid = _applyPenaltyPayment(programId, toPay, token, config.treasury);
            }
        }

        uint256 netAmount = amount - penaltyPaid;

        if (netAmount == 0) {
            if (registry.hasPayoutSchedule(programId)) {
                uint256 requiredBounty = registry.totalPayoutByProgram(programId);
                require(bountyBalance[programId] >= requiredBounty, "INSUFFICIENT_INITIAL_BOUNTY");
            }
            emit Deposited(programId, msg.sender, amount, 0, 0, 0);
            registry.activateFromDeposit(programId);
            return;
        }

        uint256 bountyAmount = netAmount * 10_000 / totalFeeBpsPs;
        require(bountyAmount > 0, "Overflow check");
        require(netAmount >= bountyAmount, "Overflow check");
        uint256 fees = netAmount - bountyAmount;

        uint256 judgeFee = 0;
        uint256 treasuryFee = 0;
        if (totalFeeBps > 0) {
            judgeFee = (fees * config.judgeFeeBps) / totalFeeBps;
            treasuryFee = fees - judgeFee;
        }

        if (registry.hasPayoutSchedule(programId)) {
            uint256 initialBountyBalance = bountyBalance[programId];
            uint256 requiredBounty = registry.totalPayoutByProgram(programId);
            require((bountyAmount + initialBountyBalance) >= requiredBounty, "INSUFFICIENT_INITIAL_BOUNTY");
        }

        bountyBalance[programId] += bountyAmount;
        judgeBalance[programId] += judgeFee;

        if (treasuryFee > 0) {
            require(token.transfer(config.treasury, treasuryFee), "TREASURY_TRANSFER_FAILED");
        }

        emit Deposited(programId, msg.sender, amount, bountyAmount, judgeFee, treasuryFee);

        registry.activateFromDeposit(programId);
    }

    /// @notice Allows the company owner to pay outstanding penalty debt while the program is PAUSED.
    /// @dev Does not add to bountyBalance or activate the program.
    /// @dev Use this before executeRefund when bountyBalance < companyPenaltyDebt.
    /// @param programId The program identifier.
    /// @param amount The debt payment amount (must be <= outstanding debt).
    function payPenaltyDebt(uint256 programId, uint256 amount) external nonReentrant {
        require(amount > 0, "AMOUNT_ZERO");
        BountyProgramRegistry.ProgramConfig memory config = registry.getProgram(programId);
        require(config.companyOwner != address(0), "PROGRAM_NOT_FOUND");
        require(config.status == BountyProgramRegistry.Status.PAUSED, "PROGRAM_NOT_PAUSED");
        require(msg.sender == config.companyOwner, "NOT_PROGRAM_OWNER");

        uint256 debt = companyPenaltyDebt[programId];
        require(debt > 0, "NO_DEBT");
        require(amount <= debt, "OVERPAYMENT");

        IERC20 token = IERC20(config.payoutToken);
        require(token.transferFrom(msg.sender, address(this), amount), "TRANSFER_FAILED");

        _applyPenaltyPayment(programId, amount, token, config.treasury);
    }

    /// @notice Pays researcher bounty from the program pool (payout controller only).
    /// @dev Decrements the bounty balance then transfers to the researcher.
    /// @dev Reverts if the program bounty pool is insufficient.
    /// @param programId The program identifier.
    /// @param to The researcher payout address.
    /// @param amount The payout amount.
    function payoutBounty(uint256 programId, address to, uint256 amount) external onlyPayoutController {
        require(to != address(0), "TO_ZERO");
        require(amount > 0, "AMOUNT_ZERO");
        uint256 balance = bountyBalance[programId];
        require(balance >= amount, "INSUFFICIENT_BOUNTY");
        bountyBalance[programId] = balance - amount;

        BountyProgramRegistry.ProgramConfig memory config = registry.getProgram(programId);
        IERC20 token = IERC20(config.payoutToken);
        require(token.transfer(to, amount), "TRANSFER_FAILED");

        uint256 totalPayout = registry.totalPayoutByProgram(programId);
        if (totalPayout == 0 || bountyBalance[programId] < totalPayout) {
            registry.deactivateFromPaidBounty(programId);
        }

        emit BountyPaid(programId, to, amount);
    }

    /// @notice Pays judge fee from the program judge pool (payout controller only).
    /// @dev Decrements the judge balance then transfers to the judge.
    /// @dev Reverts if the program judge pool is insufficient.
    /// @param programId The program identifier.
    /// @param to The judge payout address.
    /// @param amount The judge fee amount.
    function payoutJudge(uint256 programId, address to, uint256 amount) external onlyPayoutController {
        require(to != address(0), "TO_ZERO");
        require(amount > 0, "AMOUNT_ZERO");
        uint256 balance = judgeBalance[programId];
        require(balance >= amount, "INSUFFICIENT_JUDGE");
        judgeBalance[programId] = balance - amount;

        BountyProgramRegistry.ProgramConfig memory config = registry.getProgram(programId);
        IERC20 token = IERC20(config.payoutToken);
        uint256 tokenBalance = token.balanceOf(address(this));
        require(tokenBalance >= amount, "INSUFFICIENT_BALANCE");
        require(token.transfer(to, amount), "TRANSFER_FAILED");
        emit JudgePaid(programId, to, amount);
    }

    /// @notice Moves funds from bounty pool to judge pool for escalation rewards.
    /// @dev Only payout controller may rebalance pools for escalation resolution.
    /// @param programId The program identifier.
    /// @param amount The amount moved from bountyBalance into judgeBalance.
    function allocateEscalationJudgeBalance(uint256 programId, uint256 amount) external onlyPayoutController {
        require(amount > 0, "AMOUNT_ZERO");
        uint256 bounty = bountyBalance[programId];
        require(bounty >= amount, "INSUFFICIENT_BOUNTY");
        bountyBalance[programId] = bounty - amount;
        judgeBalance[programId] += amount;
        emit EscalationJudgeBalanceAllocated(programId, amount);
    }

    /// @notice Pays treasury fees directly from vault balance (payout controller only).
    /// @dev Used for escalation and penalty fee routing where treasury cut is transferred immediately.
    /// @param programId The program identifier.
    /// @param to Treasury recipient address.
    /// @param amount Treasury transfer amount.
    /// @return True when transfer succeeds.
    function payoutTreasuryFee(uint256 programId, address to, uint256 amount) external onlyPayoutController returns (bool) {
        require(to != address(0), "TO_ZERO");
        require(amount > 0, "AMOUNT_ZERO");
        uint256 bBal = bountyBalance[programId];
        require(bBal >= amount, "INSUFFICIENT_BOUNTY");
        bountyBalance[programId] = bBal - amount;
        BountyProgramRegistry.ProgramConfig memory config = registry.getProgram(programId);
        IERC20 token = IERC20(config.payoutToken);
        require(token.transfer(to, amount), "TRANSFER_FAILED");
        emit TreasuryFeePaid(programId, to, amount);
        return true;
    }

    /// @notice Refunds remaining bounty pool to the program owner after registry closes the program.
    /// @dev Only callable by the BountyProgramRegistry as part of the executeRefund flow.
    /// @dev Use payPenaltyDebt() to top up before calling executeRefund when needed.
    /// @param programId The program identifier.
    function refund(uint256 programId) external nonReentrant {
        require(msg.sender == address(registry), "NOT_REGISTRY");
        BountyProgramRegistry.ProgramConfig memory config = registry.getProgram(programId);
        require(config.companyOwner != address(0), "PROGRAM_NOT_FOUND");
        require(config.status == BountyProgramRegistry.Status.CLOSED, "PROGRAM_NOT_CLOSED");

        uint256 balance = bountyBalance[programId];
        uint256 debt = companyPenaltyDebt[programId];
        IERC20 token = IERC20(config.payoutToken);

        uint256 penaltyActuallyPaid = 0;
        if (debt > 0) {
            require(balance >= debt, "BALANCE_INSUFFICIENT_FOR_DEBT");
            penaltyActuallyPaid = _applyPenaltyPayment(programId, debt, token, config.treasury);
        }

        bountyBalance[programId] = 0;
        uint256 judgeRefund = judgeBalance[programId];
        judgeBalance[programId] = 0;

        uint256 refundAmount = balance - penaltyActuallyPaid;
        if (refundAmount > 0) {
            require(token.transfer(config.companyOwner, refundAmount), "TRANSFER_FAILED");
        }
        if (judgeRefund > 0) {
            require(token.transfer(config.companyOwner, judgeRefund), "JUDGE_REFUND_FAILED");
        }
        emit CompanyRefunded(programId, config.companyOwner, refundAmount + judgeRefund);
    }

    /// @notice Accrues a penalty debt per report to be paid on the next deposit or explicit payment.
    /// @dev Only callable by the payout controller.
    /// @param programId The program identifier.
    /// @param reportId The report identifier (used as the per-report penalty key).
    /// @param amount The penalty amount to accrue.
    /// @param primaryJudge The primary judge address for this report.
    /// @param secondaryJudge The secondary judge address for this report.
    function accrueCompanyPenalty(
        uint256 programId,
        bytes32 reportId,
        uint256 amount,
        address primaryJudge,
        address secondaryJudge
    ) external onlyPayoutController {
        require(amount > 0, "AMOUNT_ZERO");
        require(primaryJudge != address(0), "PRIMARY_JUDGE_ZERO");
        require(secondaryJudge != address(0), "SECOND_JUDGE_ZERO");
        require(reportPenaltyDebt[reportId] == 0, "REPORT_PENALTY_ALREADY_ACCRUED");

        uint256 treasuryShare = (amount * 2_000) / 10_000;
        uint256 judgesShare = amount - treasuryShare;
        uint256 primaryShare = (judgesShare * 5_000) / 10_000;
        uint256 secondaryShare = judgesShare - primaryShare;

        reportPenaltyPrimaryJudge[reportId] = primaryJudge;
        reportPenaltySecondaryJudge[reportId] = secondaryJudge;
        reportPenaltyDebt[reportId] = amount;
        reportPenaltyTreasuryDebt[reportId] = treasuryShare;
        reportPenaltyPrimaryDebt[reportId] = primaryShare;
        reportPenaltySecondaryDebt[reportId] = secondaryShare;

        programPenaltyReports[programId].push(reportId);
        companyPenaltyDebt[programId] += amount;
        emit CompanyPenaltyAccrued(programId, amount);
    }

    /// @notice Emergency admin redirect for a stuck bounty (e.g., USDC-blacklisted researcher).
    /// @dev Use alongside PayoutController.emergencyCloseReport to fully resolve a stuck payout.
    /// @param programId The program identifier.
    /// @param to Alternate recipient address.
    /// @param amount The amount to redirect.
    function emergencyBountyPayout(uint256 programId, address to, uint256 amount) external onlyAdmin {
        require(to != address(0), "TO_ZERO");
        require(amount > 0, "AMOUNT_ZERO");
        uint256 balance = bountyBalance[programId];
        require(balance >= amount, "INSUFFICIENT_BOUNTY");
        bountyBalance[programId] = balance - amount;
        BountyProgramRegistry.ProgramConfig memory config = registry.getProgram(programId);
        IERC20 token = IERC20(config.payoutToken);
        require(token.transfer(to, amount), "TRANSFER_FAILED");
        uint256 totalPayout = registry.totalPayoutByProgram(programId);
        if (totalPayout == 0 || bountyBalance[programId] < totalPayout) {
            registry.deactivateFromPaidBounty(programId);
        }
        emit BountyPaid(programId, to, amount);
    }

    /// @notice Returns current judge pool balance for a program.
    /// @param programId The program identifier.
    /// @return Judge balance held in escrow for the program.
    function getJudgeFee(uint256 programId) external view returns (uint256) {
        return judgeBalance[programId];
    }

    /// @notice Returns current bounty pool balance for a program.
    /// @param programId The program identifier.
    /// @return Bounty balance held in escrow for the program.
    function getBountyBalance(uint256 programId) external view returns (uint256) {
        return bountyBalance[programId];
    }

    /// @notice Returns total outstanding company penalty debt for a program.
    /// @param programId The program identifier.
    /// @return Outstanding company penalty debt amount.
    function getCompanyPenaltyDebt(uint256 programId) external view returns (uint256) {
        return companyPenaltyDebt[programId];
    }

    /// @notice Returns the number of reports with recorded penalty entries for a program.
    /// @param programId The program identifier.
    /// @return Number of entries in programPenaltyReports[programId].
    function getProgramPenaltyReportsLength(uint256 programId) external view returns (uint256) {
        return programPenaltyReports[programId].length;
    }

    /// @notice Computes the sum of all per-report penalty debts for a program.
    /// @dev Useful for invariant checks. O(n) where n = number of escalated reports.
    /// @param programId The program identifier.
    /// @return sum Total of all reportPenaltyDebt entries for the program.
    function sumReportPenaltyDebts(uint256 programId) external view returns (uint256 sum) {
        bytes32[] storage reportIds = programPenaltyReports[programId];
        uint256 len = reportIds.length;
        for (uint256 i = 0; i < len; i++) {
            sum += reportPenaltyDebt[reportIds[i]];
        }
    }

    /// @notice Distributes a proportional penalty payment across all pending-penalty reports for a program.
    /// @dev Called from deposit(), refund(), and payPenaltyDebt(). Each report receives a share
    /// @dev proportional to its individual debt relative to the program total.
    /// @param programId The program identifier.
    /// @param penaltyPaid The total amount to distribute across reports.
    /// @param token The ERC20 token used for transfers.
    /// @param treasuryAddr The treasury recipient address.
    /// @return actualPaid The sum actually distributed (may differ from penaltyPaid by wei-level rounding).
    function _applyPenaltyPayment(
        uint256 programId,
        uint256 penaltyPaid,
        IERC20 token,
        address treasuryAddr
    ) internal returns (uint256 actualPaid) {
        uint256 totalDebt = companyPenaltyDebt[programId];
        bytes32[] storage reportIds = programPenaltyReports[programId];
        uint256 reportCount = reportIds.length;

        for (uint256 i = 0; i < reportCount; i++) {
            bytes32 rId = reportIds[i];
            uint256 reportDebt = reportPenaltyDebt[rId];
            if (reportDebt == 0) continue;

            // Proportional share of the payment for this report.
            uint256 reportPayment = (penaltyPaid * reportDebt) / totalDebt;
            if (reportPayment == 0) continue;

            actualPaid += reportPayment;

            uint256 rTreasuryDebt = reportPenaltyTreasuryDebt[rId];
            uint256 rPrimaryDebt = reportPenaltyPrimaryDebt[rId];

            uint256 treasuryPay = (reportPayment * rTreasuryDebt) / reportDebt;
            uint256 primaryPay = (reportPayment * rPrimaryDebt) / reportDebt;
            uint256 rSecondaryDebt = reportPenaltySecondaryDebt[rId];
            uint256 secondaryPay = reportPayment - treasuryPay - primaryPay;
            if (secondaryPay > rSecondaryDebt) {
                primaryPay += (secondaryPay - rSecondaryDebt);
                secondaryPay = rSecondaryDebt;
            }

            reportPenaltyDebt[rId] -= reportPayment;
            reportPenaltyTreasuryDebt[rId] -= treasuryPay;
            reportPenaltyPrimaryDebt[rId] -= primaryPay;
            reportPenaltySecondaryDebt[rId] -= secondaryPay;

            if (treasuryPay > 0) {
                require(token.transfer(treasuryAddr, treasuryPay), "PENALTY_TREASURY_TRANSFER_FAILED");
            }
            if (primaryPay > 0) {
                address pj = reportPenaltyPrimaryJudge[rId];
                require(pj != address(0), "PRIMARY_JUDGE_ZERO");
                require(token.transfer(pj, primaryPay), "PENALTY_PRIMARY_TRANSFER_FAILED");
            }
            if (secondaryPay > 0) {
                address sj = reportPenaltySecondaryJudge[rId];
                require(sj != address(0), "SECOND_JUDGE_ZERO");
                require(token.transfer(sj, secondaryPay), "PENALTY_SECONDARY_TRANSFER_FAILED");
            }
        }

        companyPenaltyDebt[programId] -= actualPaid;
        if (actualPaid > 0) emit CompanyPenaltyPaid(programId, actualPaid);
    }
}
