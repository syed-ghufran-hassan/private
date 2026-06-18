# [M-01] SubscriptionManager will cause users to lose paid subscription time during grace period renewal

## Summary 

Users who renew their subscription during the 7-day grace period after their 30-day subscription expires will lose the remaining grace period days they already paid for. The renewal logic uses `block.timestamp` as the base time for calculating the new expiration date instead of extending from the original paidUntil timestamp, resulting in users paying for overlapping periods or losing unused time.

## Root Cause

In `SubscriptionManager.sol:143-145`, the `renewSubscription()` function calculates the base time for the new subscription period incorrectly:

```solidity
uint256 baseTime = subscription.paidUntil > block.timestamp  
    ? subscription.paidUntil  
    : block.timestamp;
```

When a user is in the grace period (where `subscription.paidUntil < block.timestamp`), the function uses `block.timestamp` as the base time instead of the original `paidUntil` timestamp. This causes the new subscription to start from the current time rather than extending from the original expiration date, effectively discarding the remaining grace period days that the user already paid for.

## Internal Pre-conditions

- User needs to call subscribe() to set subscription.paidUntil to be exactly block.timestamp + 30 days
- Time needs to advance to set block.timestamp to be greater than subscription.paidUntil (entering grace period)
- User needs to call renewSubscription() to set subscription.status to be SubscriptionStatus.GRACE
- User needs to have mntyToken.allowance(msg.sender, address(subscriptionManager)) to be at least monthlyPrice

## External Pre-conditions

None - this is a purely internal contract logic issue.

## Attack Path

- User calls subscribe() on day 0, setting paidUntil = day 30
- Time advances to day 31, user enters grace period (status becomes GRACE)
- User calls renewSubscription() on day 35
- Contract calculates baseTime = block.timestamp (day 35) instead of using original paidUntil (day 30)
- Contract sets new paidUntil = day 35 + 30 days = day 65
- User loses days 30-35 (5 days of grace period they already paid for)

## POC

Please add below POC in `SubscriptionFlow.t.sol` and run `forge test --match-test test_POC_GracePeriodRenewalLostTime`. The test will pass as the renewal used block.timestamp (day 35) as baseTime instead of the original expiration (day 30), causing the user to lose days 30-35 .


| Timeline | Timestamp | Event |
|----------|-----------|-------|
| Day 0    | 1         | Subscribe → paidUntil = 2,592,001 (day 30) |
| Day 31   | 2,678,401 | Status changes to GRACE |
| Day 35   | 3,024,001 | Renew subscription |
| Day 65   | 5,616,001 | New paidUntil = 3,024,001 + 30 days |


```solidity
  function test_POC_GracePeriodRenewalLostTime() public {  
    // EXPECTED: Renewal should extend from original expiration (day 30)  
    // ACTUAL: Renewal extends from current time (day 35), losing days 30-35  
      
    // Step 1: Subscribe on day 0  
    _subscribe();  
    uint256 initialPaidUntil = subscriptionManager.getSubscription(subscriber).paidUntil;  
    assertEq(initialPaidUntil, block.timestamp + 30 days);  
      
    // Step 2: Warp to day 31 (enter grace period)  
    vm.warp(block.timestamp + 31 days);  
    subscriptionManager.checkAndUpdateStatus(subscriber);  
      
    // Verify in grace period  
    assertEq(  
        uint256(subscriptionManager.getSubscription(subscriber).status),  
        uint256(SubscriptionManager.SubscriptionStatus.GRACE)  
    );  
      
    // Step 3: Renew on day 35 (during grace period)  
    vm.warp(block.timestamp + 4 days); // Total: day 35  
    _approveMonthlyPrice();  
      
    uint256 balanceBefore = mnty.balanceOf(subscriber);  
    vm.prank(subscriber);  
    subscriptionManager.renewSubscription();  
      
    uint256 balanceAfter = mnty.balanceOf(subscriber);  
    assertEq(balanceBefore - balanceAfter, MONTHLY_PRICE); // Paid full price  
      
    // Step 4: Check new paidUntil  
    uint256 newPaidUntil = subscriptionManager.getSubscription(subscriber).paidUntil;  
      
    // BUG CONFIRMED: baseTime = block.timestamp (day 35) since paidUntil < block.timestamp  
    // paidUntil = day 35 + 30 days = day 65  
    // User loses days 30-35 (5 days of paid service)  
    assertEq(newPaidUntil, block.timestamp + 30 days); // Extends from day 35, not day 30  
      
    // Calculate lost days  
    uint256 lostDays = (block.timestamp - initialPaidUntil) / 1 days;  
    assertEq(lostDays, 5); // Lost 5 days of service  
}
```

## Impact

The user suffers an approximate loss of up to 7 days of paid subscription time per renewal cycle during grace period. The protocol receives payment for time that is not actually provided to the user, creating a financial disadvantage for users who renew during the grace period.

## Fix

Modify the base time calculation in renewSubscription() to always extend from the original paidUntil timestamp, even during grace period:

```solidity
function renewSubscription() external nonReentrant {  
    Subscription storage subscription = subscriptions[msg.sender];  
    if (subscription.subscriber == address(0)) revert NotSubscribed();  
    if (subscription.status == SubscriptionStatus.SUSPENDED)  
        revert SubscriptionSuspended();  
  
    _collectPayment(msg.sender, monthlyPrice);  
  
    // FIX: Always extend from paidUntil, not block.timestamp  
    uint256 baseTime = subscription.paidUntil;  
    subscription.paidUntil = baseTime + 30 days;  
    subscription.totalPaid += monthlyPrice;  
    subscription.status = SubscriptionStatus.ACTIVE;  
    subscription.paymentCount += 1;  
  
    emit SubscriptionRenewed(  
        msg.sender,  
        subscription.paidUntil,  
        monthlyPrice,  
        block.timestamp  
    );  
}
```

