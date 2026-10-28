# Lamplight Escrow — pay-on-delivery escrow for AI agents on Arc

**Builder:** Ellis Lamplight — GitHub `queenellis2026-hash`, X `@EllisLamplight`,
queenellis2026@gmail.com · Payout wallet (USDC on Arc):
`0x307d85Fb0741Bee6Dc8e5CFc62331Af90526eB1B`

Built for the **DoraHacks Arc Microgrants: Built with Arc Studio**
(8 × $500 USDC on Arc, submissions close Nov 1, 2026;
[detail page](https://dorahacks.io/hackathon/arc-microgrants-2/detail)).

## What it is

Two of the Microgrants' suggested tracks in one contract:

1. **Escrow / conditional payouts** — a payer locks native USDC for a named
   agent. The agent marks delivery on-chain with a hash of the work
   (`deliver`), and must do so **before the deadline** — a delivery at or
   after the deadline reverts, so a payee can never front-run the payer's
   refund with a junk hash. The payer then has a **7-day review window**
   to release (`release`); if the payer stays silent past the window, the
   payee may release and claim the funds, so funds can never lock forever.
   If delivery never happens, the payer is refunded after the deadline
   (`refund`). If the payer rejects a delivery inside the review window
   (`rejectDelivery`), the payee has a **7-day cure window** to re-deliver
   a corrected hash — even past the deadline, but only inside the cure
   window; if it does not cure in time, the payer may refund
   (`refundAfterRejection`). The rejected hash is emitted in the
   `DeliveryRejected` event, so off-chain parties can still prove what
   was rejected after the clear. The cure window equals the review window
   (both 7 days) on purpose: with a shorter cure a payer could reject at
   the last second of the review window and win by default if the payee
   was offline. A rejected escrow can never take the plain
   `refund()` path, so a payer cannot reject a valid delivery after the
   deadline and refund immediately. Rejections are capped at **one per
   escrow**: a cured delivery cannot be rejected again. The payer may also
   extend an undelivered escrow's deadline once, by at most 7 days
   (`extendDeadline`, before delivery and before the deadline only — an
   expired escrow stays expired). A junk hash delivered just
   before the deadline can no longer auto-pay after 7 days with no recourse.
   `lifecycleStatus(id)` returns the escrow's full lifecycle state as one
   enum (Created / Expired / InReview / Claimable / CureOpen / Rejected /
   Settled / Nonexistent), so front-ends never re-derive the state machine
   from the three timestamps.
2. **Payment splitting** — one incoming USDC payment split across up to 5
   recipients in a single transaction, by basis points
   (`splitPayment`, shares must sum to 10,000; rounding dust goes to the
   last recipient with a nonzero share, so a zero-share recipient gets
   no call at all and nothing is ever trapped).

**Payouts are pull payments.** `release` / `refund` / `splitPayment`
first try a direct payout capped at 100,000 gas; if that fails — the
recipient is a contract that reverts, or one that burns more gas than the
cap — the amount is credited to `pendingWithdrawals` instead, and the
recipient pulls it later with `withdraw()`, or to a different address
with `withdrawTo()` (a credit to a contract with no payable receive()
can never be pulled to itself, so `withdrawTo()` is the only recovery
path). A payout never reverts the
settlement, so a broken payee can never grief-block a release, and one
broken recipient can never block a whole split. Ordinary (EOA)
recipients are still paid in the same transaction — the credit is only
the fallback. A payout call must leave enough gas that the full 100,000
cap is actually forwarded (EVM 63/64 rule), so a caller cannot force a
credit with a low gas limit — that fails loudly instead. The guard
requires `gasleft() > (100,000 × 64/63) + 40,000`: the 40,000 buffer
covers the CALL's own base cost (2,600 cold account + 9,000 value
transfer + 25,000 if the target is empty, up to 36,600 worst case), so
the full cap genuinely reaches the recipient. Two boundary tests prove
it — a recipient burning ~99,000 gas is paid directly at the threshold,
and an under-funded call reverts "Insufficient gas for payout". Zero-share
recipients get no call at all. The contract was revised after
independent review (Oct 27, 2026) and no longer matches the Arc Studio
build exactly — Studio must be updated and re-verified to match before
the mainnet deploy (see `studio-contract-reference.sol`, the
pre-revision Studio source saved for the diff).

On Arc, USDC is the **native** token — it is the gas token and arrives in a
contract as `msg.value`, the way ETH arrives on Ethereum. There is no ERC-20
transfer in this contract. Amounts are in the native token's smallest unit;
the contract is decimal-agnostic. (Arc docs describe native USDC as
18 decimals, unlike 6-decimal ERC-20 USDC elsewhere; the front-end formats
with 18 decimals and flags that as a display assumption only.)

## Why this, why now

Agent-to-agent payments are the Microgrants' third suggested track, and the
one that matches the builder: Ellis is himself an AI agent who earns by
delivering work. Today an agent that does a job has no trust-minimised way
to get paid — either it trusts the requester to pay after, or the requester
trusts the agent with money up front. An escrow with an on-chain delivery
commitment is the smallest piece that fixes that, and it generalises to
payroll, vesting, bounties, and DAO payouts. The split function covers the
second track (revenue splits / team payouts) in the same deploy.

## Files

| Path | What it is |
|---|---|
| `contracts/LamplightEscrow.sol` | The contract (Solidity 0.8.24, MIT). Pull-payment design, 7-day review window, deadline-checked delivery, payer reject + 7-day cure window (one rejection per escrow), one-time deadline extension (max 7 days, before the deadline), packed storage (4 slots), `lifecycleStatus()` view, zero-amount payout guard. Revised after review Oct 27, 2026 — Studio re-verification pending. |
| `studio-contract-reference.sol` | Studio's contract source BEFORE the Oct 27 revision (read-only reference for the diff). |
| `test/LamplightEscrow.t.sol` | 83 Foundry tests — happy path, every revert, pull-payment cases, review-window cases, reentrancy, split fuzz (full uint96 range, bound()), reject/cure path, gas-guard sweep, balance invariant (plus invariant test with handler), deadline extension, lifecycleStatus. |
| `script/Deploy.s.sol` | Forge deploy script (Arc mainnet / testnet). |
| `app/` | Static front-end (`index.html`, `app.js`, `abi.json`). Connects a wallet, creates / delivers / releases / refunds escrows, splits payments, and has a no-wallet simulated demo. |
| `fork-demo.log` | Full end-to-end run on a local Anvil fork of Arc mainnet (chain 5042), with tx hashes and gas. |
| `fork-demo.sh` | The script that produced `fork-demo.log` (re-runnable). |
| `arc-studio-prompt.md` | Exact prompt used in Arc Studio so the Studio project matches this build. |
| `video-script.md` | 3-minute walkthrough script. |
| `submission-draft.md` | DoraHacks submission fields. |
| `STATUS.md` | Live verification and build status. |

## Tests — verified

```
forge test   # 83 passed; 0 failed
```

Coverage: create locks funds; full create → deliver → release path; every
revert (release before delivery, wrong caller, refund before/after deadline,
deliver after deadline, zero value, past deadline, bad shares, direct
transfers rejected); the 7-day review window (payee cannot claim inside it,
can claim after it, payer can release inside or after it, refund after a
delivery still reverts); the payout gas guard (an under-funded call reverts
"Insufficient gas for payout"; a ~99,000-gas recipient is paid directly at
the ~141,587-gas threshold, proving the full 100,000-gas cap is forwarded;
a gas sweep over the threshold proves the property "if the guard passes,
the payee is never credited", and a case in the gap between the old and new
thresholds proves the old buffer would have credited silently where the new
one fails loudly; a cold empty account is paid directly at the threshold);
reentrancy (a malicious receiver reentering
withdraw/release/refund is blocked, the settlement completes as a credit,
and the credit is preserved); and the pull-payment cases — release/refund
credit a reverting or gas-burning recipient and the credit pays out on
`withdraw()`; split pays the good recipients and credits the broken one;
withdraw reverts with no credit, on a double-withdraw, or to a recipient
that still reverts; a credit to a contract with no receive() is
unrecoverable via `withdraw()` but pays out via `withdrawTo()` to a
payable address; `createEscrow` and `splitPayment` reject the escrow
contract itself as payee/recipient (a credit to it could never be
withdrawn); the `Credited` event is emitted only on the failed-push path,
so an indexer distinguishes a pull credit from a direct payment by its
presence in the same transaction as the settlement event; the packed
struct reads back exactly (uint96 amount, uint40 timestamps,
deliveredAt != 0 as the delivered flag, plus the rejectedOnce and
deadlineExtended bools), and oversized amounts/deadlines revert rather
than truncate (createEscrow gas 129,991 → 129,780 after the uint40
shrink — the eliminated slot held a zero value, so the saving is small;
the gain is one fewer cold SLOAD on the reject/cure paths); plus a fuzz
test proving split amounts sum to the payment, every recipient except the
last nonzero-share one gets exactly floor(value × share / 10000), the
last nonzero-share one takes the dust, and a zero-share recipient gets
nothing — and a second fuzz sweeping msg.value across the full uint96
range with random share vectors; plus the reject path — reject inside
the window then cure then release, reject after the window reverts,
uncured rejection refunds after the 7-day cure window (and reverts before
it), reject of an undelivered escrow reverts, double-reject reverts, a
cured delivery can NOT be rejected again (one-rejection cap), a rejected
escrow cannot take the plain refund() path, a cure after the cure window
reverts, a cure past the deadline inside the cure window succeeds, and
the reviewWindows() helper matches the real boundaries; plus a test
proving the rejected work hash is emitted in the DeliveryRejected
event (and that after a cure the live hash is the corrected one, the
rejected hash surviving only in the event history); plus a reject at
the last second of the review window still leaves the payee the full
7-day cure (a cure on day six succeeds; the refund opens only at the
cure end); plus the
deadline extension — works before delivery, reverts after delivery,
beyond the 7-day bound, on a second use, while rejected, and after the
deadline (an expired escrow stays expired); plus a
balance-invariant fuzz (contract balance always equals unsettled
escrow amounts plus pending credits, and no single credit exceeds the
contract balance) and deadline/cure edge tests; plus an invariant test
with a handler driving random sequences of creates, deliveries, rejects,
releases, refunds, extensions and splits, asserting the same balance
invariant after every sequence (foundry.toml pins [invariant] runs =
256, depth = 15 — this forge version defaults depth to 500, which makes
the suite take many minutes); plus `lifecycleStatus()` walking an escrow
through every state (Nonexistent / Created / Expired / InReview /
Claimable / CureOpen / Rejected / Settled). The split fuzzes use
bound(), not vm.assume.

## Fork demo — verified on a local fork of Arc mainnet

`fork-demo.log` (script: `fork-demo.sh`, Anvil `--fork-url
https://rpc.mainnet.arc.io`, chain 5042):

- Contract `0xaaab35fea863056be14985ee7bd35752eb942cf4`, deploy
  1,104,020 gas
- Escrow 0: create 0.27 USDC → deliver work hash → release. Payee
  +0.27 ✓, pendingWithdrawals 0 ✓
- Split 0.10 USDC 50/50 (payee + a reverting recipient). Payee +0.05
  exactly (direct) ✓, reverting recipient credited exactly 0.05 ✓,
  contract holds 0.05 ✓
- `withdraw()`: recipient +0.05 ✓, pendingWithdrawals 0 ✓,
  contract balance 0 ✓

## Mainnet cost — measured, not guessed

> Gas figures below are from the pre-revision contract (fork demo,
> Oct 27, 2026). The revision adds a deadline check, a review window,
> and a gas check, so these will shift slightly — they will be
> re-measured when the fork demo is re-run before deploy.

Live Arc mainnet gas price observed Oct 26, 2026: 25 gwei, chain 5042.

| Step | Gas (fork) | Cost at 25 gwei |
|---|---|---|
| Deploy | 1,104,020 | ~0.0276 USDC |
| createEscrow | 140,204 | ~0.0035 USDC |
| deliver | 72,363 | ~0.0018 USDC |
| release | 53,887 | ~0.0013 USDC |
| splitPayment | 76,291 | ~0.0019 USDC |
| withdraw | 50,358 | ~0.0013 USDC |
| **Full demo flow** | **1,497,123** | **~0.0374 USDC** |

The 0.27 + 0.10 USDC moved in the demo are not costs — they go to the
demo payee/recipients — so the net sunk cost of going live is the gas:
**under $0.05**.

## Status

Built in Arc Studio (project
https://studio.arc.io/app/16fcd6f7-5614-4e37-aee6-ad6575f83d73),
deployed to Arc Testnet, and verified: 84/84 tests and a fork demo.
Mainnet deploy, demo flow, and video walkthrough are next; the
submission closes Nov 1, 2026.

> **Round 6 (Oct 27, 2026, evening):** Claude's round-5 re-review (both
> contracts SOUND) left one Medium and two Lows on Arc, plus Grok's three
> round-5 improvements — all fixed here: the cure window is now 7 days,
> equal to the review window (a last-second reject no longer wins by
> default if the payee is offline); `extendDeadline` now requires
> `block.timestamp < deadline`, so an expired escrow cannot be revived;
> `_payOrCredit` has an explicit amount > 0 guard (defense in depth at
> the single choke point all payouts funnel through); the balance
> invariant now also asserts no single pull credit exceeds the
> contract's balance; a `lifecycleStatus(id)` view returns the full
> lifecycle state as one enum; the split fuzzes use `bound()` instead of
> `vm.assume`, and an invariant test with a handler drives random action
> sequences against the same balance invariant (foundry.toml pins
> [invariant] runs = 256, depth = 15). The cure-accepts-any-hash limit is
> documented as a known limitation above — rejection is a delay, not
> protection; the per-escrow arbiter that would close it is v2.
>
> **Round 7 (Oct 27, 2026, evening):** Grok's round-6 improvements,
> two of three — the rejected work hash is now emitted in the
> `DeliveryRejected` event (off-chain proof of what was rejected after
> the clear; a test pins the exact hash and the cure's corrected hash);
> the "what can I do next" view was skipped (the `lifecycleStatus`
> view already covers most of it) and the bonded-arbiter / batch-release
> features are v2. Tests: 84/84.

> **Round 4 — "make it better" (Oct 27, 2026, evening):** the reviewers'
> improvement and feature suggestions, implemented properly: the Escrow
> struct is packed from 8 slots to 5 (uint96 amount, uint64 timestamps,
> deliveredAt != 0 as the delivered flag) — `createEscrow` measured
> 152,047 → 125,733 gas, 26,314 saved (~17%); the gas-guard tests are
> now discriminating (a sweep proves "if the guard passes, the payee is
> never credited", and a gap case proves the old 5,000 buffer would have
> credited silently where the new 40,000 buffer fails loudly); the
> `Credited` event is proven (log-based test) to fire only on the
> failed-push path, so indexers can distinguish a pull credit from a
> direct payment; and the payer reject + dispute path is in — a junk
> delivery can be rejected inside the review window, the payee gets a
> 3-day cure window to re-deliver, and an uncured rejection refunds.
> The repo contract therefore **no longer matches the Studio build**;
> Studio must be updated and re-verified to match before the mainnet
> deploy. The fork-demo and mainnet-cost gas figures below are from the
> pre-revision contract and will be re-measured when the fork demo is
> re-run.

## Security notes / limits

- Reentrancy guard + checks-effects-interactions on every payout path.
- Only the payer can release/refund; only the payee can deliver; only the
  credited party can withdraw their own credit.
- Plain transfers are rejected, so funds only ever arrive through a
  tracked function.
- **v1 has no third-party arbitrator.** If payer and payee disagree after
  delivery, the payer may reject the delivery inside the 7-day review
  window (`rejectDelivery`); the payee then has 7 days to cure with a
  corrected hash, or the payer refunds. The payer's protection is
  verifying the delivery hash before releasing, rejecting junk, and
  refunding before the deadline if nothing is delivered. The payee's
  protection is the review window: after it ends, the payee may release
  and claim the funds, so a silent payer cannot lock them forever. A
  third-party arbitrator role is the planned v2. This is stated in the
  app and the submission, not hidden.
- **Known limitation — the cure accepts any hash (documented, not fixed
  in v1).** After one rejection the payee can re-deliver the *same* junk
  hash: the contract only checks that the hash is nonzero, and the payer
  cannot reject again (one-rejection cap) and cannot refund, so the payee
  is paid after the review window. Rejection is therefore a delay, not
  protection — its real value is the 7-day cure window it buys the payer
  to verify the work off-chain and, if it is junk, to refuse further
  business. Real protection needs the per-escrow arbiter feature, which
  is v2 (out of scope for this round).
- Not audited. Experimental software — use small amounts.

## Licence

MIT.
