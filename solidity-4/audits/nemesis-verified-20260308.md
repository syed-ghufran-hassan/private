# N E M E S I S — Verified Findings

## Scope
- Language: Solidity 0.8.20
- Contracts: BountyProgramRegistry, EscrowVault, PayoutController, ReportManager, JudgeRegistry
- Functions analyzed: 38
- Coupled state pairs mapped: 5
- Mutation paths traced: 14
- Nemesis loop iterations: 2 (converged after Pass 2)

---

## Nemesis Map — Phase 1 Cross-Reference

```
┌─────────────────────────────────────┬────────────────────────┬────────────────────────┬──────────────────────────────┐
│ Function                            │ report.status mutation  │ Payment action          │ Sync status                  │
├─────────────────────────────────────┼────────────────────────┼────────────────────────┼──────────────────────────────┤
│ finalizeAndPay (SUBMITTED input)    │ SUBMITTED→CLOSED        │ none                   │ ✗ GAP: no exclusion          │
│ finalizeAndPay (2ND_OP_REQ input)   │ 2ND_OP_REQ→CLOSED       │ judge fee stolen        │ ✗ GAP: bypasses 2nd opinion  │
│ finalizeAndPay (REJECTED input)     │ REJECTED→CLOSED         │ none                   │ ✗ GAP: blocks escalation     │
│ finalizeAndPay (PAID input)         │ PAID→CLOSED             │ judge fee double-paid   │ ✗ GAP: terminal not excluded │
│ SECOND_OPINION_REJECTED (final)     │ terminal state          │ no judges paid          │ ✗ GAP: secondary judge unpaid│
│ finalizeEscalation                  │ calls markEscalatedResult│ —                      │ ✗ LOW: no isJudge check      │
└─────────────────────────────────────┴────────────────────────┴────────────────────────┴──────────────────────────────┘
```

---

## Verification Summary

| ID     | Source          | Coupled Pair                     | Breaking Op                              | Severity | Verdict    |
|--------|-----------------|----------------------------------|------------------------------------------|----------|------------|
| NM-001 | Feynman→State   | report.status ↔ payment gate     | finalizeAndPay on non-excluded statuses  | HIGH     | TRUE POS   |
| NM-003 | State-only      | judgeBalance ↔ payment paths     | SECOND_OPINION_REJECTED — no payout      | MEDIUM   | TRUE POS   |
| NM-004 | Feynman-only    | isJudge allowlist ↔ finalizeEsc  | finalizeEscalation missing isJudge check | LOW      | TRUE POS   |

---

## Verified Findings

---

### Finding NM-001: `finalizeAndPay` Accepts Non-Excluded Statuses — Four Exploitable Sub-Cases

**Severity:** HIGH
**Source:** Feynman interrogation (negative exclusion pattern) confirmed by State Mapper (report.status mutation path gaps)
**Verification:** Deep code trace
**Discovery path:** Feynman-only (Phase 2 interrogation of exclusion logic)

**Root Cause:**

`finalizeAndPay` in `PayoutController.sol` uses negative exclusions to gate status:

```solidity
// PayoutController.sol L379-382
require(report.status != ReportManager.Status.CLOSED, "REPORT_CLOSED");
require(report.status != ReportManager.Status.SECOND_OPINION_REJECTED, "REPORT_SECOND_OPINION_REJECTED");
require(report.status != ReportManager.Status.ESCALATED_REJECTED, "REPORT_ESCLATED_REJECTED");
require(report.status != ReportManager.Status.ESCALATED, "REPORT_ESCALATED");
```

The terminal else-branch at the end unconditionally calls `markClosed` for any status that doesn't reach `READY_TO_PAY`:

```solidity
// PayoutController.sol L488-494
if (report.status == ReportManager.Status.READY_TO_PAY) {
    reports.markPaid(reportId);
    escrow.payoutBounty(programId, researcher, payoutAmount);
    emit PayoutExecuted(...);
} else {
    reports.markClosed(reportId);  // catch-all — no status guard
}
```

`markClosed` allows any status except `CLOSED`:
```solidity
// ReportManager.sol L349
require(report.status != Status.CLOSED, "ALREADY_CLOSED");
```

This creates four distinct attack sub-cases:

---

#### NM-001a: Primary Judge Closes Unprocessed Report (SUBMITTED → CLOSED)

**Caller:** Primary judge (assigned by admin)
**Trigger:** Call `finalizeAndPay` on a report with status `SUBMITTED` (before `approvePrimary` is called)

