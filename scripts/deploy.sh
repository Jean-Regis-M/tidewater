#!/usr/bin/env bash
# Deploys Tidewater: Reactive (Lasna) -> Token + Vault (Base Sepolia) -> bind (Lasna).
# Needs .env with PRIVATE_KEY, and funds: Base Sepolia ETH, lREACT on Lasna.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

BASE_PROXY=0x476F44b11F5C942c58f4c8E3d0300E5710743585   # Base Sepolia callback proxy (docs)
BASE_CHAIN=84532
LASNA_CHAIN=5318007
REACTIVE_FUND=${REACTIVE_FUND:-0.3ether}                # lREACT sent with the deploy (becomes reserves)
DEPLOYER=$(cast wallet address --private-key "$PRIVATE_KEY")
extract() { grep -o 'Deployed to: 0x[0-9a-fA-F]*' | awk '{print $3}'; }

echo "Deployer $DEPLOYER"
echo "1/4 Reactive contract on Lasna"
REACTIVE=$(forge create --broadcast --rpc-url "$LASNA_RPC" --private-key "$PRIVATE_KEY" --value "$REACTIVE_FUND" \
  src/TidewaterReactive.sol:TidewaterReactive --constructor-args $BASE_CHAIN | tee /dev/stderr | extract)

echo "2/4 Token on Base Sepolia"
TOKEN=$(forge create --broadcast --rpc-url "$BASE_SEPOLIA_RPC" --private-key "$PRIVATE_KEY" \
  src/TideToken.sol:TideToken | tee /dev/stderr | extract)

echo "3/4 Vault on Base Sepolia"
VAULT=$(forge create --broadcast --rpc-url "$BASE_SEPOLIA_RPC" --private-key "$PRIVATE_KEY" \
  src/TidewaterVault.sol:TidewaterVault --constructor-args "$TOKEN" "$BASE_PROXY" "$REACTIVE" "$DEPLOYER" | tee /dev/stderr | extract)
BLOCK=$(cast block-number --rpc-url "$BASE_SEPOLIA_RPC")

echo "4/4 Bind subscriptions on Lasna"
cast send --rpc-url "$LASNA_RPC" --private-key "$PRIVATE_KEY" "$REACTIVE" "bind(address)" "$VAULT"

echo "5/5 Fund vault callback gas on Base proxy"
cast send --rpc-url "$BASE_SEPOLIA_RPC" --private-key "$PRIVATE_KEY" "$BASE_PROXY" "depositTo(address)" "$VAULT" --value "${CALLBACK_FUND:-0.00005ether}"

mkdir -p deployments
cat > deployments/testnet.json <<EOF
{ "token": "$TOKEN", "vault": "$VAULT", "reactive": "$REACTIVE", "strategy": "$DEPLOYER", "deployBlock": $((BLOCK - 5)) }
EOF
cp deployments/testnet.json frontend/src/deployments.json
echo "Done. See deployments/testnet.json"
