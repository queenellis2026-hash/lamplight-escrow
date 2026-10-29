#!/usr/bin/env bash
# Lamplight Escrow keeper — sweeps matured dispute resolutions.
#
# Problem (round 6, Oct 28, 2026): after an arbiter resolves a dispute,
# the payout is deferred until finalizeResolution is called after the
# 2-day challenge window — and finalizeResolution is per-escrow. If
# both parties go offline, nobody calls it and the funds sit forever.
# finalizeMatured() lets anyone finalize a whole list in one call, and
# it SKIPS ids that are not matured instead of reverting, so this
# keeper can sweep blindly.
#
# What the keeper watches: escrows whose lifecycle is ChallengeOpen
# (lifecycleStatus == 9). It passes those ids to finalizeMatured in
# batches; the contract itself decides which are matured (challenge
# window closed) and skips the rest, so a window closing between the
# scan and the call is harmless.
#
# How often: the challenge window is 2 days, so once a day is plenty —
# a resolution can never sit more than a day past maturity. Run it as
# a daily cron (or an hourly one; the sweep is cheap).
#
# What it costs: one finalizeMatured transaction per batch. The
# keeper pays gas only, never escrow funds — the payout always goes
# to the recorded winner, never to the keeper.
#
# Gas per finalization, measured Oct 28, 2026 (round 8, temp forge
# harness, deleted after measuring; gasleft() delta, batches of 1/2/3
# matured resolutions, EOA recipients; the per-finalization figure is
# the marginal cost fitted from the three batch sizes, the base is the
# batch overhead — one MaturedResolutionsFinalized event plus the
# loop and call overhead):
#   no bond staked:  base ~49,026 + ~25,087 per finalization
#     batch of 3 ~124,286 · batch of 100 ~2.56M · full 256 ~6.47M
#   bond staked (worst case — each finalization also settles the
#   bond, one more payout + BondSettled event):
#     base ~51,523 + ~39,341 per finalization
#     batch of 3 ~169,545 · batch of 100 ~3.99M · full 256 ~10.12M
# (The old "~148,461 (~49,500 each)" figure is superseded: it came
# from a round-6 harness whose batch composition was never recorded.
# The figures above are fitted from measured 1/2/3-id batches, so
# the marginal cost and the base are separated honestly.)
#
# Arc block-gas limit assumption: Arc's block gas limit is
# 30,000,000 — verified live against both the mainnet and testnet
# RPCs (eth_getBlockByNumber, Oct 28, 2026; mainnet block 0x1af4eda,
# testnet block 0x423e3fd, both gasLimit 0x1c9c380). Even a fully
# bonded 256-id batch (~10.12M, ~34% of a block) fits in one block
# on its own, and the default BATCH_SIZE of 100 stays under ~4M
# even fully bonded (~13% of a block). The 256 contract cap
# (MAX_FINALIZE_BATCH) is a hard ceiling, not a target: tune
# BATCH_SIZE down if your batches are mostly bonded or blocks are
# congested — the safe operating range is bounded by the block
# limit, and 100 sits comfortably inside it. Re-check the limit
# (cast block latest --fields gasLimit) if Arc ever changes it;
# if the limit ever fell below ~10.5M, a full bonded 256-batch
# would no longer fit and BATCH_SIZE would need lowering.
#
# What it logs (round 7, Oct 28, 2026, Grok improvement): a live sweep
# no longer prints only a tx hash. After each batch the keeper fetches
# the mined receipt and decodes its logs: the MaturedResolutions-
# Finalized event gives the batch count, and the Released / Refunded
# events give the exact ids that actually finalized — so the operator
# sees what settled, not just that something was sent. The decoded
# count is cross-checked against the ids list; a mismatch prints a
# warning. If the receipt cannot be fetched or decoded, the keeper
# falls back to printing the tx hash — logging never fails a sweep.
# --dry-run previews the same information per id (one eth_call per
# candidate, which is the on-chain maturity decision itself, so the
# preview cannot drift from what the real sweep would do).
#
# Usage:
#   RPC_URL=http://127.0.0.1:8545 \
#   ESCROW_ADDRESS=0x... \
#   KEEPER_KEY=0x... \
#   ./scripts/keeper.sh [--dry-run]
#
#   --dry-run  simulate each candidate with `cast call` and print which
#              ids WOULD finalize, without sending anything.
#
#   BATCH_SIZE (env, default 100) caps ids per transaction. The
#   contract caps a batch at MAX_FINALIZE_BATCH (256) and reverts
#   "Batch too large" above it, so keep BATCH_SIZE at or below 256.
#   The default 100 is comfortably under both the cap and the Arc
#   30M block-gas limit (see "What it costs" above: a 100-id batch
#   is ~2.56M gas with no bonds, ~3.99M fully bonded).
#
# Requires: `cast` (Foundry) and `python3` (stdlib only, for receipt
# JSON + log decoding). Set CAST to its path if it is not on PATH,
# e.g. CAST=~/.foundry/bin/cast.
set -euo pipefail

: "${RPC_URL:?set RPC_URL to the Arc (or Anvil) JSON-RPC endpoint}"
: "${ESCROW_ADDRESS:?set ESCROW_ADDRESS to the deployed LamplightEscrow address}"
: "${KEEPER_KEY:?set KEEPER_KEY to the keeper private key (0x...)}"
CAST="${CAST:-cast}"
BATCH_SIZE="${BATCH_SIZE:-100}"
DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=1
fi

