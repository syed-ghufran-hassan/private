──Deduplication by root cause:───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────── ▪▪▪ ─
- payoutTreasuryFee accounting bug: Agents 1 [82], 4 [75], 5 [100] → keep Agent 5 [100]
- Dupl─cate severity─in─createProgram:─Agents─3─[100],─5─[85]─→─keep─Agent─3─[100]─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
- Micro-deposit penalty griefing: Agent 5 [85] — unique
- uint16 overflow in updateFeesEscalations: Agent 1 [78] — unique
- Primary judge closes escalated reports: Agent 5 [75] — unique
- Unvalidated severity in finalizeAndPay: Agent 5 [75] — unique
- Blacklisted-researcher bounty lockout: Agent 1 [75] — unique
- Judge fee locked on rejection: Agent 2 [75] — unique
- Single-step admin transfer: Agent 3 [75] — unique

  ---
🔐 Security Review — audit-contracts

  ---
Scope

┌──────────────────────────────┬─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                              │                                                                                                                                     │
├──────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ Mode                         │ deep ./src                                                                                                                          │
├──────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ Files reviewed               │ BountyProgramRegistry.sol · EscrowVault.sol · JudgeRegistry.solPayoutController.sol · ReportManager.sol · utils/ReentrancyGuard.sol │
├──────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ Confidence threshold (1-100) │ 80                                                                                                                                  │
└──────────────────────────────┴─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

  ---
Findings

[100] 1. Escalation Treasury Share Transferred Without Decrementing Internal Balance Accounting

EscrowVault.payoutTreasuryFee · Confidence: 100

Description
payoutTreasuryFee transfers the escalation treasury share directly from the vault's token holdings without decrementing bountyBalance or judgeBalance, so after every escalation resolution bountyBalance permanently over-reports
actual holdings by that amount — subsequent payoutBounty calls will pass the balance check against phantom accounting and eventually cause judge fee transfers to revert (or silently consume another program's tokens from the shared
vault).

Fix

function payoutTreasuryFee(uint256 programId, address to, uint256 amount) external onlyPayoutController returns (bool) {
require(to != address(0), "TO_ZERO");
require(amount > 0, "AMOUNT_ZERO");
+    uint256 bBal = bountyBalance[programId];
+    require(bBal >= amount, "INSUFFICIENT_BOUNTY");
+    bountyBalance[programId] = bBal - amount;
     BountyProgramRegistry.ProgramConfig memory config = registry.getProgram(programId);
     IERC20 token = IERC20(config.payoutToken);
     require(token.transfer(to, amount), "TRANSFER_FAILED");
     emit TreasuryFeePaid(programId, to, amount);
     return true;
     }

  ---
[100] 2. Duplicate Severity Entries in createProgram Inflate Required Deposit, Trapping Excess Funds

BountyProgramRegistry.createProgram · Confidence: 100

Description
The createProgram severity loop accumulates totalPayoutByProgram[programId] += payoutAmount for every entry without checking for duplicates while payoutBySeverity silently overwrites — passing severities = [2, 2] with amounts
[1000, 2000] sets totalPayoutByProgram = 3000 and payoutBySeverity[id][2] = 2000, forcing the company to deposit 1000 excess tokens that can never be paid as a bounty (only recoverable via a full 5-day refund sequence).

Fix

+    uint256 seenMask;
     for (uint256 i = 0; i < severityCount; i++) {
     uint8 severity = input.severities[i];
     require(severity != 0, "SEVERITY_ZERO");
     require(severity < 5, "INVALID_SEVERITY");
+        uint256 bit = 1 << severity;
+        require(seenMask & bit == 0, "DUPLICATE_SEVERITY");
+        seenMask |= bit;
         uint256 payoutAmount = input.payoutAmounts[i];
         payoutBySeverity[programId][severity] = payoutAmount;
         totalPayoutByProgram[programId] += payoutAmount;
         emit ProgramPayoutUpdated(programId, severity, payoutAmount);
  }

  ---
[85] 3. Micro-Deposit Griefing Routes Entire Penalty to Secondary Judge via Integer Rounding

EscrowVault.deposit · Confidence: 85

Description
Penalty distribution uses secondaryPay = penaltyPaid - treasuryPay - primaryPay with integer floor division, so when penaltyPaid is very small (e.g. 1 wei), treasuryPay and primaryPay both round to zero and secondary absorbs the
full payment; a company owner with outstanding penalty debt can spam 1-wei deposits to systematically funnel the entire penalty to the secondary judge while the treasury and primary judge receive zero from those payments.

Fix