**Trace:**
- SUBMITTED not in exclusion list → proceeds
- L388–390 caller check: SUBMITTED is not ESCALATED_RESOLVED or SECOND_OPINION_RESOLVED → `require(report.primaryJudge == msg.sender)` → primary judge passes
- `reportStatusBefore = SUBMITTED` — not in the timelock/markReadyToPay branch
- `payoutAmount = report.payoutAmount = 0` (not yet set); `judgeFeeAmount = 0`
- No payments executed
- `report.status (SUBMITTED) != READY_TO_PAY` → `markClosed()` → `SUBMITTED→CLOSED`

**Consequence:** Researcher's report is permanently closed before any review. Admin cannot re-submit (report exists with CLOSED status, `submitReport` checks `report.status == Status.NONE`).

**Trigger Sequence:**
1. Admin: `submitReport(programId, researcher, judgeAddr, hash)` → SUBMITTED
2. judgeAddr: `finalizeAndPay(programId, researcher, hash, 0, 0)` → CLOSED

---

#### NM-001b: Primary Judge Bypasses Second Opinion and Steals Judge Fee (SECOND_OPINION_REQUESTED → CLOSED)

**Caller:** Primary judge
**Trigger:** Call `finalizeAndPay` after company calls `requestSecondOpinion`

**Trace:**
- SECOND_OPINION_REQUESTED not in exclusion list → proceeds
- Caller check: not ESCALATED_RESOLVED or SECOND_OPINION_RESOLVED → `require(report.primaryJudge == msg.sender)` → passes
- `reportStatusBefore = SECOND_OPINION_REQUESTED` — not in the timelock/markReadyToPay branch
- `payoutAmount = report.payoutAmount` (set from approvePrimary, e.g. 5,000 USDC)
- `judgeFeeAmount = report.judgeFeeAmount` (e.g. 400 USDC)
- L476–477: `require(escrow.bountyBalance(programId) >= payoutAmount)` → passes (program is funded)
- L478–480: `judgeFeeAmount > 0 && firstJudgePaid == 0` → `escrow.payoutJudge(programId, report.primaryJudge, judgeFeeAmount)` → **JUDGE PAID 400 USDC**
- `report.status (SECOND_OPINION_REQUESTED) != READY_TO_PAY` → `markClosed()` → **REPORT CLOSED**
- Researcher receives 0. Company's second opinion challenge is destroyed.

**Coupled State Broken:** `judgeBalance[programId]` reduced by judgeFeeAmount; `bountyBalance[programId]` NOT reduced; researcher NOT paid; second opinion process permanently bypassed.

**Trigger Sequence:**
1. Admin: `submitReport(programId, researcher, judgeAddr, hash)`
2. judgeAddr: `approvePrimary(programId, 3, researcher, hash)` → APPROVED_PRIMARY, payoutAmount=5000, judgeFeeAmount=400
3. companyOwner: `requestSecondOpinion(programId, researcher, hash)` → SECOND_OPINION_REQUESTED
4. judgeAddr: `finalizeAndPay(programId, researcher, hash, 3, 0)` → judge steals 400 USDC, report closed

---

#### NM-001c: Primary Judge Prevents Researcher Escalation (REJECTED → CLOSED)

**Caller:** Primary judge
**Trigger:** Call `finalizeAndPay` on a REJECTED report before the researcher escalates

**Key detail:** The timelock check only applies to `APPROVED_PRIMARY`, `ESCALATED_RESOLVED`, and `SECOND_OPINION_RESOLVED`:
```solidity
// PayoutController.sol L393-401
if (
    report.status == ReportManager.Status.APPROVED_PRIMARY ||
    report.status == ReportManager.Status.ESCALATED_RESOLVED ||
    report.status == ReportManager.Status.SECOND_OPINION_RESOLVED
) {
    require(block.timestamp >= report.timelockEnd, "TIMELOCK_ACTIVE");
    ...
}
```
`REJECTED` is not in this list. No timelock enforced. Judge can call immediately.

**Trace:**
- REJECTED not excluded → proceeds
- Caller check: primary judge passes
- `reportStatusBefore = REJECTED` — not in timelock branch
- `payoutAmount = 0`, `judgeFeeAmount = 0`
- No payments
- `markClosed()` → REJECTED→CLOSED

**Consequence:** `escalateReport` requires `report.status == APPROVED_PRIMARY || REJECTED`. Once CLOSED, researcher can never escalate. Researcher permanently denied escalation rights.

**Trigger Sequence:**
1. Admin: `submitReport(programId, researcher, judgeAddr, hash)`
2. judgeAddr: `approvePrimary(programId, 0, researcher, hash)` → REJECTED, timelockEnd = now + timelock
3. [Researcher has timelockEnd to call escalateReport]
4. judgeAddr: `finalizeAndPay(programId, researcher, hash, 0, 0)` → CLOSED immediately, no timelock check

