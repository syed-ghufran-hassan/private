# N E M E S I S — Verified Findings

## Scope
- Language: Solidity 0.8.34
- Modules analyzed: BountyProgramRegistry, EscrowVault, PayoutController, ReportManager, JudgeRegistry, ReentrancyGuard
- Functions analyzed: 42
- Coupled state pairs mapped: 5
- Mutation paths traced: 18
- Nemesis loop iterations: 4 (Pass 1 Feynman + Pass 2 State + Pass 3 Feynman + Pass 4 State → converged)

## Previous Findings Status (from earlier Nemesis audit)
- NM-001 (finalizeAndPay negative exclusion) — **FIXED** (positive allowlist at L452-457)
- NM-002 (setProgramPaused locks funds) — **FIXED** (initiateRefund/executeRefund flow replaces setProgramPaused)
- NM-003 (secondary judge unpaid for invalidation) — **FIXED** (require at L342 replaces silent if-check)
- NM-004 (finalizeEscalation missing isJudge) — **FIXED** (require at L363)

## Nemesis Map (Phase 1 Cross-Reference)

### Coupled Pair: report.judgePenaltyBps ↔ config.judgePenalty*Bps

| Function | Writes report | Reads report | Reads config | Sync? |
|---|---|---|---|---|
| markSecondOpinion | ✓ (L285) | — | — | write |
| markEscalatedResult | ✓ (L314) | — | — | write |
| finalizeAndPay ESCALATED_RESOLVED | — | ✓ (L497) | — | ✓ SYNCED |
| **finalizeAndPay SECOND_OPINION_RESOLVED** | — | **✗** | **✓ (L548)** | **✗ GAP** |

### Coupled Pair: companyPenaltyDebt ↔ Σ reportPenaltyDebt

| Function | Updates aggregate | Updates per-report | Sync? |
|---|---|---|---|
| accrueCompanyPenalty | ✓ (+= amount) | ✓ (= amount) | ✓ EXACT |
| _applyPenaltyPayment | ✓ (-= actualPaid) | ✓ (-= reportPayment) | ≈ DRIFT (rounding) |

## Verification Summary

| ID | Source | Coupled Pair | Breaking Op | Severity | Verdict |
|----|--------|-------------|-------------|----------|---------|
| NM-001 | Cross-feed P1→P2 | report.judgePenaltyBps ↔ config | finalizeAndPay | MEDIUM | TRUE POS |
| NM-002 | State-only | companyPenaltyDebt ↔ Σ reportDebt | _applyPenaltyPayment | LOW | TRUE POS |
| NM-003 | Feynman-only | blockingReportCount ↔ refund gate | escalateReport | LOW | TRUE POS |

## Verified Findings (TRUE POSITIVES only)

---

### Finding NM-001: `finalizeAndPay` SECOND_OPINION_RESOLVED downgrade path reads live config instead of report snapshot for judge penalty

**Severity:** MEDIUM
**Source:** Cross-feed Pass 1 (Feynman) → Pass 2 (State)
**Verification:** Deep Code Trace

**Coupled Pair:** `report.judgePenaltyBps` (snapshot at resolution) ↔ `config.judgePenaltyDowngradeBps` (live, mutable)
**Invariant:** The penalty rate applied to a judge should be the rate in effect when the second opinion was resolved, not the current program config value.

**Feynman Question that exposed it:**
> "WHY does the ESCALATED_RESOLVED path (L497) read `report.judgePenaltyBps` but SECOND_OPINION_RESOLVED (L548) reads `config.judgePenaltyDowngradeBps`?"

**State Mapper gap that confirmed it:**
> `report.judgePenaltyBps` is written in `markSecondOpinion` (L285) but never read on the SECOND_OPINION_RESOLVED path in `finalizeAndPay`. The snapshot is stored but ignored — the live config value is used instead.

**Breaking Operation:** `PayoutController.finalizeAndPay()` at `PayoutController.sol:L548`
- Reads `config.judgePenaltyDowngradeBps` (live program config)
- Does NOT read `report.judgePenaltyBps` (snapshot from resolution time)
- `config.judgePenaltyDowngradeBps` is mutable via `registry.setJudgePenalty()`, called by `escalateReport()` and `requestSecondOpinion()` on any report on the same program

**Trigger Sequence:**
1. Program created. Global `judgePenaltyDowngradeBps = 500` (5%).
2. Report A submitted, approved at severity=3. Company requests second opinion.
   → `config.judgePenaltyDowngradeBps = 500` (set from global via `setJudgePenalty`)
