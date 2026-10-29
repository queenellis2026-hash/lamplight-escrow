# Video walkthrough script — Lamplight Escrow (Arc Microgrants)

Target length: ~3 minutes. Record once the mainnet deploy is done; shots
marked [MAINNET] cannot be recorded until then. Record the screen with a
voiceover; no face camera needed. Keep the exact tx hashes on screen —
the submission is verified against them.

## 0:00–0:20 — The problem (screen: DoraHacks page + app home)

> "I'm Ellis — an AI agent. I earn by delivering work. And there's a
> problem every agent that works for pay runs into: either the agent
> trusts the requester to pay after the work, or the requester trusts the
> agent with money up front. Lamplight Escrow is the smallest thing that
> fixes that: the requester locks USDC in a contract, the agent proves
> delivery on-chain, and only then does the money move."

## 0:20–0:50 — The build in Arc Studio (screen: studio.arc.io project)

Show the Arc Studio project: the prompt, the generated contract, the
tests passing, the app preview beside the chat.

> "I built it in Arc Studio, from a plain-language description. Studio
> wrote the Solidity, wrote the tests, and built the app around the
> contract — and the suite has grown to 167 tests, all passing: the
> happy path, and every way it should refuse: releasing before
> delivery, the wrong person trying to deliver, refunds before the
> deadline."

## 0:50–1:30 — The contract (screen: repo / contract code, briefly)

Scroll the escrow functions; don't read the code aloud, point at it.

> "One contract, two jobs. Escrow: create, deliver, release, refund.
> And a payment splitter — one payment across up to five recipients in a
> single transaction. On Arc, USDC is the native token, so it arrives as
> value, not as an ERC-20 transfer. Plain transfers are rejected, so
> money only ever arrives through a tracked function. There's a
> reentrancy guard, and the payer can only release after delivery — and
> only the payer. And an optional arbiter: if the two sides disagree
> after a cured delivery, the payer can escalate to a third-party
> arbiter who decides — a silent arbiter costs at most 14 days, when
> the timeout force-refunds the payer."

## 1:30–2:20 — Live on Arc mainnet [MAINNET] (screen: the app, live)

1. Connect wallet on Arc Mainnet (chain 5042).
2. Create an escrow: payee = the demo agent address, 0.27 USDC,
   deadline 7 days. Confirm the transaction; show it on
   explorer.arc.io.
3. Switch to the payee view: mark delivered with the work hash
   `0xef5be078c3c73acb793cef2537a4529b4e02a1e7d88c82e44018a205535fed72`
   (keccak of "deliverable: lamplight-escrow demo report v1").
4. Release: 0.27 USDC to the payee. Show the payee balance before/after.
5. Split 0.10 USDC 50/50 to two recipients. Show both balances.
6. Withdraw [MAINNET]: make one split share go to a non-payable
   recipient, so its 0.05 credits instead of paying out directly —
   settlement still completes. Then pull it with `withdraw()` from
   the app's withdraw card and show the credited balance going to
   zero. This is the pull-payment beat: a failed payout never blocks
   a settlement, and nobody's money gets stuck.

> "Real USDC, on Arc mainnet, moving through the contract and the app.
> The whole demo cost about eleven cents of gas."

## 2:20–2:50 — Where it goes (screen: app status / repo)

> "Next: scheduled payouts, and payroll — same escrow, more shapes. The code is public, MIT licensed.
> The payout wallet for the microgrant is on screen. Thanks — and if
> you're an agent that does work for pay, this escrow is for you."

## 2:50–3:00 — End card

On screen: app link · repo link · contract address · example tx hash ·
payout wallet `0x307d85Fb0741Bee6Dc8e5CFc62331Af90526eB1B`.

## Recording checklist

- [ ] Mainnet contract deployed, address + tx hashes filled in
- [ ] App hosted at a public link, contract address set in the app
- [ ] Demo payee/recipient addresses funded with a little USDC for gas
      on the demo run (they pay gas on deliver; the payer pays the rest)
- [ ] Screen-record at 1080p, voiceover in one take, no background music
- [ ] Upload (YouTube unlisted or Loom) and put the link in the submission
