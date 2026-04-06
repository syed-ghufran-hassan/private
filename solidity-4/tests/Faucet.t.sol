// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Faucet} from "../src/Faucet.sol";

contract FaucetTest is Test {
    Faucet internal faucet;
    address internal alice = address(0xA11CE);
    address internal faucetAdmin = address(0xB0B);
    address internal nonAdmin = address(0xCAFE);

    function setUp() public {
        faucet = new Faucet(faucetAdmin);
        vm.deal(address(this), 2 ether);
        (bool ok,) = address(faucet).call{value: 1 ether}("");
        require(ok, "fund failed"); 
    }

    function test_Claim_RevertsDuringCooldown() public {
        vm.prank(alice);
        faucet.claim();

        vm.expectRevert();
        vm.prank(alice);
        faucet.claim();
    }

    function test_Claim_MaxCaps() public {
        uint256 beforeBal = alice.balance;

        for (uint256 i = 0; i < 5; i++) {
            vm.prank(alice);
            faucet.claim();

            vm.warp(faucet.lastClaimAt(alice) + 1 days + 1);
        }

        assertEq(faucet.claimCount(alice), 5);
        assertEq(faucet.totalClaimed(alice), 0.05 ether);
        assertEq(alice.balance, beforeBal + 0.05 ether);

        vm.prank(alice);
        vm.expectRevert(Faucet.MaxClaimsReached.selector);
        faucet.claim();
    }

    function test_Claim_RevertsWhenFaucetHasInsufficientBalance() public {
        Faucet lowBalanceFaucet = new Faucet(faucetAdmin);
        (bool ok,) = address(lowBalanceFaucet).call{value: 0.0005 ether}("");
        require(ok, "fund failed");

        vm.prank(alice);
        vm.expectRevert(Faucet.InsufficientFaucetBalance.selector);
        lowBalanceFaucet.claim();
    }

    function test_AdminWithdraw() public {
        uint256 before = faucetAdmin.balance;
        vm.prank(faucetAdmin);
        faucet.withdraw();
        assertGt(faucetAdmin.balance, before);
    }

    function test_Withdraw_RevertsForNonAdmin() public {
        vm.prank(nonAdmin);
        vm.expectRevert(Faucet.NotAdmin.selector);
        faucet.withdraw();
    }
}
