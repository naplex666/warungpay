#!/usr/bin/env bash
# Deploy WarungPay to Aevum testnet (chain 44005).
# Reads the deployer private key from hidden_files/deployer.json WITHOUT
# printing it, then runs forge script with broadcast + Blockscout verify.
# Requires tQDAY (gas) and tUSD8 in the deployer wallet — claim at faucet.qday.info first.
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$HOME/.local/bin:$PATH"

KEYFILE="$HOME/workspace/goals/hackathon-aevum-builder-challenge/hidden_files/deployer.json"
RPC="https://rpc-test.qday.info"

if [ ! -f "$KEYFILE" ]; then
  echo "deployer.json not found: $KEYFILE" >&2
  exit 1
fi

# Balance check (no secret printed).
DEPLOYER=$(python3 -c "import json;print(json.load(open('$KEYFILE'))['data'][0]['address'])")
echo "Deployer: $DEPLOYER"
echo "tQDAY:  $(cast balance "$DEPLOYER" --rpc-url "$RPC")"
echo "tUSD8:  $(cast call 0x456569838f1d43009A91ebA4263147Afd7233483 'balanceOf(address)(uint256)' "$DEPLOYER" --rpc-url "$RPC")"

PRIVATE_KEY=$(python3 -c "import json;print(json.load(open('$KEYFILE'))['data'][0]['private_key'])")
export PRIVATE_KEY

forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$RPC" \
  --broadcast \
  --verify \
  --verifier blockscout \
  --verifier-url https://explorer-test.qday.info/api
