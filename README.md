# apple-gpu-miner

A SHA-256d miner for **Apple Silicon (M1 / M2 / M3 …) GPUs** via Metal,
with a pure-Python Stratum v1 pool client and a `getblocktemplate` solo
client. Works on any SHA-256d chain (Bitcoin, BTCC / Bitcoin-Classic, BCH,
private testnets, …).

> 中文版： [README_zh.md](README_zh.md)

## Highlights

- **Metal compute kernel** (`src/metal_nonce_finder.mm`) — runtime-compiled
  SHA-256d nonce search. ~180–250 MH/s on a base M2 (10-core GPU);
  ~400–800 MH/s estimated on M2 Pro / Max.
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
python3 tests/smoke_metal_nonce_finder.py    # expect 4x [OK]

# 3. Mine
./scripts/start_stratum.sh <YOUR_PAYOUT_ADDRESS>
# Custom worker name / pool:
./scripts/start_stratum.sh <ADDRESS> m2-laptop stratum+tcp://your.pool:3333
```

The default pool is `stratum+tcp://btccmine.top:3333` (Bitcoin-Classic).
Override with the third positional arg or the `POOL_URL` env var.

Typical log:

```
[stratum] connecting to btccmine.top:3333 ...
[stratum] subscribed: extranonce1=000001b4 extranonce2_size=4
[stratum] set_difficulty=2.0
[stratum] new job 0000000e prev=...
[stratum] authorized as 'cc1q....m2-test'
[stratum] mining ~90 MH/s  diff=2.0  shares=0
[stratum] SHARE ACCEPTED  job=0000000e nonce=fdb4fd65 hash=00000000303a9fb3...
```

## Solo mining (against your own node)

Run any Bitcoin Core-compatible daemon (`bitcoind`, `btccd`, etc.) yourself,
then point the helper at it:

```bash
RPCHOST=127.0.0.1 RPCPORT=8332 RPCUSER=user RPCPASSWORD=pass \
    ADDRESS=bc1qyourpayoutaddress \
    ./scripts/start_solo.sh
```

Defaults: `127.0.0.1:28476` (BTCC default RPC port), user `user`, password `pass`.

Or call `gbt_miner.py` directly:

```bash
python3 src/gbt_miner.py \
    --rpchost 127.0.0.1 --rpcport 8332 \
    --rpcuser user --rpcpassword pass \
    --address bc1qyouraddress \
    --gpu --gpu-binary src/metal_nonce_finder
```

## Tuning

Both the Stratum and solo paths accept the same GPU knobs:

| Flag | Default | Effect |
|---|---|---|
| `--gpu-batch` | `1<<27` (128M) pool / `1<<28` (256M) solo | Nonces per GPU subprocess call. Larger = better throughput, slower tip-change response. |
| `--gpu-per-dispatch` | `1<<24` (16M) | Single-dispatch size. |
| `--gpu-threadgroup` | `256` | Threads per Metal threadgroup. 256 is best on most Apple GPUs. |

Rule of thumb: aim for ~1 second per batch. At 500 MH/s that's `--gpu-batch 536870912` (512M).

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
│   ├── stratum_miner.py        Stratum v1 pool client
│   └── gbt_miner.py            GBT solo client (any Bitcoin Core-compat node)
├── scripts/
│   ├── build_metal.sh          clang++ + Foundation + Metal → src/metal_nonce_finder
│   ├── start_stratum.sh        One-line "mine to a pool" launcher
│   └── start_solo.sh           One-line "mine to your bitcoind" launcher
├── tests/
│   └── smoke_metal_nonce_finder.py   GPU vs. Python hashlib byte-level check
└── docs/
    └── mining-macos.md         Full guide (Chinese)
```

## Performance notes

- Base M2 (10-core GPU), `--gpu-batch=256M`: **~180–250 MH/s** sustained.
- M2 Pro / Max: estimated 2–4×.
- First batch is ~0.5 s slower because Metal compiles the shader at runtime.
- Sustained mining will throttle without active cooling. A small fan helps.

## Disclaimers

- Solo-mining Bitcoin mainnet on consumer hardware is **not economical**;
  expected time-to-block is ~100 years per ~500 MH/s. Use a pool, or mine a
  low-difficulty altchain / private network.
- This software is provided "as is", under the MIT license. Mining
  cryptocurrency may have legal and tax implications in your jurisdiction.
- The included default pool address (`btccmine.top`) is for the
  Bitcoin-Classic (BTCC) chain only. Don't point a BTC wallet at it (and
  vice-versa) — the address formats are incompatible.

## Acknowledgements

This code was extracted and generalized from the macOS GPU-mining helpers in
[Bitcoin-Classic](https://github.com/bitcoin-classic/bitcoin-classic).
The Metal kernel structure (midstate + tail-only second compress) is the
same well-known pattern used by `cgminer` / `bfgminer` / `cpuminer` for the
last decade.

## License

MIT — see [LICENSE](LICENSE).
