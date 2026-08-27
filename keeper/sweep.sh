#!/usr/bin/env bash
# Tributary keeper: sweep a loan's RewardCollector — wraps any native FLR that
# reward claims delivered and routes the balance (repayment while the loan is
# active; back to the borrower once it is terminal). Safe to run on a timer:
# an empty collector just reverts NothingToSweep.
#
# Usage:
#   COLLECTOR=0x... RPC=https://coston2-api.flare.network/ext/C/rpc ./sweep.sh
set -euo pipefail

: "${COLLECTOR:?set COLLECTOR (the loan's RewardCollector address)}"
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

# Real WNat vote-power checkpointing under-estimates: fixed generous limit.
cast send "$COLLECTOR" "sweep()" --rpc-url "$RPC" --gas-limit 600000 "${AUTH[@]}"
echo "swept $COLLECTOR"
