// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {BaseTestSuite} from "./helpers/BaseTestSuite.t.sol";
import {BountyProgramRegistry} from "../src/BountyProgramRegistry.sol";

/// @notice Unit tests for BountyProgramRegistry.
/// @dev Covers program creation, payout schedule storage, and status rules.
contract BountyProgramRegistryTest is BaseTestSuite {
    /// @notice Initializes the shared fixture.
    function setUp() public {
        setUpContracts();
    }

    /// @notice Creates a program with severity payouts and verifies storage.
    /// @dev Asserts DRAFT status and payout mapping values.
    function test_CreateProgramDraftAndPayoutsStored() public {
        uint8[] memory severities = new uint8[](2);
        uint256[] memory payoutsBySeverity = new uint256[](2);
        severities[0] = 1;
        severities[1] = 2;
        payoutsBySeverity[0] = 100e6;
        payoutsBySeverity[1] = 250e6;

        uint256 programId = createProgram(800, 200, severities, payoutsBySeverity);
        BountyProgramRegistry.ProgramConfig memory config = registry.getProgram(programId);

        assertEq(uint256(config.status), uint256(BountyProgramRegistry.Status.DRAFT));
        assertEq(registry.payoutBySeverity(programId, 1), 100e6);
        assertEq(registry.payoutBySeverity(programId, 2), 250e6);
    }

    /// @notice Ensures only the escrow vault can activate a program.
    /// @dev Direct activation calls should revert.
    function test_ActivateFromDepositOnlyEscrow() public {
        uint8[] memory severities = new uint8[](0);
        uint256[] memory payoutsBySeverity = new uint256[](0);
        uint256 programId = createProgram(800, 200, severities, payoutsBySeverity);

        vm.expectRevert("NOT_ESCROW_VAULT");
        registry.activateFromDeposit(programId);
    }

    /// @notice Rejects invalid fee bps totals on update.
    /// @dev Sum must be <= 1_000 bps (10%).
    function test_CreateProgramRejectsInvalidBps() public {
        vm.expectRevert("BPS_INVALID");
        registry.updateFeesEscalations(900, 200, 1, 1, 1, 1);
    }

    /// @notice Rejects mismatched severity and payout arrays.
    /// @dev Arrays must be same length.
    function test_CreateProgramRejectsMismatchedSchedule() public {
        uint8[] memory severities = new uint8[](1);
        uint256[] memory payoutsBySeverity = new uint256[](0);
        BountyProgramRegistry.ProgramConfigInput memory input = BountyProgramRegistry.ProgramConfigInput({
            companyOwner: company,
            payoutToken: address(token),
            judgeFeeBps: 800,
            treasuryFeeBps: 200,
            treasury: treasury,
            severities: severities,
            payoutAmounts: payoutsBySeverity
        });
        vm.expectRevert("PAYOUT_LENGTH");
        registry.createProgram(input);
    }

    /// @notice Rejects duplicate severity entries in createProgram input.
    /// @dev Duplicate severities must revert with DUPLICATE_SEVERITY.
    function test_CreateProgramRejectsDuplicateSeverityEntries() public {
        uint8[] memory severities = new uint8[](2);
        uint256[] memory payoutsBySeverity = new uint256[](2);
        severities[0] = 2;
        severities[1] = 2;
        payoutsBySeverity[0] = 1_100_000;
        payoutsBySeverity[1] = 1_100_000;

        BountyProgramRegistry.ProgramConfigInput memory input = BountyProgramRegistry.ProgramConfigInput({
            companyOwner: company,
            payoutToken: address(token),
            judgeFeeBps: 800,
            treasuryFeeBps: 200,
            treasury: treasury,
            severities: severities,
            payoutAmounts: payoutsBySeverity
        });

        vm.expectRevert("DUPLICATE_SEVERITY");
        registry.createProgram(input);
    }
}
