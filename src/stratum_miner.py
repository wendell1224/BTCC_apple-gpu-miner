#!/usr/bin/env python3
"""
Stratum v1 SHA-256d pool miner.

Connects to a Stratum v1 mining pool (e.g. stratum+tcp://btccmine.top:3333),
authenticates, receives mining jobs, drives the local Metal GPU helper
(or Python CPU) to find shares, and submits them back.

No `bitcoind` required: the pool gives you the block template; the pool
also relays found blocks to the network and pays you periodically to the
wallet address you provided in the username.

Python stdlib only (socket + threading + json + struct + hashlib + subprocess).

Usage:
  python3 miner/stratum_miner.py \\
      --url stratum+tcp://btccmine.top:3333 \\
      --user cc1q....your_btcc_address.worker1 \\
      --pass x \\
      --gpu \\
      --gpu-binary miner/metal_nonce_finder
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import queue
import random
import socket
import struct
import sys
import threading
import time
from dataclasses import dataclass, field
from typing import Any, Optional
from urllib.parse import urlparse

from metal_helper import MetalGpuHelper

# Bitcoin diff-1 target (256-bit big-endian integer).
DIFF1_TARGET = 0x00000000FFFF0000000000000000000000000000000000000000000000000000


def sha256d(b: bytes) -> bytes:
    return hashlib.sha256(hashlib.sha256(b).digest()).digest()


def diff_to_target_int(diff: float) -> int:
    if diff <= 0:
        return (1 << 256) - 1
    return int(DIFF1_TARGET / diff)


def stratum_prevhash_to_le32(prev_hex: str) -> bytes:
    """Stratum sends prevhash as 32 bytes whose 8 4-byte words are each in
    big-endian order. To produce the canonical little-endian-on-the-wire
    `prev` field for the block header, reverse each 4-byte word in place."""
    b = bytes.fromhex(prev_hex)
    if len(b) != 32:
        raise ValueError(f"prev hex must be 32 bytes, got {len(b)}")
    return b"".join(b[i : i + 4][::-1] for i in range(0, 32, 4))


@dataclass
class Job:
    job_id: str
    prev_le32: bytes              # 32 bytes ready to drop into header
    coinbase1: bytes
    coinbase2: bytes
    merkle_branch_le: list[bytes] # each 32 bytes, internal byte order
    version_le: bytes             # 4 bytes (already little-endian)
    nbits_le: bytes               # 4 bytes
    ntime_le: bytes               # 4 bytes (server-provided start time; we may bump locally)
    clean_jobs: bool
    received_at: float = field(default_factory=time.time)


@dataclass
class PoolState:
    extranonce1: bytes = b""
    extranonce2_size: int = 4
    difficulty: float = 1.0       # share target = DIFF1 / difficulty
    current_job: Optional[Job] = None
    lock: threading.Lock = field(default_factory=threading.Lock)
    new_job_event: threading.Event = field(default_factory=threading.Event)


class StratumClient:
    """Line-oriented JSON-RPC over TCP (Stratum v1)."""

    def __init__(self, host: str, port: int, *, timeout: float = 60.0):
        self.host = host
        self.port = port
        self.timeout = timeout
        self.sock: Optional[socket.socket] = None
        self._recv_buf = b""
        self._next_id = 1
        self._lock = threading.Lock()
        self._pending: dict[int, queue.Queue] = {}
        self.state = PoolState()
        self.shares_accepted = 0
        self.shares_rejected = 0
        self.connected = False

    def connect(self) -> None:
        self.sock = socket.create_connection((self.host, self.port), timeout=self.timeout)
        self.sock.settimeout(None)
        # Enable TCP keepalive so dead connections are detected within ~1 minute
        # instead of waiting for the kernel default (~2 hours on macOS).
        try:
            self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
            # macOS-specific: TCP_KEEPALIVE = idle seconds before first probe.
            TCP_KEEPALIVE = 0x10
            self.sock.setsockopt(socket.IPPROTO_TCP, TCP_KEEPALIVE, 30)
        except (OSError, AttributeError):
            pass
        self.connected = True

    def close(self) -> None:
        self.connected = False
        try:
            if self.sock:
                self.sock.shutdown(socket.SHUT_RDWR)
        except Exception:
            pass
        try:
            if self.sock:
                self.sock.close()
        except Exception:
            pass
        self.sock = None

    def _send(self, obj: dict) -> None:
        assert self.sock
        data = (json.dumps(obj) + "\n").encode("utf-8")
        with self._lock:
            self.sock.sendall(data)

    def _alloc_id(self) -> int:
        with self._lock:
            i = self._next_id
            self._next_id += 1
        return i

    def call(self, method: str, params: list, timeout: float = 15.0) -> Any:
        msg_id = self._alloc_id()
        q: queue.Queue = queue.Queue(maxsize=1)
        with self._lock:
            self._pending[msg_id] = q
        try:
            self._send({"id": msg_id, "method": method, "params": params})
            return q.get(timeout=timeout)
        finally:
            with self._lock:
                self._pending.pop(msg_id, None)

    def notify(self, method: str, params: list) -> None:
        self._send({"id": None, "method": method, "params": params})

    def reader_loop(self, on_notification) -> None:
        """Runs in a background thread. Parses incoming lines and either:
        - resolves a pending call via its queue, OR
        - forwards notifications (id=null) to on_notification(method, params)."""
        assert self.sock
        while self.connected:
            try:
                chunk = self.sock.recv(65536)
            except Exception as e:
                print(f"[stratum] socket recv error: {e}", flush=True)
                self.connected = False
                break
            if not chunk:
                print("[stratum] pool closed connection", flush=True)
                self.connected = False
                break
            self._recv_buf += chunk
            while True:
                nl = self._recv_buf.find(b"\n")
                if nl < 0:
                    break
                line, self._recv_buf = self._recv_buf[:nl], self._recv_buf[nl + 1 :]
                line = line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line.decode("utf-8"))
                except Exception as e:
                    print(f"[stratum] bad JSON line: {line[:200]!r} ({e})", flush=True)
                    continue
                mid = msg.get("id")
                if mid is not None and ("result" in msg or "error" in msg):
                    with self._lock:
                        q = self._pending.get(mid)
                    if q is not None:
                        if msg.get("error"):
                            q.put(("error", msg["error"]))
                        else:
                            q.put(("ok", msg.get("result")))
                else:
                    on_notification(msg.get("method"), msg.get("params") or [])


def build_job(notify_params: list) -> Job:
    # mining.notify params order:
    # [job_id, prevhash, coinbase1, coinbase2, merkle_branches, version, nbits, ntime, clean_jobs]
    (
        job_id,
        prevhash_hex,
        cb1_hex,
        cb2_hex,
        merkle_branches,
        version_hex,
        nbits_hex,
        ntime_hex,
        clean_jobs,
    ) = notify_params[:9]

    version_int = int(version_hex, 16)
    nbits_int = int(nbits_hex, 16)
    ntime_int = int(ntime_hex, 16)

    return Job(
        job_id=job_id,
        prev_le32=stratum_prevhash_to_le32(prevhash_hex),
        coinbase1=bytes.fromhex(cb1_hex),
        coinbase2=bytes.fromhex(cb2_hex),
        merkle_branch_le=[bytes.fromhex(h) for h in merkle_branches],
        version_le=struct.pack("<I", version_int),
        nbits_le=struct.pack("<I", nbits_int),
        ntime_le=struct.pack("<I", ntime_int),
        clean_jobs=bool(clean_jobs),
    )


def compute_merkle_root_le(coinbase_txid_le: bytes, branches_le: list[bytes]) -> bytes:
    root = coinbase_txid_le
    for b in branches_le:
        root = sha256d(root + b)
    return root


def build_block_header(
    *,
    job: Job,
    coinbase: bytes,
    nonce: int,
    ntime_override: Optional[int] = None,
) -> tuple[bytes, bytes]:
    """Return (80-byte header, merkle_root_le).
    `ntime_override` lets us bump time forward locally."""
    cb_txid_le = sha256d(coinbase)
    mr_le = compute_merkle_root_le(cb_txid_le, job.merkle_branch_le)

    ntime_bytes = job.ntime_le
    if ntime_override is not None:
        ntime_bytes = struct.pack("<I", ntime_override)

    header = (
        job.version_le
        + job.prev_le32
        + mr_le
        + ntime_bytes
        + job.nbits_le
        + struct.pack("<I", nonce & 0xFFFFFFFF)
    )
    return header, mr_le


def cpu_search(*, header80: bytes, target_int: int, start_nonce: int, count: int) -> dict:
    """Pure-Python SHA-256d nonce loop. Slow (~50 KH/s); use only as fallback."""
    t0 = time.time()
    nonce = start_nonce
    base = header80[:76]
    end = start_nonce + count
    while nonce < end:
        h = sha256d(base + struct.pack("<I", nonce & 0xFFFFFFFF))
        h_be = h[::-1]
        if int.from_bytes(h_be, "big") <= target_int:
            dt = max(time.time() - t0, 1e-6)
            return {
                "found": True,
                "nonce": nonce & 0xFFFFFFFF,
                "hash": h_be.hex(),
                "checked": nonce - start_nonce + 1,
                "hashrate": int((nonce - start_nonce + 1) / dt),
            }
        nonce += 1
    dt = max(time.time() - t0, 1e-6)
    return {
        "found": False,
        "checked": count,
        "hashrate": int(count / dt),
    }


def mine_session(args: argparse.Namespace, host: str, port: int,
                 *, helper: Optional["MetalGpuHelper"] = None) -> str:
    """Run one Stratum session against (host, port). Returns a short reason
    string when the session ends ("disconnect", "subscribe_failed", etc).
    Raises KeyboardInterrupt to bubble up Ctrl-C."""
    print(f"[stratum] connecting to {host}:{port} as {args.user!r} ...", flush=True)

    client = StratumClient(host, port, timeout=60)
    client.connect()
    state = client.state

    def on_notification(method: str, params: list) -> None:
        if method == "mining.set_difficulty":
            d = float(params[0])
            with state.lock:
                state.difficulty = d
            print(f"[stratum] set_difficulty={d}", flush=True)
        elif method == "mining.notify":
            try:
                job = build_job(params)
            except Exception as e:
                print(f"[stratum] bad notify: {e}", flush=True)
                return
            with state.lock:
                state.current_job = job
                state.new_job_event.set()
            print(
                f"[stratum] new job {job.job_id} "
                f"prev={params[1][:16]}.. clean={job.clean_jobs}",
                flush=True,
            )
        elif method == "mining.set_extranonce":
            # Some pools push new extranonce1 mid-session; uncommon for v1.
            try:
                with state.lock:
                    state.extranonce1 = bytes.fromhex(params[0])
                    state.extranonce2_size = int(params[1])
                print(
                    f"[stratum] set_extranonce: ex1={state.extranonce1.hex()} "
                    f"ex2_size={state.extranonce2_size}",
                    flush=True,
                )
            except Exception as e:
                print(f"[stratum] bad set_extranonce: {e}", flush=True)
        elif method == "client.reconnect":
            print(f"[stratum] pool asked us to reconnect: {params}", flush=True)
            client.close()
        elif method == "client.show_message":
            print(f"[stratum] pool message: {params}", flush=True)
        else:
            print(f"[stratum] unhandled notification {method!r} {params!r}", flush=True)

    reader = threading.Thread(target=client.reader_loop, args=(on_notification,), daemon=True)
    reader.start()

    # 1. subscribe
    sub_status, sub_result = client.call("mining.subscribe", ["gbt-stratum-miner/0.1"])
    if sub_status != "ok":
        print(f"[stratum] subscribe failed: {sub_result}", flush=True)
        client.close()
        return "subscribe_failed"
    # Typical reply: [[("mining.set_difficulty","..."),("mining.notify","...")], extranonce1, extranonce2_size]
    try:
        _ignored, ex1_hex, ex2_size = sub_result[0], sub_result[1], int(sub_result[2])
        with state.lock:
            state.extranonce1 = bytes.fromhex(ex1_hex)
            state.extranonce2_size = ex2_size
        print(
            f"[stratum] subscribed: extranonce1={ex1_hex} extranonce2_size={ex2_size}",
            flush=True,
        )
    except Exception as e:
        print(f"[stratum] could not parse subscribe result {sub_result!r}: {e}", flush=True)
        client.close()
        return "subscribe_parse_failed"

    # 2. authorize
    auth_status, auth_result = client.call("mining.authorize", [args.user, args.pass_])
    if auth_status != "ok" or not auth_result:
        print(f"[stratum] authorize failed: {auth_result}", flush=True)
        client.close()
        return "authorize_failed"
    print(f"[stratum] authorized as {args.user!r}", flush=True)
    session_start = time.time()

    # 3. main mining loop
    extranonce2_counter = random.getrandbits(8 * state.extranonce2_size) & (
        (1 << (8 * state.extranonce2_size)) - 1
    )
    total_shares_found = 0
    started_at = time.time()
    last_status = started_at

    # GPU batch size is auto-tuned to ~target_batch_seconds of work so the
    # caller doesn't have to pick a value per chip. It starts at 16 M nonces
    # (a few hundred ms on any M-series GPU) and adapts toward the observed
    # hashrate after each pass.
    auto_batch = (args.gpu_batch is None) or (int(args.gpu_batch) <= 0)
    cur_gpu_batch = (1 << 24) if auto_batch else int(args.gpu_batch)
    target_batch_seconds = float(args.gpu_target_seconds)

    while client.connected:
        # Wait until we have a job AND a difficulty.
        with state.lock:
            job = state.current_job
            diff = state.difficulty
            ex1 = state.extranonce1
            ex2_size = state.extranonce2_size
        if job is None or diff <= 0:
            time.sleep(0.2)
            continue

        # Build a fresh coinbase for this job iteration.
        extranonce2_counter = (extranonce2_counter + 1) & ((1 << (8 * ex2_size)) - 1)
        ex2 = extranonce2_counter.to_bytes(ex2_size, "little")
        coinbase = job.coinbase1 + ex1 + ex2 + job.coinbase2

        # Compute target from current difficulty.
        target_int = diff_to_target_int(diff)
        target_be = target_int.to_bytes(32, "big")

        # ntime: bump to local now if it's smaller (pools allow this within bounds).
        local_ntime = max(int(time.time()), struct.unpack("<I", job.ntime_le)[0])

        # Build header template with nonce=0 (GPU/CPU will overwrite).
        header_template, _mr = build_block_header(
            job=job, coinbase=coinbase, nonce=0, ntime_override=local_ntime
        )

        # Hash budget per pass. New job interrupts mid-pass via clean_jobs/new event.
        start_nonce = random.getrandbits(32)
        if args.gpu:
            assert helper is not None
            res = helper.search(
                header80=header_template,
                target_be=target_be,
                start_nonce=start_nonce,
                count=int(cur_gpu_batch),
            )
            # Auto-tune cur_gpu_batch toward target_batch_seconds of GPU work.
            if auto_batch:
                checked = int(res.get("checked", 0))
                elapsed_ms = float(res.get("elapsed_ms", 0.0))
                if checked > 0 and elapsed_ms > 0.0:
                    actual_hps = checked * 1000.0 / elapsed_ms
                    desired = int(actual_hps * target_batch_seconds)
                    desired = max(1 << 22, min(desired, 1 << 30))
                    cur_gpu_batch = (cur_gpu_batch * 3 + desired) // 4
        else:
            res = cpu_search(
                header80=header_template,
                target_int=target_int,
                start_nonce=start_nonce,
                count=int(args.cpu_batch),
            )

        # Status print
        now_t = time.time()
        if now_t - last_status >= 5.0:
            elapsed = now_t - started_at
            hps = res.get("hashrate", 0)
            print(
                f"[stratum] mining ~{hps/1e6:.1f} MH/s  diff={diff}  "
                f"shares={total_shares_found}  uptime={int(elapsed)}s  "
                f"job={job.job_id} ex2={ex2.hex()}",
                flush=True,
            )
            last_status = now_t

        if not res.get("found"):
            # If a new job arrived during our pass, drop and restart.
            with state.lock:
                if state.new_job_event.is_set():
                    state.new_job_event.clear()
            continue

        # Verify locally before submitting (cheap insurance).
        nonce = int(res["nonce"]) & 0xFFFFFFFF
        header_full = header_template[:76] + struct.pack("<I", nonce)
        h_be = sha256d(header_full)[::-1]
        if int.from_bytes(h_be, "big") > target_int:
            print(
                f"[stratum] !! local verify failed for share nonce={nonce} "
                f"hash={h_be.hex()} > target={target_be.hex()}; skipping",
                flush=True,
            )
            continue

        total_shares_found += 1
        # Build submit parameters.
        # mining.submit: [worker_name, job_id, extranonce2_hex, ntime_hex, nonce_hex]
        # Both ntime and nonce go on the wire as 8 hex chars in big-endian order.
        ntime_hex = "%08x" % local_ntime
        nonce_hex = "%08x" % nonce
        submit_status, submit_result = client.call(
            "mining.submit",
            [args.user, job.job_id, ex2.hex(), ntime_hex, nonce_hex],
            timeout=20,
        )
        if submit_status == "ok" and submit_result:
            client.shares_accepted += 1
            print(
                f"[stratum] SHARE ACCEPTED  job={job.job_id} nonce={nonce_hex} "
                f"hash={h_be.hex()}  (total accepted: {client.shares_accepted})",
                flush=True,
            )
        else:
            client.shares_rejected += 1
            print(
                f"[stratum] share rejected  job={job.job_id} nonce={nonce_hex}  "
                f"reason={submit_result}  (total rejected: {client.shares_rejected})",
                flush=True,
            )

    elapsed_min = (time.time() - session_start) / 60
    print(
        f"[stratum] disconnected after {elapsed_min:.1f} min. "
        f"accepted={client.shares_accepted} rejected={client.shares_rejected}",
        flush=True,
    )
    client.close()
    # Long-lived session: signal the outer loop to reset backoff to baseline.
    return "disconnect_stable" if elapsed_min >= 2 else "disconnect_short"


def mine(args: argparse.Namespace) -> None:
    """Top-level mining driver with auto-reconnect.

    Reconnects with exponential backoff (capped) whenever a session ends
    (pool dropped us, network hiccup, idle timeout, etc.). Fatal config
    errors like authorize_failed back off harder to avoid hammering."""
    parsed = urlparse(args.url if "://" in args.url else "stratum+tcp://" + args.url)
    host = parsed.hostname
    port = parsed.port
    if not host or not port:
        print(f"[stratum] bad --url: {args.url}", flush=True)
        sys.exit(2)

    # The GPU helper is started once for the entire process: shader
    # compilation and GPU detection happen exactly once, regardless of how
    # many times the pool socket reconnects.
    helper: Optional[MetalGpuHelper] = None
    if args.gpu:
        helper = MetalGpuHelper(
            args.gpu_binary,
            threadgroup=int(args.gpu_threadgroup),
            per_dispatch=int(args.gpu_per_dispatch),
        )

    backoff = 5
    try:
        while True:
            try:
                reason = mine_session(args, host, port, helper=helper)
            except KeyboardInterrupt:
                raise
            except (ConnectionRefusedError, ConnectionResetError, socket.gaierror,
                    socket.timeout, OSError) as e:
                print(f"[stratum] connection error: {e}", flush=True)
                reason = "connection_error"
            except Exception as e:
                print(f"[stratum] unexpected error: {type(e).__name__}: {e}", flush=True)
                reason = "exception"
                # If the GPU helper subprocess died, restart it before the
                # next session so we don't blow up on the first share.
                if (
                    args.gpu
                    and isinstance(e, RuntimeError)
                    and "GPU helper" in str(e)
                ):
                    print("[stratum] restarting GPU helper ...", flush=True)
                    if helper is not None:
                        try: helper.close()
                        except Exception: pass
                    helper = MetalGpuHelper(
                        args.gpu_binary,
                        threadgroup=int(args.gpu_threadgroup),
                        per_dispatch=int(args.gpu_per_dispatch),
                    )

            # Fatal config issues: back off a lot so we don't spam the pool.
            if reason in ("authorize_failed",):
                wait = 120
            elif reason in ("subscribe_failed", "subscribe_parse_failed"):
                wait = 60
            elif reason == "disconnect_stable":
                wait = 5
                backoff = 5
            else:
                wait = backoff
                backoff = min(backoff * 2, 60)

            print(
                f"[stratum] session ended ({reason}); reconnecting in {wait}s "
                f"(Ctrl-C to abort) ...",
                flush=True,
            )
            try:
                time.sleep(wait)
            except KeyboardInterrupt:
                raise
    finally:
        if helper is not None:
            try: helper.close()
            except Exception: pass


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Stratum v1 SHA-256d pool miner")
    p.add_argument("--url", required=True,
                   help="Pool URL, e.g. stratum+tcp://btccmine.top:3333")
    p.add_argument("--user", required=True,
                   help="Pool username, typically <wallet_address>.<worker_name>")
    p.add_argument("--pass", dest="pass_", default="x", help="Pool password (often ignored)")

    default_gpu_bin = os.path.join(os.path.dirname(os.path.abspath(__file__)), "metal_nonce_finder")
    p.add_argument("--gpu", action="store_true",
                   help="Use the Metal GPU helper for nonce search.")
    p.add_argument("--gpu-binary", default=default_gpu_bin)

    # All three GPU knobs default to 0 = auto-tune. The Metal helper detects
    # the host's GPU core count via IOKit and picks threadgroup/per-dispatch
    # for itself, and the Python driver adapts batch size to ~1 s of work
    # using the helper's reported hashrate. None of these need to be set by
    # hand even when moving between M1/M2/M3/M4 base/Pro/Max/Ultra parts.
    p.add_argument("--gpu-batch", type=int, default=0,
                   help="Nonces per GPU search call (0 = auto-tune to "
                        "~--gpu-target-seconds of work).")
    p.add_argument("--gpu-target-seconds", type=float, default=1.0,
                   help="When --gpu-batch=0, target this many seconds per "
                        "GPU call. Smaller = faster job-switch latency.")
    p.add_argument("--gpu-per-dispatch", type=int, default=0,
                   help="Per Metal dispatch size (0 = auto, scaled to GPU cores).")
    p.add_argument("--gpu-threadgroup", type=int, default=0,
                   help="Threads per Metal threadgroup (0 = auto).")

    p.add_argument("--cpu-batch", type=int, default=1 << 18,
                   help="Nonces per CPU pass when --gpu is not used (default 256K).")
    return p.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        mine(args)
    except KeyboardInterrupt:
        print("\n[stratum] interrupted", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
