# Lamplight Escrow v2 — status (Oct 27, 2026)

## Project

Lamplight Escrow v2 — the Arc pay-on-delivery escrow (v1 round 8) plus
an optional per-escrow arbiter. Built for the DoraHacks Arc Microgrants:
Built with Arc Studio (8 × $500 USDC on Arc, submissions close Nov 1,
2026).

## v1 vs v2

- **V1** (in this repo's git history): STOPPED (decision, Oct 27, 2026) — frozen at
  round 9, no further work. V2 is the only line going forward.
- **V2** (this directory): forked from v1 round 8 on Oct 27, 2026 +
  the optional per-escrow arbiter, hardened in round 2 (Oct 27,
  2026). V2 goes through the same loop — Grok every round; Claude +
  ChatGPT as final gates on a deploy candidate.
- V2 is pushed to GitHub (this repo) Oct 27, 2026 — not submitted anywhere, not deployed anywhere.

## The arbiter (the only v2 difference)

- `createEscrow(payee, deadline, arbiter)` — three-argument overload;
  the two-argument version still exists and creates a no-arbiter escrow
  (flow exactly v1's). The arbiter must be a third party (not the payer,
  payee, or the contract); address(0) means none.
- `escalateDispute(id)` — only the payer, only after a rejection + cure,
  only inside the review window, only when an arbiter was set.
  Reverts: "No arbiter", "Not rejected", "Not delivered",
  "Already escalated", "Review period ended".
- `resolveDispute(id, releaseToPayee)` — only the arbiter, only while
  escalated, only once. True pays the payee in full; false refunds the
  payer in full. Emits `DisputeResolved`; resolution settles the escrow.
- `release()` reverts "Disputed" while escalated (payer and payee both).
- `lifecycleStatus()` has a new `Escalated` state (appended after
  `Settled`, so existing enum values are unchanged).
- Events: `DisputeEscalated(id, payer, arbiter)`,
  `DisputeResolved(id, arbiter, releasedToPayee)`.
- Struct: 5 slots (v1: 4) — `escalated` packs into slot 2 (248 of 256
  bits), `arbiter` is slot 4.
- Limits, stated plainly: the arbiter check only compares addresses and
  cannot prove independence — the payee should read the arbiter before
  accepting work and only take escrows whose arbiter it trusts. A silent
  arbiter stalls the escrow (no arbiter timeout in v2). The cure still
  accepts any hash; the arbiter judges it.

## Round 2 — "everything" (Oct 27, 2026): all five Grok v2 recommendations

1. **Arbiter timeout** — `ARBITER_TIMEOUT = 14 days`,
   `resolveDisputeTimeout(id)`: either party may force-refund the
   payer after 14 days escalated. Clock restarts on re-escalation.
   Reverts "Arbiter timeout not reached" before the boundary.
2. **Arbiter terms in the event** — `EscrowCreated` now carries
   `arbiter`, `backupArbiter`, `bondAmount`. `getEscrow(id)` already
   returns the whole struct.
3. **Escalated invariant** — new handler-driven invariant suite:
   no release/refund/refundAfterRejection may ever succeed while
   escalated; release may never succeed while a challenge is open;
   balance invariant extended to staked bonds.
4. **Arbiter bond** — `createEscrow(payee, deadline, arbiter,
   backupArbiter, bondAmount)` (five-argument overload; the
   two- and three-argument versions are unchanged). The arbiter
   stakes the exact amount via `stakeBond(id)` before escalation
   can happen ("Bond not staked" otherwise). Returned to the arbiter
   on every settlement (including a normal release/refund with no
   dispute); forfeited to the payer only on a primary-arbiter
   timeout. A backup-arbiter timeout returns the bond to the primary
   arbiter instead (it acted; the backup staked nothing).
5. **Backup arbiter + challenge window** — `CHALLENGE_PERIOD =
   2 days`. After the primary arbiter resolves with a backup named,
   the payout is deferred and either party may `reEscalate(id)` to
   the backup arbiter for one final decision; `finalizeResolution(id)`
   (anyone may call) pays the recorded decision once the window
   closes. New `ChallengeOpen` lifecycle state (appended after
   `Escalated`); `release()` reverts "Resolution pending" while it
   is open.
- New revert strings: "Invalid backup arbiter", "Bond not staked",
  "No bond set", "Wrong bond amount", "Bond already staked",
  "No backup arbiter", "Not resolved", "Already challenged",
  "Challenge period ended", "Challenge period not ended",
  "Resolution pending", "Only party", "Only backup arbiter",
  "Arbiter timeout not reached".
- New events: `DisputeTimedOut(id, caller)`,
  `DisputeChallenged(id, challenger, backupArbiter)`,
  `BondStaked(id, arbiter, amount)`, `BondReturned(id, arbiter, amount)`,
  `BondForfeited(id, payer, amount)`.
- Struct: 7 slots — `challengeOpen` packs into slot 2 (221 of 256
  bits, so `release()` pays no extra cold SLOAD for the challenge
  guard); `backupArbiter` + `bondAmount` pack exactly into slot 5
  (160 + 96 = 256 bits); `escalatedAt` / `resolvedAt` /
  `resolvedToPayee` / `bondStaked` / `challenged` in slot 6.
- **Compiler note:** the `escrows` mapping is now `internal`, not
  `public`. With 19 struct fields, Solidity's auto-generated public
  getter cannot compile (solc "stack too deep" in the tuple ABI
  encoding). Nothing used it — `getEscrow(id)` is the read path.
  `_createEscrow` also writes fields one by one instead of a struct
  literal for the same reason (the 19-field literal blows the stack).
- Limits, updated: a silent arbiter now costs at most 14 days; one
  challenge round only (the backup's resolution is final); the bond
  is optional and single (primary arbiter only).

## Tests

- **130 passed, 0 failed** (`forge test` at the repo root, ~2.2s): v1's 85 tests
  unchanged (the two-argument `createEscrow` and the invariant handler
  work unmodified through the overloads) plus 14 arbiter tests (round 1)
  plus 30 round-2 unit tests plus a 2-invariant dispute suite — timeout
  (before/at/after the 14-day boundary, either party, forfeit, backup
  timeout returns the bond, post-timeout actions blocked), bond (stake
  + refund on both resolve directions, gate on escalation, wrong
  amount, only-arbiter, double-stake, no-bond-set, return on normal
  release/refund, bond without arbiter), backup/challenge (re-escalate
  by either party reversing both directions, window boundary, no
  backup, unresolved, finality, finalize both directions + during the
  window, release blocked, primary cannot re-resolve, backup
  validation), event fields, struct round-trip.
- Gas (measured Oct 27, 2026, first create in a fresh test,
  `gasleft()` delta): `createEscrow` 137,870 gas with no arbiter;
  160,379 with an arbiter; 183,193 with arbiter + backup arbiter
  (no bond); 183,295 with arbiter + backup + bond (+102 for the
  nonzero bond word). Full arbiter flow
  (create+deliver+reject+cure+escalate+resolve) 490,816 gas (was
  469,709 in round 1, +21,107 — extra slot writes and bond checks).
  Extended flow (bond + backup + challenge + backup resolution)
  723,190 gas.
- One test-expectation fix during the round: after a backup
  resolution, the primary arbiter's re-call of `resolveDispute`
  correctly reverts "Only backup arbiter" (caller check before
  settled check, same as round 1), not "Already settled" — the test
  was corrected, not the contract.

## Next steps

- Re-review: v2 round 2 goes to Grok (round-by-round reviewer).
  Claude + ChatGPT are final gates on a deploy candidate (Claude
  rule, Oct 27, 2026 — saved like ChatGPT; ChatGPT's file-upload
  limit is blocked until ~Oct 28, 2026, 4:50 PM CDT).
- Deploy: V2 is the deploy line. Studio must be updated to match it
  before the mainnet deploy, the same as v1 was.
