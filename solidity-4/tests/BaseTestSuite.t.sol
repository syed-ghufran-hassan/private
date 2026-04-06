// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BountyProgramRegistry} from "../../src/BountyProgramRegistry.sol";
import {EscrowVault} from "../../src/EscrowVault.sol";
import {JudgeRegistry} from "../../src/JudgeRegistry.sol";
import {ReportManager} from "../../src/ReportManager.sol";
import {PayoutController} from "../../src/PayoutController.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";

/// @notice Shared test fixture for MVP contracts.
/// @dev Provides common deployment and helpers to reduce boilerplate across tests.
contract BaseTestSuite is Test {
    BountyProgramRegistry internal registry;
    EscrowVault internal escrow;
    JudgeRegistry internal judges;
    ReportManager internal reports;
    PayoutController internal payouts;
    MockUSDC internal token;

    address internal admin = address(this);
    address internal company = address(0xC0);
    address internal judge = address(0xB0);
    address internal researcher = address(0xD0);
    address internal treasury = address(0xE0);

    /// @notice Deploys core contracts, wires dependencies, and seeds the judge allowlist.
    /// @dev Call from each test contract's setUp() to initialize the environment.
    function setUpContracts() internal {
        token = new MockUSDC();
        registry = new BountyProgramRegistry(
            admin,
            treasury,
            200,
            800,
            3000,
            2500,
            2000,
            1750,
            3000,
            10000,
            8000,
            address(token)
        );
        escrow = new EscrowVault(registry, admin);
        judges = new JudgeRegistry(admin);
        reports = new ReportManager(admin, address(judges), address(registry));
        payouts = new PayoutController(registry, escrow, judges, reports, 5 days, admin);

        escrow.setPayoutController(address(payouts));
        reports.setPayoutController(address(payouts));
        registry.setEscrowVault(address(escrow));
        registry.setJudgeRegistry(address(judges));
        registry.setPayoutController(address(payouts));

        judges.setReportManager(address(reports));
        judges.setJudge(judge, true);
    }

    /// @notice Creates a program with optional payout schedule.
    /// @dev Uses the shared company and token addresses from the fixture.
    /// @param judgeFeeBps Judge fee in basis points.
    /// @param treasuryFeeBps Treasury fee in basis points.
    /// @param severities Severity tier IDs (e.g., 1/2/3).
    /// @param payoutAmounts Payout amounts per severity.
    /// @return programId Newly created program ID.
    function createProgram(
        uint16 judgeFeeBps,
        uint16 treasuryFeeBps,
        uint8[] memory severities,
        uint256[] memory payoutAmounts
    ) internal returns (uint256 programId) {
        BountyProgramRegistry.ProgramConfigInput memory input = BountyProgramRegistry.ProgramConfigInput({
            companyOwner: company,
            payoutToken: address(token),
            judgeFeeBps: judgeFeeBps,
            treasuryFeeBps: treasuryFeeBps,
            treasury: treasury,
            severities: severities,
            payoutAmounts: payoutAmounts
        });
        programId = registry.createProgram(input);
    }

    /// @notice Deposits funds into the escrow for a program.
    /// @dev Mints mock tokens to the company and performs approve+deposit.
    /// @param programId Target program ID.
    /// @param amount Deposit amount in token units.
    function deposit(uint256 programId, uint256 amount) internal {
        token.mint(company, amount);
        vm.startPrank(company);
        token.approve(address(escrow), amount);
        escrow.deposit(programId, amount);
        vm.stopPrank();
    }

    /// @notice Submits a report with an assigned primary judge.
    /// @param programId Target program ID.
    /// @param reporter Researcher payout address.
    /// @param reportHash Canonical report hash.
    function submitReport(uint256 programId, address reporter, bytes32 reportHash) internal returns (bytes32 reportId) {
        reportId = reports.submitReport(programId, reporter, judge, reportHash);
    }
}
