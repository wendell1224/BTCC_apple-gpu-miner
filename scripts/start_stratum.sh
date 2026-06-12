#!/usr/bin/env bash
# Connect to a SHA-256d Stratum v1 mining pool and mine with the Metal GPU
# helper on Apple Silicon. No bitcoind required.
#
# Usage:
#   scripts/start_stratum.sh <wallet_address> [worker_name] [pool_url]
#                            [extra args passed to stratum_miner.py ...]
#
# Examples:
#   # BTCC default pool
#   scripts/start_stratum.sh cc1qs4dyl50qvvk3je2x8sn56semk40lhzc5pahufp
#
#   # Custom pool
#   scripts/start_stratum.sh bc1q....  m2-laptop  stratum+tcp://your.pool:3333
#
#   # Tune the GPU batch size
#   scripts/start_stratum.sh cc1q....  m2-laptop  ""  --gpu-batch 67108864
#
# Defaults:
#   worker_name = $(hostname -s)
#   pool_url    = stratum+tcp://btccmine.top:3333
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ "$(uname)" != "Darwin" ]]; then
    echo "[stratum] macOS only (Metal). uname=$(uname)"; exit 1
fi

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <wallet_address> [worker_name] [pool_url] [extra args]"
    echo "Examples:"
    echo "  $0 cc1qs4dyl50qvvk3je2x8sn56semk40lhzc5pahufp"
    echo "  $0 bc1q....  m2-laptop  stratum+tcp://your.pool:3333"
    exit 2
fi

ADDRESS="$1"; shift || true

WORKER="${1:-$(hostname -s 2>/dev/null || echo m2)}"
if [[ $# -ge 1 ]]; then shift || true; fi

URL_DEFAULT="${POOL_URL:-stratum+tcp://btccmine.top:3333}"
URL="${1:-$URL_DEFAULT}"
if [[ "$URL" =~ ^stratum ]]; then
    if [[ $# -ge 1 ]]; then shift || true; fi
else
    URL="$URL_DEFAULT"
fi

EXTRA_ARGS=()
if [[ $# -gt 0 ]]; then EXTRA_ARGS=("$@"); fi

GPU_BIN="${GPU_BIN:-$REPO_ROOT/src/metal_nonce_finder}"
if [[ ! -x "$GPU_BIN" ]]; then
    echo "[stratum] $GPU_BIN not built; building now ..."
    "$SCRIPT_DIR/build_metal.sh"
fi

USERNAME="${ADDRESS}.${WORKER}"

echo "[stratum] pool   : $URL"
echo "[stratum] user   : $USERNAME"
echo "[stratum] gpu    : $GPU_BIN"
echo "[stratum] press Ctrl-C to stop."
echo

exec python3 "$REPO_ROOT/src/stratum_miner.py" \
    --url "$URL" \
    --user "$USERNAME" \
    --pass x \
    --gpu --gpu-binary "$GPU_BIN" \
    ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
