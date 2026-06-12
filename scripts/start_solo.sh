#!/usr/bin/env bash
# Solo-mine against a Bitcoin Core-compatible node via getblocktemplate +
# submitblock, using the Metal GPU helper for the SHA-256d nonce search.
#
# This script DOES NOT start a node for you. Run your own bitcoind / btccd /
# any Core-compatible daemon, then point this script at its RPC endpoint.
#
# Usage:
#   scripts/start_solo.sh [extra args passed to gbt_miner.py ...]
#
# Configure the RPC endpoint and payout address either as gbt_miner.py flags
# or via environment variables:
#
#   RPCHOST=127.0.0.1   RPCPORT=8332   (defaults shown below: 28476 for BTCC)
#   RPCUSER=user        RPCPASSWORD=pass
#   ADDRESS=bc1q....    (optional; if empty, the miner asks the node's wallet)
#
# Examples:
#   # Default RPC (127.0.0.1:28476 user/pass), use wallet's getnewaddress
#   scripts/start_solo.sh
#
#   # Override pinned to your own bitcoind on standard mainnet port
#   RPCPORT=8332 ADDRESS=bc1q... scripts/start_solo.sh
#
#   # Pass any flag through to gbt_miner.py
#   scripts/start_solo.sh --max-blocks 3 --gpu-batch 67108864
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ "$(uname)" != "Darwin" ]]; then
    echo "[solo-gpu] macOS only (Metal). uname=$(uname)"; exit 1
fi

GPU_BIN="${GPU_BIN:-$REPO_ROOT/src/metal_nonce_finder}"
if [[ ! -x "$GPU_BIN" ]]; then
    echo "[solo-gpu] $GPU_BIN not built; building now ..."
    "$SCRIPT_DIR/build_metal.sh"
fi

RPCHOST="${RPCHOST:-127.0.0.1}"
RPCPORT="${RPCPORT:-28476}"
RPCUSER="${RPCUSER:-user}"
RPCPASSWORD="${RPCPASSWORD:-pass}"

ARGS=(
    --rpchost "$RPCHOST"
    --rpcport "$RPCPORT"
    --rpcuser "$RPCUSER"
    --rpcpassword "$RPCPASSWORD"
    --gpu --gpu-binary "$GPU_BIN"
)
if [[ -n "${ADDRESS:-}" ]]; then
    ARGS+=(--address "$ADDRESS")
fi
if [[ $# -gt 0 ]]; then
    ARGS+=("$@")
fi

echo "[solo-gpu] RPC    : http://$RPCHOST:$RPCPORT"
echo "[solo-gpu] gpu    : $GPU_BIN"
echo "[solo-gpu] launching gbt_miner.py ${ARGS[*]}"

exec python3 "$REPO_ROOT/src/gbt_miner.py" "${ARGS[@]}"
