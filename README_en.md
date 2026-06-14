# apple-gpu-miner

A SHA-256d miner for **Apple Silicon (M1 / M2 / M3 …) GPUs** via Metal,
with a pure-Python Stratum v1 pool client and a `getblocktemplate` solo
client. Works on any SHA-256d chain (Bitcoin, BTCC / Bitcoin-Classic, BCH,
private testnets, …).

> 中文版： [README.md](README.md)

## Highlights

- **Metal compute kernel** (`src/metal_nonce_finder.mm`) — runtime-compiled
  SHA-256d nonce search. ~180 MH/s sustained on a base M2 (10-core GPU);
  ~400-800 MH/s estimated on M2 Pro / Max.
- **Zero-knob auto-tuning for any M-series chip.** GPU core count is read
  from IOKit (`AGXAccelerator/gpu-core-count`); threadgroup defaults to the
  Metal pipeline's `maxTotalThreadsPerThreadgroup`; per-dispatch is sized
  from the core count; the Python driver adapts batch size to the observed
  hashrate. M1 / M2 / M3 / M4 base / Pro / Max / Ultra all "just work" with
  no chip-model parameter. In Stratum mode the miner also auto-suggests a
  suitable share difficulty based on the detected Apple chip.
- **Persistent GPU helper.** `metal_nonce_finder --persistent` reads JSON
  jobs from stdin so the Metal shader is compiled exactly once per mining
  session instead of per batch (~0.5 s saved every batch). Two command
  buffers are kept in flight to keep the GPU saturated while the host
  prepares the next dispatch.
- **Stratum v1 pool client** (`src/stratum_miner.py`) — Python stdlib only
  (no `pip install`), auto-reconnect with backoff, share verify before submit.
- **GBT solo client** (`src/gbt_miner.py`) — same GPU helper, talks to any
  Bitcoin Core-compatible RPC.
- **Smoke test** (`tests/smoke_metal_nonce_finder.py`) — verifies the GPU
  kernel is byte-for-byte identical to Python's `hashlib` SHA-256d.

## Requirements

- macOS 12+ (Apple Silicon recommended; Intel iGPUs work but are slow)
- Xcode Command Line Tools: `xcode-select --install`
- Python 3.9+ (stdlib only)

## Quick start (pool, recommended)

```bash
git clone https://github.com/<you>/apple-gpu-miner
cd apple-gpu-miner

# 1. Compile the Metal helper (a few seconds)
./scripts/build_metal.sh

# 2. (Optional) Verify GPU == CPU
python3 tests/smoke_metal_nonce_finder.py     # expect 4x [OK]

# 3. Mine
./scripts/start_stratum.sh <YOUR_BTCC_ADDRESS>
```

Default pool: `stratum+tcp://pool.btc-classic.org:63101` (the current
recommended Bitcoin-Classic public pool).

### `start_stratum.sh` calling forms

The script auto-detects which trailing positional is the worker name and
which is the URL (anything starting with `stratum` is the URL). Anything
starting with `--` is forwarded to `stratum_miner.py` verbatim.

```bash
# Default pool, worker = hostname
./scripts/start_stratum.sh cc1q....

# Default pool, custom worker
./scripts/start_stratum.sh cc1q....  m2-laptop

# Default worker, custom pool
./scripts/start_stratum.sh cc1q....  stratum+tcp://your.pool:3333

# Both custom
./scripts/start_stratum.sh cc1q....  m2-laptop  stratum+tcp://your.pool:3333

# Forward extra GPU/network flags
./scripts/start_stratum.sh cc1q....  --gpu-target-seconds 0.3

# Manually suggest share difficulty; omitted = auto by chip
./scripts/start_stratum.sh cc1q....  --suggest-difficulty 16

# Disable difficulty suggestion and accept the pool default
./scripts/start_stratum.sh cc1q....  --suggest-difficulty 0

# Or use the env var
POOL_URL=stratum+tcp://your.pool:3333 ./scripts/start_stratum.sh cc1q....
```

### Calling `stratum_miner.py` directly

