# N E M E S I S — Verified Findings

## Scope
- Language: Solidity ^0.8.20
- Modules analyzed: BountyProgramRegistry, EscrowVault, PayoutController, ReportManager, JudgeRegistry, ReentrancyGuard
- Functions analyzed: 38
- Coupled state pairs mapped: 8
- Mutation paths traced: 42
- Nemesis loop iterations: 4 (Pass 1 Feynman + Pass 2 State + Pass 3 Feynman targeted + Pass 4 State targeted)

## Nemesis Map (Phase 1 Cross-Reference)

| Function | Writes bountyBalance | Writes judgeBalance | Writes report.status | Writes blockingCount | Writes penaltyDebt | Triggers deactivation |
|---|---|---|---|---|---|---|
| deposit | +bountyAmount | +judgeFee | — | — | -penaltyPaid | activateFromDeposit |
| payoutBounty | -amount | — | — | — | — | YES |
| payoutJudge | — | -amount | — | — | — | — |
| allocateEscalationJudgeBalance | -amount | +amount | — | — | — | **NO** |
| payoutTreasuryFee | -amount | — | — | — | — | **NO** |
| refund | =0 | =0 | — | — | -debt | N/A (CLOSED) |
| emergencyBountyPayout | -amount | — | — | — | — | YES |
| accrueCompanyPenalty | — | — | — | — | +amount | — |
| _applyPenaltyPayment | — | — | — | — | -actualPaid | — |
| markApprovedPrimary | — | — | YES | via _transitionStatus | — | — |
| markEscalated | — | — | YES | via _transitionStatus | — | — |
| markSecondOpinion | — | — | YES | via _transitionStatus | — | — |
| markEscalatedResult | — | — | YES | via _transitionStatus | — | — |
| markReadyToPay | — | — | YES | via _transitionStatus | — | — |
| markPaid | — | — | YES | via _transitionStatus | — | — |
| markClosed | — | — | YES | via _transitionStatus | — | — |

## Verification Summary

| ID | Source | Coupled Pair / Root Cause | Breaking Op | Severity | Verdict |
|----|--------|--------------------------|-------------|----------|---------|
| NM-001 | Cross-feed P1→P3 | payoutAmount=0 ↔ payoutBounty(amount>0) | approveSecondOpinion | HIGH | TRUE POS |
| NM-002 | Both passes (F-001 + SI-001) | reportPenaltyDebt ↔ sub-debt sum | _applyPenaltyPayment | HIGH | TRUE POS |
| NM-003 | Feynman + State cross-feed | report.payoutAmount ↔ ESCALATED_REJECTED terminal | finalizeEscalation | MEDIUM | TRUE POS |
| NM-004 | Cross-feed S-005→P2→P3 | program.status(DRAFT) ↔ in-flight reports | payoutBounty→deactivate | MEDIUM | TRUE POS |
| NM-005 | Feynman-only | defense-in-depth | refund() | LOW | TRUE POS |
| NM-006 | Feynman-only | dead code | finalizeAndPay | LOW | TRUE POS |

## Verified Findings (TRUE POSITIVES only)

### Finding NM-001: Second-opinion downgrade to unconfigured severity permanently bricks report
**Severity:** HIGH
**Source:** Cross-feed P1→P3 (Feynman agent declared SOUND; State gap analysis + Feynman re-interrogation exposed the payoutAmount=0 downstream impact)
**Verification:** Code trace (full call chain: approveSecondOpinion → markSecondOpinion → finalizeAndPay → payoutBounty)

**Feynman Question that exposed it:**
> "What happens when severity < lowest configured tier in the downgrade fallback? The `if (severity > lowest)` guard doesn't fire. payoutAmount stays 0. Does any downstream check catch this?"

**State Mapper gap that confirmed it:**
> report.payoutAmount = 0 stored in SECOND_OPINION_RESOLVED state. payoutBounty requires amount > 0. No code path bridges this gap.

**Breaking Operation:** `PayoutController.approveSecondOpinion` at `src/PayoutController.sol:297`
- Sets payoutAmount = 0 when severity < lowest configured tier
- Does NOT revert — the `require(severity < report.primarySeverity)` check passes

