# Arc Studio prompt — Lamplight Escrow

Paste this into Arc Studio (https://studio.arc.io) as the project prompt.
Eligibility for the Arc Microgrants requires the project be built in Arc
Studio, so this prompt reproduces — in Studio — the contracts and app that
already exist in this repo (`contracts/LamplightEscrow.sol`, `app/`).
After Studio generates the project, compare its contracts against the repo
version before deploying; they must match in behaviour.

---

Build an onchain app called **Lamplight Escrow** on Arc mainnet: a
pay-on-delivery escrow for AI agents, plus a one-transaction payment
splitter. On Arc, USDC is the native token — it pays gas and arrives in a
contract as msg.value, exactly like ETH on Ethereum. There is no ERC-20
transfer anywhere in this app.

## Smart contract (Solidity 0.8.24, one contract, name: LamplightEscrow)

### Escrow

- Struct Escrow: payer (address), payee (address), amount (uint256),
  deadline (uint256 unix time), workHash (bytes32), delivered (bool),
  settled (bool).
- `createEscrow(address payee, uint256 deadline) payable returns (uint256 id)`:
  require payee is not the zero address and not the sender; require
  msg.value > 0; require deadline is in the future. Store the escrow,
  increment the id counter, emit EscrowCreated(id, payer, payee, amount,
  deadline).
- `deliver(uint256 id, bytes32 workHash)`: only the payee, only if not
  settled and not already delivered, workHash must be non-zero. Sets
  delivered = true and workHash. Emit Delivered(id, workHash).
- `release(uint256 id)`: only the payer, only if not settled, only if
  delivered. Marks settled FIRST, then sends the full amount to the payee
  with a low-level call and requires success. Emit Released(id, payee,
  amount). Must be reentrancy-guarded.
- `refund(uint256 id)`: only the payer, only if not settled, only if NOT
  delivered, only after block.timestamp >= deadline. Marks settled FIRST,
  then sends the full amount back to the payer. Emit Refunded(id, payer,
  amount). Must be reentrancy-guarded.
- `getEscrow(uint256 id) view returns (Escrow)`, plus a public mapping and
  a public nextEscrowId counter.
- Events: EscrowCreated, Delivered, Released, Refunded.
- A simple boolean reentrancy guard (no external dependency).
- Reject plain transfers with a receive() that reverts, telling the sender
  to use createEscrow or splitPayment, so funds only ever arrive through a
  tracked function.

### Payment splitting

- `splitPayment(address[] recipients, uint256[] sharesBps) payable`:
  require msg.value > 0; 1–5 recipients; arrays the same length; no zero
  addresses; shares must sum to exactly 10000 basis points. Pay each
  recipient share = msg.value * sharesBps[i] / 10000, EXCEPT the last
  recipient, who receives msg.value minus everything already paid, so
  rounding dust is never trapped in the contract. Reentrancy-guarded.
  Emit SplitPaid(payer, total, recipientCount).

### Tests to write and run in Studio

Fourteen cases: create locks funds; full create → deliver → release path;
release before delivery reverts; only payee can deliver; only payer can
release; refund after deadline when undelivered; refund before deadline
reverts; refund after delivery reverts; zero-value create reverts;
past-deadline create reverts; split exact amounts; split bad shares
reverts; split of 1 wei sends the dust to the last recipient and leaves
the contract at zero; direct transfer reverts. All must pass before deploy.

## App (frontend, wired to the contract)

A clean single-page app, warm light-on-dark "lamplight" styling, with:

1. Network panel: Arc Mainnet (chain 5042, RPC https://rpc.mainnet.arc.io,
   explorer https://explorer.arc.io) and Arc Testnet (chain 5042002,
   RPC https://rpc.testnet.arc.io, explorer
   https://explorer.testnet.arc.io). Connect-wallet button, add-network
   button, connected address + USDC balance display.
2. Create escrow form: payee address, amount in USDC, deadline in days.
3. Deliver / release / refund panel: escrow ID, work-hash field (accept a
   0x hash or plain text and hash it with keccak256), look-up that shows
   the escrow's full state.
4. Split payment form: recipient addresses and basis-point shares, one per
   line, total amount; validate the shares sum to 10000 before sending.
5. A demo mode that runs the whole flow with simulated data and needs no
   wallet, clearly labelled as simulated.
6. A short "how it works" section and an honest limits note: v2 has an
   optional per-escrow arbiter — if payer and payee disagree after a
   cured delivery, the payer may escalate to the arbiter, who decides.

## Deployment

- Test everything on Arc Testnet first (test USDC from the Circle faucet
  at https://faucet.circle.com — testnet only, never mainnet).
- Deploy to Arc mainnet with small amounts for the demo: a 0.27 USDC
  escrow and a 0.10 USDC 50/50 split.
- Do NOT sign, fund, or submit mainnet transactions yourself: deployment
  is done by the builder with their own credentials after review.
