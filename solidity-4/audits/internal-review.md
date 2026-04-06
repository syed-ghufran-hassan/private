# Internal Audit - Need4Audit Protocol

## Findings

# High-01 Immutable addresses in `PayoutController` make the protocol unfunctional if one of them is updated

## Description

In `PayoutController` the `registry`, `escrow`, `judges` and `reports` addresses are immutable, but in other contracts they can be changed:

```solidity
BountyProgramRegistry public immutable registry;
EscrowVault public immutable escrow;
JudgeRegistry public immutable judges;
ReportManager public immutable reports;
```

If some of these addresses are changed the `PayoutController` contract will be unable to work.

Also, the `BountyProgramRegistry::setRegistryAddresses` allows the admin to change the `escrowVault`, `judgeRegistry` and `payoutController` addresses. B
ut the function doesn't allow to change only one of them.

## Recommendation

Add a option the `registry`, `escrow`, `judges` and `reports` addresses to be updated in `PayoutController` and allow to change only one of them at time in `BountyProgramRegistry::setRegistryAddresses` function.

---

# High-02: `EscrowVault::accrueCompanyPenalty` reverts when there is more than one judge pair for one program

## Description

The [`EscrowVault::accrueCompanyPenalty`](https://github.com/JordyKingz/need4audit-smart-contracts/blob/25f8c2a488be58c70fa1eccd3e5b7e2f7096eebc/src/EscrowVault.sol#L356) 
function checks if the `companyPenaltyDebt[programId]` is 0, if it is not the function requires the `primaryJudge` and the `secondaryJudge` to be equal to these set in the mapping:

```solidity
  function accrueCompanyPenalty(
    uint256 programId,
    uint256 amount,
    address primaryJudge,
    address secondaryJudge
  ) external onlyPayoutController {
    require(amount > 0, "AMOUNT_ZERO");
    require(primaryJudge != address(0), "PRIMARY_JUDGE_ZERO");
    require(secondaryJudge != address(0), "SECOND_JUDGE_ZERO");

@>  if (companyPenaltyDebt[programId] == 0) {
        companyPenaltyPrimaryJudge[programId] = primaryJudge;
        companyPenaltySecondaryJudge[programId] = secondaryJudge;
    } else {
        require(companyPenaltyPrimaryJudge[programId] == primaryJudge, "PRIMARY_JUDGE_MISMATCH");
        require(companyPenaltySecondaryJudge[programId] == secondaryJudge, "SECOND_JUDGE_MISMATCH");
    }
...
```

But the `deposit` function also allows the company to pay only part of the `companyPenaltyDebt`:

```solidity
...
  if (debt > 0) {
    penaltyPaid = amount < debt ? amount : debt;
    if (penaltyPaid > 0) {
        uint256 treasuryDebt = companyPenaltyTreasuryDebt[programId];
        uint256 primaryDebt = companyPenaltyPrimaryDebt[programId];
        uint256 secondaryDebt = companyPenaltySecondaryDebt[programId];

        uint256 treasuryPay = (penaltyPaid * treasuryDebt) / debt;
        uint256 primaryPay = (penaltyPaid * primaryDebt) / debt;
        uint256 secondaryPay = penaltyPaid - treasuryPay - primaryPay;

@>      companyPenaltyDebt[programId] = debt - penaltyPaid;
...

```

This means that there is a scenario in that the company program has a report that is escalated, the company should pay debt. 
The company doesn't pay the full amount of debt, but there is second report with second pair of judges for a second escalted report for the same program. 
In that case the `primary/secondaryJudge` will be not the same as these in the mappings and the function reverts, the `approveSecondOpinion` in `PayoutController` also reverts and the judges are not paid.

Also, the `EscrowVault::refund` function transfers funds to the primary and secondary judges and gets their addresses from the mapping. But if the program has multiple pairs of judges, it is possible, the mapping to point to the first one pair not the last one (if the dept was not 0).

## Recommendation

Track the judges pair per report not programId and also you can track the reports per program ids.

---

# Medium-01: Companies can set any token for `payoutToken` in `BountyProgramRegistry::createProgram` function

## Description

In [`EscrowVault`](https://github.com/JordyKingz/need4audit-smart-contracts/blob/25f8c2a488be58c70fa1eccd3e5b7e2f7096eebc/src/EscrowVault.sol#L28) contract we see that the minimum amount is hardcoded to 1e6:
` uint256 public constant MIN_DEPOSIT = 1e6;`

Also, in the `ProgramConfigInput` we see that the expected `payoutToken` is USDC:

```solidity

struct ProgramConfigInput {
    address companyOwner;
    address payoutToken; // usdc
    uint16 judgeFeeBps; // deprecated
    uint16 treasuryFeeBps; // deprecated
    address treasury; // create a setter for this
    uint8[] severities;
    uint256[] payoutAmounts;
}
```

But in the `BountyProgramRegistry::createProgram` function, there is no check for that:

```solidity

  function createProgram(ProgramConfigInput calldata input) external returns (uint256 programId) {
    require(input.companyOwner != address(0), "OWNER_ZERO");
    require(input.payoutToken != address(0), "TOKEN_ZERO");
    require(treasury != address(0), "TREASURY_ZERO");
    require(uint256(judgeFeeBps) + uint256(treasuryFeeBps) <= 1_000, "BPS_INVALID"); // 10%
    require(input.severities.length == input.payoutAmounts.length, "PAYOUT_LENGTH");

    programId = nextProgramId++;
    programs[programId] = ProgramConfig({
        companyOwner: input.companyOwner,
        payoutToken: input.payoutToken,
        judgeFeeBps: judgeFeeBps,
        treasuryFeeBps: treasuryFeeBps,
        treasury: treasury,
        companyPenaltyBps: 0,
        judgePenaltyInvalidBps: 0,
        judgePenaltyDowngradeBps: 0,
        escalationCriticalBps: escalationCriticalBps,
        escalationHighBps: escalationHighBps,
        escalationMediumBps: escalationMediumBps,
        escalationLowBps: escalationLowBps,
        status: Status.DRAFT,
        createdAt: uint64(block.timestamp),
        updatedAt: uint64(block.timestamp),
        pausedAt: uint64(0)
    });

    uint256 severityCount = input.severities.length;
    if (severityCount > 0) {
        hasPayoutSchedule[programId] = true;
    }
    uint256 seenMask;
    for (uint256 i = 0; i < severityCount; i++) {
        uint8 severity = input.severities[i];
        // 1=Low,2=Medium,3=High,4=Critical
        require(severity != 0, "SEVERITY_ZERO");
        require(severity < 5, "INVALID_SEVERITY");
        uint256 bit = 1 << severity;
        require(seenMask & bit == 0, "DUPLICATE_SEVERITY");
        seenMask |= bit;
        uint256 payoutAmount = input.payoutAmounts[i];
        payoutBySeverity[programId][severity] = payoutAmount;
        totalPayoutByProgram[programId] += payoutAmount;
        emit ProgramPayoutUpdated(programId, severity, payoutAmount);
    }

    bytes32 payoutHash = keccak256(abi.encode(input.severities, input.payoutAmounts));
    bytes32 configHash = keccak256(
        abi.encode(input.companyOwner, input.payoutToken, judgeFeeBps, treasuryFeeBps, treasury, payoutHash)
    );
    emit ProgramCreated(programId, input.companyOwner, input.payoutToken, treasury, configHash);
}

```

The companies can set for payout token any token that they want. But if the token is USDT the transfer operations will all revert, because the USDT doesn't return bool value on `transfer` operation. That means it will revert all functions that use `transfer/transferFrom`. Also, it is assumed in the protocol that the used token has 6 decimals.

## Recommendation

Add a check in `BountyProgramRegistry::createProgram` function that the payout token is USDC.

---

# Medium-02: The `EscrowVault::emergencyBountyPayout` function bypasses `deactivateFromPaidBounty`

## Description

[`EscrowVault::emergencyBountyPayout`](https://github.com/JordyKingz/need4audit-smart-contracts/blob/25f8c2a488be58c70fa1eccd3e5b7e2f7096eebc/src/EscrowVault.sol#L391) 
function decrements the `bountyBalance` and transfers tokens but never calls `registry.deactivateFromPaidBounty`, 
so after an emergency payout the program can remain `ACTIVE` with `bountyBalance == 0`, 
allowing `PayoutController` to attempt subsequent payouts that will revert with `INSUFFICIENT_BOUNTY` 
while the program appears active to researchers.

## Recommendation

Add a call to the `registry.deactivateFromPaidBounty` like in a normal paid bounty execution path.

---

# Medium-03: The `EscrowVault::deposit` function reverts if the `amount` is equal to `penaltyPaid`

## Description

The function [`EscrowVault::deposit`](https://github.com/JordyKingz/need4audit-smart-contracts/blob/25f8c2a488be58c70fa1eccd3e5b7e2f7096eebc/src/EscrowVault.sol#L117) 
allows the companies to make a deposit and pay debs to activate the program:

```solidity
  function deposit(uint256 programId, uint256 amount) external nonReentrant {
    require(amount > 0, "AMOUNT_ZERO");
    require(amount >= MIN_DEPOSIT, "AMOUNT_TOO_SMALL");
    BountyProgramRegistry.ProgramConfig memory config = registry.getProgram(programId);
    require(config.companyOwner != address(0), "PROGRAM_NOT_FOUND");
    require(
        config.status == BountyProgramRegistry.Status.DRAFT,
        "PROGRAM_NOT_DEPOSITABLE"
    );
    require(
        config.judgeFeeBps + config.treasuryFeeBps < 10_000,
        "INVALID_FEE_CONFIGURATION"
    );
    uint256 totalFeeBps = config.judgeFeeBps + config.treasuryFeeBps;
    uint256 totalFeeBpsPs = 10_000 + totalFeeBps;

    IERC20 token = IERC20(config.payoutToken);
    require(token.transferFrom(msg.sender, address(this), amount), "TRANSFER_FAILED");

    uint256 penaltyPaid = 0;
    uint256 debt = companyPenaltyDebt[programId];

    if (debt > 0) {
@>      penaltyPaid = amount < debt ? amount : debt;
        if (penaltyPaid > 0) {
            uint256 treasuryDebt = companyPenaltyTreasuryDebt[programId];
            uint256 primaryDebt = companyPenaltyPrimaryDebt[programId];
            uint256 secondaryDebt = companyPenaltySecondaryDebt[programId];

            uint256 treasuryPay = (penaltyPaid * treasuryDebt) / debt;
            uint256 primaryPay = (penaltyPaid * primaryDebt) / debt;
            uint256 secondaryPay = penaltyPaid - treasuryPay - primaryPay;

            companyPenaltyDebt[programId] = debt - penaltyPaid;
            companyPenaltyTreasuryDebt[programId] = treasuryDebt - treasuryPay;
            companyPenaltyPrimaryDebt[programId] = primaryDebt - primaryPay;
            companyPenaltySecondaryDebt[programId] = secondaryDebt - secondaryPay;

            if (treasuryPay > 0) {
                require(token.transfer(config.treasury, treasuryPay), "PENALTY_TREASURY_TRANSFER_FAILED");
            }
            if (primaryPay > 0) {
                address primaryJudge = companyPenaltyPrimaryJudge[programId];
                require(primaryJudge != address(0), "PRIMARY_JUDGE_ZERO");
                require(token.transfer(primaryJudge, primaryPay), "PENALTY_PRIMARY_TRANSFER_FAILED");
            }
            if (secondaryPay > 0) {
                address secondaryJudge = companyPenaltySecondaryJudge[programId];
                require(secondaryJudge != address(0), "SECOND_JUDGE_ZERO");
                require(token.transfer(secondaryJudge, secondaryPay), "PENALTY_SECONDARY_TRANSFER_FAILED");
            }
            if (companyPenaltyDebt[programId] == 0) {
                companyPenaltyPrimaryJudge[programId] = address(0);
                companyPenaltySecondaryJudge[programId] = address(0);
            }
            emit CompanyPenaltyPaid(programId, penaltyPaid);
        }
    }

@>  uint256 netAmount = amount - penaltyPaid;
    uint256 bountyAmount = netAmount * 10_000 / totalFeeBpsPs;
@>  require(bountyAmount > 0, "Overflow check");
    require(netAmount >= bountyAmount, "Overflow check");
    uint256 fees = netAmount - bountyAmount;

    uint256 judgeFee = 0;
    uint256 treasuryFee = 0;
    if (totalFeeBps > 0) {
        judgeFee = (fees * config.judgeFeeBps) / totalFeeBps;
        treasuryFee = fees - judgeFee;
    }

    if (registry.hasPayoutSchedule(programId)) {
        uint256 initialBountyBalance = bountyBalance[programId];
        uint256 requiredBounty = registry.totalPayoutByProgram(programId);
@>      require((bountyAmount + initialBountyBalance) >= requiredBounty, "INSUFFICIENT_INITIAL_BOUNTY");
    }

    bountyBalance[programId] += bountyAmount;
    judgeBalance[programId] += judgeFee;

    if (treasuryFee > 0) {
        require(token.transfer(config.treasury, treasuryFee), "TREASURY_TRANSFER_FAILED");
    }

    emit Deposited(programId, msg.sender, amount, bountyAmount, judgeFee, treasuryFee);

    registry.activateFromDeposit(programId);
}

```

But let's imagine the following scenario. 
The company pays for Low severity issues and the company has deposited for more than one Low report, 
because the function alows that: `require((bountyAmount + initialBountyBalance) >= requiredBounty, "INSUFFICIENT_INITIAL_BOUNTY");`, 
but the company has debt. The company calls the `deposit` function with the `amount` equals or lower than `debt`. 
In that case the `penaltyPaid` will be equal to `amount`: `penaltyPaid = amount < debt ? amount : debt;`. 
Then the `netAmount` will be 0: `uint256 netAmount = amount - penaltyPaid;` and the `bountyAmount` will be 0: `uint256 bountyAmount = netAmount * 10_000 / totalFeeBpsPs;`, 
then the function reverts in this check: `require(bountyAmount > 0, "Overflow check");`. 

But in reality the company has enough deposit to continue the bounty program and to pass this check: 
`require((bountyAmount + initialBountyBalance) >= requiredBounty, "INSUFFICIENT_INITIAL_BOUNTY");`.
This means that the company is unable to pay the debts and activate again the bounty program when it has enough deposit for the bounty program. 
Moreover, the `penaltyPaid` variable to be equal to the `amount` variable is a correct path in the function.

## Recommendation

Check first if the company's `initialBountyBalance` is sufficient to cover the `requiredBounty` and then calculate the `netAmount`, `bountyAmount` and fees.

---

# Medium-04: Companies can close their program without paying the whole amount of debt

## Description

The `BountyProgramRegistry::executeRefund` call the `EscrowVault::refund` function to refund the left funds to the company:

```solidity

function refund(uint256 programId) external  {
  require(msg.sender == address(registry), "NOT_REGISTRY");
  BountyProgramRegistry.ProgramConfig memory config = registry.getProgram(programId);
  require(config.companyOwner != address(0), "PROGRAM_NOT_FOUND");
  require(config.status == BountyProgramRegistry.Status.CLOSED, "PROGRAM_NOT_CLOSED");

  uint256 balance = bountyBalance[programId];
  uint256 refundAmount = balance;
  uint256 debt = companyPenaltyDebt[programId];
  IERC20 token = IERC20(config.payoutToken);

  if (debt > 0) {
@>    uint256 penaltyPaid = balance < debt ? balance : debt;
...
```

The problem is that the function check if the `balance` is lower than `debt` and if it is, it assigns this `balance` to the `penaltyPaid` variable. 
This means that the function allows the company to close the program without paying the full amount of the debt. 
This leads to less funds for the judges and treasury than the intended. 
Also, after the company program receives CLOSED status, it can be activate again through the `deposit` function.

## Recommendation

If the balance is not sufficient to cover the debt, require the company to send the required amount of funds to cover the full debt.

---

# Low-01: The modifier `BountyProgramRegistry::onlyPayoutController` uses wrong error string

## Description

The `onlyPayoutController` modifier emits the error string `NOT_ESCROW_VAULT` instead of `NOT_PAYOUT_CONTROLLER`:

```solidity
modifier onlyPayoutController() {
    require(msg.sender == payoutController, "NOT_ESCROW_VAULT");
    _;
}
```

## Recommendation

```diff
modifier onlyPayoutController() {
-     require(msg.sender == payoutController, "NOT_ESCROW_VAULT");
+     require(msg.sender == payoutController, "NOT_PAYOUT_CONTROLLER");
      _;
}
```

---

# Low-02: Incorrect use of `block.timestamp` comparison

## Description

In [`BountyProgramRegistry::cancelRefund`](https://github.com/JordyKingz/need4audit-smart-contracts/blob/25f8c2a488be58c70fa1eccd3e5b7e2f7096eebc/src/BountyProgramRegistry.sol#L265) 
any researcher with a non-terminal report can cancel the refund within a 5-day window:

```solidity
  function cancelRefund(uint256 programId, bytes32 reportHash) external {
    ProgramConfig storage config = programs[programId];
    require(config.companyOwner != address(0), "PROGRAM_NOT_FOUND");
    require(config.status == Status.PAUSED, "PROGRAM_NOT_REFUND_STATE");
@>  require(block.timestamp <= uint256(config.pausedAt) + REFUND_WINDOW, "REFUND_WINDOW_EXPIRED");
  ...
```

The function requires the current `block.timestamp` to be lower or equal to the `uint256(config.pausedAt) + REFUND_WINDOW`.
The [`BountyProgramRegistry::executeRefund`](https://github.com/JordyKingz/need4audit-smart-contracts/blob/25f8c2a488be58c70fa1eccd3e5b7e2f7096eebc/src/BountyProgramRegistry.sol#L296) 
function executes the refund and permanently closes the program after the 5-day cancellation window has passed:

```solidity
  function executeRefund(uint256 programId) external {
    ProgramConfig storage config = programs[programId];
    require(config.companyOwner != address(0), "PROGRAM_NOT_FOUND");
    require(msg.sender == config.companyOwner, "NOT_PROGRAM_OWNER");
    require(config.status == Status.PAUSED, "PROGRAM_NOT_ACTIVE");
@>  require(block.timestamp >= uint256(config.pausedAt) + REFUND_WINDOW, "REFUND_WINDOW_NOT_PASSED");
  ...
```

The problem is that the `executeRefund` function requires the current `block.timestamp` to be greater or equal to the `uint256(config.pausedAt) + REFUND_WINDOW`. 
This means that in the exact same time when the `block.timestamp` is equal to the `uint256(config.pausedAt) + REFUND_WINDOW` the cancel refund and execute refund operations are both possible.

## Recommendation

Update the `require` statement in the `executeRefund` function to requires the current `block.timestamp` to be greater than the `uint256(config.pausedAt) + REFUND_WINDOW`:

```diff
  function executeRefund(uint256 programId) external {
    ProgramConfig storage config = programs[programId];
    require(config.companyOwner != address(0), "PROGRAM_NOT_FOUND");
    require(msg.sender == config.companyOwner, "NOT_PROGRAM_OWNER");
    require(config.status == Status.PAUSED, "PROGRAM_NOT_ACTIVE");
-   require(block.timestamp >= uint256(config.pausedAt) + REFUND_WINDOW, "REFUND_WINDOW_NOT_PASSED");
+   require(block.timestamp > uint256(config.pausedAt) + REFUND_WINDOW, "REFUND_WINDOW_NOT_PASSED");
  ...
```

---

# Low-03: Incorrect error in `BountyProgramRegistry::executeRefund` function

## Description

In the [`BountyProgramRegistry::executeRefund`](https://github.com/JordyKingz/need4audit-smart-contracts/blob/25f8c2a488be58c70fa1eccd3e5b7e2f7096eebc/src/BountyProgramRegistry.sol#L295) function the error returned in one of the require statement is not correct:
`require(config.status == Status.PAUSED, "PROGRAM_NOT_ACTIVE");`

## Recommendation

Change the error to be: `PROGRAM_NOT_REFUND_STATE` like in the `cancelRefund` function.

---

# Low-04: Incorrect error in `JudgeRegistry::setReportManager`

## Description

In `JudgeRegistry::setReportManager` is used `ADMIN_ZERO` error when the `newReportManager` address is zero which is incorrect:

```solidity
function setReportManager(address newReportManager) external onlyAdmin {
@>  require(newReportManager != address(0), "ADMIN_ZERO");
    require(reportManager != newReportManager, "ALREADY_MANAGER");
    reportManager = newReportManager;
    emit ReportManagerUpdated(newReportManager);
}
```

## Recommendation

Use for example `REPORT_MANAGER_ZERO` error:

```diff
- require(newReportManager != address(0), "ADMIN_ZERO");
+ require(newReportManager != address(0), "REPORT_MANAGER_ZERO");
```

---

# Low-05: Only `PayoutController::approvePrimary` function checks if the program is active

## Description

In the `PayoutController` contract only `PayoutController::approvePrimary` function checks if the program is still active. But other functions like `approveSecondOpinion`, `finalizeEscalation` and `finalizeAndPay` don't check if the program is active.
If there is another report that is finalized and payed the program can be not longer active. And if there are not enough balance in the vault, the transaction reverts.

## Recommendation

Add a check in these function to ensure that the program is active.

---

# Info-01: Incorrect natspec for the `createProgram` function

## Description

In the natspec for the [`BountyProgramRegistry::createProgram`](https://github.com/JordyKingz/need4audit-smart-contracts/blob/25f8c2a488be58c70fa1eccd3e5b7e2f7096eebc/src/BountyProgramRegistry.sol#L308) is written:
`/// @dev Fee bps must sum to <= 10_000. Optional severity payouts are stored onchain and`
But actually the sum of the fees should be lower or equal to 10% that is 1_000 not 10_000 (100%).

## Recommendation

Change the natspec to: `/// @dev Fee bps must sum to <= 1_000. Optional severity payouts are stored onchain and`.

---

# Info-02: Incorrect natspec for the `deactivateFromPaidBounty` function

## Description

In the natspec for the [`BountyProgramRegistry::deactivateFromPaidBounty`](https://github.com/JordyKingz/need4audit-smart-contracts/blob/25f8c2a488be58c70fa1eccd3e5b7e2f7096eebc/src/BountyProgramRegistry.sol#L380) is written: `@dev Only escrow vault can call this transition. ACTIVE programs move back to DRAFT.` But actually `DEACTIVATE` programs move back to `DRAFT`.

## Recommendation

Change the natspec to: `@dev Only escrow vault can call this transition. DEACTIVATE programs move back to DRAFT.`

---

# Info-03: Redundant check in `BountyProgramRegistry::initiateRefund` and `BountyProgramRegistry::executeRefund` functions

## Description

There is a redundant check in `BountyProgramRegistry::initiateRefund` and `BountyProgramRegistry::executeRefund` functions:

```solidity
require(config.companyOwner != address(0), "PROGRAM_NOT_FOUND");
require(msg.sender == config.companyOwner, "NOT_PROGRAM_OWNER");
```

If the caller is the `config.companyOwner`, the `config.companyOwner` can't be the zero address.

## Recommendation

The check if the caller is the company owner is sufficient.

---

# Info-04: `EscrowVault` uses `transfer/transferFrom` instead `safeTransfer/safeTransferFrom`

## Description

The `EscrowVault` contract uses `transfer/transferFrom` to transfer funds. 
The returned value is checked and the used token will be USDC, so there is no problem from that. 
But if in the future USDT will be used too, it will be a problem. 
The USDT token on Ethereum doesn't return bool value and all operations that use `transfer/transferFrom` will revert. 
Therefore, it is a good practice to use `safeTransfer/safeTransferFrom`.

## Recommendation

Use `safeTransfer/safeTransferFrom` functions instead of `transfer/transferFrom`.

---

# Info-05: Incorrect check for the sum of the fees in the `EscrowVault::deposit` function

## Description

The [`EscrowVault::deposit`](https://github.com/JordyKingz/need4audit-smart-contracts/blob/25f8c2a488be58c70fa1eccd3e5b7e2f7096eebc/src/EscrowVault.sol#L127) function requires the sum of the fees to be lower than 100%:

```solidity
require(
    config.judgeFeeBps + config.treasuryFeeBps < 10_000,
    "INVALID_FEE_CONFIGURATION"
);
```

But according to the [`BountyProgram::createProgram`](https://github.com/JordyKingz/need4audit-smart-contracts/blob/25f8c2a488be58c70fa1eccd3e5b7e2f7096eebc/src/BountyProgramRegistry.sol#L317):
`require(uint256(judgeFeeBps) + uint256(treasuryFeeBps) <= 1_000, "BPS_INVALID");` the sum of the fees should be lower or equal to 10% (1_000). 
There is no impact of that, because the program is created in `createProgram` function where the condition is correct.

## Recommendation

Change the `require` condition in the `EscrowVault::deposit` to `config.judgeFeeBps + config.treasuryFeeBps <= 1_000

---

# Info-06: `EscrowVault::deposit` function can be called by anyone

## Description

There is no access control in `EscrowVault::deposit` function. This means that anyone can deposit instead of company owner. 
There is no impact from that, but it is a good recommendation, the function to be called only by the company owner.

## Recommenation

Add a check in the `deposit` function if the caller is the company owner.

---

# Info-07: NatDoc comment says 0.001 ETH But `DRIP_AMOUNT` is 0.01 ETH

## Description

The NatDoc comment on `Faucet::claim` says `Claims 0.001 ETH` but `DRIP_AMOUNT = 0.01 ether`.

## Recommendation

```diff
- /// @notice Claims 0.001 ETH if caller is eligible.
+ /// @notice Claims 0.01 ETH if caller is eligible.
```

---

**Notes:**

- Currently the company initiates refund and the researchers have 5 day to cancel it if they have a report in the reuired status. 
- But I am not sure if this is a good design.
- What if the researcher didn't see that the company wants to close the program. 
- Probably it is better if there is a check if the program has a reports in a required status and delays the refund until these reports are done.