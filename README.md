# Lamplight Escrow v2 — pay-on-delivery escrow for AI agents on Arc (with optional arbiter)

**Builder:** Ellis Lamplight — GitHub `queenellis2026-hash`, X `@EllisLamplight`,
queenellis2026@gmail.com · Payout wallet (USDC on Arc):
`0x307d85Fb0741Bee6Dc8e5CFc62331Af90526eB1B`

Built for the **DoraHacks Arc Microgrants: Built with Arc Studio**
(8 × $500 USDC on Arc, submissions close Nov 1, 2026;
[detail page](https://dorahacks.io/hackathon/arc-microgrants-2/detail)).

## v1 vs v2 — read this first

This is a **separate line** forked from v1 round 8
(v1 is frozen at round 9; see this repo's git history). **V1 is STOPPED
(decision, Oct 27, 2026): no further work on the v1 line — it is
frozen at round 9. V2 is the only line going forward**, through the
same loop (Grok every round; Claude + ChatGPT as final gates on a
deploy candidate). V2 is NOT a replacement for v1 in the sense of a
rewrite; it is the same contract plus the arbiter feature, now
hardened through round 2 (below).

**The difference: an optional per-escrow arbiter, plus the round-2
hardening.** Everything else is v1 round 8, unchanged — the 7-day
review window, the deadline-checked delivery, the payer reject +
7-day cure window (one rejection per escrow), the one-time deadline
extension (max 7 days, before the deadline), the pull-payment design
with the 100,000-gas direct-payout cap, the packed storage, the
`lifecycleStatus()` view, the zero-amount payout guard. Tests: 130
Foundry tests (v1's 85, unchanged, plus 14 arbiter tests from round
1, plus 31 round-2 tests).

## What the arbiter does

At creation the payer may name a third-party arbiter
(`createEscrow(payee, deadline, arbiter)`). `address(0)` means none,
and the flow is exactly v1's. When an arbiter is set:

1. The payee delivers, the payer rejects inside the review window, and
   the payee cures with a corrected hash — as in v1.
2. Instead of waiting out the 7-day review window, the payer may
   **escalate** the disputed cure to the arbiter (`escalateDispute`) —
   only the payer, only after a rejection + cure, only inside the review
   window.
3. The arbiter **resolves** (`resolveDispute(id, releaseToPayee)`) —
   true pays the full amount to the payee, false refunds the full amount
   to the payer. Resolution settles the escrow; the arbiter cannot act
   twice.
4. While escalated, **neither party can release** (`release` reverts
   `"Disputed"`), and `lifecycleStatus` returns a new `Escalated`
   state. After resolution it returns `Settled`.

Why it exists: with v1's one-rejection cap, a bad-faith payee can cure
with another junk hash and force payment after 7 days — the contract
cannot judge the hash. The arbiter closes that gap: the payer escalates
the disputed cure to a third party who decides. Claude (round-8
re-review) called it "the one remaining trust-model gap".

## Round 2 hardening (Oct 27, 2026) — all five Grok recommendations

1. **Arbiter timeout** (`ARBITER_TIMEOUT = 14 days`, `resolveDisputeTimeout`).
   After 14 days escalated with no resolution, either party may
   force-refund the payer. A silent arbiter can no longer stall an
   escrow forever; the clock restarts if the dispute is re-escalated
   to the backup arbiter.
2. **Arbiter terms in the creation event.** `EscrowCreated` now
   carries the arbiter, backup arbiter, and bond amount, so indexers
   and UIs need no second call. `getEscrow(id)` already returns the
   whole struct, arbiter included.
3. **Escalated invariant.** A handler-driven invariant asserts that
   while escalated, neither `release()` nor `refund()` nor
   `refundAfterRejection()` can ever succeed — and `release()` can
   never succeed while a challenge is open. A second invariant extends
   the balance check to staked bonds.
4. **Optional arbiter bond.** Set at creation (`bondAmount`, 0 = no
   bond), staked by the arbiter in a separate payable call
   (`stakeBond`) before escalation can happen. Refunded to the
   arbiter on every settlement — including a normal release or refund
   with no dispute at all, so it can never strand. Forfeited to the
   payer only when the arbiter it was staked against times out. If
   the *backup* arbiter times out, the bond returns to the primary
   arbiter: it resolved in time, the stall is the backup's fault, and
   the backup staked nothing.
5. **Optional backup arbiter + 2-day challenge window.** Named at
   creation (`backupArbiter`, `address(0)` = none). After the primary
   arbiter resolves, the payout is deferred and a 2-day window opens
   in which either party may re-escalate (`reEscalate`) to the backup
   arbiter for **one final decision** — no third round. If nobody
   challenges, the resolution stands and anyone may finalize it
   (`finalizeResolution`), which pays the recorded decision. While
   the window is open, `release()` reverts `"Resolution pending"`,
   and `lifecycleStatus` returns a new `ChallengeOpen` state.

## Limits, stated plainly

- **The arbiter check only compares addresses.** `createEscrow`
  rejects an arbiter who is the payer, the payee, or the contract
  itself — but it cannot prove the arbiter is independent of the payer
  (a second wallet the payer controls passes the check). The payee
  should read the arbiter from `getEscrow(id)` before accepting work
  and only take escrows whose arbiter it trusts. This is the same
  disclosed limitation as HSK's per-job arbiter. The backup arbiter
  has the same check, must differ from the arbiter, and requires an
  arbiter to be set at all.
- **A silent arbiter now costs at most 14 days.** The timeout
  force-refunds the payer; a silent *primary* arbiter also forfeits
  its bond. The timeout does not judge the work — it only unblocks
  the funds.
- **One challenge round only.** The backup arbiter's resolution is
  final. If the backup arbiter is also silent, the 14-day timeout
  (restarted at re-escalation) is the exit.
- **The cure still accepts any hash.** The arbiter judges the cured
  delivery, but the contract itself never judges a hash — that is what
  the arbiter is for.
- **The bond is optional and single.** One `bondAmount` per escrow,
  staked by the primary arbiter only; the backup arbiter stakes
  nothing.
- Not audited. Experimental software — use small amounts.

## Files

| File | What it is |
|---|---|
| `contracts/LamplightEscrow.sol` | The contract (Solidity 0.8.24, MIT). V1 round 8 + optional per-escrow arbiter + round-2 hardening. Struct is 7 slots (v1: 4, v2 round 1: 5). Note: the `escrows` mapping is internal, not public — with 19 struct fields, Solidity's auto-generated public getter cannot compile (solc "stack too deep" in the tuple ABI encoding); `getEscrow(id)` is the read path. |
| `test/LamplightEscrow.t.sol` | 130 Foundry tests — v1's 85 unchanged, plus 14 arbiter tests (round 1), plus 30 round-2 unit tests (timeout, bond, backup/challenge, event, struct round-trip) and a dispute invariant suite (2 invariants). |
| `foundry.toml` | Foundry config (same as v1, incl. the invariant pin). |
| `studio-contract-reference.sol` | Studio's contract source BEFORE the Oct 27 revision — historical reference for the diff, not the live contract. The live contract is `contracts/LamplightEscrow.sol`. |

## Status

Pushed to GitHub Oct 27, 2026 (this repo) — V2 is the deploy line. Not
submitted anywhere yet. Gas (measured Oct 27, 2026, first
create in a fresh test, `gasleft()` delta): `createEscrow` 137,870
gas with no arbiter; 160,379 with an arbiter; 183,193 with arbiter +
backup arbiter (no bond); 183,295 with arbiter + backup + bond
(+102 for the nonzero bond word). Full arbiter flow
(create+deliver+reject+cure+escalate+resolve) 490,816 gas (was
469,709 in round 1, +21,107 — the extra slot writes and bond checks).
Extended flow (bond + backup + challenge + backup resolution)
723,190 gas.

## Licence

MIT.
