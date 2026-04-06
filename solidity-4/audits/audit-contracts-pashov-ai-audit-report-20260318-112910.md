# Security Review — audit-contracts

---

## Scope

|                                  |                                                        |
| -------------------------------- | ------------------------------------------------------ |
| **Mode**                         | DEEP                                                   |
| **Files reviewed**               | `BountyProgramRegistry.sol` · `EscrowVault.sol` · `JudgeRegistry.sol`<br>`PayoutController.sol` · `ReportManager.sol` · `ReentrancyGuard.sol` |
| **Confidence threshold (1-100)** | 80                                                     |

---

## Findings

[85] **1. Secondary judge invalidation fee silently skipped when judge pool insufficient**

`PayoutController.approveSecondOpinion` · Confidence: 85

**Description**
When a secondary judge invalidates a report (outcome==2), the invalidation fee payment is conditionally skipped with a silent `if` check (`if (secondaryInvalidationFee > 0 && totalJudgeFeeAmount >= secondaryInvalidationFee)`) instead of reverting; the judge performs work, the report transitions to SECOND_OPINION_REJECTED, but the judge receives zero compensation with no event or revert indicating the fee was skipped — a griefable condition since the company can strategically drain the judge pool via other reports first.

**Fix**

```diff
- if (secondaryInvalidationFee > 0 && totalJudgeFeeAmount >= secondaryInvalidationFee) {
-     escrow.payoutJudge(programId, msg.sender, secondaryInvalidationFee);
- }
+ if (secondaryInvalidationFee > 0) {
+     require(totalJudgeFeeAmount >= secondaryInvalidationFee, "INSUFFICIENT_JUDGE_BALANCE");
+     escrow.payoutJudge(programId, msg.sender, secondaryInvalidationFee);
+ }
```

---

[80] **2. USDC-blacklisted judge permanently DoSes report payout with no recovery path**

`EscrowVault.payoutJudge` / `PayoutController.finalizeAndPay` · Confidence: 80

**Description**
`finalizeAndPay` unconditionally calls `escrow.payoutJudge(programId, report.primaryJudge, judgeFeeAmount)` before marking the report paid; if Circle blacklists the judge's address, the `token.transfer` call permanently reverts, trapping the researcher's payout in `READY_TO_PAY` forever — unlike the analogous researcher-blacklist scenario, no `emergencyJudgePayout` or judge-redirect function exists anywhere in the system.

**Fix**

```diff
+ // Add to EscrowVault:
+ function emergencyJudgePayout(uint256 programId, address to, uint256 amount) external onlyAdmin {
+     require(to != address(0), "TO_ZERO");
+     require(amount > 0, "AMOUNT_ZERO");
+     require(judgeBalance[programId] >= amount, "INSUFFICIENT_JUDGE");
+     judgeBalance[programId] -= amount;
+     BountyProgramRegistry.ProgramConfig memory config = registry.getProgram(programId);
+     IERC20 token = IERC20(config.payoutToken);
+     require(token.transfer(to, amount), "TRANSFER_FAILED");
+     emit JudgePaid(programId, to, amount);
+ }
```

Additionally, refactor `PayoutController.finalizeAndPay` so a failed judge transfer does not block the researcher payout (e.g., accumulate unclaimed judge fees separately).

---

[75] **3. Admin can drain `bountyBalance` via `emergencyBountyPayout` while `READY_TO_PAY` reports exist**

`EscrowVault.emergencyBountyPayout` · Confidence: 75

**Description**
`emergencyBountyPayout` reduces `bountyBalance` without checking whether any report is in `READY_TO_PAY` status; a malicious or compromised admin can drain the pool after a researcher's report has been approved, causing `finalizeAndPay` → `escrow.payoutBounty` to revert on `INSUFFICIENT_BOUNTY` and permanently blocking the researcher's payout.

---

[75] **4. Fee-on-Transfer token causes inflated accounting leading to insolvency**

`EscrowVault.deposit` · Confidence: 75

**Description**
`deposit()` credits `bountyBalance[programId]` using the caller-supplied `amount` parameter without measuring the token balance before and after `transferFrom`; if `allowedPayoutToken` is a fee-on-transfer ERC20, the vault receives less than `amount` but records the full pre-fee value, permanently inflating internal accounting such that later `payoutBounty` or `payoutJudge` calls will revert for the last claimant.

---

[75] **5. Rebasing / elastic-supply token causes vault insolvency**

`EscrowVault.deposit` · Confidence: 75

**Description**
`EscrowVault` uses internal ledger mappings (`bountyBalance`, `judgeBalance`) set at deposit time and never reconciled with `token.balanceOf(address(this))`; if `allowedPayoutToken` is a negative-rebasing token, the vault's actual token balance silently falls below the sum of all recorded balances, causing final `payoutBounty` or `payoutJudge` transfers to revert permanently.

---

[70] **6. Rounding adjustment in `_applyPenaltyPayment` may cause arithmetic underflow DoS**

`EscrowVault._applyPenaltyPayment` · Confidence: 70

**Description**
When the rounding remainder `secondaryPay = reportPayment - treasuryPay - primaryPay` exceeds `rSecondaryDebt`, the excess is added to `primaryPay`; in theory, `primaryPay` could then exceed `reportPenaltyPrimaryDebt[rId]`, causing an underflow revert under Solidity 0.8's checked arithmetic. Extensive manual testing with concrete values could not produce a triggering case — the excess appears bounded to at most 1-2 wei which stays within `rPrimaryDebt` for realistic penalty amounts — but a formal proof of safety is absent.

---

[60] **7. Deactivated judge can still finalize payments via `finalizeAndPay`**

`PayoutController.finalizeAndPay` · Confidence: 60

**Description**
`finalizeAndPay` verifies the caller matches the stored `primaryJudge` or `secondaryJudge` address but does not check `judges.isJudge(msg.sender)`, so a judge removed from the registry after approving a report can still call `finalizeAndPay` to complete payouts and collect fees despite being deactivated.

---

## Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [85] | Secondary judge invalidation fee silently skipped when judge pool insufficient |
| 2 | [80] | USDC-blacklisted judge permanently DoSes report payout with no recovery path |
| | | **Below Confidence Threshold** |
| 3 | [75] | Admin can drain `bountyBalance` via `emergencyBountyPayout` while `READY_TO_PAY` reports exist |
| 4 | [75] | Fee-on-Transfer token causes inflated accounting leading to insolvency |
| 5 | [75] | Rebasing / elastic-supply token causes vault insolvency |
| 6 | [70] | Rounding adjustment in `_applyPenaltyPayment` may cause arithmetic underflow DoS |
| 7 | [60] | Deactivated judge can still finalize payments via `finalizeAndPay` |

---

> This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)