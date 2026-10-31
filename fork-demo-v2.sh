#!/usr/bin/env bash
# Fork demo for LamplightEscrow V2 (arbiter line, round 9) on a local Anvil
# fork of Arc mainnet. Mirrors the v1 demo flows: A (0.27 escrow release),
# B (0.10 split with a credited + withdrawn share), C (reject -> cure ->
# release). Usage: bash fork-demo-v2.sh (writes fork-demo-v2.log here).
# Keys are generated fresh at runtime and NEVER printed or logged.
# Gotcha (see v1 STATUS §7): never use well-known Anvil test addresses as
# recipients on an Arc fork — they carry EIP-7702 delegation code on mainnet
# and forward any funds they receive. Fresh random addresses, verified
# code-free on mainnet, are used for every role.
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$HOME/.foundry/bin:$PATH"

FORK=http://127.0.0.1:8545
LOG=fork-demo-v2.log
: > "$LOG"
log() { echo "$*" | tee -a "$LOG"; }
wei2eth() { python3 -c "print(f'{int(\"$1\") / 10**18:.18f}')"; }

newkey() { # prints "address privatekey" on one line (never logged)
    cast wallet new --json | python3 -c "import json,sys; d=json.load(sys.stdin)['data'][0]; print(d['address'], d['private_key'])"
}

# ---- start anvil fork ----
anvil --fork-url https://rpc.mainnet.arc.io --chain-id 5042 --port 8545 >/tmp/anvil-fork-v2.log 2>&1 &
ANVIL_PID=$!
trap 'kill $ANVIL_PID 2>/dev/null || true' EXIT
for i in $(seq 1 60); do
    cast block-number --rpc-url "$FORK" >/dev/null 2>&1 && break
    sleep 1
done
cast block-number --rpc-url "$FORK" >/dev/null

