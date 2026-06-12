#!/usr/bin/env bash
# Build the Metal GPU SHA-256d nonce searcher (Apple Silicon / macOS only).
#
# Output: src/metal_nonce_finder
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$REPO_ROOT/src/metal_nonce_finder.mm"
OUT="$REPO_ROOT/src/metal_nonce_finder"

if [[ "$(uname)" != "Darwin" ]]; then
    echo "[build_metal] error: macOS only (Metal). uname=$(uname)"
    exit 1
fi

if [[ ! -f "$SRC" ]]; then
    echo "[build_metal] error: source not found: $SRC"
    exit 1
fi

if ! command -v clang++ >/dev/null 2>&1; then
    echo "[build_metal] error: clang++ not found. Install Xcode Command Line Tools:"
    echo "    xcode-select --install"
    exit 1
fi

echo "[build_metal] arch=$(uname -m)  compiling $SRC ..."
clang++ -std=c++17 -O3 -fobjc-arc \
    -Wall -Wno-deprecated-declarations \
    -framework Foundation -framework Metal -framework IOKit \
    -o "$OUT" "$SRC"

echo "[build_metal] built: $OUT"
ls -la "$OUT"
