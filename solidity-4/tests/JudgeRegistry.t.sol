// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {BaseTestSuite} from "./helpers/BaseTestSuite.t.sol";

/// @notice Unit tests for JudgeRegistry.
/// @dev Covers allowlist updates and toggling.
contract JudgeRegistryTest is BaseTestSuite {
    /// @notice Initializes the shared fixture.
    function setUp() public {
        setUpContracts();
    }

    /// @notice Adds and removes a judge and checks allowlist state.
    /// @dev Uses the admin to set and unset a judge.
    function test_SetJudge() public {
        address newJudge = address(0xAA);
        judges.setJudge(newJudge, true);
        assertTrue(judges.isJudge(newJudge));
        judges.setJudge(newJudge, false);
        assertTrue(!judges.isJudge(newJudge));
    }

    /// @notice Batch updates judges in one call.
    /// @dev Ensures allowlist reflects the batch update.
    function test_BatchSetJudges() public {
        address[] memory newJudges = new address[](2);
        newJudges[0] = address(0xA1);
        newJudges[1] = address(0xA2);

        judges.batchSetJudges(newJudges, true);
        assertTrue(judges.isJudge(newJudges[0]));
        assertTrue(judges.isJudge(newJudges[1]));
    }

    /// @notice Allows admin rotation for the judge registry.
    /// @dev New admin should be able to modify the allowlist.
    function test_AdminRotation() public {
        address newAdmin = address(0xBB);
        judges.setAdmin(newAdmin);
        vm.prank(newAdmin);
        judges.acceptAdmin();

        vm.prank(newAdmin);
        judges.setJudge(address(0xCC), true);
        assertTrue(judges.isJudge(address(0xCC)));
    }
}
