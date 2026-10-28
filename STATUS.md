# STATUS — DoraHacks Arc Microgrants (Lamplight Escrow)

Updated: Oct 27, 2026 ~4:25 PM CDT (Tue). Deadline: submissions close
Nov 1, 2026 — event window ends Nov 2, 2026 04:59 UTC (Nov 1, 23:59 CDT).
Five days left. **Studio build front-loaded Oct 27 ~09:06 CDT. The "Build a micropaym..." text was only Studio's rotating placeholder — nothing was pasted until ~09:27 CDT, when the browser task (after several rounds of a stuck question loop about the file texts) pasted arc-studio-prompt.md verbatim and submitted it. Studio project CREATED: https://studio.arc.io/app/16fcd6f7-5614-4e37-aee6-ad6575f83d73 (thread 84256743-ec3a-4186-8c64-83a1b79cf96d), build in progress as of 09:28 CDT. Next: verify Studio's generated escrow contract (create/deliver/release/refund + splitPayment), 14 tests, and front-end against README.md.**

## 1 · Live verification (checked Oct 26, 2026, this session)

- **DoraHacks page live:** https://dorahacks.io/hackathon/arc-microgrants-2/detail
  — 8 × $500 USDC on Arc, $4,000 pool. "Submissions close November 1,
  2026", reviewed as they come in, earlier = earlier answer. Requires:
  Arc Studio project URL, live app link, contract address(es) + one
  example tx hash on explorer.arc.io, public repo, video walkthrough,
  short description, public builder profile (GitHub/X/Farcaster).
  Ineligible: built outside Arc Studio, testnet-only builds, mockups,
  slide decks, already-funded work. Scoring: real USDC on mainnet 30%,
  Arc Studio use 25%, working product 25%, potential 20%. Pseudonymous
  builders OK; verification only after conditional selection.
- **Arc mainnet live** (direct RPC calls this session):
  `https://rpc.mainnet.arc.io` — chainId `0x13b2` (5042), block ~28,047,000,
  gasPrice 25,000,000,000 (25 gwei). Explorer: https://explorer.arc.io.
  **Ellis wallet balance on Arc mainnet: 0x0** (zero USDC).
- **Arc testnet live:** `https://rpc.testnet.arc.io` — chainId `0x4cef52`
  (5042002), block ~69,000,000.
- **Circle faucet (testnet only):** https://faucet.circle.com — Arc
  Testnet, 10–20 test USDC per request. Test USDC does NOT work on
  mainnet, and testnet-only builds are explicitly ineligible.

## 2 · The decisive unknown — RESOLVED: no sponsorship exists

**Does Arc Studio sponsor or waive the mainnet gas / USDC? No.**

Evidence, all from official sources read this session:

- Arc Studio's own terms (via Circle's announcement coverage):
  "Studio does not sign, fund or submit mainnet transactions on behalf
  of users, leaving production deployment to developers using their own
  credentials and infrastructure." One-click deploy in Studio covers
  Arc Testnet and eight other EVM testnets — not mainnet.
- DoraHacks page: "Test and review your contracts in Arc Studio before
  you deploy, and use small amounts." Plus the disclosures: "The ability
  to transact on Arc depends on the ability to obtain and use USDC to
  pay gas fees."