**Trigger Sequence:**
1. Program configured with severity 2 (Medium, $5000) and severity 4 (Critical, $50000). Severity 1 (Low) NOT configured.
2. Primary judge approves at severity 4 (payoutAmount = $50000).
3. Company requests second opinion (too expensive).
4. Secondary judge calls approveSecondOpinion with outcome=1 (downgrade), severity=1 (Low).
5. `payoutBySeverity(programId, 1)` returns 0. Fallback finds lowest=2. `1 > 2` is false — no correction. payoutAmount = 0.
6. `require(1 < 4, "SEVERITY_NOT_DOWNGRADE")` passes. Report stored as SECOND_OPINION_RESOLVED with payoutAmount=0.
7. Judge calls finalizeAndPay → markReadyToPay succeeds → payoutBounty(programId, researcher, 0) → **REVERT "AMOUNT_ZERO"**.
8. Entire tx reverts. Report stuck in SECOND_OPINION_RESOLVED forever. Every retry hits the same wall.
9. blockingReportCount stays at 1 → program can never be refunded.

**Consequence:**
- Report permanently bricked — researcher gets $0 despite having a valid finding
- blockingReportCount never decrements — program permanently blocked from refund
- Company funds permanently locked in escrow

**Fix:**
```solidity
// In approveSecondOpinion, after the fallback loop:
- if (severity > lowest) {
-     severity = lowest;
- }
+ severity = lowest;
```

---

### Finding NM-002: Rounding in _applyPenaltyPayment breaks sub-debt invariant, permanently locking refund
**Severity:** HIGH
**Source:** Both passes (Feynman F-001 + State SI-001) — independent discovery from both dimensions
**Verification:** Code trace + concrete numerical proof

**Coupled Pair:** `reportPenaltyDebt[reportId]` ↔ `(reportPenaltyTreasuryDebt + reportPenaltyPrimaryDebt + reportPenaltySecondaryDebt)`
**Invariant:** reportPenaltyDebt == treasuryDebt + primaryDebt + secondaryDebt

**Feynman Question that exposed it:**
> "Both treasuryPay and primaryPay are rounded DOWN by integer division. secondaryPay gets the accumulated remainder. Can secondaryPay exceed reportPenaltySecondaryDebt?"

**State Mapper gap that confirmed it:**
> The defensive clamp at L465 `min(secondaryPay, rSecondaryDebt)` prevents immediate underflow but creates invariant violation: sub-debts sum to MORE than reportPenaltyDebt. Next payment attempt underflows at L459.

**Breaking Operation:** `EscrowVault._applyPenaltyPayment` at `src/EscrowVault.sol:459-465`

**Trigger Sequence:**
1. `accrueCompanyPenalty` creates penalty: debt=100 (treasury=20, primary=40, secondary=40).
2. Company `deposit()` with amount such that partial penalty payment of 99 occurs.
3. `_applyPenaltyPayment`: treasuryPay=floor(99×20/100)=19, primaryPay=floor(99×40/100)=39, secondaryPay=99-19-39=**41**.
4. secondaryPay(41) > secondaryDebt(40) → clamp fires → secondaryDebt set to 0.
5. After: reportDebt=1, treasuryDebt=1, primaryDebt=1, secondaryDebt=0. **Sum=2 ≠ 1**.
6. Any subsequent payment of remaining debt=1: treasuryPay=(1×1)/1=1, primaryPay=(1×1)/1=1, secondaryPay=1-1-1 → **UNDERFLOW REVERT**.
7. `refund()`, `deposit()`, `payPenaltyDebt()` all permanently revert for this program.

**Consequence:**
- Company funds permanently locked in escrow vault
- No path to clear the corrupted penalty debt
- All three penalty-paying code paths (`deposit`, `payPenaltyDebt`, `refund`) are bricked

**Masking Code:**
```solidity
// Line 465 — this clamp prevents the FIRST underflow but creates a worse problem:
reportPenaltySecondaryDebt[rId] -= (secondaryPay > rSecondaryDebt ? rSecondaryDebt : secondaryPay);
// The invariant is now broken: sub-debts sum > reportPenaltyDebt
// The NEXT payment will underflow at line 459
```

**Fix:**
```solidity
  uint256 treasuryPay = (reportPayment * rTreasuryDebt) / reportDebt;
  uint256 primaryPay = (reportPayment * rPrimaryDebt) / reportDebt;
- uint256 secondaryPay = reportPayment - treasuryPay - primaryPay;
+ uint256 rSecondaryDebt = reportPenaltySecondaryDebt[rId];
+ uint256 secondaryPay = reportPayment - treasuryPay - primaryPay;
+ if (secondaryPay > rSecondaryDebt) {
+     // Redistribute excess back to primary (or treasury)
+     primaryPay += (secondaryPay - rSecondaryDebt);
+     secondaryPay = rSecondaryDebt;
+ }
```

---

### Finding NM-003: Rejected escalation permanently destroys approved researcher payout
**Severity:** MEDIUM
**Source:** Feynman Pass 1 (F-004), elevated by State Pass 2 cross-feed showing ESCALATED_REJECTED is non-blocking → company can immediately refund
**Verification:** Code trace (finalizeEscalation outcome=1 → markEscalatedResult → ESCALATED_REJECTED terminal state)

