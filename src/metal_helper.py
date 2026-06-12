"""Persistent metal_nonce_finder subprocess helper.

The Metal binary takes ~0.5 s to compile its SHA-256d shader on first run.
Doing that once per batch (the old fork-and-exec model) wasted CPU and meant
job-switch latency was dominated by helper startup. This module keeps the
binary alive across batches: one shader compile + one IOKit GPU probe at
startup, then one JSON line in / one JSON line out per batch.

The helper itself auto-tunes its threadgroup and per-dispatch sizes from
the detected Apple GPU core count, so callers don't need to know whether
they're on M1/M2/M3/M4 base/Pro/Max/Ultra.

This module uses only the Python standard library.
"""
from __future__ import annotations

import json
import subprocess


class MetalGpuHelper:
    """Wraps a long-lived metal_nonce_finder process in --persistent mode."""

    def __init__(self, binary: str, *,
                 threadgroup: int = 0, per_dispatch: int = 0) -> None:
        self._binary = binary
        argv = [binary, "--persistent"]
        if threadgroup and threadgroup > 0:
            argv += ["--threadgroup", str(int(threadgroup))]
        if per_dispatch and per_dispatch > 0:
            argv += ["--per-dispatch", str(int(per_dispatch))]
        try:
            self._proc = subprocess.Popen(
                argv,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=None,           # passthrough to terminal
                bufsize=1,
                text=True,
            )
        except FileNotFoundError as e:
            raise RuntimeError(
                f"GPU helper not found at '{binary}'. "
                "Build it with scripts/build_metal.sh."
            ) from e

    def search(self, *, header80: bytes, target_be: bytes,
               start_nonce: int, count: int) -> dict:
        """Submit one nonce-search job and block until a JSON result arrives."""
        if len(header80) != 80:
            raise ValueError("header80 must be 80 bytes")
        if len(target_be) != 32:
            raise ValueError("target_be must be 32 bytes (big-endian)")
        rc = self._proc.poll()
        if rc is not None:
            raise RuntimeError(f"GPU helper exited (rc={rc})")

        req = json.dumps({
            "header_prefix": header80.hex(),
            "target": target_be.hex(),
            "start_nonce": int(start_nonce) & 0xFFFFFFFF,
            "count": int(count),
        })
        try:
            self._proc.stdin.write(req + "\n")
            self._proc.stdin.flush()
        except (BrokenPipeError, OSError) as e:
            raise RuntimeError("GPU helper stdin closed") from e

        line = self._proc.stdout.readline()
        if not line:
            raise RuntimeError(
                f"GPU helper closed unexpectedly (rc={self._proc.poll()})"
            )
        result = json.loads(line)
        if isinstance(result, dict) and "error" in result:
            raise RuntimeError(f"GPU helper error: {result['error']}")
        return result

    def close(self) -> None:
        try:
            if self._proc.stdin:
                self._proc.stdin.close()
        except Exception:
            pass
        try:
            self._proc.wait(timeout=5)
        except Exception:
            try:
                self._proc.kill()
            except Exception:
                pass