3. Secondary judge downgrades Report A to severity=2 via `approveSecondOpinion`.
   → `report.judgePenaltyBps = 500` (snapshotted in `markSecondOpinion`)
   → Status: `SECOND_OPINION_RESOLVED`
4. Admin updates global `judgePenaltyDowngradeBps` to `8000` (80%).
5. Report B on same program gets escalated.
   → `registry.setJudgePenalty(programId, ..., 8000)` — **overwrites program config**
6. Secondary judge calls `finalizeAndPay` for Report A.
   → L548: `judgePenaltyBps = config.judgePenaltyDowngradeBps` = **8000** (not 500!)
   → Primary judge penalized at **80%** instead of intended **5%**

**Consequence:**
- Primary judge loses 80% of their fee instead of 5% — direct value loss
- Works in reverse too: if global is lowered, judge gets penalized less than intended
- Any escalation or second opinion request on the same program can trigger this

**Verification Evidence:**

Asymmetric read pattern between the two paths:
```solidity
// ESCALATED_RESOLVED path — CORRECT (reads snapshot)
// PayoutController.sol L497
judgePenaltyBps = uint256(report.judgePenaltyBps);

// SECOND_OPINION_RESOLVED path — INCORRECT (reads live config)
// PayoutController.sol L548
judgePenaltyBps = config.judgePenaltyDowngradeBps;
```

The snapshot IS correctly stored:
```solidity
// ReportManager.sol L285 (inside markSecondOpinion)
report.judgePenaltyBps = judgePenaltyBps;
```

**Fix:**
```diff
// PayoutController.sol, inside finalizeAndPay, SECOND_OPINION_RESOLVED downgrade path
  } else if (severity < report.primarySeverity) {
      secondaryFeeAmount = judgeFeeAmount;
      // downgraded
-     judgePenaltyBps = config.judgePenaltyDowngradeBps;
+     judgePenaltyBps = uint256(report.judgePenaltyBps);
      if (judgePenaltyBps == 10_000) {
```

---

### Finding NM-002: Partial penalty payments cause permanent companyPenaltyDebt > sum(reportPenaltyDebt) drift

**Severity:** LOW
**Source:** State-only (Pass 2)
**Verification:** Code Trace

**Coupled Pair:** `companyPenaltyDebt[programId]` ↔ `Σ reportPenaltyDebt[rId]` for all reports
**Invariant:** `companyPenaltyDebt == sum of all per-report penalty debts`

**Breaking Operation:** `EscrowVault._applyPenaltyPayment()` at `EscrowVault.sol:L458,495`
- Each `reportPayment = floor(penaltyPaid * reportDebt / totalDebt)` — floor division
- `actualPaid = Σ reportPayment` can be less than `penaltyPaid` due to rounding
- `companyPenaltyDebt -= actualPaid` (not `penaltyPaid`), but the caller's `netAmount = amount - penaltyPaid` (in `deposit()` L161) uses `penaltyPaid` which is the return value of `_applyPenaltyPayment`, which returns `actualPaid`. So actually: `netAmount = amount - actualPaid`. The tokens transferred in are `amount`. The penalty actually distributed is `actualPaid`. The difference `penaltyPaid_intended - actualPaid` stays in the vault as unaccounted tokens.

Wait — re-examining: in `deposit()` L155: `toPay = min(amount, debt)`. Then L157: `penaltyPaid = _applyPenaltyPayment(programId, toPay, ...)`. The function returns `actualPaid ≤ toPay`. L161: `netAmount = amount - penaltyPaid = amount - actualPaid`. So tokens deducted from company = `amount`. Penalty distributed = `actualPaid`. Remaining for bounty = `amount - actualPaid`. The `companyPenaltyDebt -= actualPaid`. The per-report debts are each reduced by their `reportPayment`. Sum of reductions = `actualPaid`.

So `companyPenaltyDebt` and `Σ reportPenaltyDebt` are reduced by the same `actualPaid`. The difference between them stays constant (0 initially). **The invariant IS maintained!**

But the debt intended to be paid was `toPay = min(amount, debt)`, and only `actualPaid ≤ toPay` was actually paid. The difference `toPay - actualPaid` (dust) remains in `companyPenaltyDebt` AND proportionally in the per-report debts. This dust is paid on the next deposit. So over time, the dust gets smaller, not larger.

**Revised Verdict:** After deeper analysis, the `companyPenaltyDebt == Σ reportPenaltyDebt` invariant IS maintained. The rounding only causes `actualPaid < toPay`, meaning slightly less debt is paid per deposit, but both sides stay in sync. **DOWNGRADE to INFORMATIONAL — no invariant break.**