**Feynman Question that exposed it:**
> "WHY is payoutAmount unconditionally zeroed on outcome=1? What if the report was APPROVED_PRIMARY before escalation — the researcher had a valid finding with an approved payout."

**State Mapper gap that confirmed it:**
> ESCALATED_REJECTED is non-blocking status (not in `_isBlockingStatus`). blockingReportCount decrements. Company can immediately initiate refund and recover the full bountyBalance — including the amount that should have been paid to the researcher.

**Breaking Operation:** `PayoutController.finalizeEscalation` at `src/PayoutController.sol:414-418`
- Lines 415-417: unconditionally zero payoutAmount, judgeFeeAmount, escalationAmount
- Line 420: remaps outcome 1→2, triggering ESCALATED_REJECTED

**Trigger Sequence:**
1. Primary judge approves report at severity 3 (High), payoutAmount = $50,000.
2. Researcher believes finding is Critical, escalates for higher payout.
3. Second judge calls `finalizeEscalation(outcome=1)` — rejects the escalation.
4. payoutAmount = 0, report transitions to ESCALATED_REJECTED (terminal, non-blocking).
5. blockingReportCount decrements — no blocking reports remain.
6. Company calls `initiateRefund` → waits 5 days → `executeRefund` → recovers full bountyBalance.
7. Researcher with a valid, previously-approved High-severity finding receives $0.

**Consequence:**
- Researcher loses approved payout ($50,000 in example) — not just the escalation premium
- Company recovers funds that should have been paid out
- Creates chilling effect on legitimate escalations (researchers risk losing everything)

**Fix:**
```solidity
  } else if (outcome == 1) {
      require(severity == 0, "INVALID_SEVERITY_FOR_OUTCOME");
      escalationAmount = 0;
-     payoutAmount = 0;
-     judgeFeeAmount = 0;
+     // Preserve original payout if report was previously approved (payoutAmount > 0).
+     // Only zero if report was originally REJECTED (payoutAmount was already 0).
      judgePenaltyBps = 0;
      outcome = 2;
  }
```

---

### Finding NM-004: Program deactivation to DRAFT blocks finalization of in-flight reports
**Severity:** MEDIUM
**Source:** Cross-feed P1(S-005)→P2→P3 (Feynman suspect → State parallel path analysis → Feynman re-interrogation)
**Verification:** Code trace (payoutBounty → deactivateFromPaidBounty → ACTIVE→DRAFT; finalizeAndPay requires ACTIVE||PAUSED)

**Coupled Pair:** `program.status` ↔ in-flight `report.status` (blocking reports)
**Invariant:** Programs with blocking reports should remain in a state that allows report finalization

**Feynman Question that exposed it:**
> "deactivateFromPaidBounty moves ACTIVE→DRAFT. finalizeAndPay requires ACTIVE||PAUSED. What happens to OTHER in-flight reports when one report's payout triggers deactivation?"

**State Mapper gap that confirmed it:**
> bountyBalance decremented by payoutBounty → program deactivated to DRAFT. Other reports in APPROVED_PRIMARY/ESCALATED_RESOLVED/SECOND_OPINION_RESOLVED cannot reach finalizeAndPay (requires ACTIVE||PAUSED). No admin path to close reports on DRAFT programs.

**Breaking Operation:** `EscrowVault.payoutBounty` at `src/EscrowVault.sol:234-236` → `BountyProgramRegistry.deactivateFromPaidBounty`

**Trigger Sequence:**
1. Program has bountyBalance covering two reports. Report A (Critical, $50K) and Report B (High, $10K).
2. Report A finalized — payoutBounty pays $50K. bountyBalance drops below totalPayoutByProgram.
3. `deactivateFromPaidBounty` transitions program from ACTIVE → DRAFT.
4. Report B is in APPROVED_PRIMARY. Judge calls `finalizeAndPay` → `require(ACTIVE || PAUSED)` → **REVERT** (program is DRAFT).
5. Company can't refund (Report B is blocking). Report B can't be finalized (program is DRAFT).
6. **Soft deadlock** — only resolved if company deposits again to reactivate.

**Consequence:**
- In-flight reports become unfinalizable until company re-deposits
- Company and researcher in deadlock: company can't refund, researcher can't get paid
- No admin emergency path for reports stuck in non-READY_TO_PAY states on DRAFT programs

