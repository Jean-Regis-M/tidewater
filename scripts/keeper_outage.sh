#!/usr/bin/env bash
# Keeper outage experiment on the BASELINE vault (same vault code, keeper EOA is the authorised caller).
#
# 1. With NO keeper process running, queue a withdrawal and return liquidity.
# 2. Watch the vault for OUTAGE seconds: does anything settle it?
# 3. Start the keeper (poll 250 ms) and measure how long until the queue is paid.
#
# Stop any running keeper before using this. Usage: scripts/keeper_outage.sh [outage_seconds]
# Prints one JSON line. Read the README section "Keeper baseline" for how to interpret it.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
OUTAGE=${1:-30}
B=$BASE_SEPOLIA_RPC

# Preflight: the experiment is meaningless if any keeper is still alive (a stray one invalidated an earlier attempt).
RUNNING=$(powershell -NoProfile -Command "@(Get-CimInstance Win32_Process -Filter \"Name='node.exe'\" | Where-Object { \$_.CommandLine -match 'keeper\\.mjs' }).Count" | tr -d '\r')
if [ "${RUNNING:-0}" != "0" ]; then
  echo "refusing to run: $RUNNING keeper process(es) already running. Stop them with baseline/stop-keepers.ps1" >&2
  exit 1
fi
D=$(cast wallet address --private-key "$PRIVATE_KEY")
T=$(python -I -c "import json;print(json.load(open('deployments/baseline.json'))['token'])")
V=$(python -I -c "import json;print(json.load(open('deployments/baseline.json'))['vault'])")
AMT=100000000
snd() { cast send --rpc-url "$B" --private-key "$PRIVATE_KEY" "$@" --json; }
now_ms() { python -I -c "import time;print(int(time.time()*1000))"; }
pend() { cast call $V 'pending()(uint256)' --rpc-url $B | awk '{print $1}'; }

CLAIM=$(cast call $V 'claims(address)(uint256)' $D --rpc-url $B | awk '{print $1}')
[ "$CLAIM" -lt "$AMT" ] && snd $V "deposit(uint256)" $((AMT*2)) >/dev/null
LIQ=$(cast call $V 'liquidity()(uint256)' --rpc-url $B | awk '{print $1}')
[ "$LIQ" -gt 0 ] && snd $V "lend(uint256)" "$LIQ" >/dev/null
snd $V "requestWithdraw(uint256)" $AMT >/dev/null
P0=$(pend)
T0=$(now_ms)
snd $V "repay(uint256)" $((AMT*2)) >/dev/null     # liquidity returns; no keeper is running
echo "liquidity returned at t=0; keeper is OFFLINE; watching for ${OUTAGE}s" >&2
SETTLED_DURING_OUTAGE=0
while [ $(( $(now_ms) - T0 )) -lt $((OUTAGE*1000)) ]; do
  [ "$(pend)" -lt "$P0" ] && { SETTLED_DURING_OUTAGE=1; break; }
  sleep 1
done
T1=$(now_ms)
PENDING_AFTER_OUTAGE=$(pend)

# bring the keeper back
(cd baseline && nohup node keeper.mjs "$V" 250 > /tmp/keeper-outage.log 2>&1 & echo $! > /tmp/keeper-outage.pid)
T2=$(now_ms)
while [ "$(pend)" -ge "$P0" ]; do sleep 0.25; [ $(( $(now_ms) - T2 )) -gt 60000 ] && break; done
T3=$(now_ms)
powershell -NoProfile -ExecutionPolicy Bypass -File baseline/stop-keepers.ps1 >&2

echo "{\"outageSeconds\":$OUTAGE,\"settledDuringOutage\":$SETTLED_DURING_OUTAGE,\"pendingAfterOutage\":$PENDING_AFTER_OUTAGE,\"unsettledForMs\":$((T1-T0)),\"msFromKeeperRestartToSettled\":$((T3-T2))}"
