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
hardened through rounds 2–8 (below).

**The difference: an optional per-escrow arbiter, plus the round-2
hardening.** Everything else is v1 round 8, unchanged — the 7-day
review window, the deadline-checked delivery, the payer reject +
7-day cure window (one rejection per escrow), the one-time deadline
extension (max 7 days, before the deadline), the pull-payment design
with the 100,000-gas direct-payout cap, the packed storage, the
`lifecycleStatus()` view, the zero-amount payout guard. Tests: 158
Foundry tests (v1's 85, unchanged, plus 14 arbiter tests from round
1, plus 31 round-2 tests, plus 8 round-3 tests, plus 3 round-4 tests,
plus 1 round-5 test, plus 9 round-6 tests, plus 2 round-7 tests, plus
5 round-8 tests).

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

## Round 3 (Oct 27, 2026) — all three Grok round-2 improvements

1. **Clocks view.** `disputeClocks(id)` returns the remaining
   arbiter-timeout seconds and remaining challenge-window seconds (0
   when a clock does not apply), so UIs never re-derive the two
   clocks. The timeout counts down from 14 days while escalated; the
   challenge counts down from 2 days while a window is open. The
   clocks never run at once.
2. **Single bond event.** `BondSettled(id, recipient, amount,
   forfeited)` replaces `BondReturned` / `BondForfeited`: the
   recipient is the arbiter on a return and the payer on a forfeit, so
   indexers watch one event. Settlement paths unchanged — only the
   emit.
3. **Forfeit-split invariant.** The dispute-invariant handler now
   tracks whether a backup-arbiter timeout ever failed to return the
   primary's bond, and a third invariant asserts it never happens.
   The handler also gained a bounded `warpTime` action (0–30 days):
   without it the timeout could never fire in a fuzz run and the
   invariant would be vacuous. A unit test drives the handler through
   its own actions to a backup timeout and proves the path is reached.

## Round 4 (Oct 27, 2026) — all three Grok round-3 improvements

1. **NatSpec cross-reference.** `disputeClocks` now points at the two
   constants and the two state-changing functions that define the
   clock boundaries — `ARBITER_TIMEOUT` + `resolveDisputeTimeout`
   (>=) and `CHALLENGE_PERIOD` + `finalizeResolution` (>=) — so a
   future reader never has to rediscover the >= vs < contract.
2. **Symmetric forfeit invariant.** The dispute-invariant handler now
   also tracks whether a primary-arbiter timeout ever failed to
   forfeit the bond to the payer, and a fourth invariant asserts it
   never happens — the counterpart to round 3's backup check. A unit
   test drives the handler through its own actions to a primary
   timeout and proves the path is reached (and the bond forfeits).
3. **`DisputeTimedOut` carries the bond outcome.** The event now
   emits `(id, caller, bondAmount, bondForfeited)` with exactly the
   values `_settleBond` settles in the same call — `_settleBond`
   returns them now, so there is no second source of truth. No bond
   staked means `bondAmount = 0, bondForfeited = false`. Indexers read
   the settlement outcome from this one log instead of joining on
   `BondSettled`.

## Round 5 (Oct 27, 2026) — all three Grok round-4 improvements

1. **`_settleBond` return comment.** The NatSpec now notes that
   only `resolveDisputeTimeout` uses the returned tuple — every
   other caller is expected to discard it, so a future reader does
   not treat the return as mandatory. Comment only, no behaviour
   change.
2. **Seeded fuzz start.** The dispute-invariant handler's setup now
   seeds one primary-timeout path — create (arbiter + backup +
   bond), deliver, reject, cure, stake, escalate, warp past the
   14-day timeout, timeout — using the handler's own actions, before
   the random actions begin. The very first invariant check already
   covers a staked primary timeout, so the forfeit-split invariant
   can no longer pass vacuously. The seed is real handler state
   (ids[0]); a flag (`seededPrimaryTimeoutReached`) records that
   its timeout succeeded, and a unit test pins the seed (flag set,
   one primary timeout, seeded escrow settled, handler 100.001
   ether, arbiter 9.999 ether).
3. **Shared log-scanner utility.** `_findBondSettled` and
   `_findDisputeTimedOut` were duplicated between the main test
   contract and the dispute invariant test contract; they now live
   in one abstract contract (`test/LogScanners.sol`) both test
   contracts inherit, so the scanners stay in sync by
   construction. Behaviour identical — the helpers were
   byte-identical copies.

## Round 6 (Oct 28, 2026) — all three Grok round-5 improvements, plus the auto-finalize keeper path

