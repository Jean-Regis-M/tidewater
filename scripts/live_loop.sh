#!/usr/bin/env bash
# Runs N live loops on testnet: illiquid vault -> queued withdrawal -> repay (origin event) -> Reactive -> settle callback.
# Appends one JSON line per loop to deployments/measurements.jsonl. Usage: scripts/live_loop.sh [N]
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
N=${1:-1}
B=$BASE_SEPOLIA_RPC
D=$(cast wallet address --private-key "$PRIVATE_KEY")
T=$(python -I -c "import json;print(json.load(open('deployments/testnet.json'))['token'])")
V=$(python -I -c "import json;print(json.load(open('deployments/testnet.json'))['vault'])")
AMT=${AMT:-100000000}   # 100 tUSD (6 decimals)
snd() { cast send --rpc-url "$B" --private-key "$PRIVATE_KEY" "$@" --json; }
field() { python -I -c "import sys,json;print(json.load(sys.stdin)['$1'])"; }
now_ms() { python -I -c "import time;print(int(time.time()*1000))"; }

# one-time setup (idempotent enough for testnet)
if [ "$(cast call $T 'balanceOf(address)(uint256)' $D --rpc-url $B | awk '{print $1}')" -lt "$((AMT*3))" ]; then snd $T "faucet()" >/dev/null; fi
snd $T "approve(address,uint256)" $V $(python -I -c "print(2**256-1)") >/dev/null
CLAIM=$(cast call $V 'claims(address)(uint256)' $D --rpc-url $B | awk '{print $1}')
if [ "$CLAIM" -lt "$AMT" ]; then snd $V "deposit(uint256)" $((AMT*2)) >/dev/null; fi

for i in $(seq 1 "$N"); do
  LIQ=$(cast call $V 'liquidity()(uint256)' --rpc-url $B | awk '{print $1}')
  CLAIM=$(cast call $V 'claims(address)(uint256)' $D --rpc-url $B | awk '{print $1}')
  [ "$CLAIM" -lt "$AMT" ] && snd $V "deposit(uint256)" $((AMT*2)) >/dev/null   # keep a claim to withdraw
  LIQ=$(cast call $V 'liquidity()(uint256)' --rpc-url $B | awk '{print $1}')
  [ "$LIQ" -gt 0 ] && snd $V "lend(uint256)" "$LIQ" >/dev/null           # make vault illiquid
  Q=$(snd $V "requestWithdraw(uint256)" $AMT) || { echo "queue failed, skipping loop $i" >&2; continue; }
  QTX=$(echo "$Q" | field transactionHash)
  sleep 4                                                                  # let Reactive mirror the queue
  P0=$(cast call $V 'pending()(uint256)' --rpc-url $B | awk '{print $1}')
  T0=$(now_ms)
  R=$(snd $V "repay(uint256)" $((AMT*2)))                                  # ORIGIN EVENT: LiquidityAdded
  RTX=$(echo "$R" | field transactionHash)
  T1=$(now_ms)
  SETTLED=0
  for k in $(seq 1 120); do
    P=$(cast call $V 'pending()(uint256)' --rpc-url $B | awk '{print $1}')
    if [ "$P" -lt "$P0" ]; then SETTLED=1; break; fi
    sleep 0.25
  done
  T2=$(now_ms)
  # find the Settled event tx (latest)
  SETTLE_TX=$(cast logs --rpc-url $B --address $V "Settled(uint256,uint256,uint256,uint256,uint256)" --from-block $(( $(cast block-number --rpc-url $B) - 150 )) --json | python -I -c "import sys,json;l=json.load(sys.stdin);print(l[-1]['transactionHash'] if isinstance(l,list) and l else '')")
  echo "{\"loop\":$i,\"queueTx\":\"$QTX\",\"originTx\":\"$RTX\",\"settleTx\":\"$SETTLE_TX\",\"settled\":$SETTLED,\"repayConfirmedToSettledMs\":$((T2-T1)),\"sendToSettledMs\":$((T2-T0))}" | tee -a deployments/measurements.jsonl
done
