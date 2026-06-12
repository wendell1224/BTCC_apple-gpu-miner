#!/usr/bin/env bash
# Connect to a SHA-256d Stratum v1 mining pool and mine with the Metal GPU
# helper on Apple Silicon. No bitcoind required.
#
# Usage:
#   scripts/start_stratum.sh <wallet_address> [worker_name | pool_url] [pool_url]
#                            [extra args passed to stratum_miner.py ...]
#
# Either of the two trailing positional slots can be a stratum:// URL; the
# script auto-detects which is which. Anything else is treated as the worker
# name. Anything starting with "--" is forwarded verbatim to stratum_miner.py.
#
# Examples:
#   # Default pool, worker = hostname
#   scripts/start_stratum.sh cc1qs4dyl50qvvk3je2x8sn56semk40lhzc5pahufp
#
#   # Custom pool only (worker stays at hostname)
#   scripts/start_stratum.sh cc1q....  stratum+tcp://your.pool:3333
#
#   # Custom worker AND pool
#   scripts/start_stratum.sh cc1q....  m2-laptop  stratum+tcp://your.pool:3333
#
#   # Forward extra flags to the Python miner
#   scripts/start_stratum.sh cc1q....  --gpu-target-seconds 0.3
#
# Defaults:
#   worker_name = $(hostname -s)
#   pool_url    = $POOL_URL  (env)  ||  stratum+tcp://pool.btc-classic.org:63101
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ "$(uname)" != "Darwin" ]]; then
    echo "[stratum] macOS only (Metal). uname=$(uname)"; exit 1
fi

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <wallet_address> [worker_name | pool_url] [pool_url] [extra args]"
    echo "Examples:"
    echo "  $0 cc1qs4dyl50qvvk3je2x8sn56semk40lhzc5pahufp"
    echo "  $0 cc1q....  stratum+tcp://pool.btc-classic.org:63101"
    echo "  $0 cc1q....  m2-laptop  stratum+tcp://your.pool:3333"
    exit 2
fi

ADDRESS="$1"; shift || true

URL_DEFAULT="${POOL_URL:-stratum+tcp://pool.btc-classic.org:63101}"
WORKER_DEFAULT="$(hostname -s 2>/dev/null || echo m2)"
WORKER=""
URL=""

# Walk up to the first two trailing positional args (anything before --flags),
# auto-detecting which is the URL and which is the worker name.
while [[ $# -gt 0 && "$1" != --* ]]; do
    if [[ "$1" =~ ^stratum ]]; then
        URL="$1"
    else
        WORKER="$1"
    fi
    shift || true
    # We only consume up to two leading positionals.
    if [[ -n "$WORKER" && -n "$URL" ]]; then break; fi
    if [[ $# -gt 0 && "$1" == --* ]]; then break; fi
done

WORKER="${WORKER:-$WORKER_DEFAULT}"
URL="${URL:-$URL_DEFAULT}"

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