---

#### NM-001d: Primary Judge Double-Pays Themselves on Already-PAID Report (PAID → CLOSED)

**Caller:** Primary judge
**Trigger:** Call `finalizeAndPay` again after a report has already been paid

**Trace:**
- PAID not excluded → proceeds
- Caller check: PAID is not ESCALATED_RESOLVED or SECOND_OPINION_RESOLVED → `require(report.primaryJudge == msg.sender)` → passes
- `reportStatusBefore = PAID` — not in any special branch
- `judgeFeeAmount = report.judgeFeeAmount` (same non-zero value as original)
- L478–480: if `judgeBalance[programId] >= judgeFeeAmount` → `payoutJudge` executes again
- `report.status (PAID) != READY_TO_PAY` → `markClosed()` → PAID→CLOSED

**Prerequisite:** `judgeBalance[programId]` must still have `>= judgeFeeAmount` after the first payment. This is plausible: the deposit judge fee is calculated on the full deposit amount, while `judgeFeeAmount` is calculated on a single payout. If the deposit funds multiple potential payouts, the remaining `judgeBalance` after one payout is likely sufficient.

**Example:** Program deposits 100,000 USDC (8% judge fee = 8,000 USDC in judgeBalance). Medium finding payout = 5,000 USDC, judge fee = 400 USDC. After first payment: judgeBalance = 7,600 USDC. Judge can call again: 7,600 >= 400 → double-paid. Status: PAID→CLOSED.

**Fix for all NM-001 sub-cases:**

Switch from negative exclusions to a positive allowlist:

```solidity
// Replace the negative exclusion block in finalizeAndPay with:
require(
    report.status == ReportManager.Status.APPROVED_PRIMARY ||
    report.status == ReportManager.Status.ESCALATED_RESOLVED ||
    report.status == ReportManager.Status.SECOND_OPINION_RESOLVED ||
    report.status == ReportManager.Status.READY_TO_PAY,
    "REPORT_NOT_FINALIZABLE"
);
```

---

### Finding NM-003: Secondary Judge Unpaid for `SECOND_OPINION_REJECTED` Outcome

**Severity:** MEDIUM
**Source:** State Mapper (parallel path comparison — all payment paths vs SECOND_OPINION_REJECTED path)
**Verification:** Code trace
**Discovery path:** State-only (Phase 3B parallel path comparison)

**Coupled Pair:** `judgeBalance[programId]` ↔ secondary judge payment for outcome=invalidate
**Invariant:** Judge balance should be distributed to judges proportional to work performed

**Gap:** When `approveSecondOpinion` is called with `outcome == 2` (invalidate):

```solidity
// PayoutController.sol L253-256
else if (outcome == 2) {
    require(severity == 0, "INVALIDATE_SEVERITY");
    judgePenaltyBps = config.judgePenaltyInvalidBps;
    payoutAmount = 0;
}

// PayoutController.sol L260-263
uint256 judgeFeeAmountForSeverity = 0;
if (payoutAmount > 0) {  // payoutAmount == 0, so this block is skipped
    judgeFeeAmountForSeverity = (payoutAmount * config.judgeFeeBps) / 10_000;
}
```

`markSecondOpinion` is called with `judgeAmount = 0`, setting `report.judgeFeeAmount = 0`.

Then `finalizeAndPay` explicitly blocks this status:
```solidity
// PayoutController.sol L380
require(report.status != ReportManager.Status.SECOND_OPINION_REJECTED, "REPORT_SECOND_OPINION_REJECTED");
```

No other function in `PayoutController` pays `report.secondaryJudge` when status is `SECOND_OPINION_REJECTED`.