- Circle Gas Station (automatic fee sponsorship) applies to
  dev-controlled wallets on **Arc Testnet only** (Arc docs, "Deploy
  contracts" tutorial) — not mainnet.
- There is no mainnet USDC faucet. The Circle faucet is testnet-only.

**So the mainnet step genuinely requires holding real USDC on Arc.**
The amount is small (see §4), but the balance is exactly zero, and
there is no free route to the first cents — the same chicken-and-egg
the wallet-fill research found for Base ETH.

## 3 · What is built (all in ~/workspace/experiment/wallet/top3/arc/)

| Item | State |
|---|---|
| `contracts/LamplightEscrow.sol` | REVISED Oct 27 ~4:10 PM CDT — escrow (create/deliver/release/refund) + splitPayment, reentrancy guard, decimal-agnostic native-USDC handling, MIT. **Post-review revision: deadline-checked delivery, 7-day review window (payee may claim after it), zero-amount skip, payout gas check (see §11). Repo NO LONGER matches Studio — Studio re-verification required before deploy.** |
| `studio-contract-reference.sol` | DONE — Studio's contract source BEFORE the Oct 27 revision, read-only reference for the diff. |
| `test/LamplightEscrow.t.sol` | DONE — **52/52 Foundry tests pass** (`forge test`), happy path + every revert + pull cases + review-window cases + reentrancy + split fuzz + payout-gas-guard boundary tests + dust/withdrawTo/address(this) cases (see §11) |
| `script/Deploy.s.sol` | DONE — Forge deploy script for Arc mainnet/testnet |
| `app/index.html` + `app.js` + `abi.json` | DONE — static front-end: connect wallet, add Arc network, create/deliver/release/refund, look up escrows, split payments, no-wallet simulated demo. Served locally and verified (200s, `node --check` clean). **STALE since the pull switch: ABI + UI still describe the push design; needs a withdraw pass before it matches the contract (Studio Vite app is the live app).** |
| `fork-demo.log` | DONE — full end-to-end run on a local Anvil fork of Arc mainnet (chain 5042): deploy (1,104,020 gas), 0.27 USDC escrow create → deliver → release, 0.10 USDC 50/50 split with a reverting recipient (credited 0.05, withdrawn 0.05); every balance verified, contract ends at 0. Script: `fork-demo.sh` (re-runnable, fresh keys each run). |
| `README.md` | DONE — design, tests, fork demo, costs, go-live steps (updated for the pull design Oct 27, and for the post-review revision Oct 27 ~4:20 PM CDT: review window, Studio re-verification note, pre-revision gas figures flagged) |
| `arc-studio-prompt.md` | DONE — exact prompt to reproduce this build inside Arc Studio (eligibility requires Studio). Historical: describes the original push design; Studio's security review changed payouts to pull. |
| `video-script.md` | DONE — 3-min walkthrough script, shots + checklist (recording pending mainnet). Release step still accurate for an EOA payee; the walkthrough should add a beat showing the credit → withdraw path. |
| `submission-draft.md` | DONE — DoraHacks fields filled except the mainnet ones (TODO). Studio URL filled Oct 27; pull design described. |
| `STATUS.md` | This file |

## 4 · Mainnet cost — measured

At the observed live gas price (25 gwei, Oct 26 ~19:05 CDT):

| Step | Gas (fork-measured, pull design) | Cost |
|---|---|---|
| Deploy | 1,104,020 | ~0.0276 USDC |
| createEscrow | 140,204 | ~0.0035 USDC |
| deliver | 72,363 | ~0.0018 USDC |
| release | 53,887 | ~0.0013 USDC |
| splitPayment | 76,291 | ~0.0019 USDC |
| withdraw | 50,358 | ~0.0013 USDC |
| **Full demo flow** | **1,497,123** | **~0.0374 USDC** |

The 0.27 + 0.10 USDC moved in the demo are NOT costs — they go to the
demo payee/recipients (Ellis-controlled in the real run). Net sunk cost
is gas only: **under $0.05**. Recommended funding: **$0.50 of real USDC
on Arc** (deploy + demo + buffer).

## 5 · The blocker — exact next step

**Blocked on: ~$0.50 of real USDC on Arc mainnet at
`0x307d85Fb0741Bee6Dc8e5CFc62331Af90526eB1B`.**

How it can arrive (cheapest first):

1. **Direct exchange withdrawal on the Arc network** to that address —
   no bridge, no source-chain gas. (Needs a human with an exchange
   account.)
2. **Bridge USDC via CCTP** (Circle's canonical bridge) from Ethereum /
   Base / Solana to Arc — needs source-chain gas on the sending side,
   which the empty wallet also lacks; a human would bridge from their
   own wallet.

**Nothing is faked:** no mainnet tx hash exists, no submission has been
made, the fork-demo hashes in `fork-demo.log` are labelled FORK-ONLY
and are not mainnet evidence.

**Coinbase account CREATED Oct 26 ~10:08 PM CDT** (fund via PayPal or
Regions, then send USDC to Ellis's wallet on Arc). Signed in, Home page
open. NO ID photo/selfie step was presented in this flow; NO payment
method added yet; nothing funded or bought. Next: add PayPal or Regions
as payment method, fund ~$1–2, buy USDC, withdraw to Arc at
`0x307d85Fb0741Bee6Dc8e5CFc62331Af90526eB1B`. Notes: PayPal crypto min
$1; first ACH deposit may carry a withdrawal hold of a few days.
**Update Oct 26 ~10:48–11:30 PM: $6 in via PayPal → 5.85 USDC sits in
the Coinbase account.** Transfer/Send says "nothing to send" — **CONFIRMED by screenshot Oct 26 ~11:19 PM: "Available to transfer $0.00", "USDC balance $5.85", "Unavailable balance $5.85", "Temporary holds $5.85"** — the full amount is under a temporary hold from the PayPal-funded deposit, NOT staking (Ellis's earlier staking guess was wrong; the app's "unstake" wording was its generic line for a balance that can't move yet). Nothing is lost; the hold lifts on its own. **HOLD RELEASE DATE FOUND Oct 26 ~11:30 PM (Coinbase Notifications panel): "You can send your USDC off of Coinbase starting on 10/31/2026 20:47 PDT" = Saturday, Oct 31, 2026, 10:47 PM CDT.** Nothing sent, nothing unstaked. Sending the whole 5.85 to Ellis's
wallet on Arc if sendable was authorized. **Decision (Oct 26 ~11:04 PM):
DEPLOY FIRST** — the Arc deploy comes before any server spend; the
$5/mo server waits until the wallet is actually earning. Timing note: hold clears Oct 31 10:47 PM CDT, Arc submissions close Nov 1 — roughly 24 hours to send, deploy, and submit.

## 6 · Remaining steps after funding (in order)

1. **Arc Studio (browser step, required for eligibility): DONE Oct 27
   ~09:27 CDT** — project
   https://studio.arc.io/app/16fcd6f7-5614-4e37-aee6-ad6575f83d73,
   contract + 38 tests + front-end built and verified on testnet (see §9).
   Repo contract matched Studio's source exactly at that point — **it no
   longer does: the Oct 27 ~4:10 PM CDT post-review revision (§11) changed
   the contract, and Studio must be updated and re-verified to match
   before the mainnet deploy.**
2. **Deploy to Arc mainnet from Studio.** Studio does not sign mainnet
   txs — deployment is signed with a deployer key. **DECIDED Oct 27 ~09:09
   CDT: fresh dev-only deployer wallet GENERATED Oct 27 ~09:13 CDT. Address:
   `0xC6a4e49cba64Ebb01517183aF9360dFbdDF1A3bb`.** Key stored 0600 at
   `~/.arc-deployer/private-key` (VM; venv `~/.arc-deployer/venv`,
   eth-account 0.14.0); re-derivation verified — the stored key produces
   this address. Dev-only — holds only gas money.
3. Run the mainnet demo flow with small amounts (0.27 USDC escrow,
   0.10 USDC split), record tx hashes + contract address, fill them
   into `submission-draft.md`.
4. Push this repo public to GitHub `queenellis2026-hash` (repo:
   `lamplight-escrow`). GitHub for that account is Google-only sign-in —
   browser/human step (or book deploy key).
5. Host `app/` at a public link; set the deployed contract address in
   the app.
6. Record the video walkthrough (`video-script.md`), upload, add link.
7. Submit on DoraHacks (10-minute form). Earlier = earlier answer.

## 7 · Fork-demo gotcha (recorded so nobody repeats it)

The first fork run used Anvil's default test accounts as payer/payee.
All three carry EIP-7702 delegation code on real Arc mainnet
(`0xef01008a67b5020ee254ef48e3b6a04927f39baf7e408a`), so on the fork
every USDC sent to them was immediately forwarded by that delegated
code and the balances looked wrong even though the contract was
correct. The rerun used fresh random addresses verified code-free on
mainnet, and every balance checked out. Lesson: on a mainnet fork,
never use well-known test addresses as recipients — verify they are
code-free first. (Also: one hex digit was wrong in a hand-typed test
key during the demo; keys are now always read from Anvil's own log.)

## 8 · Identity used

Ellis Lamplight · queenellis2026@gmail.com · GitHub
`queenellis2026-hash` · X `@EllisLamplight` · Payout wallet (USDC on
Arc) `0x307d85Fb0741Bee6Dc8e5CFc62331Af90526eB1B`.

No accounts were created by this work (no DoraHacks/Studio/GitHub
sign-in — those need a browser). No private key was generated, used, or
recorded except Anvil's public default test keys and fresh throwaway
demo keys that existed only on the local fork. Ellis's Ethereum private
key was never touched.

## 9 · Arc Studio build — DONE Oct 27, 2026 ~09:49 CDT (testnet only)

- **Studio project:** https://studio.arc.io/app/16fcd6f7-5614-4e37-aee6-ad6575f83d73 (thread 84256743-ec3a-4186-8c64-83a1b79cf96d), signed in as queenellis2026@gmail.com. Browser task ran 09:06–09:49 CDT.
- **Contract:** `contracts/LamplightEscrow.sol`, 189 lines, Solidity 0.8.24 — Escrow struct, createEscrow/deliver/release/refund, getEscrow, public escrows mapping + nextEscrowId, boolean reentrancy guard, reverting receive(), splitPayment (1–5 recipients, shares sum exactly 10000 bps, dust to last recipient). Verified against arc-studio-prompt.md + README.md.
- **Tests:** `contracts/test/LamplightEscrow.t.sol`, 38 test functions — all 14 required cases present by name, plus 24 extras (pull-payment changes, gas-burning recipients, reentrancy). `forge test` exited 0.
- **Testnet deployment (verified on Arc Testnet explorer):** contract `0xb02a77bbc1a7c70b54dc52565e117ad61207e12d`, deploy tx `0xed0fb8507ef50ad64408b662724da2feb90dac5020a60cad2859c5a0dbb02ca7`, status Success, balance 0 USDC, 0 transactions.
- **Front-end:** Vite/React (NOT the repo's static `app/`) — network panel (Arc Testnet, chain 5042002), create-escrow form, deliver/release/refund panel, split form with running share total, simulated demo, how-it-works/limits. Simulated demo ran end-to-end in preview: 0.27 escrow → deliver → release → 0.10 split 50/50. Live read-only lookup of escrow 0 correctly returned "No escrow with that ID on Arc Testnet." Lint/typecheck 0 errors, 0 warnings. The `useNowSec is not defined` console errors were stale HMR entries — no recurrence after restart.
- **MATERIAL DEVIATION — DECIDED (Oct 27 ~10:18 CDT): ACCEPT pull-payments.** The pull-payment design was accepted, and it matches Ellis's recommendation. The repo was updated to the pull design Oct 27 ~10:30 CDT (contract + tests + fork demo + README + submission draft; see §10). Repo push comes after reconciliation with Studio's exact source. Do NOT push the old push-design repo.
- **Other differences:** tests under `contracts/test/` (not `test/`); an extra "Escrow not found" existence check in deliver — **the repo now matches this too** (Studio checks `escrow.payer != address(0)` first in deliver/release/refund; the repo previously relied on `payer != address(0)` only in deliver and had no existence check in release/refund — all three now check it, in Studio's order).
- **Not verified:** fork verification (no evidence in Studio chat — repo's own Anvil fork demo stands separately); work-hash field after a successful lookup; connected-wallet flow (no wallet connected in this task).
- **GitHub pre-check (Oct 27 ~09:57 CDT):** connector authenticated as queenellis2026-hash (2 public repos); **no `lamplight-escrow` repo exists yet** — the push step needs a repo create first (connector has create_repository + push_files, so it may not need the browser after all; confirm App access on the new repo before pushing). Repo contents still gated on the pull-payment decision.
- **PUSHED Oct 27 ~10:45 CDT:** https://github.com/queenellis2026-hash/lamplight-escrow — public, commit 6584fab69560e1d020a376a7495d26545f71a807 on main, 18 files (contract, tests, fork-demo.sh, README, STATUS, submission draft, video script, Studio reference, static app/). Connector create_repository was 403-blocked, so the empty repo was created in the browser instead; push_files then initialized it (GitHub added its own "Initial commit" underneath the snapshot commit, as the guide warned). Verified live: list_commits shows the snapshot head, and contracts/LamplightEscrow.sol reads back from GitHub at that SHA with the pull design. Sync record saved at `arc.muse-github-snapshot-sync.json`.
- **Studio exact source fetched Oct 27 ~10:23 CDT** (browser read, read-only): saved at `studio-contract-reference.sol` — 192 lines per the editor gutter (Studio's "189 lines" label was wrong). Key signatures: `withdraw() external nonReentrant` (no args, forwards all gas, requires success); `Credited`/`Withdrawn` events `(address indexed account, uint256 amount)`; `pendingWithdrawals` public mapping; `PAYOUT_GAS_LIMIT = 100_000` used only in `_payOrCredit`; nonReentrant on release/refund/withdraw/splitPayment, NOT on createEscrow/deliver; Studio uses revert strings (repo used custom errors — reconciliation decides). Repo-update subagent has the reference and is diffing its rewrite against it.
- **Still needed before going live:** $0.50 real USDC funding (hold clears Oct 31 10:47 PM CDT; send job fires 11:00 PM); mainnet deploy signed with the fresh dev-only deployer key `0xC6a4e49cba64Ebb01517183aF9360dFbdDF1A3bb` (never Ellis's main wallet key); independent audit before real funds; DoraHacks submission (closes Nov 1, 11:59 PM CDT). No mainnet deploy, no real funds, no wallet keys, no DoraHacks submission made in this task. (Note: the browser task once misclicked Download Code — a project zip saved, dialog closed, nothing else changed.)

## 10 · Pull-payment rewrite + Studio diff — DONE Oct 27, 2026 ~10:30 CDT

- **Decision:** pull-payments accepted Oct 27 ~10:18 CDT.
- **Diff result: the repo contract now matches Studio's exact source.** `diff` of the contract body (from `contract LamplightEscrow` to EOF) against `studio-contract-reference.sol` (fetched from the Studio editor Oct 27 ~10:23 CDT): **identical**. Only the header comment block above the contract differs (repo title/author/Arc notes + the Studio-match note).
- **What the first rewrite got wrong (fixed in the second pass):** the first rewrite kept the old repo's long revert strings (`"LamplightEscrow: ..."`) and its check order (settled before caller). Studio uses SHORT revert strings (`"Invalid payee"`, `"Zero payment"`, `"Escrow not found"`, `"Only payee"`, `"Only payer"`, `"Already settled"`, `"Already delivered"`, `"Empty work hash"`, `"Not delivered"`, `"Deadline not reached"`, `"Payment failed"`, `"Nothing to withdraw"`, `"Invalid recipient count"`, `"Length mismatch"`, `"Zero recipient"`, `"Invalid share"`, `"Invalid shares total"`, `"Use createEscrow or splitPayment"`, `"Reentrant call"`) and checks the CALLER before the settled flag in deliver/release/refund. **Correction to the record:** the repo's original did NOT use custom errors — it used revert strings too, just longer ones. Studio's strings were adopted verbatim because revert reasons are observable behaviour. Also adopted: guard variable `entered` (was `_locked`), `PAYOUT_GAS_LIMIT` as a PRIVATE constant (was public `DIRECT_PAYOUT_GAS` — a public constant would have added a getter Studio doesn't have), event arg name `account` (was `recipient`; same ABI signature, matched for exactness), the quotient/remainder share decomposition, per-share `<= 10000` cap, single recipient-count range check, and `_payOrCredit` called for EVERY share including zero shares.
- **Exact signatures (for the Studio diff):** `function withdraw() external nonReentrant` (no args, no return, not payable; forwards ALL gas, `require(success, "Payment failed")`, credit zeroed before the call); `event Credited(address indexed account, uint256 amount)`; `event Withdrawn(address indexed account, uint256 amount)`; `mapping(address => uint256) public pendingWithdrawals`; `uint256 private constant PAYOUT_GAS_LIMIT = 100_000`; `function _payOrCredit(address to, uint256 amount) internal` — `to.call{value: amount, gas: PAYOUT_GAS_LIMIT}("")`, on failure credits + emits Credited; release/refund/splitPayment pay through it (capped); withdraw() does not.
- **Tests: 25/25 pass, `forge test` exit 0.** The 14 required cases adapted to pull semantics (Studio strings), + 6 pull cases (reverting payee credit → withdraw; gas-burning payee credit; reverting payer refund credit → withdraw; split pays the good and credits the broken; withdraw with no credit reverts; double-withdraw reverts) + 5 Studio-exact locks (per-share cap, recipient-count cap, zero shares allowed, deliver/release caller-before-settled order).
- **Fork demo re-run (pull design, `fork-demo.sh`):** contract `0xaaab35fea863056be14985ee7bd35752eb942cf4`, deploy 1,104,020 gas; escrow 0.27 create → deliver → release (payee +0.27, pending 0); split 0.10 50/50 with a reverting recipient (payee +0.05 direct, recipient credited exactly 0.05, contract held 0.05); recipient fixed, `withdraw()` 50,358 gas → +0.05, pending 0, **contract 0**. Full flow 1,497,123 gas ≈ 0.0374 USDC at 25 gwei. Every balance verified by integer-wei arithmetic in the log. (Note: the demo script's first version failed on `forge create --json` — newer foundry wraps JSON output in a `{"schema_version":1,...,"data":...}` envelope, and the artifact bytecode already carries its `0x` prefix; the script now deploys via `cast send --create` with an unwrapping helper.)
- **Known stale pieces (not blockers for the deploy, flagged for the next pass):** `app/` static front-end still describes the push design (ABI + UI need a withdraw pass; Studio's Vite app is the live app). `arc-studio-prompt.md` still describes the original push design (historical — it is what was pasted). `video-script.md` release step is still accurate for an EOA payee but should add a credit → withdraw beat.

## Studio verification — Oct 27, 2026 ~11:05 AM CDT

Browser check of the live Arc Studio project
(https://studio.arc.io/app/16fcd6f7-5614-4e37-aee6-ad6575f83d73,
"Lamplight Escrow Arc Studio", built from arc-studio-prompt.md ~1h
earlier): Studio's contract MATCHES the repo contract exactly — same
selectors, events, revert strings, pull-payment crediting (see
studio-contract-reference.sol). Differences vs the ORIGINAL PROMPT are
all deliberate Studio security-review changes already in the repo
design: pull payments (failed payout credited to pendingWithdrawals +
withdraw(), instead of "call and require success"), 100,000-gas payout
cap, 2 extra events (Credited, Withdrawn), quotient/remainder split
math. Testnet deploy LIVE in Studio: LamplightEscrow
0xb02a77bbc1a7c70b54dc52565e117ad61207e12d, Oct 27 09:28 AM CDT, balance
0 USDC, nextEscrowId 0 (no escrow created yet). NO mainnet deployment
in Studio; mainnet writes off until VITE_LAMPLIGHT_ESCROW_ADDRESS_MAINNET
is set. Nothing deployed, signed, or spent on mainnet. Open detail:
Studio reports 38 tests (14 prompt + 24 extra) vs the repo's 25 Foundry
tests — same behaviour coverage, count not reconciled. On-chain
confirmation rests on Studio's Contracts panel (Blockscout page loaded
as a skeleton during the check).

## 11 · Independent review + fixes — DONE Oct 27, 2026 ~4:10–4:25 PM CDT

- **Review method:** the contract + tests were loaded into three free
  models (Grok, ChatGPT, Claude — histories reset first) with a fixed
  demands brief, one shot each, no back-and-forth. Full record:
  `reviews-2026-10-27.md`.
- **Grok:** no findings. **ChatGPT:** no findings. **Claude:** 5 findings,
  judgment "needs work" — the disagreement is the value.
- **Fixes applied (all five, approved):**
  1. **HIGH — deliver() had no deadline check.** A payee could deliver a
     junk hash at/after the deadline and kill the payer's refund.
     Fixed: `require(block.timestamp < escrow.deadline, "Deadline passed")`
     in deliver(). New revert string: "Deadline passed".
  2. **MEDIUM — a silent payer could lock funds forever.** Fixed, not
     just documented (scope update — implement, don't just document): a
     7-day review window.
     `deliveredAt` is recorded on delivery; `REVIEW_PERIOD = 7 days`
     (public constant). During the window only the payer may release;
     after `deliveredAt + REVIEW_PERIOD` the payee may also call
     release() and claim the funds. refund() stays blocked once
     delivered. New revert string: "Review period not ended". The trust
     model stays payer-as-arbiter during the window — the payer verifies
     the delivery hash and releases; the window exists only so a silent
     payer cannot lock funds forever. No arbitrator, no dispute path in
     v1 (documented in README).
  3. **LOW — a caller could force a credit with a low gas limit.**
     Fixed: `_payOrCredit` now requires
     `gasleft() > (PAYOUT_GAS_LIMIT * 64) / 63 + PAYOUT_GAS_BUFFER`
     before the call, so the full 100,000-gas cap is actually forwarded
     (EVM 63/64 rule); a low-gas call fails loudly instead of silently
     crediting. New revert string: "Insufficient gas for payout".
     **Re-review (Oct 27, ~4:53 PM CDT, Claude — judgment sound; Grok —
     no findings):** the 5,000 buffer did not cover the CALL's own base
     cost (2,600 cold + 9,000 value + 25,000 if the target is empty =
     up to 36,600), so a caller could still tune the gas limit to
     forward only ~93.5k to a ~97k-gas recipient. Fixed: buffer raised
     to 40,000, covering the worst-case base cost with margin, plus two
     boundary tests (under-funded call reverts; a ~99k-gas recipient is
     paid directly at the ~141,587-gas threshold). Total now 46 tests.
  4. **LOW — zero-share recipients got a call and a bogus Credited
     event.** Fixed: splitPayment() skips `_payOrCredit` when the
     computed amount is 0. **Re-review round 2 (Oct 27, ~5:22 PM CDT,
     Claude — judgment sound, both Lows called optional; Grok — no
     findings):** the dust still went to a zero-share LAST recipient —
     splitPayment{value: 1}([A,B,C], [5000,5000,0]) paid C the full 1 wei
     and made a payout call. Fixed: the remainder now goes to the last
     recipient with a nonzero share, so a zero-share recipient gets no
     payment and no call. New tests: the exact 1-wei repro (zero-share
     last gets nothing, contract balance 0), and dust to a nonzero-share
     last recipient. Fuzz-test invariant updated to the last-nonzero
     rule. Total now 52 tests.
  5. **LOW — tests missed the main safety paths.** Fixed: 19 new tests
     (see below).
  6. **LOW (round-2 re-review) — a credit could be unrecoverable.**
     withdraw() could only pull a credit to the credited address itself,
     so a contract with no payable receive() that missed a deadline was
     credited a refund it could never pull ("Payment failed" forever),
     and a credit to the escrow contract itself was stranded the same
     way. Fixed: new `withdrawTo(address)` — a credited party pulls its
     credit to a different address (zero address rejected, "Invalid
     recipient"); and `createEscrow` / `splitPayment` reject
     `address(this)` as payee/recipient ("Invalid recipient"), so a
     credit can never be stranded inside the contract. New tests: a
     credited no-receive contract recovers its full credit via
     withdrawTo(); withdrawTo() to the zero address reverts; the escrow
     contract itself is rejected as payee and as split recipient.
- **New tests (19, total 25 → 44, all passing):** deliver-after-deadline
  reverts (proves fix 1); payee cannot claim inside the window; payee
  claims after the window; payer releases inside and after the window;
  reentrancy with a malicious receiver (ReentrantAttacker) attempting to
  reenter withdraw/release/refund — blocked, settlement completes as a
  credit, credit preserved; withdraw "Payment failed" to a still-reverting
  recipient; "Already delivered" on second deliver; "Empty work hash";
  "Escrow not found" (deliver/release/refund); "Already settled" on second
  release and second refund; createEscrow "Invalid payee" (zero address
  and self); splitPayment "Zero recipient", "Length mismatch", zero-length
  array; split fuzz test (256 runs) proving amounts sum to msg.value and
  match floor(value × share / 10000) for the first n−1 recipients, with
  the contract balance ending at 0.
- **Verification:** `forge test` — **52 passed, 0 failed** (was 25/25
  before the revision, 44/44 after it; the re-review added 2 boundary
  tests for the gas-guard buffer, and the round-2 re-review added 6
  more — dust, withdrawTo, and address(this) rejection). Two test-side bugs were found and fixed during
  the run (a reverted receive() frame rolls back its own flag reset, so
  the attacker helper needed an explicit disarm(); one balance assertion
  miscounted who funded the escrow). The contract itself needed no
  correction after the fixes. During the round-3 test work a "Stack too
  deep" compiler error in the fuzz test was fixed by extracting the
  split-and-measure step into an internal helper, and a test append
  accidentally dropped the gas-guard boundary test — caught by a
  test-list diff and restored before reporting.
- **Deliberately left as-is:** nothing in either reviewer's list is
  unfixed. The v1 trust model (payer-as-arbiter, no arbitrator/dispute
  path) is unchanged by design — the review window bounds it, it does
  not replace it. Reviewers' improvement and new-feature suggestions
  (gas-test discrimination, struct packing, payer reject/dispute path,
  payer cancel) were NOT implemented in this round — findings only, per
  instruction; those are a separate decision.
- **Still needed before deploy (Ellis, not this task):** update the
  contract in Arc Studio to match the revised repo source and re-verify
  (the repo NO LONGER matches Studio); re-run the fork demo
  (`fork-demo.sh`) — the gas figures in README/§4 are from the
  pre-revision contract and will shift slightly; then mainnet deploy,
  demo, video, submit. No GitHub push and no Studio change were made in
  this task.

## 12 · Round 4 — "make it better" — DONE Oct 27, 2026 (evening)

The reviewers' improvement + feature suggestions from the round-2
re-review (Grok + Claude, updated brief rules 7+8), implemented
properly per the standing grant ("make it better ellis not the easy way do
what you think is best"). Only Grok's payer-cancel short-circuit was
skipped (weaker than the reject path — redundant once reject exists).

- **Struct packing (Claude improvement 4):** the Escrow struct went
  from 8 slots to 5 — uint96 amount, uint64 deadline / deliveredAt /
  rejectedAt, deliveredAt != 0 as the delivered flag (no separate bool).
  `createEscrow` measured 152,047 → 125,733 gas (26,314 saved, ~17%;
  measured with a throwaway gasleft() test, deleted after). Oversized
  amounts (> 2**96 wei) and deadlines (> 2**64 s) revert rather than
  truncate. The packed fields read back exactly (tested). Side effect:
  the release path's pre-check gas burn dropped ~75,000 → ~33,000, so
  the round-2 gas-guard test's hardcoded 195,000 limit stopped
  reverting — re-tuned to 153,000 (lands at ~120,000 gas left).
- **Discriminating gas-guard tests (Claude improvement 1):** the old
  boundary test would also pass on the old 5,000 buffer, so it proved
  nothing. Added a sweep (gas limits 150k–280k, ~99.9k burner) proving
  the property "if the guard passes, the payee is never credited" with
  monotonic outcomes, plus a gap case: a binary-searched minimum direct
  -pay limit (174,384) minus 15,000 lands in the gap between the old and
  new thresholds and must revert "Insufficient gas for payout" (old code
  would have credited silently). The existing boundary test was kept.
- **Cold empty account (Grok improvement 3, Arc leg):** a fresh address
  with no code and no balance — the worst-case CALL base cost (36,600)
  — is paid directly at the threshold limit, never credited.
- **Credit event (Grok improvement 1):** checked — the `Credited` event
  already fires ONLY on the failed-push path, and every settlement emits
  its own event, so an indexer distinguishes a pull credit from a direct
  payment by Credited's presence in the same transaction. Proven with a
  log-based test (direct pay: Released, no Credited; failed push:
  Released + exactly one Credited; split: SplitPaid + one Credited for
  the broken recipient only). No event change was needed.
- **Payer reject + dispute path (Claude feature):** `rejectDelivery()`
  (payer only, inside the review window; at the exact boundary second
  the payee may already claim, so the payee wins the boundary),
  `refundAfterRejection()` (payer only, after the 3-day cure window),
  `REJECT_CURE_PERIOD = 3 days`, `DeliveryRejected` event. A rejection
  clears the delivery; the payee cures by re-delivering (fresh review
  window, rejection cleared); a cured delivery can be rejected again.
  The happy path is unchanged when no reject happens.
- **Tests: 67 passed, 0 failed** (52 before + 15 new). No contract
  correction was needed after the fixes, but the round surfaced and fixed
  5 test-side issues: the "Already rejected" check was unreachable (a
  rejection clears deliveredAt, so "Not delivered" fired first — checks
  reordered); the credit-event test double-counted a credit across its
  own parts (fresh recipient for the split part); the cold-account test
  asserted an absolute balance the binary search had already changed
  (assert the delta); the sweep's lower bound was above the new
  threshold after packing (150k–280k now); the old underfund test's
  hardcoded limit (see above).
- **Deliberately left as-is:** Grok's payer-cancel short-circuit only.
- **Still needed before deploy (Ellis, not this task):** update the
  contract in Arc Studio to match the revised repo source and re-verify
  (the repo NO LONGER matches Studio); re-run the fork demo
  (`fork-demo.sh`) — the gas figures in README/§4 are from the
  pre-revision contract and will shift; then mainnet deploy, demo,
  video, submit. No GitHub push and no Studio change were made in
  this task.
## 13 · Round 5 — Claude round-4 findings + round-4 improvements — DONE Oct 27, 2026 (evening)

Claude's round-4 re-review found the new reject/cure path unsafe for the
payee (1 High, 1 Medium, 1 Low); Grok found nothing. This round fixes
all three findings and implements Grok's + Claude's round-4 improvement
and feature suggestions. Skipped only: partial-release (Grok feature —
held) and the per-escrow arbiter (Claude feature — the one-rejection cap
is the chosen fix).

- **HIGH — payer could reject a valid delivery after the deadline and
  refund immediately, with no cure possible.** rejectDelivery() reset
  deliveredAt to 0, then refund() passed (deliveredAt == 0, now >=
  deadline), and deliver() reverted "Deadline passed", so the 3-day cure
  never opened. Fixed in three parts: (1) refund() now requires
  rejectedAt == 0 ("Already rejected") — rejected escrows exit only
  through refundAfterRejection(); (2) deliver() accepts a cure until
  rejectedAt + REJECT_CURE_PERIOD even past the deadline; (3) rejections
  are capped at ONE per escrow (new `rejectedOnce` flag — a second
  rejectDelivery reverts "Already rejected"), so a payer cannot reject
  every cured delivery in turn.
- **MEDIUM — the cure window was never enforced on the payee side.**
  deliver() only checked the deadline. Fixed: when rejectedAt != 0,
  deliver() requires block.timestamp < rejectedAt + REJECT_CURE_PERIOD
  ("Cure period ended") — after the window the payee can no longer
  front-run refundAfterRejection with a junk hash and a fresh review
  window. The boundary is exact: cure < rejectedAt + 3d, refund >=.
- **LOW — the new tests covered neither of the above.** Added three:
  reject near/after the deadline then refund() reverts; re-deliver
  after the cure period reverts; a second rejection on the same escrow
  reverts. The old test that expected a cured delivery to be rejectable
  again was rewritten to assert the revert (one-rejection cap).
- **View helper (Grok improvement 1):** new `reviewWindows(id)` returns
  (reviewEnd, cureEnd) — deliveredAt + REVIEW_PERIOD and rejectedAt +
  REJECT_CURE_PERIOD, each 0 when it does not apply — mirroring HSK's
  claimWindows. Tested against the real boundaries (reject at reviewEnd
  reverts, payee claims there; cure at cureEnd-1 succeeds).
- **Extend deadline (Grok feature):** new `extendDeadline(id, extra)`
  — payer-only, before delivery, once only, at most +7 days
  (`MAX_DEADLINE_EXTENSION`), never on a rejected escrow, new deadline
  must fit uint40. `DeadlineExtended` event. Cannot reopen the front-run
  hole: after delivery the deadline gates nothing, and the increase is
  bounded.
- **Split fuzz, full uint96 range (Grok improvement 3):** a fuzz test
  sweeping msg.value across the full uint96 range with random share
  vectors summing to 10,000 — contract balance ends at zero, dust
  always lands on a non-zero-share recipient.
- **Balance invariant + boundary tests (Claude improvement):** a fuzz
  test asserting address(this).balance always equals unsettled escrow
  amounts plus pending credits, after every step of a fuzzed
  create/deliver/release/reject/cure/refund/split sequence (256 runs);
  plus pinned deadline/cure edges (deliver at deadline-1 succeeds, at
  the deadline reverts; cure at cure-end-1 succeeds, at the cure end
  reverts; refundAfterRejection at cure-end-1 reverts, at the cure end
  succeeds).
- **uint40 timestamps (Claude improvement):** the three timestamps
  shrank uint64 → uint40; the struct is now 4 slots (96 + 3×40 + 3
  bools = 240 bits in one slot). createEscrow gas 129,991 → 129,780
  (211 saved, measured with the same throwaway gasleft() test) — the
  eliminated slot held a zero value, so the saving is small; the gain
  is one fewer cold SLOAD on the reject/cure paths. The gas-guard tests
  still discriminate (the hardcoded 153,000 underfund limit still
  reverts; the sweep is adaptive).
- **Tests: 79 passed, 0 failed** (67 before + 12 new). One test-side fix
  during the run: the invariant fuzz's helper double-counted escrow 0
  (uninitialized array slots default to id 0) — the helper now takes an
  explicit count.
- **Still needed before deploy (Ellis, not this task):** update the
  contract in Arc Studio to match the revised repo source and re-verify
  (the repo NO LONGER matches Studio); re-run the fork demo
  (`fork-demo.sh`) — the gas figures in README/§4 are from the
  pre-revision contract and will shift; then mainnet deploy, demo,
  video, submit. No GitHub push and no Studio change were made in
  this task.

## 14 · Round 6 — Claude round-5 findings + Grok round-5 improvements — DONE Oct 27, 2026 (evening)
- **Cure window = review window (Claude Medium, the fix-first item):**
  `REJECT_CURE_PERIOD` was 3 days while `REVIEW_PERIOD` is 7, so a payer
  could reject at deliveredAt + 7d - 1s and win by default if the payee
  was offline 3 days. Fix is the one-constant change:
  `REJECT_CURE_PERIOD = REVIEW_PERIOD` (7 days), with the NatSpec
  rewritten to say why. New test: reject at deliveredAt + 7d - 1s, cure
  on day six succeeds and releases normally; a second escrow pins the
  refund side (reverts at cure-end-1, succeeds at the cure end). All
  existing cure tests moved from 3-day to 7-day literals.
- **extendDeadline deadline check (Claude Low):** `extendDeadline` had
  no `block.timestamp < deadline` check, so a payer could revive an
  expired undelivered escrow and let the payee deliver again. Fix:
  `require(block.timestamp < escrow.deadline, "Deadline passed")`,
  placed before the once-only check. New test: extend at exactly the
  deadline reverts, and the refund path is still the only exit.
- **Cure accepts any hash (Claude Low — DOCUMENTED, not fixed):** after
  one rejection the payee can re-deliver the same junk hash; the payer
  cannot reject again (one-rejection cap) and cannot refund, so the
  payee is paid after the review window. Stated plainly in README
  ("Security notes / limits") and here: rejection is a delay, not
  protection; real protection needs the per-escrow arbiter feature,
  which is v2 (out of scope for this round).
- **Zero-amount guard (Grok improvement 1):** `_payOrCredit` now
  requires amount > 0 ("Zero payment"), defense in depth at the single
  choke point all payouts funnel through. Every public entry point
  already enforces nonzero amounts, so the guard cannot fire through a
  public call today; it exists so a future zero-value credit can never
  emit a confusing Credited event.
- **Balance invariant, per-address bound (Grok improvement 2):** the
  invariant helper now also asserts no single pull credit exceeds the
  contract's native balance, for every address that can hold a credit.
- **lifecycleStatus view (Grok improvement 3):** new
  `lifecycleStatus(id)` returns one enum — Nonexistent / Created /
  Expired / InReview / Claimable / CureOpen / Rejected / Settled —
  with boundaries mirroring the state-changing functions exactly
  (InReview while now < deliveredAt + REVIEW_PERIOD, CureOpen while
  now < rejectedAt + REJECT_CURE_PERIOD, Expired from now >= deadline).
  New test walks escrows through every state.
- **bound() + invariant test with handlers (Claude improvement):** the
  full-uint96 split fuzz now uses `bound()` instead of `vm.assume`
  (assume() on a uint256 can reject most inputs and risks "too many
  rejects" flakiness); the other split fuzz already used bound(). New
  `EscrowInvariantHandler` + `LamplightEscrowInvariantTest`: the handler
  drives random sequences of creates, deliveries, rejects, releases,
  refunds, extensions and splits (all calls try/catch — a revert is a
  legal outcome), and the invariant asserts the balance invariant plus
  the per-address credit bound after every sequence. foundry.toml pins
  `[invariant] runs = 256, depth = 15`: this forge version (1.8.6)
  defaults depth to 500 (256 x 500 = 128,000 handler calls), which made
  the suite hang for 6+ minutes; with the pin the whole suite runs in
  ~2 seconds.
- **Tests: 83 passed, 0 failed** (79 before + 3 new unit tests + 1
  invariant test). No GitHub push and no Studio change were made in
  this task — verify + push is Ellis's step.
- **Still needed before deploy:** update the contract in Arc Studio to
  match the revised repo source and re-verify (the repo NO LONGER
  matches Studio — it has now diverged through rounds 2–7); re-run the
  fork demo (`fork-demo.sh`) — the gas figures in README/§4 are from
  the pre-revision contract and will shift; then mainnet deploy, demo,
  video, submit.

## 15 · Round 7 — Grok round-6 improvements (2 of 3) — DONE Oct 27, 2026 (evening)

- **Rejected work hash emitted (Grok improvement 1):**
  `DeliveryRejected` now carries `bytes32 rejectedWorkHash` — the hash
  `rejectDelivery` clears from storage is captured before the clear and
  emitted, so off-chain parties can still prove what was rejected after
  the clear (it also remains in the earlier `Delivered` event's
  history). NatSpec updated. New test
  `testRejectEmitsRejectedWorkHash`: `vm.expectEmit` pins the exact
  rejected hash in the event, the struct holds zero right after the
  reject, and after a cure + re-delivery the live hash is the corrected
  one.
- **Skipped:** Grok improvement 2 (a "what can I do next" view for both
  contracts) — `lifecycleStatus()` already covers most of it; Grok's
  features (per-escrow bonded-stake arbiter, batch release/refund) are
  v2, NOT built here (out of scope). Claude's round-6 findings are still
  pending (resume after the 9:00 PM CDT limit reset) and are NOT part of
  this round — these two items fold in with whatever Claude says later.
- **Tests: 84 passed, 0 failed** (83 before + 1 new event test). No
  GitHub push and no Studio change were made in this task — verify +
  push is Ellis's step.
