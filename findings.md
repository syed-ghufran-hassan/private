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

# [M-02] Dispute Window Duration Mismatch creates 4-day withdrawal block period

## Summary

The DisputeResolution contract enforces a 3-day window for opening disputes against slashes, while the StakingVault contract uses a 7-day disputeWindowDuration for auto-clearing dispute flags. This creates a 4-day gap where workers who choose not to dispute (or miss the 3-day window) cannot withdraw their stakes, even though the dispute window has already expired in DisputeResolution.

## Root Cause

The mismatch stems from hardcoded default values in different contracts:

DisputeResolution is deployed with a 3-day dispute window in the test setup

```solidity
 disputeResolution = new DisputeResolution(
            address(registry),
            address(slashingController),
            address(vault),
            address(mnty),
            3 days
        );

```

StakingVault has a default disputeWindowDuration of 7 days

```solidity
  /// @notice C-04 FIX: Duration after which a dispute flag auto-clears if no dispute was opened
    uint256 public disputeWindowDuration = 7 days;

```

The auto-clear mechanism in StakingVault uses the 7-day duration in two places:

- Inline in withdraw()

```solidity
  // C-04 FIX: Auto-clear expired dispute flag if no active dispute was opened
        if (stake.underDispute && !hasActiveDispute[agentId]) {
            if (lastSlashedAt[agentId] > 0
                && block.timestamp > lastSlashedAt[agentId] + disputeWindowDuration) {
                stake.underDispute = false;
                emit DisputeFlagAutoCleared(agentId, block.timestamp);
            }
        }

```

- As a standalone clearExpiredDispute() function

```solidity
 /**
     * @notice Permissionless auto-clear of expired dispute flags
     * @dev C-04 FIX: Anyone can call this to clear a dispute flag after the window expires,
     *      as long as no active dispute was opened via DisputeResolution.
     */
    function clearExpiredDispute(bytes32 agentId) external {
        StakeRecord storage stake = stakes[agentId];
        if (!stake.underDispute) revert NotUnderDispute();
        if (hasActiveDispute[agentId]) revert StakeUnderDispute();
        if (lastSlashedAt[agentId] == 0 ||
            block.timestamp <= lastSlashedAt[agentId] + disputeWindowDuration) {
            revert DisputeWindowNotExpired();
        }


```

## Internal Pre-conditions

- Worker needs to be slashed by an authorized auditor to set stake.underDispute = true and lastSlashedAt = T=0
- Worker needs to not open a dispute within the 3-day window enforced by DisputeResolution
- No active dispute must be opened via setActiveDispute() in DisputeResolution

## External Pre-conditions

None - this is an internal protocol inconsistency.

## Attack Path

- Auditor calls executeSlash(workerAgentId, evidence) at T=0, setting stake.underDispute = true and lastSlashedAt = T=0
- Worker chooses not to dispute (or misses the 3-day window)
- At T=3 days, the dispute window expires in DisputeResolution - worker can no longer open a dispute
- At T=3-7 days, worker attempts to call withdraw() but vault still has underDispute = true
- At T=7 days, vault auto-clears the flag via withdraw() or clearExpiredDispute()
- Worker can finally withdraw their remaining stake

## Impact

The affected party (workers) suffers a temporary loss of liquidity for 4 extra days after the dispute window expires. This is not a financial loss but an operational inefficiency that blocks access to their own funds. The attacker gains nothing (this is not an exploit, but a design inconsistency).

## POC

Please add following test in `DisputeFlow.t.sol` and run `forge test --match-test test_POC_DisputeWindowDurationMismatch`. The test will pass confirming that the worker cannot withdraw at day 3 (when DisputeResolution window expires) but must wait until day 7 (when StakingVault's disputeWindowDuration expires). The trace confirms the duration mismatch vulnerability:

| Timeline | Timestamp | Event |
|:---------|----------:|-------|
| Day 0    |         1 | Worker slashed |
| Day 3    |   259,202 | openDispute() fails with DisputeWindowExpired |
| Day 3    |   259,202 | withdraw() fails with StakeUnderDispute |
| Day 7    |   604,802 | withdraw() succeeds with DisputeFlagAutoCleared |



```solidity
function test_POC_DisputeWindowDurationMismatch() public {  
    // ASSUMPTION: Worker chooses not to dispute after being slashed  
    // EXPECTED: Worker can withdraw after 3-day dispute window expires  
    // ACTUAL: Worker blocked for 4 extra days until 7-day vault window expires  
      
    // Step 1: Worker gets slashed  
    bytes32 slashId = _slash();  
      
    // Step 2: Worker does NOT open a dispute  
    // (simulating worker choosing not to dispute or missing the window)  
      
    // Step 3: Wait 3 days - DisputeResolution window expires  
    vm.warp(block.timestamp + 3 days + 1);  
      
    // Verify dispute window has expired in DisputeResolution  
    vm.expectRevert(DisputeResolution.DisputeWindowExpired.selector);  
    vm.prank(workerOwner);  
    disputeResolution.openDispute(slashId, keccak256("counter"));  
      
    // Step 4: Try to withdraw at T=3 days - IMPACT: fails due to StakingVault's 7-day window  
    vm.expectRevert(StakingVault.StakeUnderDispute.selector);  
    vm.prank(workerOwner);  
    vault.withdraw(workerAgentId, 100 ether);  
      
    // Step 5: Wait until T=7 days - StakingVault auto-clear window expires  
    vm.warp(block.timestamp + 4 days); // Total: 7 days from slash  
      
    // Step 6: Now withdrawal succeeds  
    uint256 balanceBefore = mnty.balanceOf(workerOwner);  
    vm.prank(workerOwner);  
    vault.withdraw(workerAgentId, 100 ether);  
      
    assertEq(mnty.balanceOf(workerOwner), balanceBefore + 100 ether);  
}
```

## Fix

Align the dispute window durations between contracts:

```solidity
// Option 1: Change StakingVault default to 3 days  
uint256 public disputeWindowDuration = 3 days;  
  
// Option 2: Change DisputeResolution default to 7 days  
disputeResolution = new DisputeResolution(  
    address(registry),  
    address(slashingController),  
    address(vault),  
    address(mnty),  
    7 days  // Match StakingVault  
);  
  
// Option 3: Make StakingVault.disputeWindowDuration configurable via constructor  
constructor(address mntyTokenAddress, address agentRegistryAddress, uint256 disputeWindowDuration_) Ownable(msg.sender) {  
    // ...  
    disputeWindowDuration = disputeWindowDuration_;  
}

```

The owner can also manually align the durations post-deployment by calling setDisputeWindowDuration()

```solidity
    constructor(address mntyTokenAddress, address agentRegistryAddress) Ownable(msg.sender) {
        // L-04 FIX: Zero-address checks
        require(mntyTokenAddress != address(0), "Invalid MNTY token");
        require(agentRegistryAddress != address(0), "Invalid agent registry");
        mntyToken = IMNTY(mntyTokenAddress);
        agentRegistry = IAgentRegistryForVault(agentRegistryAddress);

```

but the default mismatch remains a deployment risk.

