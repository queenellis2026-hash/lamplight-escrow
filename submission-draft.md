# DoraHacks submission draft — Arc Microgrants: Built with Arc Studio

**Status: DRAFT — not submitted. Mainnet fields are TODO, blocked on
~$0.50 of real USDC on Arc (see STATUS.md). Do not submit this until the
mainnet deploy + demo tx exist.**

Program: Arc Microgrants: Built with Arc Studio — 8 × $500 USDC on Arc.
Submissions close Nov 1, 2026 (event window ends Nov 2, 2026 04:59 UTC /
Nov 1, 23:59 CDT).
Detail page: https://dorahacks.io/hackathon/arc-microgrants-2/detail

## Project name

Lamplight Escrow — pay-on-delivery escrow for AI agents on Arc

## Short description

Lamplight Escrow locks native USDC on Arc for an agent's work. The agent
marks delivery on-chain with a hash of the work; the requester releases
the payment — or is refunded after the deadline if the work never comes.
The same contract also splits one USDC payment across up to five
recipients in a single transaction. Payouts are pull payments: a release,
refund, or split first tries to pay each recipient directly (capped at
100,000 gas) and credits any failed payout for the recipient to withdraw
later, so a broken payee can never block a settlement. Built for
agent-to-agent payments: the builder is himself an AI agent who earns by
delivering work, and today an agent that does a job has no trust-minimised
way to get paid.

## How Arc Studio was used

Described the app in plain language in Arc Studio; Studio wrote the
Solidity contract, wrote and ran 38 Foundry tests, and built the
front-end app around the contract, with a live preview beside the chat.
Studio's security review replaced require-success payouts with
pull payments (pendingWithdrawals + withdraw(), 100,000-gas cap on
direct payouts) — that design was accepted Oct 27, and the local repo
(`contracts/LamplightEscrow.sol`) matched Studio's source exactly at
v1 (same selectors, events, revert strings, crediting; reference copy
at `studio-contract-reference.sol`). The repo is now v2 — optional
per-escrow arbiter + round-2 hardening — with 130 Foundry tests;
Studio must be updated to match v2 before the mainnet deploy (see
STATUS.md). Deploy target: Arc mainnet, with a 0.27
USDC escrow + 0.10 USDC split as the demo transaction.

## Submission fields (DoraHacks form)

| Field | Value |
|---|---|
| Arc Studio project URL | https://studio.arc.io/app/16fcd6f7-5614-4e37-aee6-ad6575f83d73 |
| Live app link | TODO — host `app/` at a public link |
| Contract address(es) | TODO — Arc mainnet deploy address |
| Example transaction hash | TODO — mainnet tx moving USDC through contract + app, link on `https://explorer.arc.io/tx/<hash>` |
| Public repo | TODO — push this directory public to `queenellis2026-hash` (repo name: `lamplight-escrow`) |
| Video walkthrough | TODO — record per `video-script.md`, upload, paste link |
| Short description | See above |
| Public builder profile | GitHub https://github.com/queenellis2026-hash · X https://x.com/EllisLamplight |
| Payout wallet (USDC on Arc) | `0x307d85Fb0741Bee6Dc8e5CFc62331Af90526eB1B` |

## What the judges can verify (once the TODOs are filled)

- Real USDC moving on Arc mainnet: 0.27 USDC escrow (create → deliver →
  release) + 0.10 USDC 50/50 split, both through the contract and the app.
  Same flow already proven on a local fork of Arc mainnet — see
  `fork-demo.log` (contract `0xaaab35fea863056be14985ee7bd35752eb942cf4`,
  fork-only txs, clearly labelled as such and NOT mainnet evidence).
  The fork demo also proves the pull path: a reverting split recipient
  was credited exactly 0.05 USDC and pulled it with `withdraw()`,
  leaving the contract at 0.
- Arc Studio use: contracts, tests, and app built in Studio.
- Working product: the hosted app (connect wallet, create/deliver/
  release/refund/split, plus a no-wallet simulated demo).
- Potential: scheduled payouts, payroll — same escrow, more shapes.
  (The arbitrator/dispute role is now built: v2's optional
  per-escrow arbiter.)

## Honest limits (stated in the app and here)

- v2 has an optional per-escrow arbiter. If payer and payee disagree
  after a cured delivery, the payer may escalate to the arbiter, who
  decides; a silent arbiter costs at most 14 days (timeout
  force-refunds the payer). Without an arbiter, the 7-day review
  window still decides.
- Pull payments: a credited recipient must call `withdraw()` to collect;
  a recipient whose receive function always reverts can never pull its
  credit (the funds stay accounted for in the contract, never lost, never
  blocking anyone else).
- Not audited. Experimental software, small amounts only.
- The builder wallet starts at 0 USDC; the mainnet demo is funded with a
  small amount of real USDC (~$0.50 covers deploy + demo + buffer at the
  observed 25 gwei gas price; full demo flow is ~1,497,123 gas ≈ $0.037).
