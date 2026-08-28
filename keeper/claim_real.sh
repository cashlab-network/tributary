#!/usr/bin/env bash
# Execute the FIRST real Flare reward claim through the executor path, once
# epoch 5994's root is signed (watcher watch_claim.sh fires). Proofless
# weight-based claim (provider's WNAT claims already initialised), executor =
# deployer, owner = the delegator EOA, recipient = deployer (enrolled as an
# allowed recipient 2026-08-27). See research/REAL-CLAIM-RUNBOOK.md.
#
# Usage: source .env && EPOCH=5994 ./keeper/claim_real.sh
set -euo pipefail
: "${DEPLOYER_PK:?source .env}"
: "${BORROWER_PK:?source .env}"
EPOCH="${EPOCH:-5994}"
R=https://coston2-api.flare.network/ext/C/rpc
RM=0xB4f43E342c5c77e6fe060c0481Fe313Ff2503454   # RewardManager (Coston2)
OWNER=0xB428fdb8fd187eeabeF1De68c136995AD576577e  # delegator (reward owner)
RECIP=0xadC5dDB878FfEb396256e5F56900cf44931FE92B  # deployer/keeper (allowed recipient)
GAS="--gas-price 1200gwei --priority-gas-price 100gwei"

echo "== pre-claim state =="
echo "recipient native C2FLR before (wrap=false delivers native):"
cast balance "$RECIP" --rpc-url "$R"

# Proofless claim: empty RewardClaimWithProof[] array.
SIG="claim(address,address,uint24,bool,(bytes32[],(uint24,bytes20,uint120,uint8))[])"
echo "== dry-run (eth_call) =="
cast call "$RM" "$SIG" "$OWNER" "$RECIP" "$EPOCH" false "[]" --from "$RECIP" --rpc-url "$R" || {
  echo "dry-run reverted — rewards may not be claimable yet, or proofless path unavailable."
  echo "Check research/REAL-CLAIM-RUNBOOK.md for the proof-bearing fallback."
  exit 1
}

echo "== broadcasting claim (executor = deployer) =="
cast send "$RM" "$SIG" "$OWNER" "$RECIP" "$EPOCH" false "[]" \
  --private-key "$DEPLOYER_PK" --rpc-url "$R" $GAS

echo "== post-claim state =="
echo "recipient native C2FLR after (delta minus gas = the real reward):"
cast balance "$RECIP" --rpc-url "$R"
