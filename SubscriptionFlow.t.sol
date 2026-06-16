// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockMNTY} from "../src/MockMNTY.sol";
import {SubscriptionManager} from "../src/SubscriptionManager.sol";

contract SubscriptionFlowTest is Test {
    MockMNTY private mnty;
    SubscriptionManager private subscriptionManager;

    address private subscriber = address(0xA11CE);
    address private treasury = address(0xB0B);
    address private ownerWithdrawReceiver = address(0xCAFE);

    uint256 private constant MONTHLY_PRICE = 100 ether;
    uint256 private constant TREASURY_SPLIT_BPS = 7000;

    function setUp() public {
        mnty = new MockMNTY();
        subscriptionManager = new SubscriptionManager(
            address(mnty),
            treasury,
            MONTHLY_PRICE,
            TREASURY_SPLIT_BPS
        );
        mnty.mint(subscriber, 1_000 ether);
    }

    function test_Subscribe_Success() public {
        _approveMonthlyPrice();
        uint256 subscribedAt = block.timestamp;

        vm.prank(subscriber);
        subscriptionManager.subscribe();

        SubscriptionManager.Subscription memory sub = subscriptionManager.getSubscription(subscriber);
        assertEq(uint256(sub.status), uint256(SubscriptionManager.SubscriptionStatus.ACTIVE));
        assertEq(sub.paidUntil, subscribedAt + 30 days);
        assertEq(mnty.balanceOf(treasury), 70 ether);
        assertEq(subscriptionManager.rewardsPool(), 30 ether);
    }

    function test_RenewSubscription_Success() public {
        _subscribe();
        uint256 initialPaidUntil = subscriptionManager.getSubscription(subscriber).paidUntil;
        vm.warp(block.timestamp + 29 days);
        _approveMonthlyPrice();

        vm.prank(subscriber);
        subscriptionManager.renewSubscription();

        assertEq(subscriptionManager.getSubscription(subscriber).paidUntil, initialPaidUntil + 30 days);
    }

    function test_CheckStatus_Grace() public {
        _subscribe();
        vm.warp(block.timestamp + 31 days);
        subscriptionManager.checkAndUpdateStatus(subscriber);

        assertEq(
            uint256(subscriptionManager.getSubscription(subscriber).status),
            uint256(SubscriptionManager.SubscriptionStatus.GRACE)
        );
    }

    function test_CheckStatus_Suspended() public {
        _subscribe();
        vm.warp(block.timestamp + 38 days);
        subscriptionManager.checkAndUpdateStatus(subscriber);

        assertEq(
            uint256(subscriptionManager.getSubscription(subscriber).status),
            uint256(SubscriptionManager.SubscriptionStatus.SUSPENDED)
        );
    }

    function test_Renew_Revert_WhenSuspended() public {
        _subscribe();
        vm.warp(block.timestamp + 38 days);
        subscriptionManager.checkAndUpdateStatus(subscriber);
        _approveMonthlyPrice();

        vm.expectRevert(SubscriptionManager.SubscriptionSuspended.selector);
        vm.prank(subscriber);
        subscriptionManager.renewSubscription();
    }

    function test_WithdrawRewardsPool_Success() public {
        _subscribe();
        uint256 balanceBefore = mnty.balanceOf(ownerWithdrawReceiver);

        subscriptionManager.withdrawRewardsPool(ownerWithdrawReceiver, 20 ether);

        assertEq(mnty.balanceOf(ownerWithdrawReceiver), balanceBefore + 20 ether);
        assertEq(subscriptionManager.rewardsPool(), 10 ether);
    }

    function _subscribe() internal {
        _approveMonthlyPrice();
        vm.prank(subscriber);
        subscriptionManager.subscribe();
    }

    function _approveMonthlyPrice() internal {
        vm.prank(subscriber);
        mnty.approve(address(subscriptionManager), MONTHLY_PRICE);
    }
}