function deposit(uint256 programId, uint256 amount) external nonReentrant {
require(amount > 0, "AMOUNT_ZERO");
+    require(amount >= MIN_DEPOSIT, "AMOUNT_TOO_SMALL"); // e.g. 1e6 for USDC
     Additionally enforce a minimum per-payment penalty repayment proportional to total outstanding debt so no component rounds to zero.

  ---

┌─────┬────────────┬───────────────────────────────────────────────────────────────────────────────────────────────┐
│  #  │ Confidence │                                             Title                                             │
├─────┼────────────┼───────────────────────────────────────────────────────────────────────────────────────────────┤
│ 1   │ [100]      │ Escalation Treasury Share Transferred Without Decrementing Internal Balance Accounting        │
├─────┼────────────┼───────────────────────────────────────────────────────────────────────────────────────────────┤
│ 2   │ [100]      │ Duplicate Severity Entries in createProgram Inflate Required Deposit, Trapping Excess Funds   │
├─────┼────────────┼───────────────────────────────────────────────────────────────────────────────────────────────┤
│ 3   │ [85]       │ Micro-Deposit Griefing Routes Entire Penalty to Secondary Judge via Integer Rounding          │
├─────┼────────────┼───────────────────────────────────────────────────────────────────────────────────────────────┤
│     │            │ Below Confidence Threshold                                                                    │
├─────┼────────────┼───────────────────────────────────────────────────────────────────────────────────────────────┤
│ 4   │ [78]       │ uint16 Addition Overflow Bypasses Fee Cap in updateFeesEscalations                            │
├─────┼────────────┼───────────────────────────────────────────────────────────────────────────────────────────────┤
│ 5   │ [75]       │ Primary Judge Can Close Escalated Reports Before Second-Judge Resolution                      │
├─────┼────────────┼───────────────────────────────────────────────────────────────────────────────────────────────┤
│ 6   │ [75]       │ Unvalidated severity Parameter Enables Judge Fee Manipulation in SECOND_OPINION_RESOLVED Path │
├─────┼────────────┼───────────────────────────────────────────────────────────────────────────────────────────────┤
│ 7   │ [75]       │ Push-Model Transfer to Blacklisted Researcher Permanently Locks Bounty Funds                  │
├─────┼────────────┼───────────────────────────────────────────────────────────────────────────────────────────────┤
│ 8   │ [75]       │ Judge Fee Permanently Locked When Second Opinion Invalidates or Escalation Is Rejected        │
├─────┼────────────┼───────────────────────────────────────────────────────────────────────────────────────────────┤
│ 9   │ [75]       │ Single-Step Admin Transfer Risks Permanent Lockout Across All Contracts                       │
└─────┴────────────┴───────────────────────────────────────────────────────────────────────────────────────────────┘

  ---
[78] 5. uint16 Addition Overflow Bypasses Fee Cap in updateFeesEscalations

BountyProgramRegistry.updateFeesEscalations · Confidence: 78

Description
uint16 totalBps = treasuryFeeBps_ + judgeFeeBps_ is evaluated in uint16 arithmetic before the require(totalBps <= 1_000) guard, so passing treasuryFeeBps_ = 60_000 and judgeFeeBps_ = 6_000 wraps modulo 65536 to 464 — silently
bypassing the cap and setting global fee rates to values that would extract more than 100% of a program's deposit.

  ---
[75] 6. Primary Judge Can Close Escalated Reports Before Second-Judge Resolution

PayoutController.finalizeAndPay · Confidence: 75

Description
finalizeAndPay routes control to the primary judge for any status not in {ESCALATED_RESOLVED, SECOND_OPINION_RESOLVED}, including ESCALATED; the primary judge can call this on an actively escalated report, reach
reports.markClosed(reportId), and permanently close it before any secondary judge resolution — voiding the researcher's escalation rights and payout.

  ---
[75] 7. Unvalidated severity Parameter Enables Judge Fee Manipulation in SECOND_OPINION_RESOLVED Path

PayoutController.finalizeAndPay · Confidence: 75

Description
In the SECOND_OPINION_RESOLVED branch the caller-supplied severity parameter drives primary-vs-secondary fee splits without being validated against report.secondarySeverity; passing severity > report.primarySeverity hits no branch
and routes the full judge fee to the primary judge, while passing severity == primarySeverity when the actual outcome was a downgrade lets the primary judge evade the downgrade penalty.

  ---
[75] 8. Push-Model Transfer to Blacklisted Researcher Permanently Locks Bounty Funds

EscrowVault.payoutBounty · Confidence: 75

Description
finalizeAndPay pays judge fees first then calls escrow.payoutBounty(researcher, amount) which does token.transfer(researcher, amount); if the researcher's address is USDC-blacklisted the transfer reverts, leaving the report stuck
in READY_TO_PAY with no recovery path and the bounty permanently locked while the judge has already been compensated.

  ---
[75] 9. Judge Fee Permanently Locked When Second Opinion Invalidates or Escalation Is Rejected

PayoutController.finalizeAndPay · Confidence: 75

Description
When approveSecondOpinion(outcome=2) sets status to SECOND_OPINION_REJECTED or finalizeEscalation(outcome=1) sets ESCALATED_REJECTED, finalizeAndPay reverts immediately on those statuses — but the judgeBalance[programId]
accumulated from deposits is never paid out or returned, leaving judge fees permanently stranded in the vault with no rescue path.

  ---
[75] 10. Single-Step Admin Transfer Risks Permanent Lockout Across All Contracts

BountyProgramRegistry.setAdmin · EscrowVault.setAdmin · JudgeRegistry.setAdmin · ReportManager.setAdmin · Confidence: 75

Description
All four contracts implement setAdmin(address newAdmin) as an immediate single-step assignment with no pending-owner confirmation pattern; a typo or wrong address irreversibly surrenders all administrative control with no recovery
mechanism across the entire protocol.


  ---
⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are
strongly recommended. For a consultation regarding your projects' security, visit https://www.pashov.com