1. **Second seeded fuzz path.** The dispute-invariant handler's
   setup now seeds a backup-timeout path as well — create (arbiter
   + backup + bond), deliver, reject, cure, stake, escalate,
   primary resolves (challenge opens), re-escalate, warp past the
   14-day timeout, timeout — using the handler's own actions, right
   after the primary seed. Both sides of the forfeit-split rule are
   now exercised from the very first invariant check. The backup
   seed is ids[1]; a flag (`seededBackupTimeoutReached`) records
   that its timeout succeeded, and a unit test pins the seed (flag
   set, one backup timeout, seeded escrow settled, handler 100.001
   ether, arbiter 9.999 ether). The seed is balance-neutral — the
   timeout refunds the amount and returns the bond — so the
   primary-seed balance assertions are unchanged.
2. **`DisputeResolved` bond fields.** The event now carries
   `(bondAmount, bondForfeited)`, exactly the values `_settleBond`
   settles in the same call — matching the round-4 treatment of
   `DisputeTimedOut` — so every settlement log is self-contained.
   On the deferred path (a backup arbiter was named and the first
   resolution only opens the challenge window), no bond is settled
   in that call, so the fields carry the 0 / false convention; the
   bond settles later and is reported in `BondSettled` then.
3. **Collapsed create overloads.** The three `createEscrow`
   overloads were already thin wrappers over one internal
   `_createEscrow`; round 6 finishes the collapse — when no arbiter
   terms are set at all, the arbiter-term validation and the zero
   arbiter-term writes are skipped (a fresh struct is already zero
   in every arbiter field). The public signatures are unchanged
   (2-arg = no arbiter, 3-arg = arbiter, 5-arg = full terms). The
   saving is bigger than Grok's "few hundred" estimate: the
   no-arbiter create drops 4,493 gas (137,852 → 133,359), because
   the three zero writes were each paying cold-slot access. The
   arbiter paths cost 118 gas more (the branch check).
4. **Auto-finalize keeper path.** After an arbiter resolves, the
   payout is deferred until `finalizeResolution` is called after
   the 2-day challenge window — and it is per-escrow. If both
   parties go offline, nobody calls it and the funds sit forever.
   `finalizeMatured(uint256[] ids)` closes that: anyone may call
   it, it finalizes every matured resolution in the list in one
   call, and it SKIPS ids that are not matured (nonexistent,
   settled, never resolved, still inside the window) instead of
   reverting, so a keeper can sweep blindly. A duplicate id
   finalizes once. `scripts/keeper.sh` is the keeper: it scans
   `lifecycleStatus` for ChallengeOpen escrows and sweeps them in
   batches (default 100 ids), with a `--dry-run` mode that
   simulates first. The challenge window is 2 days, so once a day
   is plenty. A batch of 3 matured resolutions measures 148,461 gas (~49,500 each) — the keeper pays gas only, the payout always goes to the recorded winner, never to the keeper. (The rebuilt round-7 harness measures the same batch at 150,953 on round-6 code — a definitional gap in the deleted round-6 harness, not a code change. The round-8 fitted figures, ~124,286 per batch of 3, are in the round-8 paragraph below.) See `scripts/keeper.sh` for the measured figures and the tuning guidance.

## Round 7 (Oct 28, 2026) — two Grok round-6 improvements: keeper logging and the batch cap

1. **Keeper logs what it finalized.** A live sweep used to print
   only a tx hash — the operator learned nothing about what
   actually settled. Now, after each batch, the keeper fetches the
   mined receipt (`cast receipt`) and decodes its logs: the
   `MaturedResolutionsFinalized` event gives the batch count, and
   the `Released` / `Refunded` events give the exact ids that
   finalized, in log order — `keeper: batch [0] finalized 1: ids 0
   (tx 0x...)`. The count is cross-checked against the ids list
   and a mismatch prints a warning. If the receipt cannot be
   fetched or decoded, the keeper falls back to printing the tx
   hash — logging never fails a sweep. `--dry-run` previews the
   same information per id (one `cast call` per candidate, which is
   the on-chain maturity decision itself, so the preview cannot
   drift from what the real sweep would do) — `keeper: dry-run
   batch [1] would finalize 0`.
2. **Batch cap.** `finalizeMatured` now hard-caps the ids array at
   `MAX_FINALIZE_BATCH = 256` (public constant) and reverts
   "Batch too large" above it, before the loop starts — the loop
   is no longer unbounded and a careless or malicious batch cannot
   run the call out of gas. 256 is comfortably above the keeper's
   100-id batches, so normal sweeps never touch the bound. Two
   tests pin the boundary: a 256-id batch with one matured
   resolution finalizes it, a 257-id batch reverts. The cap check
   costs ~26 gas on a batch of 3 (150,953 → 150,979); every other
   measured path is unchanged within dispatcher noise (see Status).