**Fix:**
```solidity
  // In finalizeAndPay, also allow DRAFT status (to process remaining reports):
  require(
      config.status == BountyProgramRegistry.Status.ACTIVE ||
      config.status == BountyProgramRegistry.Status.PAUSED ||
+     config.status == BountyProgramRegistry.Status.DRAFT,
      "PROGRAM_NOT_ACTIVE"
  );
```

---

### Finding NM-005: refund() missing nonReentrant modifier
**Severity:** LOW
**Source:** Feynman-only (F-005)
**Verification:** Code trace — access controls (msg.sender == registry) and status machine (CLOSED) prevent exploitation with current architecture

`EscrowVault.refund` at `src/EscrowVault.sol:298` performs multiple token transfers (via `_applyPenaltyPayment` and direct transfers to companyOwner) without `nonReentrant`. Currently safe because: (a) only the registry can call it, (b) the program is already CLOSED, blocking re-entry into any meaningful state-changing path. However, this violates defense-in-depth principles. If the payout token is changed to one with transfer callbacks (ERC-777), or if access controls are modified, this becomes exploitable.

---

### Finding NM-006: finalizeAndPay severity and outcome parameters are dead code
**Severity:** LOW
**Source:** Feynman-only (F-003)
**Verification:** Code search — neither `severity` nor `outcome` is referenced anywhere in the `finalizeAndPay` function body

`PayoutController.finalizeAndPay` at `src/PayoutController.sol:443` declares `uint8 severity` and `uint8 outcome` in its signature but never reads them. Callers pass arbitrary values with no effect. This creates confusion about the function's API contract and could mask integration bugs.

---

## Feedback Loop Discoveries

Findings that ONLY emerged from the cross-feed between auditors:

1. **NM-001** — The Feynman agent analyzed `approveSecondOpinion` and declared it SOUND, focusing on the `require(severity < primarySeverity)` safety net. The State Inconsistency analysis identified the `payoutAmount=0 ↔ payoutBounty(amount>0)` coupling gap. When fed back to Feynman in Pass 3, the downstream code trace (finalizeAndPay → payoutBounty(0) → revert) proved the report permanently bricks. **Neither auditor alone would have caught this** — Feynman saw the fallback as "clunky but safe" and State saw payoutBounty's require but didn't trace the specific input path.

2. **NM-004** — Feynman flagged `deactivateFromPaidBounty` as SUSPECT (S-005) noting the ACTIVE→DRAFT transition. State analysis confirmed the `bountyBalance ↔ program.status` coupling gap in the parallel path comparison. Feynman re-interrogation in Pass 3 traced the full deadlock: in-flight blocking reports can't finalize, company can't refund. **The deadlock only appears when both the state machine (report lifecycle) and the status coupling (program lifecycle) are analyzed together.**

## False Positives Eliminated

1. **cancelRefund DRAFT→ACTIVE skip** — The Feynman agent analyzed this thoroughly. While the status transition (DRAFT→PAUSED→ACTIVE via cancelRefund) is theoretically inconsistent, it's **unreachable** in practice because DRAFT programs can't have reports (submitReport requires ACTIVE), and cancelRefund requires a non-terminal report. FALSE POSITIVE.

2. **Reentrancy in refund()** — Despite missing `nonReentrant`, the function is protected by: (a) `msg.sender == registry` access control, (b) program status already CLOSED preventing re-entry into any state-changing path, (c) USDC has no transfer callbacks. Downgraded from MEDIUM to LOW (defense-in-depth only).

3. **allocateEscalationJudgeBalance / payoutTreasuryFee missing deactivation** — These functions decrease bountyBalance without calling deactivateFromPaidBounty. However, they are only called within `finalizeAndPay` (atomic transaction) immediately before `payoutBounty` which DOES trigger deactivation. No externally observable inconsistency. FALSE POSITIVE for deactivation, though NM-004 reveals the deactivation itself causes problems.

4. **finalizeAndPay double judge payment on READY_TO_PAY** — The Feynman agent initially flagged this as MEDIUM (F-002). On deeper analysis, READY_TO_PAY can only be reached through `finalizeAndPay` itself (atomic transaction). If the tx reverts after markReadyToPay, the state rolls back. No path to partial execution. Revised to FALSE POSITIVE.

## Summary
- Total functions analyzed: 38
- Coupled state pairs mapped: 8
- Nemesis loop iterations: 4 (converged at Pass 4)
- Raw findings (pre-verification): 2 C | 3 H | 3 M | 4 L
- Feedback loop discoveries: 2 (NM-001, NM-004 — found ONLY via cross-feed)
- After verification: 6 TRUE POSITIVE | 4 FALSE POSITIVE | 1 DOWNGRADED
- **Final: 0 CRITICAL | 2 HIGH | 2 MEDIUM | 2 LOW**
