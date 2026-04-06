# 🔐 Security Review — audit-contracts

---

## Scope

|                                  |                                                        |
| -------------------------------- | ------------------------------------------------------ |
| **Mode**                         | DEEP                                                   |
| **Files reviewed**               | `BountyProgramRegistry.sol` · `EscrowVault.sol`<br>`PayoutController.sol` · `ReportManager.sol`<br>`JudgeRegistry.sol` · `utils/ReentrancyGuard.sol` |
| **Confidence threshold (1-100)** | 75                                                     |

---

## Findings

[100] **1. Second-opinion downgrade to unconfigured severity below lowest tier creates permanently stuck report**

`PayoutController.approveSecondOpinion` · Confidence: 100

**Description**

When outcome==1 (downgrade) and the secondary judge picks a severity tier below the lowest configured payout tier (e.g., severity=1 when only severity 2–4 are configured), the fallback guard `if (severity > lowest)` does not fire because severity < lowest, leaving `payoutAmount = 0`. The report transitions to `SECOND_OPINION_RESOLVED` with zero payout. In `finalizeAndPay`, `payoutBounty(programId, researcher, 0)` always reverts with `AMOUNT_ZERO`, permanently bricking the report — it can never be paid or closed, and `blockingReportCount` is never decremented, blocking program refund.

**Fix**

```diff
- if (severity > lowest) {
-     severity = lowest;
- }
+ severity = lowest;
```

---

[100] **2. Rounding in `_applyPenaltyPayment` causes arithmetic underflow revert on partial payments**

`EscrowVault._applyPenaltyPayment` · Confidence: 100

**Description**

`secondaryPay` is computed as the remainder `reportPayment - treasuryPay - primaryPay`, accumulating upward rounding that can exceed `reportPenaltySecondaryDebt[rId]`. Concrete example: debt=100 (treasury=20, primary=40, secondary=40), partial payment=99 → treasuryPay=19, primaryPay=39, secondaryPay=41 > secondaryDebt=40 → underflow revert on line 464. This bricks `deposit()`, `payPenaltyDebt()`, and `refund()` for any program with outstanding penalty debt whenever a partial payment triggers the rounding edge case.

**Fix**

```diff
  uint256 treasuryPay = (reportPayment * rTreasuryDebt) / reportDebt;
  uint256 primaryPay = (reportPayment * rPrimaryDebt) / reportDebt;
  uint256 secondaryPay = reportPayment - treasuryPay - primaryPay;

  reportPenaltyDebt[rId] -= reportPayment;
  reportPenaltyTreasuryDebt[rId] -= treasuryPay;
  reportPenaltyPrimaryDebt[rId] -= primaryPay;
- reportPenaltySecondaryDebt[rId] -= secondaryPay;
+ uint256 rSecondaryDebt = reportPenaltySecondaryDebt[rId];
+ reportPenaltySecondaryDebt[rId] -= (secondaryPay > rSecondaryDebt ? rSecondaryDebt : secondaryPay);
```

---

[80] **3. Blacklisted USDC recipient permanently locks funds via push-pattern payments**

`EscrowVault.payoutJudge` · `EscrowVault._applyPenaltyPayment` · Confidence: 80

**Description**

All fund disbursements use push-pattern `token.transfer()` with `require` guards. If any recipient (judge, treasury, or penalty beneficiary) is USDC-blacklisted: (a) `payoutJudge` reverts inside `finalizeAndPay`, bricking the entire report finalization with no emergency bypass for judge payments; (b) `_applyPenaltyPayment` reverts inside `deposit()`, `refund()`, and `payPenaltyDebt()`, blocking all deposits and refunds for the program. Unlike researcher payouts (which have `emergencyBountyPayout`), there is no emergency path for stuck judge or penalty payments.

**Fix**

```diff
  // In payoutJudge — wrap transfer in try/catch or use pull pattern
- require(token.transfer(to, amount), "TRANSFER_FAILED");
+ bool success = token.transfer(to, amount);
+ if (!success) {
+     // Credit a claimable balance instead of reverting
+     unclaimedBalance[to] += amount;
+ }
```

---

[75] **4. Rejected escalation zeroes bounty payout for previously-approved reports**

`PayoutController.finalizeEscalation` · Confidence: 75

**Description**

When `finalizeEscalation` is called with outcome==1 (reject escalation), lines 416–418 unconditionally set `payoutAmount = 0` and `judgeFeeAmount = 0`. For a report that was `APPROVED_PRIMARY` before escalation (researcher escalated seeking higher severity), a rejected escalation now zeroes the originally approved payout amount. The report transitions to `ESCALATED_REJECTED` with `payoutAmount = 0` stored in the report struct, and since `ESCALATED_REJECTED` is not in the `finalizeAndPay` allowlist, the researcher permanently loses the originally approved bounty.

**Fix**

```diff
  } else if (outcome == 1) {
      require(severity == 0, "INVALID_SEVERITY_FOR_OUTCOME");
      escalationAmount = 0;
-     payoutAmount = 0;
-     judgeFeeAmount = 0;
+     // Preserve original payout if report was previously approved
+     // payoutAmount and judgeFeeAmount remain from the original approval
      judgePenaltyBps= 0;
      outcome = 2;
  }
```

---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [100] | Second-opinion downgrade to unconfigured severity below lowest tier creates permanently stuck report |
| 2 | [100] | Rounding in `_applyPenaltyPayment` causes arithmetic underflow revert on partial payments |
| 3 | [80] | Blacklisted USDC recipient permanently locks funds via push-pattern payments |
| 4 | [75] | Rejected escalation zeroes bounty payout for previously-approved reports |
| | | **Below Confidence Threshold** |
| 5 | [70] | Rounding dust residual in proportional penalty distribution leaves `companyPenaltyDebt` permanently non-zero |

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