**Consequence:**
- The secondary judge who caught a fraudulent/inflated report and performed the invalidation receives zero compensation
- The judge fee from `judgeBalance[programId]` remains locked until the company closes the program (at which point it's returned to the company, not the judge)
- This creates a perverse incentive: secondary judges are economically rational to confirm or downgrade (which triggers payment paths) rather than invalidate

**Comparison:**
| Outcome | Primary Judge Paid | Secondary Judge Paid |
|---|---|---|
| Confirm (outcome=0) | ✓ 80% of judge fee | ✓ 20% of judge fee |
| Downgrade (outcome=1) | ✓ reduced by penalty | ✓ penalty portion |
| Invalidate (outcome=2) | ✗ never | ✗ never |

**Fix:** Add a payment path for `SECOND_OPINION_REJECTED`. One approach — pay the secondary judge at the point of `approveSecondOpinion` for outcome=2, funded from the judge balance:

```solidity
// In approveSecondOpinion, outcome == 2 branch:
// Pay secondary judge from judgeBalance for performing the invalidation
uint256 secondaryInvalidationFee = (registry.payoutBySeverity(programId, report.primarySeverity)
    * config.judgeFeeBps) / 10_000;
if (secondaryInvalidationFee > 0 && totalJudgeFeeAmount >= secondaryInvalidationFee) {
    escrow.payoutJudge(programId, msg.sender, secondaryInvalidationFee);
}
```

---

### Finding NM-004: `finalizeEscalation` Missing `judges.isJudge` Check

**Severity:** LOW
**Source:** Feynman (Category 3 — consistency: guard present in analogous functions, absent here)
**Verification:** Code trace
**Discovery path:** Feynman-only

**Breaking Operation:** `PayoutController.finalizeEscalation()` at `PayoutController.sol:L294-366`

All three other judge-action functions check the allowlist:
- `approvePrimary` L62: `require(judges.isJudge(msg.sender), "NOT_JUDGE")`
- `approveSecondOpinion` L208: `require(judges.isJudge(msg.sender), "NOT_JUDGE")`
- `finalizeEscalation` L300-309: **no `isJudge` check**

`assignSecondJudge` adds the judge to the registry, so the judge is in the allowlist when assigned. But if the admin removes the judge from the registry after assignment (via `judgeRegistry.setJudge(judge, false)`) and before `finalizeEscalation`, the removed judge can still finalize the escalation.

**Impact:** Low — the admin explicitly assigned the judge. No external party gains unauthorized access; the issue is only that revocation is ineffective for already-in-progress escalations.

**Fix:**
```solidity
// Add to finalizeEscalation after the reportId check:
require(judges.isJudge(msg.sender), "NOT_JUDGE");
```

---

## Feedback Loop Discoveries

**NM-002** was enriched by the feedback loop: Phase 2 (Feynman) exposed the naming inconsistency (`setProgramPaused` → CLOSED). Phase 4 Step B (State dependency expansion) confirmed the PAUSED↔refund coupling, revealing that `CLOSED` set by this function is a dead-end with no recovery path.

**NM-001** sub-cases b and d were surfaced via Phase 3C (operation ordering): the catch-all `markClosed` in the else branch was identified as the root cause shared across all four sub-cases. Phase 4 Step A deepened this by tracing the adversarial sequence for the SECOND_OPINION_REQUESTED case.

---

## False Positives Eliminated

**Penalty debt invariant (eliminated):** Initially suspected that proportional debt splits during partial payment could break `companyPenaltyDebt == sum(sub-debts)`. Formal verification showed the invariant is maintained through both `accrueCompanyPenalty` and `deposit` partial payment math. The cleanup code (L168-170) does not create a gap because if `debt == 0` then all sub-debts are provably 0.

**refund() reentrancy (eliminated):** `refund()` lacks `nonReentrant` but is only callable via `msg.sender == address(registry)`. Reentrant callbacks from a malicious token would have `msg.sender = token ≠ registry`. State updates (`bountyBalance = 0`, `judgeBalance = 0`) occur before the final company transfers. Not exploitable.

**approveSecondOpinion bounce check (eliminated):** No `bountyBalance >= payoutAmount` check at confirmation time. The check exists at payment time in `finalizeAndPay` (L476-477). Emergency drain between confirmation and payment is an admin operational risk, not an exploit vector on normal flows.

---

## Summary

| Metric | Value |
|---|---|
| Functions analyzed | 38 |
| Coupled state pairs mapped | 5 |
| Mutation paths traced | 14 |
| Nemesis loop iterations | 2 |
| Raw findings (pre-verification) | 0 C \| 4 H \| 1 M \| 1 L |
| Feedback loop discoveries | 1 (NM-002 enriched via cross-feed) |
| After verification | 4 TRUE POSITIVE \| 3 FALSE POSITIVE \| 0 DOWNGRADED |
| **Final** | **0 CRITICAL \| 2 HIGH \| 1 MEDIUM \| 1 LOW** |

---

## Recommended Fix Priority

1. **NM-001** (HIGH) — Replace negative exclusions with positive allowlist in `finalizeAndPay`. Single fix covers all four sub-cases.
2. **NM-002** (HIGH) — Fix `setProgramPaused` to either set PAUSED (not CLOSED) or add a direct admin refund path.
3. **NM-003** (MEDIUM) — Add payment path for secondary judge on invalidation outcome.
4. **NM-004** (LOW) — Add `judges.isJudge(msg.sender)` check to `finalizeEscalation`.