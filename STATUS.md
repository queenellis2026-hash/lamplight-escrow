# Lamplight Escrow v2 — status (Oct 28, 2026)

## Project

Lamplight Escrow v2 — the Arc pay-on-delivery escrow (v1 round 8) plus
an optional per-escrow arbiter. Built for the DoraHacks Arc Microgrants:
Built with Arc Studio (8 × $500 USDC on Arc, submissions close Nov 1,
2026).

## v1 vs v2

- **V1** (in this repo's git history): STOPPED (decision, Oct 27, 2026) — frozen at
  round 9, no further work. V2 is the only line going forward.
- **V2** (this directory): forked from v1 round 8 on Oct 27, 2026 +
  the optional per-escrow arbiter, hardened in rounds 2–9 (Oct 27–28, 2026). V2 goes through the same loop — Grok every round; Claude +
  ChatGPT as final gates on a deploy candidate.
- V2 is pushed to GitHub (this repo) Oct 28, 2026 — rounds 3–9 on top of round-2 head `f1ce32ec`; not submitted anywhere, not deployed anywhere.

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
- Events: `DisputeEscalated(id, payer, arbiter)`, `DisputeResolved(id, arbiter, releasedToPayee, bondAmount, bondForfeited)` (bond fields added round 6).
- Struct: 7 slots (v1: 4) — `escalated` packs into slot 2 (248 of 256 bits), `arbiter` is slot 4; `backupArbiter` + `bondAmount` pack into slot 5, `escalatedAt` / `resolvedAt` / `resolvedToPayee` / `bondStaked` / `challenged` in slot 6 (round 2).
- Limits, stated plainly: the arbiter check only compares addresses and
  cannot prove independence — the payee should read the arbiter before
  accepting work and only take escrows whose arbiter it trusts. A silent arbiter now costs at most 14 days (`ARBITER_TIMEOUT = 14 days`, `resolveDisputeTimeout` — round 2). The cure still
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

## Round 3 (Oct 27, 2026): all three Grok round-2 improvements

1. **Clocks view** — `disputeClocks(id)` returns the remaining
   arbiter-timeout seconds and remaining challenge-window seconds
   (0 when a clock does not apply), so UIs never re-derive the two
   clocks. The timeout counts down from 14 days while escalated and
   reads 0 at the exact boundary (the timeout call uses >=); the
   challenge counts down from 2 days while a window is open and reads
   0 at its boundary (finalize uses >=). The clocks never run at once.
2. **Single bond event** — `BondSettled(id, recipient, amount,
   forfeited)` replaces `BondReturned` / `BondForfeited` (round 2):
   the recipient is the arbiter on a return (forfeited = false) and
   the payer on a forfeit (forfeited = true), so indexers watch one
   event. The settlement paths are unchanged — only the emit.
3. **Forfeit-split invariant** — the dispute-invariant handler now
   tracks whether a backup-arbiter timeout ever failed to return the
   primary's bond (direct payment or pull credit), and a third
   invariant asserts it never happens. The handler also gained a
   bounded `warpTime` action (0–30 days forward): without it,
   `resolveDisputeTimeout` could never succeed in a fuzz run
   (escalatedAt is always "now") and the invariant would be vacuous.
   A unit test drives the handler through its own actions to a backup
   timeout and asserts the path is actually reached
   (`backupTimeoutsSucceeded == 1`).
- Gas: effectively unchanged from round 2 (within ~60 gas on creates
  — harness noise; the changes are a view, an event rename, and
  test-only handler code, none on the create path).

## Round 4 (Oct 27, 2026): all three Grok round-3 improvements

1. **NatSpec cross-reference** — `disputeClocks` now points at the
   two constants and the two state-changing functions that define
   the clock boundaries: ARBITER_TIMEOUT + resolveDisputeTimeout
   (>=) and CHALLENGE_PERIOD + finalizeResolution (>=). No
   behaviour change.
2. **Symmetric forfeit invariant** — the dispute-invariant handler
   now tracks whether a primary-arbiter timeout ever failed to
   forfeit the bond to the payer (`primaryTimeoutFailedToForfeitBond`
   + `primaryTimeoutsSucceeded`), and a fourth invariant asserts it
   never happens. A unit test drives the handler through its own
   actions to a primary timeout and asserts the path is reached
   (`primaryTimeoutsSucceeded == 1`), the flag is clear, the bond
   forfeits to the payer (the handler), and the BondSettled event
   says so from the raw logs (recipient = payer, forfeited = true).
3. **DisputeTimedOut carries the bond outcome** — the event is now
   `DisputeTimedOut(id, caller, bondAmount, bondForfeited)` and
   `_settleBond` returns the (amount, forfeited) it settles, so the
   timeout emit reports exactly the values settled in the same call
   — one source of truth, no drift. No-bond convention: amount = 0,
   forfeited = false, documented in the event NatSpec and in
   resolveDisputeTimeout's NatSpec. The existing boundary test now
   asserts the no-bond fields via expectEmit (data checked); two
   new tests assert the event both ways from the raw logs (primary:
   forfeited = true; backup: forfeited = false) and cross-check it
   against the BondSettled event in the same call.
- Mutation-tested, both directions: with `_settleBond` forced to
  never forfeit, the new primary-timeout unit test FAILS (and the
  fuzz invariant passes — see the caveat below); with it forced to
  always forfeit, the round-3 backup unit test FAILS. Both unit
  tests are the live proof; both pass on the good code.
- Caveat, stated plainly: like its round-3 backup counterpart, the
  new fuzz invariant is only exercised when random sequences reach
  a staked primary timeout — in 256 runs x 3840 calls the fuzzer
  never got there (the sequence is ~7 actions on one escrow with a
  warp in the middle), so under mutation the invariant still
  passes. The deterministic handler unit test is the reachability
  proof, exactly as round 3 accepted for the backup side.
- Gas: creates +32 gas vs round 3 across the board (137,852 /
  160,383 / 183,168 / 183,270) — the create path itself is
  untouched, no logic change on it; the shift is a codegen/layout
  effect of the `_settleBond` return-value change. Full arbiter
  flow 490,840 (+49); extended flow 723,580 (+379, two
  resolveDispute sites inlining the return plumbing). All
  negligible (≤0.05%).

## Round 5 (Oct 27, 2026): all three Grok round-4 improvements

1. **`_settleBond` return comment** — the NatSpec now notes that
   only resolveDisputeTimeout uses the returned (amount, forfeited)
   tuple; every other caller is expected to discard it, so a future
   reader does not treat the return as mandatory. Comment only; no
   behaviour change.
2. **Seeded fuzz start** — the dispute-invariant handler's setup
   now seeds one primary-timeout path before the random actions:
   create (arbiter + backup + bond), deliver, reject, cure
   (re-deliver), stake, escalate, warp 15 days past the 14-day
   timeout, timeout — all through the handler's OWN actions, so
   the seeded escrow is real handler state (ids[0]), not a
   separate fixture. The very first invariant check already covers
   a staked primary timeout, so the forfeit-split invariant can no
   longer pass vacuously. A flag (`seededPrimaryTimeoutReached`,
   set in the handler's `timeout()` when the seeded escrow's
   timeout succeeds) records that the path was reached, and a new
   unit test pins the seed: flag set, exactly one primary timeout
   recorded, seeded escrow settled, handler 100.001 ether, arbiter
   9.999 ether. The two reachability tests now drive their OWN
   escrow (seed 1, ids[1]) and their balance assertions account
   for the seed — the primary test asserts the timeout count as a
   delta (seed 1 + this test 1) and the handler at 100.002 ether,
   the arbiter at 9.998 ether; the backup test asserts the arbiter
   at 9.999 ether. The seeded escrow is settled by the seed, so
   later random actions on it exercise the settled-state revert
   paths; live-dispute interaction happens on fuzzer-created
   escrows.
- Mutation proof — the round-4 caveat is CLOSED: with
  `_settleBond` forced to never forfeit in the timeout path
  (`forfeitBond = false` in resolveDisputeTimeout), the fuzz
  invariant `invariant_PrimaryTimeoutForfeitsBond` FAILS (the
  seed's own timeout in setUp sets the flag, so the first check
  fails) — and the three unit tests fail with it. The backup
  invariant still passes under the mutation, as it should (a
  backup timeout returns the bond; the mutation only breaks
  forfeits). The contract was restored byte-identical after
  (md5-verified, diff clean, `forfeitBond = !escrow.challenged`
  back in place), and the full suite is green again.
3. **Shared log-scanner utility** — `_findBondSettled` and
   `_findDisputeTimedOut` were byte-identical duplicates in the
   main test contract and the dispute invariant test contract
   (verified by diff before moving); they now live in one abstract
   contract, `test/LogScanners.sol`, which both test contracts
   inherit. Behaviour identical; only the home changed.
- Gas: all six figures IDENTICAL to round 4 (137,852 / 160,383 /
  183,168 / 183,270; full arbiter flow 490,840; extended flow
  723,580) — round 5 changes no contract logic (a NatSpec comment
  only), so the gas profile is unchanged. The extended flow was
  re-measured with the backup resolving to the payer, as in round
  4; resolving to the payee measures 723,365 — the 215 gas is the
  payout-direction difference, not a code change.

## Round 6 (Oct 28, 2026): all three Grok round-5 improvements + the auto-finalize keeper path

All four items. 151/151 forge tests pass (142 + 9 new). V1 untouched
(0 arbiter hits in the v1 contract). No push — rounds 3 + 4 + 5 + 6
push together after the round-6 Grok re-review, on top of head
`f1ce32ec` (round 2).

1. **Second seeded fuzz path** — the dispute-invariant handler's
   setup now seeds a backup-timeout path as well (ids[1]): create
   (arbiter + backup + bond), deliver, reject, cure, stake,
   escalate, primary resolves (challenge opens), re-escalate, warp
   15 days, timeout — all through the handler's OWN actions
   (`seedBackupTimeout()`, idempotent). Both sides of the
   forfeit-split rule are now exercised from the very first
   invariant check. A flag (`seededBackupTimeoutReached`) records
   that the seed's timeout succeeded, and a new unit test pins the
   seed (flag set, exactly one backup timeout, seeded escrow
   settled, handler 100.001 ether, arbiter 9.999 ether). The seed
   is balance-neutral — the timeout refunds the amount and returns
   the bond — so the primary-seed balance assertions are unchanged.
   The two reachability tests now drive their OWN escrow (seed 2,
   ids[2]); the backup test asserts its timeout count as a delta
   (seed 1 + this test 1).
2. **DisputeResolved bond fields** — the event now carries
   `(bondAmount, bondForfeited)`, exactly the values `_settleBond`
   settles in the same call (captured from its return, like the
   round-4 DisputeTimedOut treatment), so every settlement log is
   self-contained. On the deferred path the fields carry the 0 /
   false convention (no bond settled in that call); the bond
   settles later and is reported in `BondSettled` then. Three new
   tests assert the fields from the raw logs via a new shared
   scanner (`_findDisputeResolved` in `test/LogScanners.sol`):
   immediate resolution with bond (agrees with BondSettled),
   deferred resolution (0 / false, bond still staked, no
   BondSettled fired), immediate resolution with no bond (0 /
   false, no BondSettled fired). The `_settleBond` NatSpec now
   notes two callers use the tuple (resolveDisputeTimeout and
   resolveDispute); the other callers still discard it.
3. **Collapsed create overloads** — the three `createEscrow`
   overloads already funneled into one internal `_createEscrow`;
   round 6 finishes the collapse: when no arbiter terms are set at
   all, the arbiter-term validation and the zero arbiter-term
   writes are skipped (a fresh struct is already zero in every
   arbiter field). The public signatures are unchanged. The saving
   is far bigger than Grok's "few hundred" estimate: the no-arbiter
   create drops 4,493 gas (137,852 → 133,359), because the three
   zero writes were each paying cold-slot access (~2,100 each).
   The arbiter paths cost 118 gas more each (the branch check).
   The skip is exactly semantics-preserving: validation can only
   revert when at least one term is nonzero, so when all three are
   zero it trivially passes, and the skipped writes would have
   written zeros.
4. **Auto-finalize keeper path** — `finalizeMatured(uint256[] ids)`
   (permissionless, returns how many it finalized): finalizes every
   matured resolution in the list in one call and SKIPS ids that
   are not matured instead of reverting, so a keeper can sweep
   blindly. A duplicate id finalizes once; a failed payout credits
   the recipient instead of blocking the batch. `finalizeResolution`
   now shares the internal `_finalizeResolution` with the batch —
   its behaviour is unchanged (existing tests cover it). Five new
   tests: batch of 3 (two refunds, one release, one with a bond —
   returns 3, balances exact, `MaturedResolutionsFinalized`
   emitted), mixed-list skip (matured + in-window + escalated-only
   + nonexistent + already-settled → returns 1, no revert), empty
   batch (returns 0), duplicate id (finalizes once, paid exactly
   once), no-bond matured (finalizes cleanly). `scripts/keeper.sh`
   is the keeper: scans `lifecycleStatus` for ChallengeOpen
   escrows, sweeps them in batches (default 100), `--dry-run`
   simulates first. Verified end-to-end against local Anvil:
   deployed the round-6 contract, drove one escrow to a matured
   resolution with `cast`, dry-run previewed "would finalize 1",
   real sweep sent the batch (tx confirmed), escrow settled
   (lifecycle 7), payee paid, bond returned, escrow balance 0, and
   a second sweep found nothing to do.
- Gas (same temp harness as round 5, deleted after measuring):
  create no-arbiter 133,359 (-4,493); with-arbiter 160,501 (+118);
  with backup 183,286 (+118); with backup + bond 183,388 (+118);
  full arbiter flow 491,644 (+702 — the create branch plus the two
  extra `DisputeResolved` data fields, 512 gas of LOG data);
  extended flow 724,910 (+1,252 — same two causes, two
  resolutions). `finalizeMatured` batch of 3: 148,461 gas (~49,500
  each). The flow deltas vs the recorded round-5 figures are +102
  / +78 gas of harness noise (the creates reproduce exactly; the
  flows were re-measured on the same harness for both rounds, so
  the round-5-vs-6 deltas above are the apples-to-apples numbers).
- Mutation proofs — BOTH sides of the forfeit-split rule are now
  deterministically covered, not just the primary side: (a) with
  `_settleBond` forced to always forfeit in the timeout path
  (`forfeitBond = true` in resolveDisputeTimeout), the fuzz
  invariant `invariant_BackupTimeoutNeverForfeitsPrimaryBond`
  FAILS on the first check (the backup seed's own timeout in setUp
  sets the flag) — and the seed test + the backup reachability
  test fail with it; the primary invariant still passes, as it
  should. (b) Re-verified the round-5 primary mutation
  (`forfeitBond = false`): `invariant_PrimaryTimeoutForfeitsBond`
  FAILS on the first check, backup invariant still passes. The
  contract was restored byte-identical after each mutation
  (md5-verified, diff clean, `forfeitBond = !escrow.challenged`
  back in place), and the full suite is green again.
- One test bug caught during the build (mine, not the contract's):
  the mixed-list skip test settled its already-settled escrow
  AFTER the 3-day warp, past its 1-day deadline — `deliver`
  reverted "Deadline passed". The setup was reordered (settle
  before the warp), not the contract.
- One build bug caught during the build (mine, not the contract's):
  `scripts/keeper.sh` had an apostrophe in a `${VAR:?message}`
  expansion ("keeper's"), which bash parses as an unterminated
  quote and ate the rest of the file. Fixed to "keeper private
  key"; `bash -n` clean.
- Note for the push: the app ABI (`arc/app/abi.json`) is stale
  relative to even the round-2 contract (it still lists the old
  BondReturned/BondForfeited events) — it must be regenerated from
  the round-6 build artifact at push time. Round 6 changes the ABI
  further: `DisputeResolved` gains two fields, plus the new
  `finalizeMatured` function and `MaturedResolutionsFinalized`
  event.

## Round 7 (Oct 28, 2026): two Grok round-6 improvements — keeper logging + batch cap

Both items. 153/153 forge tests pass (151 + 2 new). V1 untouched
(0 arbiter hits in the v1 contract). No push — rounds 3 + 4 + 5 + 6
+ 7 push together after the round-7 Grok re-review, on top of head
`f1ce32ec` (round 2).

1. **Keeper logs what it finalized** — after each batch the keeper
   fetches the mined receipt (`cast receipt --json`) and decodes
   its logs with python3 stdlib: the `MaturedResolutionsFinalized`
   event gives the batch count, the `Released` / `Refunded` events
   give the exact finalized ids in log order (id is the first
   indexed topic; topic0 hashes are hardcoded from
   `cast keccak`). The count is cross-checked against the ids
   list; a mismatch prints a WARNING. If the receipt cannot be
   fetched or decoded, the keeper falls back to printing the tx
   hash — logging never fails a sweep. `--dry-run` now previews
   per id: one `cast call finalizeMatured([id])` per candidate,
   which IS the on-chain maturity decision, so the preview lists
   precisely what the real sweep would settle. Verified live
   against local Anvil (round-7 contract): dry-run previewed
   "would finalize 1: ids 0", real sweep logged "finalized 1:
   ids 0 (tx 0xfc2c...)", escrow settled (lifecycle 7), payee
   paid 0.5 ether, escrow balance 0, second sweep idle. Plus the
   not-yet-matured case on a second escrow: dry-run "would
   finalize 0", real sweep "finalized 0: ids (none)" and the
   escrow stays ChallengeOpen (9); after the warp the sweep logs
   "finalized 1: ids 1" and it settles. (The payee's Anvil balance
   reads 10000.4998... rather than 10000.5 because the payee paid
   gas on its own deliver transactions — the escrow paid the full
   0.5.)
2. **Batch cap** — `finalizeMatured` now requires
   `ids.length <= MAX_FINALIZE_BATCH` (public constant, 256) and
   reverts "Batch too large" above it, before the loop starts.
   256 is comfortably above the keeper's 100-id batches. Two new
   tests pin the boundary: a 256-id batch with one matured
   resolution finalizes it (255 nonexistent ids skipped), a 257-id
   batch reverts. The keeper's header now states the cap (default
   BATCH_SIZE 100 is under it) instead of the old "loop is
   unbounded" warning; the contract NatSpec says the same.
- Gas (temp harness rebuilt from the round-5 method, deleted after
  measuring; same harness for round-6 and round-7 code, so the
  deltas are apples-to-apples): create no-arbiter 133,359 → 133,359
  (0); with-arbiter 160,501 → 160,479 (-22); with backup 183,286 →
  183,286 (0); with backup + bond 183,388 → 183,388 (0); full
  arbiter flow 491,542 → 491,542 (0); extended flow 724,832 →
  724,921 (+89); `finalizeMatured` batch of 3: 150,953 → 150,979
  (+26 — the cap check itself). The -22 / +89 are dispatcher
  noise from the new `MAX_FINALIZE_BATCH` public getter shifting
  the function-selector dispatch (verified deterministic: two
  runs, identical figures). The rebuilt harness reproduces round
  6's recorded figures exactly for the four creates and within
  ~100 gas for the two flows (full flow 491,542 vs recorded
  491,644; extended 724,832 vs recorded 724,910) — the flow
  definitions were reconstructed from the round-6 record (full =
  arbiter-only create through immediate resolution; extended =
  backup resolving to the payer), since round 6's harness was
  deleted. The batch figure is the one gap: the rebuilt harness
  measures 150,953 on round-6 code while round 6 recorded
  148,461 — two independent setups (fresh contract, and inside
  the main test contract's seeded setUp) agree to within 3 gas,
  so the gap is a definitional difference in the deleted round-6
  harness (its batch composition is not recorded), not a code
  change; the +26 round-6→7 delta is the rigorous number.
- Mutation proofs re-run for round 7 (same method as round 6):
  (a) `forfeitBond = true` in resolveDisputeTimeout →
  `invariant_BackupTimeoutNeverForfeitsPrimaryBond` FAILS on the
  first check and the seed test fails with it; the primary
  invariant still passes. (b) `forfeitBond = false` →
  `invariant_PrimaryTimeoutForfeitsBond` FAILS on the first check;
  the backup invariant still passes. Contract restored
  byte-identical after each mutation (md5-verified,
  `forfeitBond = !escrow.challenged` back in place), full suite
  green again.
- Two build bugs caught during the build (mine, not the
  contract's): (1) the first contract edit left the NatSpec for
  MAX_FINALIZE_BATCH in place but omitted the constant
  declaration itself — caught on re-read before compiling.
  (2) The Anvil verification hit three script bugs, none in the
  keeper or contract: the remembered Anvil account-2/3 private
  keys were wrong (taken from the Anvil log instead); `forge
  create` without `--broadcast` only simulates (added the flag);
  and the part-2 deadline was computed from wall-clock time
  while the chain clock sat ~2 days ahead after part 1's warp
  ("Invalid deadline" — deadline now read from the chain's
  latest block). The keeper itself needed no fix: receipt decode,
  dry-run preview, and the zero-finalization branch all worked
  first try.
- Note for the push: the app ABI is still stale (see round 6) and
  must be regenerated from the round-7 build artifact at push
  time. Round 7 changes the ABI further: the new public constant
  `MAX_FINALIZE_BATCH` adds its getter; `finalizeMatured`'s
  behaviour is unchanged.

## Round 8 (Oct 28, 2026): three Grok round-7 improvements — disputeStatus view + explicit reentrancy guards + keeper gas docs

All three items. 158/158 forge tests pass (153 + 5 new). V1 untouched
(0 arbiter hits in the v1 contract). No push — rounds 3 + 4 + 5 + 6
+ 7 + 8 push together after the round-8 Grok re-review, on top of
head `f1ce32ec` (round 2).

1. **`disputeStatus(id)` — bond status + clocks in one call.** New
   public view returning `(uint256 bondAmount, bool bondStaked,
   uint256 arbiterTimeoutRemaining, uint256 challengeRemaining)`:
   the bond amount set at creation, whether the bond is currently
   held, and the two remaining dispute clocks — the same clock
   values `disputeClocks(id)` returns. `bondStaked` is true only
   while the bond is actually held (false before the stake, false
   again after return or forfeit on settlement). `disputeClocks`
   is refactored onto a shared internal `_disputeClocks(Escrow
   storage)` that both views call, so the two can never drift
   apart; its behaviour is unchanged. Five new tests pin the view
   across states: no bond (fresh, delivered, settled, nonexistent
   id — all zero), bond set then staked, escalated (14-day timeout
   clock, challenge 0), challenge open (2-day clock, bond held, 0
   at the boundary, cleared on finalization), and timeout forfeit
   (bond reads set-but-not-held after it). Verified live against
   local Anvil (round-8 contract, cast-driven, escrow
   `0x5FbDB2315678afecb367f032d93F642f64180aa3`): disputeStatus
   read at every stage — (0.1 ether, false, 0, 0) created, (0.1,
   true, 0, 0) staked, (0.1, true, 1209600, 0) escalated, (0.1,
   true, 0, 172800) challenge open, (0.1, true, 0, 0) after the
   2-day warp, (0.1, false, 0, 0) after the keeper sweep settled
   it; lifecycle 9 while ChallengeOpen, 7 after; escrow balance 0.
   Keeper dry-run said 0 before maturity and 1 after, the real
   sweep finalized 1: ids 0 (tx 0x29c483...). Per-escrow read only
   — the ChallengeOpen/matured-ids view stays held.
2. **Explicit `nonReentrant` on `deliver()` and the three create
   overloads.** Every state-changing external entry point is now
   guarded uniformly, including the ones that make no external
   calls today, so a future edit that adds one cannot silently
   open a reentrancy path. Behaviour is unchanged: no external
   calls exist in the newly guarded paths, and the full suite —
   including the three reentrancy tests — stays green. The cost
   is real and measured (see Gas): ~+22,480 per newly guarded
   call.
3. **Keeper header documents the exact gas-per-finalization and
   the Arc block-gas limit.** The old "~148,461 (~49,500 each)"
   is superseded — it came from a round-6 harness whose batch
   composition was never recorded. Fitted from measured 1/2/3-id
   batches (round-8 harness): no bond staked, base ~49,026 +
   ~25,087 per finalization (batch of 3 ~124,286; batch of 100
   ~2.56M; full 256 ~6.47M); fully bonded, base ~51,523 +
   ~39,341 per finalization (batch of 3 ~169,545; batch of 100
   ~3.99M; full 256 ~10.12M). Arc's block gas limit is 30,000,000
   — verified live against both RPCs (eth_getBlockByNumber,
   Oct 28, 2026; mainnet block 0x1af4eda, testnet block
   0x423e3fd, both gasLimit 0x1c9c380). A fully bonded 256-id
   batch is ~34% of a block, the default 100-id batch ~13% even
   fully bonded; the header says how to tune BATCH_SIZE and when
   to re-check the limit. No behaviour change to the keeper
   (header + BATCH_SIZE comment only; `bash -n` clean, and the
   keeper ran the Anvil verification sweep above).
- Gas (temp harness rebuilt from the round-5 method, deleted after
  measuring; same harness for round-7 and round-8 code, so the
  deltas are apples-to-apples; reproduces round-7 figures within
  ~25 gas): create no-arbiter 133,383 → 155,862 (+22,479);
  with-arbiter 160,503 → 182,985 (+22,482); with backup 183,310 →
  205,792 (+22,482); with backup + bond 183,412 → 205,894
  (+22,482); `deliver` 56,645 → 79,112 (+22,467); full arbiter
  flow 491,549 → 558,987 (+67,438); extended flow 724,955 →
  792,393 (+67,438) — each flow has exactly three newly guarded
  calls (create + two delivers), and 3 × 22,479 = 67,437, so the
  flow deltas are exactly the guard cost. `finalizeMatured`
  moves only +11 on every batch (x1 74,113, x2 99,198, x3
  124,286; bonded x1 90,864, x3 169,545) — dispatcher noise from
  the new `disputeStatus` selector. Per-finalization marginals:
  no-bond (99,198 − 74,113) = 25,085 and (124,286 − 99,198) =
  25,088 → ~25,087; base 74,113 − 25,087 = 49,026. Bonded
  (169,545 − 90,864) / 2 = 39,340.5 → ~39,341; base 90,864 −
  39,341 = 51,523.
- Mutation proof NOT re-run for round 8: no settlement logic was
  touched. The forfeit-split code (`_settleBond`,
  `resolveDisputeTimeout`, `resolveDispute`) is unchanged by this
  round — the contract edits are the `nonReentrant` guards on
  `deliver()`/creates, the new view, and the `disputeClocks`
  refactor onto a shared internal (view-only). The full suite
  passes, including the 4 dispute invariants and both seeded
  timeout tests that the round-6/7 mutations were designed to
  catch, so there is nothing new to mutate against.
- One build bug caught during the build (mine, not the
  contract's): the escalated-clocks test had a redundant tail
  that re-ran reject + cure + escalate on an escrow that was
  already escalated (it would have reverted on "Already
  delivered") — caught on re-read before the suite ran, and the
  test now covers only the escalated state (the challenge-open
  side has its own test).
- Note for the push: the app ABI is still stale (see round 6) and
  must be regenerated from the round-8 build artifact at push
  time. Round 8 changes the ABI further: the new `disputeStatus`
  view function; `disputeClocks` is unchanged.

## Round 9 (Oct 28, 2026): shared maturity rule + maturedIds view + permissionless autoFinalizeAfter

All items. 167/167 forge tests pass (158 + 9 new). V1 untouched
(0 arbiter hits in the v1 contract). Pushed to the public repo Oct 28,
2026, on top of head `f1ce32ec` (round 2) — rounds 3–9 together.

1. **Shared maturity guards** — new internal
   `_requireMaturedResolution(id)`: the escrow exists, is unsettled,
   has a challenge window open, and the CHALLENGE_PERIOD has passed.
   `finalizeResolution` and the new `autoFinalizeAfter` both use it.
   Guards REVERT, never skip — `finalizeMatured`'s skip rule stays
   separate, because a batch must not fail on one bad id.
2. **Permissionless `autoFinalizeAfter(id)`** — the single-id escape
   hatch when the keeper is offline (Grok improvement): exactly the
   same finalization as `finalizeResolution` (same guards, same
   `_finalizeResolution` path, same events, same bond return) under a
   name keepers and automation can call without building a batch. It
   reverts while the challenge window is still open ("Challenge
   period not ended") and on a second call ("Already settled"), so a
   resolution can never finalize twice.
3. **Shared maturity rule `_isMatured`** — one definition for
   `finalizeMatured` and the new view: exists, unsettled,
   challengeOpen, and `block.timestamp >= resolvedAt +
   CHALLENGE_PERIOD` (the boundary second counts, matching
   `finalizeResolution`'s `>=`). The view and the sweep can never
   disagree.
4. **`maturedIds(start, limit)` view** — the ids of resolutions ready
   to finalize, ascending, so a keeper never scans `lifecycleStatus`
   for every id up to `nextEscrowId`. Bounded scan (at most `limit`
   ids examined from `start`; page with start = last examined id +
   1). Ids at or past `nextEscrowId` are never returned; an empty
   range returns an empty array. Two passes (count, then fill) over
   the same `_isMatured` rule.
5. **Grok round-9 review (run by Chris, Oct 28, 2026): SOUND, no
   findings.** The verdict checks the round-9 machinery explicitly
   (view/sweep agreement, autoFinalizeAfter/finalizeResolution
   equivalence, no double finalization through any combination of
   the three paths, maturedIds correctness inside its scanned
   window including the boundary second) and all money-moving
   invariants (delivery before release, exactly-once settlement,
   credit-on-failed-payout, consistent deadline/review/cure/
   timeout/challenge edges, bond returned on every settlement
   except primary-timeout forfeit, no release/refund while
   escalated or challenge-open). Improvements: ABI regen at push
   time (done in this push); a NatSpec cross-reference on
   maturedIds pointing at _isMatured/finalizeMatured (applied,
   comment only — suite re-run green, no logic change). No new
   features worth the cost.
- Fork demo (Anvil fork of Arc mainnet, Oct 28, 2026, `fork-demo.sh`):
  deploy 3,728,799 gas; flow A (0.27 escrow create→deliver→release)
  234,131; flow B (0.10 split 50/50, reverting recipient credited
  0.05 and withdrawn) 127,593; flow C (0.05 reject→cure→release,
  settled true, rejectedOnce stays true) 326,774. Full demo (deploy
  + A + B + C) 4,417,297 gas ≈ 0.1104 USDC at 25 gwei — the $0.50
  funding still covers deploy + demo with wide margin.
- Note for the push: the app ABI is regenerated from the round-9
  build artifact in this push (rounds 6–9 changed it:
  DisputeResolved bond fields, finalizeMatured,
  MAX_FINALIZE_BATCH getter, disputeStatus, autoFinalizeAfter,
  maturedIds). The app UI is unchanged — v1 base flows work on V2
  through the overloads; arbiter buttons are a later UI question.
  `fork-demo.sh` in the repo is replaced with the V2 version (the
  round-2 script targeted the round-2 contract); `scripts/keeper.sh`
  is added (the keeper from rounds 6–7).

## Fixed artifact — maturedIds overflow fix + three-reviewer re-review (Oct 28, 2026)

- **The fix** (contracts/LamplightEscrow.sol, maturedIds only): the
  round-9 code computed `end = start + limit` and then guarded with
  `if (end < start || end > nextEscrowId)`. Under checked arithmetic
  the addition itself reverts on overflow before the guard can run,
  so a keeper paging with a huge limit saw a panic instead of the
  bounded page. The fix bounds the range BEFORE adding: end starts
  at nextEscrowId, and only when start is below nextEscrowId and
  limit is below the remaining range does end become start + limit
  (which then cannot overflow). Paging behavior is otherwise
  unchanged. No signature, event, or struct changed; app ABI
  unchanged (51 entries, verified against a fresh pinned-0.8.24
  build).
- **Regression test** (test/LamplightEscrow.t.sol,
  testMaturedIdsOverflowInputsDoNotRevert): overflowing limit returns
  the capped page, overflowing start returns empty, never reverts;
  boundary pins with more than one escrow (limit exactly the
  remaining range; start exactly nextEscrowId when nextEscrowId > 1).
  Fail-before proof: the new test against the pre-fix contract fails
  with panic 0x11 (arithmetic overflow). Fixed contract md5
  8d392b64a51b617f6cd01a39e28a1d66. Suite 168/168.
- **Re-review verdicts** (all run by Chris, Oct 28, 2026): Grok
  SOUND, no findings. Claude SOUND, nothing blocks Sunday — 1 Low
  (design, not a blocker): resolveDisputeTimeout after reEscalate
  refunds the payer in full when a silent backup overturns a primary
  payee win (pinned by testBackupArbiterTimeoutReturnsBond,
  deliberate); fix for the post-deploy round: when challenged,
  settle per the stored resolvedToPayee. 1 Informational (docs):
  "Batch too large" missing from the header revert-string list —
  left as-is, since a comment edit changes the metadata hash on a
  frozen candidate. ChatGPT SOUND, no findings (source-based
  verdict: ChatGPT and Claude could not run Foundry in their
  sandboxes; the suite/md5 numbers were verified against the pinned
  build).
- **Post-deploy queue** (unchanged by this fix; the fix touches no
  bond, escalation, or settlement logic): the bond-liveness Low
  (staked arbiter bond frozen if an escrow never escalates and the
  payer goes silent); the timeout-path pair (Claude's Low +
  permissionless resolveDisputeTimeout); single-pass maturedIds
  (gas-only view optimization); timeoutMatured batch; paged
  getEscrows; the revert-string list gap; the >256-ids keeper doc
  note (keepers must chunk before finalizeMatured); finalizeMatured
  gas sizing at 256 matured escrows; fuzz paging property tests.
- **Prior Studio state** (round 9): 157 Studio Foundry tests passing,
  Arc testnet deployment 0xb6a3dacec470d04fc48a93a163f8f0d01330575c
  (tx 0x1579ac1697694be1fa90f5a4c9402971ef5acd6d73cf0e464b3ffed3a2d17bae).
  Studio re-verify to the fixed artifact is next; that testnet
  deployment does not match the fixed contract.

## Tests

- **168 passed, 0 failed** (`forge test` at the repo root, ~2s): v1's 85 tests
  unchanged (the two-argument `createEscrow` and the invariant handler
  work unmodified through the overloads) plus 14 arbiter tests (round 1)
  plus 29 round-2 unit tests plus a 2-invariant dispute suite plus 8
  round-3 tests — 4 disputeClocks (non-escalated zero, escalation
  countdown + boundary, challenge countdown + boundary, restart on
  re-escalation), 2 BondSettled event tests (returned + forfeited,
  asserted from the raw logs since the bond event is never first in
  its call), the forfeit-split unit test (backup timeout, balances +
  event), and the handler-reachability test — plus a 3rd dispute
  invariant (backup timeout never forfeits the primary's bond) —
  plus 3 round-4 tests: 2 DisputeTimedOut bond-outcome tests
  (primary forfeit + backup return, asserted from the raw logs and
  cross-checked against BondSettled in the same call) and the
  primary-timeout handler-reachability test (balances + BondSettled
  event) — plus a 4th dispute invariant (primary timeout forfeits
  the bond) — plus 1 round-5 test: the seeded primary timeout
  pinned (flag set, exactly one primary timeout, seeded escrow
  settled, handler 100.001 ether, arbiter 9.999 ether) — plus 9
  round-6 tests: 3 DisputeResolved bond-field tests (immediate
  with bond, deferred 0/false, no bond 0/false), 5 finalizeMatured
  tests (batch of 3, mixed-list skip, empty batch, duplicate id,
  no-bond matured), and 1 seeded backup timeout test (flag set,
  exactly one backup timeout, seeded escrow settled, handler
  100.001 ether, arbiter 9.999 ether) — plus 2 round-7 tests:
  the finalizeMatured batch cap (passes at 256 with one matured
  resolution among skipped ids, reverts "Batch too large" at 257)
  — plus 5 round-8 tests: disputeStatus across states (no bond
  zero incl. nonexistent id, bond set then staked, escalated
  14-day clock, challenge open 2-day clock + boundary + cleared
  on finalization, timeout forfeit reads set-but-not-held) — plus 9
  round-9 tests: maturedIds across states (matured, in-window,
  escalated-but-never-resolved, settled, nonexistent, empty range,
  past-end start, limit paging, boundary second), view/sweep
  agreement (every id maturedIds returns is finalized by
  finalizeMatured, and afterwards maturedIds is empty),
  autoFinalizeAfter happy path, reverts (window open, already
  settled, nonexistent id), and mixed finalization (one id via
  autoFinalizeAfter, one via finalizeMatured, one via the batch).
  Forge counts each invariant campaign as one test, so the suite
  total is 168 (164 main-contract unit tests, including both seed
  tests + the maturedIds overflow regression test, + 2
  handler-reachability unit tests + 1 balance invariant
  campaign + 1 dispute invariant campaign carrying 4 invariants).
- Gas (round 8, measured Oct 28, 2026, not re-measured for round 9 — round 9 changes no settlement logic; see the round-9 fork-demo figures for deploy + demo gas, first create in a fresh test, `gasleft()` delta, `start` read BEFORE `vm.prank` — the prank itself costs ~4,973 gas and must sit outside the measured span): `createEscrow` 155,862 gas with no arbiter; 182,985 with an arbiter; 205,792 with arbiter + backup arbiter (no bond); 205,894 with arbiter + backup + bond. Full arbiter flow (create+deliver+reject+cure+escalate+resolve) 558,987 gas. Extended flow (bond + backup + challenge + backup resolution) 792,393 gas. `finalizeMatured` batch of 3: 124,286 gas. (Round-6 figures for comparison: 133,359 / 160,501 / 183,286 / 183,388; flows 491,644 / 724,910; batch of 3: 148,461 — see the round-6/7/8 sections above for the dated measurements and deltas.)
- One test-expectation fix during the round: the handler's balance
  after a primary timeout is 100.001 ether, not 100 — it funded
  0.01 and gets back 0.01 refund + 0.001 forfeited bond (the bond
  is the arbiter's stake, not the handler's). The test was
  corrected, not the contract.

## Next steps

- Gate closed: the fixed artifact was reviewed by all three reviewers
  (run by Chris, Oct 28, 2026): Grok SOUND, no findings; Claude
  SOUND, 1 Low (design, not a blocker) + 1 Informational, both
  post-deploy; ChatGPT SOUND, no findings. Reviews are run by Chris
  himself and sent to Ellis — Ellis does not run reviewer bots.
- Push: this commit (fixed artifact: maturedIds bound-before-add fix
  + overflow regression test with >1-escrow boundary pins; contract
  md5 8d392b64a51b617f6cd01a39e28a1d66; suite 168/168; app ABI
  unchanged, 51 entries).
- Deploy: V2 is the deploy line and the deploy candidate (SOUND
  commit). Studio re-verify to the fixed artifact is next (contract
  replaced in full, byte-identical; fresh testnet deployment to
  follow). Sunday Nov 1 window: mainnet deploy + demo + video +
  DoraHacks submit before 10:59 PM CDT (rules as shown read Nov 1,
  11:59 PM ET).
