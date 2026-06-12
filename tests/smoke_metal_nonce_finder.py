#!/usr/bin/env python3
"""Smoke-test miner/metal_nonce_finder against CPU SHA-256d.

Builds a deterministic 80-byte header and a series of targets ranging from
'trivial' to 'a bit harder'. For each, invokes the GPU helper and verifies
that the returned (nonce, hash) actually satisfies sha256d(header) <= target.
"""
import hashlib
import json
import os
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(HERE)
GPU_BIN = os.environ.get(
    "GPU_BIN",
    os.path.join(REPO_ROOT, "src", "metal_nonce_finder"),
)


def sha256d(b: bytes) -> bytes:
    return hashlib.sha256(hashlib.sha256(b).digest()).digest()


def make_header(version, prev, merkle, ntime, nbits, nonce):
    return (
        struct.pack("<I", version)
        + prev
        + merkle
        + struct.pack("<I", ntime)
        + struct.pack("<I", nbits)
        + struct.pack("<I", nonce)
    )


def run_gpu(header80: bytes, target_be: bytes, start_nonce: int, count: int,
            per_dispatch: int = 1 << 16):
    cmd = [
        GPU_BIN,
        "--header-prefix", header80.hex(),
        "--target", target_be.hex(),
        "--start-nonce", str(start_nonce),
        "--count", str(count),
        "--per-dispatch", str(per_dispatch),
    ]
    out = subprocess.run(cmd, check=True, capture_output=True, text=True)
    return json.loads(out.stdout.strip().splitlines()[-1])


def main():
    # Fixed header content (nonce field will be overwritten by the kernel anyway).
    version = 0x20000000
    prev = bytes(range(32))                   # 00..1f
    merkle = bytes(range(64, 96))             # 40..5f
    ntime = 0x65000000
    nbits = 0x207fffff                        # regtest-style nbits

    header_prefix = make_header(version, prev, merkle, ntime, nbits, 0)

    # (name, target, scan_count, must_find)
    # must_find=True cases set scan_count well above 1/p so missing is a bug.
    # must_find=False is informational only (probabilistic).
    cases = [
        ("trivial-all-ff", (1 << 256) - 1, 1 << 16, True),
        ("2^248-1",        (1 << 248) - 1, 1 << 18, True),
        ("2^240-1",        (1 << 240) - 1, 1 << 20, True),
        ("2^232-1",        (1 << 232) - 1, 1 << 28, True),   # ~1 in 16M, scan 256M
    ]

    rc = 0
    for name, target_int, scan_count, must_find in cases:
        target_be = target_int.to_bytes(32, "big")
        result = run_gpu(header_prefix, target_be, start_nonce=0,
                         count=scan_count, per_dispatch=1 << 20)
        if not result.get("found"):
            status = "FAIL" if must_find else "INFO"
            if must_find:
                rc = 1
            print(f"[{status}] {name}: not found in {scan_count} scans "
                  f"(hashrate={result.get('hashrate')} H/s)")
            continue

        nonce = int(result["nonce"]) & 0xFFFFFFFF
        gpu_hash_hex = result["hash"]

        header_full = make_header(version, prev, merkle, ntime, nbits, nonce)
        cpu_hash_be_hex = sha256d(header_full)[::-1].hex()
        cpu_hash_int = int(cpu_hash_be_hex, 16)

        ok_match = (gpu_hash_hex == cpu_hash_be_hex)
        ok_below = (cpu_hash_int <= target_int)
        status = "OK" if (ok_match and ok_below) else "FAIL"
        if status != "OK":
            rc = 1
        print(f"[{status}] {name}")
        print(f"        nonce         = {nonce}")
        print(f"        gpu_hash_be   = {gpu_hash_hex}")
        print(f"        cpu_hash_be   = {cpu_hash_be_hex}")
        print(f"        target_be     = {target_be.hex()}")
        print(f"        match         = {ok_match}")
        print(f"        hash<=target  = {ok_below}")
        print(f"        hashrate      = {result.get('hashrate')} H/s")

    return rc


if __name__ == "__main__":
    sys.exit(main())
