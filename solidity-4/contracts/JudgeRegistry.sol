// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

contract JudgeRegistry {
    mapping(address => bool) public isJudge;
    address public admin;
    address public pendingAdmin;
    address public reportManager;

    event JudgeUpdated(address indexed judge, bool allowed);
    event AdminUpdated(address admin);
    event ReportManagerUpdated(address reportManager);

    modifier onlyAdmin() {
        require(msg.sender == admin, "NOT_ADMIN");
        _;
    }

    modifier onlyAdminOrReportManager() {
        require(reportManager != address(0), "REPORT_MANAGER_ZERO");
        require(msg.sender == admin || msg.sender == reportManager, "NOT_ADMIN");
        _;
    }

    /// @notice Initializes the judge registry with an admin.
    /// @dev The admin can add or remove judges; use a multisig for safety.
    /// @param admin_ The admin address.
    constructor(address admin_) {
        require(admin_ != address(0), "ADMIN_ZERO");
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

    /// @notice Updates the registry report manager.
    /// @param newReportManager The new report manager address.
    function setReportManager(address newReportManager) external onlyAdmin {
        require(newReportManager != address(0), "REPORT_MANAGER_ZERO");
        require(reportManager != newReportManager, "ALREADY_MANAGER");
        reportManager = newReportManager;
        emit ReportManagerUpdated(newReportManager);
    }

    /// @notice Adds or removes a judge from the allowlist.
    /// @dev A judge must be allowlisted to approve payouts.
    /// @param judge The judge address to update.
    /// @param allowed Whether the judge is allowlisted.
    function setJudge(address judge, bool allowed) external onlyAdminOrReportManager {
        require(judge != address(0), "JUDGE_ZERO");
        isJudge[judge] = allowed;
        emit JudgeUpdated(judge, allowed);
    }

    /// @notice Adds or removes multiple judges from the allowlist.
    /// @dev Emits an event per judge update.
    /// @param judges The list of judge addresses to update.
    /// @param allowed Whether the judges are allowlisted.
    function batchSetJudges(address[] calldata judges, bool allowed) external onlyAdmin {
        uint256 length = judges.length;
        for (uint256 i = 0; i < length; i++) {
            address judge = judges[i];
            require(judge != address(0), "JUDGE_ZERO");
            isJudge[judge] = allowed;
            emit JudgeUpdated(judge, allowed);
        }
    }
}
