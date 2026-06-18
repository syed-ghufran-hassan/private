# SubscriptionManager will cause users to lose paid subscription time during grace period renewal

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

## Impact

The user suffers an approximate loss of up to 7 days of paid subscription time per renewal cycle during grace period. The protocol receives payment for time that is not actually provided to the user, creating a financial disadvantage for users who renew during the grace period.

