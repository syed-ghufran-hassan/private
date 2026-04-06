# Need4Audit Protocol

Need4Audit is a decentralized bug bounty protocol for smart contracts. It lets companies escrow bounty funds onchain, routes report decisions through allowlisted judges, and settles payouts transparently for researchers.

## What the Protocol Does

- Creates per-company bounty programs with severity-based payout schedules.
- Holds funds in escrow before reports are resolved.
- Tracks report state onchain from submission to payout/closure.
- Supports disputes via researcher escalation and company second-opinion requests.
- Applies configurable fee and penalty logic for treasury, judges, and companies.

## Core Contracts

- `BountyProgramRegistry`: Program creation, status lifecycle (`DRAFT`, `ACTIVE`, `PAUSED`, `CLOSED`), payout schedule config, and refund windows.
- `EscrowVault`: Token custody for each program, bounty/judge balances, treasury transfers, refunds, and penalty debt accounting.
- `ReportManager`: Canonical report state machine (`SUBMITTED` to `PAID`/`CLOSED`) with immutable report IDs.
- `JudgeRegistry`: Judge allowlist management.
- `PayoutController`: Decision execution and payout orchestration (primary approval, escalation, second opinion, final settlement).

## Roles

- Researchers:
  - Submit vulnerabilities (offchain data anchored by `reportHash` onchain).
  - Receive bounty payouts when reports are confirmed.
  - Can escalate during timelock if they disagree with a decision.
- Judges:
  - Primary judge sets first severity/outcome.
  - Secondary judge resolves escalations and second-opinion disputes.
  - Earn judge fees; may be penalized for invalidation/downgrade outcomes.
- Companies:
  - Create and fund bounty programs.
  - Define payout schedules and run active campaigns.
  - Can request second opinion and trigger refund flow when no open blocking reports remain.
- Protocol Admin:
  - Maintains registry wiring and admin controls.
  - In current MVP flow, anchors report submission and judge assignment via `ReportManager`.

## High-Level Report Flow

1. Company creates program and deposits payout token into escrow.
2. Report is anchored onchain with assigned primary judge.
3. Primary judge approves severity (or rejects), starting a timelock.
4. During timelock:
   - Researcher may escalate.
   - Company may request second opinion.
5. Secondary judge resolves disputed reports.
6. `PayoutController` finalizes and pays researcher/judge(s) from escrow.

## Local Development

This repository uses Foundry.

```bash
forge build
forge test -vv
```

## Security Notes

- This is an onchain settlement and accountability layer; report contents remain offchain, while report hashes and outcomes are onchain.
- Always review deployed parameterization (fees, penalties, timelock, treasury) before integrating.