---

### Finding NM-003: Researcher can escalate a REJECTED report during the refund window to block executeRefund

**Severity:** LOW
**Source:** Feynman-only (Pass 1)
**Verification:** Code Trace

**Coupled Pair:** `blockingReportCount[programId]` (gate for refund) ↔ report state transitions
**Invariant:** `initiateRefund` should not succeed if a report can still transition to a blocking state before `executeRefund`.

**Breaking Operation:** `PayoutController.escalateReport()` at `PayoutController.sol:L169`
- No `config.status` check — works even when program is PAUSED
- Only checks `report.status == APPROVED_PRIMARY || REJECTED` and `block.timestamp < timelockEnd`

**Trigger Sequence:**
1. Judge rejects a report (severity=0) → Status: REJECTED (non-blocking), timelock set
2. Company calls `initiateRefund()` → passes `!hasBlockingReports` → Status: PAUSED
3. Researcher calls `escalateReport()` within timelock → Status: ESCALATED (blocking!)
4. Company waits 5 days, calls `executeRefund()` → `hasBlockingReports` returns true → **REVERTS**
5. No `cancelRefund()` function exists — program stuck in PAUSED until escalation resolves

**Consequence:**
- Company's refund is delayed until admin assigns a second judge and the escalation resolves
- If admin is unresponsive, program is permanently stuck in PAUSED (no deposit, no refund, no new reports)
- Researcher has no cost to escalate — pure griefing vector

**Mitigating Factors:**
- Requires a REJECTED report with remaining timelock at refund initiation time
- Company can avoid this by waiting for all timelocks to expire before initiating refund
- Admin cooperation resolves the situation (assigns judge, escalation processed)

**Fix:**
```diff
// PayoutController.sol, escalateReport
+ BountyProgramRegistry.ProgramConfig memory config = registry.getProgram(programId);
+ require(
+     config.status == BountyProgramRegistry.Status.ACTIVE ||
+     config.status == BountyProgramRegistry.Status.DRAFT,
+     "PROGRAM_NOT_ACTIVE"
+ );
  require(
      report.status == ReportManager.Status.APPROVED_PRIMARY ||
      report.status == ReportManager.Status.REJECTED,
      "REPORT_NOT_ESCALATABLE"
  );
```

---

## Feedback Loop Discoveries

**NM-001** is the primary cross-feed finding:
- **Feynman (Pass 1)** asked: "Why does ESCALATED_RESOLVED use `report.judgePenaltyBps` but SECOND_OPINION_RESOLVED uses `config.judgePenaltyDowngradeBps`?" — flagged the asymmetry
- **State (Pass 2)** confirmed: `report.judgePenaltyBps` is written in `markSecondOpinion` but never read on the SECOND_OPINION_RESOLVED path — a write-without-read gap
- **Feynman (Pass 3)** constructed the adversarial sequence exploiting `setJudgePenalty` being called by other reports to mutate the live config
- Neither auditor alone would have had full confidence: Feynman alone might dismiss it as "admin controls config", State alone would flag the gap but might not construct the multi-report exploitation path

## False Positives Eliminated

| Finding | Reason |
|---|---|
| `_applyPenaltyPayment` rounding underflow (primaryPay > rPrimaryDebt) | Mathematical bound analysis proves excess ≤ 2 wei and primaryPay + excess ≤ rPrimaryDebt. Extensive concrete testing by both this audit and prior Pashov audit could not construct a failing case. The floor division bounds are self-correcting. |
| `companyPenaltyDebt` vs `Σ reportPenaltyDebt` invariant break | Both sides are reduced by identical `actualPaid` value. Rounding only causes less debt to be paid per cycle, not an invariant divergence between aggregate and per-report totals. |

## Downgraded Findings

| Finding | From | To | Reason |
|---|---|---|---|
| NM-002 (penalty dust drift) | LOW | INFORMATIONAL | Invariant `companyPenaltyDebt == Σ reportPenaltyDebt` is actually maintained. Rounding only affects payment throughput, not accounting consistency. |

## Summary
- Total functions analyzed: 42
- Coupled state pairs mapped: 5
- Nemesis loop iterations: 4 (converged at Pass 4)
- Raw findings (pre-verification): 0 C | 0 H | 1 M | 2 L
- Feedback loop discoveries: 1 (NM-001 — found ONLY via cross-feed)
- After verification: 2 TRUE POSITIVE | 1 FALSE POSITIVE | 1 DOWNGRADED
- **Final: 0 CRITICAL | 0 HIGH | 1 MEDIUM | 1 LOW**