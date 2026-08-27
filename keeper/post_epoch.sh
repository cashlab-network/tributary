#!/usr/bin/env bash
# Tributary keeper: post one borrower's ledger row for the new reward epoch.
# v1 trust model: the poster derives every value from Flare's PUBLIC per-epoch
# reward + pass files; anyone can verify a post against those files.
#
# Usage:
#   ORACLE=0x... BORROWER=0x... EPOCH=1234 TRAILING_WEI=... PASSES=3 \
#   SETTLED=20 ALIVE=true RPC=https://coston2-api.flare.network/ext/C/rpc \
#   ./post_epoch.sh
#
# The poster key comes from KEEPER_KEYSTORE (cast keystore path) or, for
# throwaway testnet keys only, KEEPER_PK. Never a mainnet-funds key.
set -euo pipefail

: "${ORACLE:?set ORACLE (PassLedgerOracle address)}"
: "${BORROWER:?set BORROWER}"
: "${EPOCH:?set EPOCH (must be > last posted)}"
: "${TRAILING_WEI:?set TRAILING_WEI (trailing avg reward per epoch, wei)}"
: "${PASSES:?set PASSES (0..3)}"
: "${SETTLED:?set SETTLED (total settled epochs)}"
: "${ALIVE:?set ALIVE (true|false)}"
: "${RPC:?set RPC}"

AUTH=()
if [[ -n "${KEEPER_KEYSTORE:-}" ]]; then
  AUTH=(--keystore "$KEEPER_KEYSTORE")
elif [[ -n "${KEEPER_PK:-}" ]]; then
  AUTH=(--private-key "$KEEPER_PK")
else
  echo "set KEEPER_KEYSTORE or (testnet only) KEEPER_PK" >&2
  exit 1
fi

# WNat checkpointing downstream costs more than estimates: pad gas.
cast send "$ORACLE" \
  "post(address,uint64,uint192,uint32,uint32,bool)" \
  "$BORROWER" "$EPOCH" "$TRAILING_WEI" "$PASSES" "$SETTLED" "$ALIVE" \
  --rpc-url "$RPC" --gas-limit 200000 "${AUTH[@]}"

echo "posted: borrower=$BORROWER epoch=$EPOCH trailing=$TRAILING_WEI passes=$PASSES alive=$ALIVE"