## Round 8 (Oct 28, 2026) — three Grok round-7 improvements

1. **Bond status + clocks in one call.** `disputeStatus(id)` returns
   the bond amount set at creation, whether the bond is currently
   held (`bondStaked`), and the two remaining dispute clocks —
   the same values `disputeClocks(id)` returns — so UIs and keepers
   make one call instead of joining `getEscrow` + `disputeClocks`.
   `bondStaked` is true only while the bond is actually held: false
   before the stake, false again after it is returned or forfeited
   on settlement. Five tests pin it across states: no bond (fresh,
   delivered, settled, nonexistent id — all zero), bond set then
   staked, escalated (14-day timeout clock), challenge open (2-day
   clock, bond held, 0 at the boundary, cleared on finalization),
   and timeout forfeit (bond reads set-but-not-held after it).
   The clocks share one internal implementation with
   `disputeClocks`, so the two views can never drift apart. This is
   a per-escrow read only — it does not list matured ids (the
   ChallengeOpen/matured-ids view stays held).
2. **Explicit reentrancy guard on `deliver()` and the create
   overloads.** `nonReentrant` now covers every state-changing
   external entry point uniformly, including the ones that make no
   external calls today — so a future edit that adds one cannot
   silently open a reentrancy path. Behaviour is unchanged (no
   external calls exist there today; the full suite, including the
   reentrancy tests, stays green). The cost is real and measured:
   ~+22,480 gas per newly guarded call (one SLOAD + two SSTOREs,
   the second refunding on the 0-write) — creates go 133,359 →
   155,862 (no arbiter), 160,479 → 182,985 (arbiter), 183,286 →
   205,792 (backup), 183,388 → 205,894 (backup + bond); `deliver`
   56,645 → 79,112; the full and extended flows each +67,438 (the
   three newly guarded calls in each). `finalizeMatured` moves
   only +11 (dispatcher noise from the new view's selector).
3. **Keeper gas, measured honestly, and the block-limit
   assumption.** The keeper header now documents the exact
   gas-per-finalization measurement instead of the old
   "~148,461 (~49,500 each)", which came from a round-6 harness
   whose batch composition was never recorded: fitted from
   measured 1/2/3-id batches, no bond staked is base ~49,026 +
   ~25,087 per finalization (batch of 3 ~124,286; batch of 100
   ~2.56M; full 256 ~6.47M), and fully bonded is base ~51,523 +
   ~39,341 per finalization (batch of 3 ~169,545; batch of 100
   ~3.99M; full 256 ~10.12M). Arc's block gas limit is 30,000,000
   (verified live against mainnet + testnet RPCs, Oct 28, 2026),
   so even a fully bonded 256-id batch (~34% of a block) fits in
   one block on its own, and the default `BATCH_SIZE` of 100 stays
   under ~4M even fully bonded. The header says how to tune it
   and when to re-check the limit.

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
| `contracts/LamplightEscrow.sol` | The contract (Solidity 0.8.24, MIT). V1 round 8 + optional per-escrow arbiter + rounds 2–8 hardening. Struct is 7 slots (v1: 4, v2 round 1: 5). Note: the `escrows` mapping is internal, not public — with 19 struct fields, Solidity's auto-generated public getter cannot compile (solc "stack too deep" in the tuple ABI encoding); `getEscrow(id)` is the read path. |
| `test/LamplightEscrow.t.sol` | 158 Foundry tests — v1's 85 unchanged, plus 14 arbiter tests (round 1), plus 31 round-2 tests (timeout, bond, backup/challenge, event, struct round-trip) and a dispute invariant suite (4 invariants), plus 8 round-3 tests (disputeClocks, BondSettled event, forfeit-split unit + handler reachability), plus 3 round-4 tests (DisputeTimedOut bond outcome ×2, primary-timeout handler reachability), plus 1 round-5 test (seeded primary timeout pinned), plus 9 round-6 tests (DisputeResolved bond fields ×3, finalizeMatured batch ×5, seeded backup timeout pinned), plus 2 round-7 tests (finalizeMatured batch cap: passes at 256, reverts at 257), plus 5 round-8 tests (disputeStatus across states: no bond, bond set/unstaked then staked, escalated clocks, challenge open and settled, timeout forfeit clears bond). |
| `test/LogScanners.sol` | Shared log-scanning helpers (`_findBondSettled`, `_findDisputeTimedOut`, `_findDisputeResolved`) both test contracts inherit (round 5; `_findDisputeResolved` added round 6). |
| `scripts/keeper.sh` | The keeper: scans `lifecycleStatus` for ChallengeOpen escrows and sweeps them with `finalizeMatured` in batches (round 6). Round 7: each sweep logs the finalized count and ids decoded from the mined receipt (Released / Refunded events cross-checked against the batch event), and `--dry-run` previews which ids would finalize per id. Verified end-to-end against local Anvil — dry-run preview, real sweep, settlement confirmed, second sweep idle; plus the not-yet-matured case (dry-run 0, sweep finalizes 0 and leaves the escrow ChallengeOpen, then finalizes it after the warp). Round 8: header documents the exact measured gas-per-finalization (base ~49,026 + ~25,087 per finalization no bond; ~51,523 + ~39,341 fully bonded) and the Arc 30M block-gas limit assumption with tuning guidance; re-verified against local Anvil with the round-8 contract — `disputeStatus` read live at every stage (unstaked → staked → escalated 14d clock → challenge open 2d clock → window closed → settled, bond cleared), dry-run 0 before maturity, 1 after, real sweep finalizes 1, escrow balance 0. |
| `foundry.toml` | Foundry config (same as v1, incl. the invariant pin). |
| `studio-contract-reference.sol` | Studio's contract source BEFORE the Oct 27 revision — historical reference for the diff, not the live contract. The live contract is `contracts/LamplightEscrow.sol`. |

## Status

Pushed to GitHub (this repo) — V2 is the deploy line, Studio-verified Oct 31, 2026 (byte-identical to the fixed source). Mainnet deploy scheduled Nov 1. Gas (current — round 8, measured Oct 28, 2026, same harness as round 5 — first create in a fresh test, `gasleft()` delta, `start` read before `vm.prank`; flows as single spans): `createEscrow` 155,862 gas with no arbiter; 182,985 with an arbiter; 205,792 with arbiter + backup arbiter (no bond); 205,894 with arbiter + backup + bond. Full arbiter flow (create+deliver+reject+cure+escalate+resolve) 558,987 gas. Extended flow (bond + backup + challenge + backup resolution) 792,393 gas. `finalizeMatured` batch of 3 matured resolutions: 124,286 gas. The round-8 paragraph below gives the deltas vs round 7. For comparison, the round-6 figures were 133,359 / 160,501 / 183,286 / 183,388 (creates), flows 491,644 / 724,910, batch of 3: 148,461 (~49,500 each); the round-6 extended-flow figure was re-measured with the backup resolving to the payer, as in round 4 (resolving to the payee measures 723,365 — the 215 gas is the payout-direction difference, not a code change).
Round 7 (same harness, rebuilt — reproduces round 6's four creates
exactly): no-arbiter create 133,359 (unchanged), with-arbiter 160,479
(−22, dispatcher noise from the new `MAX_FINALIZE_BATCH` getter),
with backup 183,286 and with backup + bond 183,388 (unchanged), full
arbiter flow 491,542 (unchanged on the same harness), extended flow
724,921 (+89, same dispatcher noise), `finalizeMatured` batch of 3
150,979 (+26 — the cap check itself; the batch figure differs from
the recorded round-6 148,461 because the rebuilt harness measures the
batch at 150,953 on round-6 code too, a definitional gap in the
deleted round-6 harness, not a code change).
Round 8 (same harness, rebuilt — reproduces round-7 figures within
~25 gas; temp harness deleted after measuring): the explicit
`nonReentrant` on `deliver()` and the three create overloads costs
~+22,480 per newly guarded call — no-arbiter create 155,862
(133,383, +22,479), with-arbiter 182,985 (160,503, +22,482), with
backup 205,792 (183,310, +22,482), with backup + bond 205,894
(183,412, +22,482), `deliver` 79,112 (56,645, +22,467), full arbiter
flow 558,987 (491,549, +67,438) and extended flow 792,393 (724,955,
+67,438) — each flow has exactly three newly guarded calls. No
behaviour change: no external calls exist in the newly guarded
paths, and the full suite (including the reentrancy tests) stays
green. `finalizeMatured` moves only +11 on every batch (x1 74,113,
x2 99,198, x3 124,286; bonded x1 90,864, x3 169,545 — dispatcher
noise from the new `disputeStatus` selector). Per-finalization,
fitted from the measured 1/2/3-id batches: no bond staked base
~49,026 + ~25,087 per finalization (batch of 100 ~2.56M, full 256
~6.47M); fully bonded base ~51,523 + ~39,341 per finalization
(batch of 100 ~3.99M, full 256 ~10.12M). Arc's block gas limit is
30,000,000, verified live against the mainnet and testnet RPCs
(eth_getBlockByNumber, Oct 28, 2026 — both gasLimit 0x1c9c380),
so a fully bonded 256-id batch is ~34% of a block and the default
100-id batch ~13% even fully bonded.

## Licence

MIT.