# ---- fresh keys for every role ----
read -r DEPLOYER_ADDR DEPLOYER_KEY <<<"$(newkey)"
read -r PAYER_ADDR PAYER_KEY <<<"$(newkey)"
read -r PAYEE_ADDR PAYEE_KEY <<<"$(newkey)"
read -r THIRD_ADDR THIRD_KEY <<<"$(newkey)"
log "DEPLOYER=$DEPLOYER_ADDR"
log "PAYER=$PAYER_ADDR"
log "PAYEE=$PAYEE_ADDR"
log "THIRD=$THIRD_ADDR"
for a in "$DEPLOYER_ADDR" "$PAYER_ADDR" "$PAYEE_ADDR" "$THIRD_ADDR"; do
    CODE=$(cast code "$a" --rpc-url https://rpc.mainnet.arc.io)
    [ "$CODE" = "0x" ] || { echo "FATAL: $a has code on mainnet: $CODE" >&2; exit 1; }
done
log "All four demo addresses are code-free on mainnet. Funding each with 10 USDC on the fork..."
for a in "$DEPLOYER_ADDR" "$PAYER_ADDR" "$PAYEE_ADDR" "$THIRD_ADDR"; do
    cast rpc anvil_setBalance "$a" 0x8ac7230489e80000 --rpc-url "$FORK" >/dev/null
done

gasof() { cast receipt "$1" --rpc-url "$FORK" --json | python3 -c "import json,sys; d=json.load(sys.stdin); d=d.get('data', d); print(int(d['gasUsed'], 16))"; }
jget() { python3 -c "import json,sys; d=json.load(sys.stdin); d=d.get('data', d); print(d['$1'])"; }

deploy_contract() { # $1 = artifact path -> prints "address txhash"
    local bc tx addr
    bc=$(python3 -c "import json; print(json.load(open('$1'))['bytecode']['object'])")
    tx=$(cast send --private-key "$DEPLOYER_KEY" --rpc-url "$FORK" --create "$bc" --json | jget transactionHash)
    addr=$(cast receipt "$tx" --rpc-url "$FORK" --json | jget contractAddress)
    echo "$addr $tx"
}

# ---- deploy escrow + flaky recipient ----
read -r ESCROW DEPLOY_TX <<<"$(deploy_contract out/LamplightEscrow.sol/LamplightEscrow.json)"
read -r FLAKY FLAKY_TX <<<"$(deploy_contract out/LamplightEscrow.t.sol/FlakyRecipient.json)"
DEPLOY_GAS=$(gasof "$DEPLOY_TX")
FLAKY_GAS=$(gasof "$FLAKY_TX")
log "CONTRACT= $ESCROW"
log "FLAKY= $FLAKY"
log "DEPLOY_TX= $DEPLOY_TX GAS= $DEPLOY_GAS"
log "FLAKY_TX= $FLAKY_TX GAS= $FLAKY_GAS"

DEADLINE=1893456000  # 2030-01-01
WORKHASH=0xef5be078c3c73acb793cef2537a4529b4e02a1e7d88c82e44018a205535fed72

# ---- Flow A: escrow 0.27, EOA payee (direct payout path) ----
CREATE_TX=$(cast send "$ESCROW" "createEscrow(address,uint256)" "$PAYEE_ADDR" "$DEADLINE" --value 0.27ether --private-key "$PAYER_KEY" --rpc-url "$FORK" --json | jget transactionHash)
CREATE_GAS=$(gasof "$CREATE_TX")
log "CREATE_TX= $CREATE_TX GAS= $CREATE_GAS"
DELIVER_TX=$(cast send "$ESCROW" "deliver(uint256,bytes32)" 0 "$WORKHASH" --private-key "$PAYEE_KEY" --rpc-url "$FORK" --json | jget transactionHash)
DELIVER_GAS=$(gasof "$DELIVER_TX")
log "DELIVER_TX= $DELIVER_TX GAS= $DELIVER_GAS"
RELEASE_TX=$(cast send "$ESCROW" "release(uint256)" 0 --private-key "$PAYER_KEY" --rpc-url "$FORK" --json | jget transactionHash)
RELEASE_GAS=$(gasof "$RELEASE_TX")
log "RELEASE_TX= $RELEASE_TX GAS= $RELEASE_GAS"
PAYEE_BAL_AFTER_RELEASE=$(cast balance "$PAYEE_ADDR" --rpc-url "$FORK")
PENDING_PAYEE=$(cast call "$ESCROW" "pendingWithdrawals(address)(uint256)" "$PAYEE_ADDR" --rpc-url "$FORK")
log "--- balances after release (payee ~10 + 0.27 minus deliver gas; pending 0) ---"
log "payee: $(wei2eth "$PAYEE_BAL_AFTER_RELEASE")"
log "payee pendingWithdrawals: $PENDING_PAYEE"

# ---- Flow B: split 0.10 50/50, payee (EOA, direct) + flaky (reverting, credited) ----
SPLIT_TX=$(cast send "$ESCROW" "splitPayment(address[],uint256[])" "[$PAYEE_ADDR,$FLAKY]" "[5000,5000]" --value 0.1ether --private-key "$PAYER_KEY" --rpc-url "$FORK" --json | jget transactionHash)
SPLIT_GAS=$(gasof "$SPLIT_TX")
log "SPLIT_TX= $SPLIT_TX GAS= $SPLIT_GAS"
PENDING_FLAKY=$(cast call "$ESCROW" "pendingWithdrawals(address)(uint256)" "$FLAKY" --rpc-url "$FORK")
CONTRACT_BAL=$(cast balance "$ESCROW" --rpc-url "$FORK")
log "--- balances after split (payee +0.05 direct; flaky credited 0.05; contract holds 0.05) ---"
log "payee: $(wei2eth "$(cast balance "$PAYEE_ADDR" --rpc-url "$FORK")")"
log "flaky pendingWithdrawals: $PENDING_FLAKY"
log "contract: $(wei2eth "$CONTRACT_BAL")"

# ---- Flaky fixes itself and pulls the credit ----
cast send "$FLAKY" "setReverting(bool)" false --private-key "$PAYER_KEY" --rpc-url "$FORK" --json >/dev/null
WITHDRAW_TX=$(cast send "$FLAKY" "withdrawFrom(address)" "$ESCROW" --private-key "$PAYER_KEY" --rpc-url "$FORK" --json | jget transactionHash)
WITHDRAW_GAS=$(gasof "$WITHDRAW_TX")
log "WITHDRAW_TX= $WITHDRAW_TX GAS= $WITHDRAW_GAS"
log "--- final balances (flaky 0.05; contract must be 0) ---"
log "flaky: $(wei2eth "$(cast balance "$FLAKY" --rpc-url "$FORK")")"
log "flaky pendingWithdrawals: $(cast call "$ESCROW" "pendingWithdrawals(address)(uint256)" "$FLAKY" --rpc-url "$FORK")"
log "contract (must be 0): $(wei2eth "$(cast balance "$ESCROW" --rpc-url "$FORK")")"

# ---- Flow C: reject -> cure -> release ----
WORKHASH2=0x1111111111111111111111111111111111111111111111111111111111111111
WORKHASH3=0x2222222222222222222222222222222222222222222222222222222222222222
PAYEE_BAL_BEFORE_C=$(cast balance "$PAYEE_ADDR" --rpc-url "$FORK")
CREATE2_TX=$(cast send "$ESCROW" "createEscrow(address,uint256)" "$PAYEE_ADDR" "$DEADLINE" --value 0.05ether --private-key "$PAYER_KEY" --rpc-url "$FORK" --json | jget transactionHash)
CREATE2_GAS=$(gasof "$CREATE2_TX")
log "CREATE2_TX= $CREATE2_TX GAS= $CREATE2_GAS"
DELIVER2_TX=$(cast send "$ESCROW" "deliver(uint256,bytes32)" 1 "$WORKHASH2" --private-key "$PAYEE_KEY" --rpc-url "$FORK" --json | jget transactionHash)
DELIVER2_GAS=$(gasof "$DELIVER2_TX")
log "DELIVER2_TX= $DELIVER2_TX GAS= $DELIVER2_GAS"
REJECT_TX=$(cast send "$ESCROW" "rejectDelivery(uint256)" 1 --private-key "$PAYER_KEY" --rpc-url "$FORK" --json | jget transactionHash)
REJECT_GAS=$(gasof "$REJECT_TX")
log "REJECT_TX= $REJECT_TX GAS= $REJECT_GAS"
CURE_TX=$(cast send "$ESCROW" "deliver(uint256,bytes32)" 1 "$WORKHASH3" --private-key "$PAYEE_KEY" --rpc-url "$FORK" --json | jget transactionHash)
CURE_GAS=$(gasof "$CURE_TX")
log "CURE_TX= $CURE_TX GAS= $CURE_GAS"
RELEASE2_TX=$(cast send "$ESCROW" "release(uint256)" 1 --private-key "$PAYER_KEY" --rpc-url "$FORK" --json | jget transactionHash)
RELEASE2_GAS=$(gasof "$RELEASE2_TX")
log "RELEASE2_TX= $RELEASE2_TX GAS= $RELEASE2_GAS"
# V2 getEscrow tuple order starts payer, payee, amount, deadline,
# deliveredAt, rejectedAt, settled(7), rejectedOnce(8), ... — same first
# eight positions as v1, so the same line picks work.
ESCROW1_FIELDS=$(cast call "$ESCROW" "getEscrow(uint256)(address,address,uint96,uint40,uint40,uint40,bool,bool,bool,bool,bool,bytes32,address,address,uint96,uint40,uint40,bool,bool,bool)" 1 --rpc-url "$FORK")
SETTLED1=$(echo "$ESCROW1_FIELDS" | sed -n '7p')
REJECTED_ONCE1=$(echo "$ESCROW1_FIELDS" | sed -n '8p')
PAYEE_BAL_AFTER_C=$(cast balance "$PAYEE_ADDR" --rpc-url "$FORK")
log "--- flow C (escrow 1 rejected, cured, released; settled must be true, rejectedOnce stays true) ---"
log "escrow1 settled: $SETTLED1 · rejectedOnce: $REJECTED_ONCE1"
log "payee before C: $(wei2eth "$PAYEE_BAL_BEFORE_C") · after C: $(wei2eth "$PAYEE_BAL_AFTER_C")"
[ "$SETTLED1" = "true" ] || { echo "FLOW C FAIL: escrow 1 not settled" | tee -a "$LOG"; exit 1; }
[ "$REJECTED_ONCE1" = "true" ] || { echo "FLOW C FAIL: escrow 1 rejectedOnce not set" | tee -a "$LOG"; exit 1; }
python3 - "$PAYEE_BAL_AFTER_C" "$PAYEE_BAL_BEFORE_C" <<'PY' | tee -a "$LOG"
import sys
after, before = int(sys.argv[1]), int(sys.argv[2])
assert after > before, (after, before)
print("FLOW C OK: rejected, cured, released; payee gained")
PY

# ---- verify arithmetic (same shape as v1: split delta + flaky + contract) ----
python3 - "$PAYEE_BAL_AFTER_RELEASE" "$PAYEE_BAL_BEFORE_C" "$(cast balance "$FLAKY" --rpc-url "$FORK")" "$(cast balance "$ESCROW" --rpc-url "$FORK")" <<'PY' | tee -a "$LOG"
import sys
payee_after_release, payee_final, flaky_final, contract_final = (int(x) for x in sys.argv[1:5])
ONE = 10**18
assert payee_final - payee_after_release == int(0.05 * ONE), (payee_final - payee_after_release)
assert flaky_final == int(0.05 * ONE), flaky_final
assert contract_final == 0, contract_final
print("VERIFY OK: payee +0.05 from split, flaky 0.05 after withdraw, contract 0")
PY

# ---- gas totals ----
python3 - "$DEPLOY_GAS" "$CREATE_GAS" "$DELIVER_GAS" "$RELEASE_GAS" "$SPLIT_GAS" "$WITHDRAW_GAS" "$CREATE2_GAS" "$DELIVER2_GAS" "$REJECT_GAS" "$CURE_GAS" "$RELEASE2_GAS" "$FLAKY_GAS" <<'PY' | tee -a "$LOG"
import sys
(d, c, dv, r, s, w, c2, dv2, rj, cu, r2, f) = (int(x) for x in sys.argv[1:13])
flow_a = c + dv + r
flow_b = s + w
flow_c = c2 + dv2 + rj + cu + r2
total = d + flow_a + flow_b + flow_c
GWEI = 25
usdc = lambda g: g * GWEI * 10**9 / 10**18
print(f"GAS deploy={d} flowA={flow_a} flowB={flow_b} flowC={flow_c} flakyDeploy={f}")
print(f"GAS fullDemoContractTotal={total} usdc@25gwei={usdc(total):.4f}")
print(f"GAS fullDemoInclFlaky={total + f} usdc@25gwei={usdc(total + f):.4f}")
PY
log "FORK DEMO V2 COMPLETE"
