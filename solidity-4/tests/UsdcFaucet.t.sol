// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {UsdcFaucet} from "../src/UsdcFaucet.sol";

contract UsdcFaucetTest is Test {
    MockUSDC internal usdc;
    UsdcFaucet internal faucet;
    address internal alice = address(0xA11CE);

    function setUp() public {
        usdc = new MockUSDC();
        faucet = new UsdcFaucet(address(usdc));
    }

    function test_Claim_MintsToCaller() public {
        vm.prank(alice);
        faucet.claim();

        assertEq(usdc.balanceOf(alice), 50_000 * 1e6);
        assertEq(faucet.lastClaimAt(alice), block.timestamp);
    }

    function test_Claim_RevertsDuringCooldown() public {
        vm.prank(alice);
        faucet.claim();

        vm.expectRevert();
        vm.prank(alice);
        faucet.claim();
    }

    function test_Claim_AllowsAfterOneDay() public {
        vm.prank(alice);
        faucet.claim();

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(alice);
        faucet.claim();

        assertEq(usdc.balanceOf(alice), 100_000 * 1e6);
    }
}