# lifecycleStatus enum: 9 = ChallengeOpen (arbiter resolved, challenge
# window open, payout deferred until it closes or is answered).
CHALLENGE_OPEN=9

# Event topic0 hashes (keccak of the canonical signatures), for
# decoding a sweep receipt's logs. Released / Refunded carry the
# finalized escrow id as their first indexed topic; MaturedResolutions-
# Finalized carries the batch count in its data field.
TOPIC_RELEASED=0x3bfce8de0db7450cc169b94323c210e69a36c6a4a58c9f5d96bec4973adce392
TOPIC_REFUNDED=0x7ca5472b7ea78c2c0141c5a12ee6d170cf4ce8ed06be3d22c8252ddfc7a6a2c4
TOPIC_BATCH=0x44603c1cec76f6948dbab2a67210399b04495f360dce9201289fc730e8cdd63e

next_id="$("$CAST" call "$ESCROW_ADDRESS" "nextEscrowId()(uint256)" --rpc-url "$RPC_URL")"
candidates=()
for ((id = 0; id < next_id; id++)); do
    status="$("$CAST" call "$ESCROW_ADDRESS" "lifecycleStatus(uint256)(uint8)" "$id" --rpc-url "$RPC_URL")"
    if [ "$status" -eq "$CHALLENGE_OPEN" ]; then
        candidates+=("$id")
    fi
done

if [ "${#candidates[@]}" -eq 0 ]; then
    echo "keeper: no challenge-open resolutions (0..$((next_id - 1)) scanned)"
    exit 0
fi

echo "keeper: ${#candidates[@]} challenge-open resolution(s): ${candidates[*]}"

# Decode one sweep receipt (JSON on stdin) into the finalized ids and
# the batch count: prints "<count> <id> <id> ..." — the count from the
# MaturedResolutionsFinalized event, the ids from the Released /
# Refunded events in log order. Prints nothing and exits nonzero if
# the receipt has no decodable batch event (caller falls back to the
# tx hash alone).
decode_receipt() {
    TOPIC_RELEASED="$TOPIC_RELEASED" TOPIC_REFUNDED="$TOPIC_REFUNDED" TOPIC_BATCH="$TOPIC_BATCH" python3 -c '
import json, os, sys
try:
    receipt = json.load(sys.stdin)
except Exception:
    sys.exit(1)
released = os.environ["TOPIC_RELEASED"].lower()
refunded = os.environ["TOPIC_REFUNDED"].lower()
batch = os.environ["TOPIC_BATCH"].lower()
count = None
ids = []
for log in receipt.get("logs", []):
    topics = [t.lower() for t in log.get("topics", [])]
    if not topics:
        continue
    if topics[0] in (released, refunded) and len(topics) > 1:
        ids.append(str(int(topics[1], 16)))
    elif topics[0] == batch:
        count = int(log.get("data", "0x0"), 16)
if count is None:
    sys.exit(1)
print(count, *ids)
'
}

# Emit the ids as a cast array literal, e.g. [0,1,2].
total_finalized=0
for ((i = 0; i < ${#candidates[@]}; i += BATCH_SIZE)); do
    batch=("${candidates[@]:i:BATCH_SIZE}")
    joined="$(IFS=,; echo "${batch[*]}")"
    if [ "$DRY_RUN" -eq 1 ]; then
        # One eth_call per candidate: finalizeMatured([id]) returns 1
        # exactly when that id is matured — the on-chain decision, so
        # the preview lists precisely what the real sweep would settle.
        would=()
        for id in "${batch[@]}"; do
            n="$("$CAST" call "$ESCROW_ADDRESS" "finalizeMatured(uint256[])(uint256)" "[$id]" --rpc-url "$RPC_URL")"
            if [ "$n" -eq 1 ]; then
                would+=("$id")
            fi
        done
        if [ "${#would[@]}" -eq 0 ]; then
            echo "keeper: dry-run batch [$joined] would finalize 0"
        else
            echo "keeper: dry-run batch [$joined] would finalize ${#would[@]}: ids ${would[*]}"
        fi
        total_finalized=$((total_finalized + ${#would[@]}))
    else
        tx="$("$CAST" send "$ESCROW_ADDRESS" "finalizeMatured(uint256[])(uint256)" "[$joined]" \
            --private-key "$KEEPER_KEY" --rpc-url "$RPC_URL" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["transactionHash"])')"
        if decoded="$("$CAST" receipt "$tx" --json --rpc-url "$RPC_URL" 2>/dev/null | decode_receipt 2>/dev/null)"; then
            # First field is the batch event's count; the rest (if any)
            # are the finalized ids in log order.
            set -- $decoded
            count="$1"
            shift
            if [ "$#" -eq 0 ]; then
                echo "keeper: batch [$joined] finalized $count: ids (none) (tx $tx)"
            else
                echo "keeper: batch [$joined] finalized $count: ids $* (tx $tx)"
            fi
            if [ "$count" -ne "$#" ]; then
                echo "keeper: WARNING: batch event count ($count) disagrees with decoded ids ($#) for tx $tx"
            fi
            total_finalized=$((total_finalized + count))
        else
            echo "keeper: batch [$joined] sent: $tx (receipt decode unavailable — see tx for outcome)"
        fi
    fi
done

if [ "$DRY_RUN" -eq 1 ]; then
    echo "keeper: dry-run total: $total_finalized would be finalized"
else
    echo "keeper: total finalized: $total_finalized"
fi
