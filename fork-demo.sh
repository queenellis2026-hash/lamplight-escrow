#!/usr/bin/env bash
# Fork demo for LamplightEscrow (PULL design) on a local Anvil fork of Arc mainnet.
# Usage: bash fork-demo.sh   (writes fork-demo.log in this directory)
# Keys are generated fresh at runtime and NEVER printed or logged.
# Gotcha (see STATUS.md §7): never use well-known Anvil test addresses as
# recipients on an Arc fork — they carry EIP-7702 delegation code on mainnet
# and forward any funds they receive. Fresh random addresses, verified
# code-free on mainnet, are used for every role.
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$HOME/.foundry/bin:$PATH"

FORK=http://127.0.0.1:8545
LOG=fork-demo.log
: > "$LOG"
log() { echo "$*" | tee -a "$LOG"; }
wei2eth() { python3 -c "print(f'{int(\"$1\") / 10**18:.18f}')"; }

newkey() { # prints "address privatekey" on one line (never logged)
    cast wallet new --json | python3 -c "import json,sys; d=json.load(sys.stdin)['data'][0]; print(d['address'], d['private_key'])"
}

# ---- start anvil fork ----
anvil --fork-url https://rpc.mainnet.arc.io --chain-id 5042 --port 8545 >/tmp/anvil-fork.log 2>&1 &
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

# cast/forge --json output is wrapped: {"schema_version":1,...,"data":{...}}
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
log "CONTRACT= $ESCROW"
log "FLAKY= $FLAKY"
log "DEPLOY_TX= $DEPLOY_TX GAS= $(gasof "$DEPLOY_TX")"
log "FLAKY_TX= $FLAKY_TX GAS= $(gasof "$FLAKY_TX")"

DEADLINE=1893456000  # 2030-01-01
WORKHASH=0xef5be078c3c73acb793cef2537a4529b4e02a1e7d88c82e44018a205535fed72

# ---- Flow A: escrow 0.27, EOA payee (direct payout path) ----
CREATE_TX=$(cast send "$ESCROW" "createEscrow(address,uint256)" "$PAYEE_ADDR" "$DEADLINE" --value 0.27ether --private-key "$PAYER_KEY" --rpc-url "$FORK" --json | jget transactionHash)
log "CREATE_TX= $CREATE_TX GAS= $(gasof "$CREATE_TX")"
log "WORKHASH=$WORKHASH"
DELIVER_TX=$(cast send "$ESCROW" "deliver(uint256,bytes32)" 0 "$WORKHASH" --private-key "$PAYEE_KEY" --rpc-url "$FORK" --json | jget transactionHash)
log "DELIVER_TX= $DELIVER_TX GAS= $(gasof "$DELIVER_TX")"
RELEASE_TX=$(cast send "$ESCROW" "release(uint256)" 0 --private-key "$PAYER_KEY" --rpc-url "$FORK" --json | jget transactionHash)
log "RELEASE_TX= $RELEASE_TX GAS= $(gasof "$RELEASE_TX")"
log "--- escrow 0 after release (payer, payee, amount, deadline, workHash, delivered, settled) ---"
cast call "$ESCROW" "getEscrow(uint256)(address,address,uint256,uint256,bytes32,bool,bool)" 0 --rpc-url "$FORK" | tee -a "$LOG"
PAYEE_BAL_AFTER_RELEASE=$(cast balance "$PAYEE_ADDR" --rpc-url "$FORK")
PENDING_PAYEE=$(cast call "$ESCROW" "pendingWithdrawals(address)(uint256)" "$PAYEE_ADDR" --rpc-url "$FORK")
log "--- balances after release (payee should be ~10 + 0.27 minus deliver gas; pending 0) ---"
log "payee: $(wei2eth "$PAYEE_BAL_AFTER_RELEASE")"
log "payee pendingWithdrawals: $PENDING_PAYEE"

# ---- Flow B: split 0.10 50/50, payee (EOA, direct) + flaky (reverting, credited) ----
SPLIT_TX=$(cast send "$ESCROW" "splitPayment(address[],uint256[])" "[$PAYEE_ADDR,$FLAKY]" "[5000,5000]" --value 0.1ether --private-key "$PAYER_KEY" --rpc-url "$FORK" --json | jget transactionHash)
log "SPLIT_TX= $SPLIT_TX GAS= $(gasof "$SPLIT_TX")"
PENDING_FLAKY=$(cast call "$ESCROW" "pendingWithdrawals(address)(uint256)" "$FLAKY" --rpc-url "$FORK")
CONTRACT_BAL=$(cast balance "$ESCROW" --rpc-url "$FORK")
log "--- balances after split (payee +0.05 direct; flaky credited 0.05; contract holds 0.05) ---"
log "payee: $(wei2eth "$(cast balance "$PAYEE_ADDR" --rpc-url "$FORK")")"
log "flaky pendingWithdrawals: $PENDING_FLAKY"
log "contract: $(wei2eth "$CONTRACT_BAL")"

# ---- Flaky fixes itself and pulls the credit ----
cast send "$FLAKY" "setReverting(bool)" false --private-key "$PAYER_KEY" --rpc-url "$FORK" --json >/dev/null
WITHDRAW_TX=$(cast send "$FLAKY" "withdrawFrom(address)" "$ESCROW" --private-key "$PAYER_KEY" --rpc-url "$FORK" --json | jget transactionHash)
log "WITHDRAW_TX= $WITHDRAW_TX GAS= $(gasof "$WITHDRAW_TX")"
log "--- final balances (flaky 0.05; contract must be 0) ---"
log "flaky: $(wei2eth "$(cast balance "$FLAKY" --rpc-url "$FORK")")"
log "flaky pendingWithdrawals: $(cast call "$ESCROW" "pendingWithdrawals(address)(uint256)" "$FLAKY" --rpc-url "$FORK")"
log "contract (must be 0): $(wei2eth "$(cast balance "$ESCROW" --rpc-url "$FORK")")"

# ---- verify arithmetic ----
python3 - "$PAYEE_BAL_AFTER_RELEASE" "$(cast balance "$PAYEE_ADDR" --rpc-url "$FORK")" "$(cast balance "$FLAKY" --rpc-url "$FORK")" "$(cast balance "$ESCROW" --rpc-url "$FORK")" <<'PY' | tee -a "$LOG"
import sys
payee_after_release, payee_final, flaky_final, contract_final = (int(x) for x in sys.argv[1:5])
ONE = 10**18
# payee: 10 + 0.27 (release) + 0.05 (split) - deliver gas. Deliver gas is
# unknown here, so check the delta between release and final instead:
assert payee_final - payee_after_release == int(0.05 * ONE), (payee_final - payee_after_release)
assert flaky_final == int(0.05 * ONE), flaky_final
assert contract_final == 0, contract_final
print("VERIFY OK: payee +0.05 from split, flaky 0.05 after withdraw, contract 0")
PY
log "FORK DEMO COMPLETE (pull design)"