```bash
python3 src/stratum_miner.py \
    --url  stratum+tcp://pool.btc-classic.org:63101 \
    --user cc1q....your_btcc_address.m2-laptop \
    --pass x \
    --suggest-difficulty 16 \
    --gpu --gpu-binary src/metal_nonce_finder
```

### Typical log

```
[stratum] connecting to pool.btc-classic.org:63101 as 'cc1q....m2-test' ...
[metal] device="Apple M2" gpu_cores=10 threadExecutionWidth=32 maxTPT=576 threadgroup=576 per_dispatch=20971520 (20.0M) [auto]
[stratum] subscribed: extranonce1=000001b4 extranonce2_size=4
[stratum] auto suggest_difficulty=16 (Apple M2)
[stratum] suggest_difficulty accepted by pool: 16
[stratum] set_difficulty=2.0
[stratum] new job 0000000e prev=...
[stratum] authorized as 'cc1q....m2-test'
[stratum] mining ~178.5 MH/s  diff=2.0  avg_share=48s  shares=0
[stratum] SHARE ACCEPTED  job=0000000e nonce=fdb4fd65 hash=00000000303a9fb3...
```

`SHARE ACCEPTED` means your hashrate is registered with the pool. The
`[metal] device=...` line is the GPU helper's auto-tune report — a quick
sanity check that the right threadgroup / per-dispatch were picked.

## Solo mining (against your own node)

Run any Bitcoin Core-compatible daemon (`bitcoind`, `btccd`, etc.) yourself,
then point the helper at it:

```bash
RPCHOST=127.0.0.1 RPCPORT=28476 RPCUSER=user RPCPASSWORD=pass \
    ADDRESS=cc1qyourpayoutaddress \
    ./scripts/start_solo.sh
```

`start_solo.sh` defaults: `RPCHOST=127.0.0.1`, `RPCPORT=28476` (BTCC; use
`8332` for BTC mainnet), `RPCUSER=user`, `RPCPASSWORD=pass`. If `ADDRESS`
is empty the miner calls the node's `getnewaddress`.

Or call `gbt_miner.py` directly:

```bash
python3 src/gbt_miner.py \
    --rpchost 127.0.0.1 --rpcport 28476 \
    --rpcuser user --rpcpassword pass \
    --address cc1qyouraddress \
    --gpu --gpu-binary src/metal_nonce_finder
```

## Tuning (you usually don't need to)

All GPU knobs default to `0` (auto). Both miners share the same flags:

| Flag | Default (`0` = auto) | What auto does |
|---|---|---|
| `--gpu-batch` | `0` | Adapts toward `--gpu-target-seconds` of GPU work using the observed hashrate. |
| `--gpu-target-seconds` | `1.0` (pool) / `2.0` (solo) | Smaller = faster job-switch latency; larger = lower per-batch overhead. |
| `--gpu-per-dispatch` | `0` | Scales with detected GPU core count (≈ cores × 2 M, clamped to 4 M-64 M). |
| `--gpu-threadgroup` | `0` | Uses the pipeline's `maxTotalThreadsPerThreadgroup` (576 for the SHA-256d kernel on M2). |
| `--suggest-difficulty` | `-1` | Stratum share difficulty suggestion; `-1` auto-picks by chip, `0` disables the suggestion, positive values pin it. |

The Metal helper logs its choices on stderr at startup, e.g.:

```
[metal] device="Apple M2" gpu_cores=10 threadExecutionWidth=32 maxTPT=576 \
        threadgroup=576 per_dispatch=20971520 (20.0M) [auto]
```

Pass any flag a positive integer to pin it; pass `0` to go back to auto.

### Share Difficulty Suggestion

The pool's `mining.set_difficulty` notification is authoritative. This option
only sends a `mining.suggest_difficulty` request; the pool may accept it, ignore
it, or clamp it to a pool-defined minimum.
The default BTCC public pool currently has a minimum share difficulty of `16`,
so the automatic suggestion does not go below `16`.

When `--suggest-difficulty` is omitted, the miner reads
`sysctl machdep.cpu.brand_string` and suggests:

| Chip | Auto suggestion |
|---|---:|
| CPU fallback | `16` |
| M1 | `16` |
| M2 / M3 / M4 base | `16` |
| M Pro | `32` |
| M Max | `64` |
| M Ultra | `128` |

Manual override:

```bash
./scripts/start_stratum.sh cc1q.... --suggest-difficulty 16
```

Use the pool default:

```bash
./scripts/start_stratum.sh cc1q.... --suggest-difficulty 0
```

Lower share difficulty makes `SHARE ACCEPTED` and pool dashboard updates appear
sooner, but it does not increase real payout. Pools weight shares by difficulty;
for example, one diff-16 share is roughly equivalent to sixteen diff-1 shares.
The status line's `avg_share=...` estimate uses the actual difficulty most
recently sent by the pool.

## How it works

The Metal kernel (`src/metal_nonce_finder.mm`) precomputes the SHA-256
midstate of the first 64 bytes of the 80-byte block header on the CPU, then
each GPU thread does:

1. Build the 16-word second SHA-256 block (merkle tail + ntime + nbits + per-thread nonce).
2. Apply the precomputed midstate.
3. Run a second full SHA-256 over the 32-byte intermediate hash.
4. Byte-reverse and compare against the 256-bit BE target.

On a hit, atomic CAS records `(nonce, hash)` and the host process prints a
single line of JSON:

```
{"found": true, "nonce": 1234567, "hash": "0000abc...", "checked": ..., "elapsed_ms": ..., "hashrate": ...}
```

The Python drivers (`stratum_miner.py`, `gbt_miner.py`) verify each candidate
on the CPU before submitting, so a buggy GPU result can never produce an
invalid block / share.

## Project layout

```
apple-gpu-miner/
├── src/
│   ├── metal_nonce_finder.mm   Apple Metal SHA-256d kernel + host driver (Objective-C++)
│   ├── metal_helper.py         Persistent-helper subprocess wrapper (stdin/stdout JSON)
│   ├── stratum_miner.py        Stratum v1 pool client
│   └── gbt_miner.py            GBT solo client (any Bitcoin Core-compat node)
├── scripts/
│   ├── build_metal.sh          clang++ + Foundation + Metal + IOKit → src/metal_nonce_finder
│   ├── start_stratum.sh        One-line "mine to a pool" launcher
│   └── start_solo.sh           One-line "mine to your bitcoind" launcher
├── tests/
│   └── smoke_metal_nonce_finder.py   GPU vs. Python hashlib byte-level check
└── docs/
    └── mining-macos.md         Full guide (Chinese)
```

## Performance notes

- Base M2 (10-core GPU), zero tuning: **~178-180 MH/s** sustained
  (pipelined dispatch, threadgroup auto-tuned to 576).
- M2 Pro / Max: estimated 2-4× the base M2 (scales with GPU cores).
- First batch is ~0.5 s slower while Metal compiles the shader; with the
  persistent helper that cost is paid **once per mining session**, not per
  batch as in the previous fork-and-exec design.
- Sustained mining will throttle without active cooling. A small fan helps.

## Disclaimers

- Solo-mining Bitcoin mainnet on consumer hardware is **not economical**;
  expected time-to-block is ~100 years per ~500 MH/s. Use a pool, or mine a
  low-difficulty altchain / private network.
- This software is provided "as is", under the MIT license. Mining
  cryptocurrency may have legal and tax implications in your jurisdiction.
- The default pool `pool.btc-classic.org:63101` is the Bitcoin-Classic
  (BTCC) chain only. Payout addresses must use the `cc1...` prefix. Don't
  point a BTC `bc1...` wallet at it (and vice-versa) — the address formats
  are incompatible. To mine BTC mainnet, override `--url` and `--user`.

## Acknowledgements

This code was extracted and generalized from the macOS GPU-mining helpers in
[Bitcoin-Classic](https://github.com/bitcoin-classic/bitcoin-classic).
The Metal kernel structure (midstate + tail-only second compress) is the
same well-known pattern used by `cgminer` / `bfgminer` / `cpuminer` for the
last decade.

## License

MIT — see [LICENSE](LICENSE).
