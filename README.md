# BTCC_apple-gpu-miner

苹果 Apple Silicon（M1 / M2 / M3 …）GPU 上跑的 SHA-256d 挖矿工具，
基于 Metal 计算内核 + 纯 Python 标准库 Stratum v1 矿池客户端。
适用于任意 SHA-256d 链（Bitcoin、BTCC / Bitcoin-Classic、BCH、私有测试链 …）。

> English version: [README_en.md](README_en.md)

## 亮点

- **Metal 内核** (`src/metal_nonce_finder.mm`)：运行时编译的 SHA-256d nonce 搜索内核。
  M2 (10 核 GPU) 实测 **~180 MH/s**；M2 Pro/Max 估计 ~400–800 MH/s。
- **零调参 / 自动适配 M 系列芯片**：通过 IOKit (`AGXAccelerator/gpu-core-count`) 自动读到
  GPU 核数，pipeline 自己挑 threadgroup（直接用 `maxTotalThreadsPerThreadgroup`）和
  per-dispatch 大小；Python 端按观测算力把每次搜索调成约 1 秒（stratum）/ 2 秒（solo）。
  M1 / M2 / M3 / M4 base / Pro / Max / Ultra 全部不需要手动写"我是哪颗芯片"。
- **持久化 GPU helper**：`metal_nonce_finder --persistent` 读 stdin 上的 JSON 任务，
  Metal shader 只编译一次，避免每个 batch 都付 ~0.5 s 编译开销 + fork 开销。
  双命令缓冲区流水线让 GPU 在 host 准备下一个 dispatch 时不空转。
- **Stratum v1 矿池客户端** (`src/stratum_miner.py`)：只用 Python 标准库（**不需要 pip 装任何东西**），
  自动重连、submit 前 CPU 复核。
- **GBT solo 客户端** (`src/gbt_miner.py`)：同一份 GPU helper，对接任何 Bitcoin Core 兼容节点。
- **冒烟测试** (`tests/smoke_metal_nonce_finder.py`)：验证 GPU 内核结果跟 Python `hashlib` 字节级一致。

## 系统要求

- macOS 12+（推荐 Apple Silicon；Intel 核显也能跑但很慢）
- Xcode Command Line Tools：`xcode-select --install`
- Python 3.9+（只用标准库）

## 快速开始（连矿池，**推荐**）

```bash
git clone https://github.com/<your-name>/apple-gpu-miner
cd apple-gpu-miner

# 1. 编译 Metal helper（几秒）
./scripts/build_metal.sh

# 2. 可选：跑一次冒烟测试，验证 GPU == CPU
python3 tests/smoke_metal_nonce_finder.py    # 期望 4 个 [OK]

# 3. 开挖
./scripts/start_stratum.sh <你的收款地址>

# 自定义矿工名 / 矿池：
./scripts/start_stratum.sh <你的收款地址>  stratum+tcp://your.pool:3333
```

默认矿池是 `stratum+tcp://btccmine.top:3333`（Bitcoin-Classic）。
想换矿池可以传第三个参数，或者用 `POOL_URL` 环境变量。


现在最新的公矿地址是 `stratum+tcp://pool.btc-classic.org:63101 `，建议使用这个

典型日志：

```
[stratum] connecting to btccmine.top:3333 ...
[stratum] subscribed: extranonce1=000001b4 extranonce2_size=4
[stratum] set_difficulty=2.0
[stratum] new job 0000000e prev=...
[stratum] authorized as 'cc1q....m2-test'
[stratum] mining ~90 MH/s  diff=2.0  shares=0
[stratum] SHARE ACCEPTED  job=0000000e nonce=fdb4fd65 hash=00000000303a9fb3...
```

`SHARE ACCEPTED` 就代表你的算力已经被矿池记录、参与分账。

## Solo 模式（连自己的节点）

你需要先自己跑一个 Bitcoin Core 兼容的节点（`bitcoind` / `btccd` / …），然后：

```bash
RPCHOST=127.0.0.1 RPCPORT=8332 RPCUSER=user RPCPASSWORD=pass \
    ADDRESS=bc1qyouraddress \
    ./scripts/start_solo.sh
```

默认值：`127.0.0.1:28476`（BTCC 默认 RPC 端口）、用户 `user`、密码 `pass`。

或者直接调 `gbt_miner.py`：

```bash
python3 src/gbt_miner.py \
    --rpchost 127.0.0.1 --rpcport 8332 \
    --rpcuser user --rpcpassword pass \
    --address bc1qyouraddress \
    --gpu --gpu-binary src/metal_nonce_finder
```

## 调参（一般不需要动）

默认情况下所有 GPU 参数都是 `auto`：

| 参数 | 默认（0 = auto） | 自动行为 |
|---|---|---|
| `--gpu-batch` | `0` | 按观测算力调整，让单次搜索约 `--gpu-target-seconds` 秒 |
| `--gpu-target-seconds` | stratum `1.0` / solo `2.0` | 越小切换 job 越快，越大开销摊得越薄 |
| `--gpu-per-dispatch` | `0` | 按 IOKit 读到的 GPU 核数缩放（基本上 GPU\_cores × 2 M，4 M~64 M 之间） |
| `--gpu-threadgroup` | `0` | 用 `maxTotalThreadsPerThreadgroup`（M2 上 SHA-256d 内核 = 576） |

启动时会在 stderr 上打印一行检测结果，例如：

```
[metal] device="Apple M2" gpu_cores=10 threadExecutionWidth=32 maxTPT=576 \
        threadgroup=576 per_dispatch=20971520 (20.0M) [auto]
```

如果你确实想手工锁定，所有参数都接受正整数；传 `0` 就是恢复 auto。

## 工作原理

Metal 内核 (`src/metal_nonce_finder.mm`) 在 CPU 端预算 80 字节区块头前 64 字节的 SHA-256 midstate，然后每个 GPU 线程：

1. 拼出第二个 16-word SHA-256 块（merkle 尾巴 + ntime + nbits + 本线程的 nonce）。
2. 套用预算好的 midstate。
3. 对 32 字节中间 hash 再做一次完整 SHA-256。
4. 字节翻转后跟 256-bit big-endian target 比较。

命中时用原子 CAS 记录 `(nonce, hash)`，host 进程打印一行 JSON：

```
{"found": true, "nonce": 1234567, "hash": "0000abc...", "checked": ..., "elapsed_ms": ..., "hashrate": ...}
```

Python 驱动（`stratum_miner.py` / `gbt_miner.py`）在 submit 之前会**用 CPU 再校验一遍**——即便 GPU 内核有 bug，也不会产生无效的 share / 区块。

## 目录结构

```
apple-gpu-miner/
├── src/
│   ├── metal_nonce_finder.mm   Apple Metal SHA-256d 内核 + host 驱动（Objective-C++）
│   ├── metal_helper.py         持久化 GPU helper 子进程封装（stdin/stdout JSON）
│   ├── stratum_miner.py        Stratum v1 矿池客户端
│   └── gbt_miner.py            GBT solo 客户端
├── scripts/
│   ├── build_metal.sh          clang++ + Foundation + Metal + IOKit → src/metal_nonce_finder
│   ├── start_stratum.sh        一键挖矿池
│   └── start_solo.sh           一键挖自己节点
├── tests/
│   └── smoke_metal_nonce_finder.py   GPU vs Python hashlib 字节级一致性测试
└── docs/
    └── mining-macos.md         详细中文使用指南
```

## 性能

- 基础 M2 (10 核 GPU)，自动调参：稳定 **~178-180 MH/s**（持续，含双 cb 流水线）。
- M2 Pro / Max：估计 2–4× 提升（GPU 核数线性放大）。
- 第一次启动会慢约 0.5 s（运行时编译 shader），由于 helper 是持久化进程，**整个挖矿
  会话都只付一次** 这个开销，不再像旧版本每个 batch 都重新编译。
- 长时间满载会让 M 系列芯片热降频；建议加个垫高架或小风扇。

## 重要提醒

- 在 Bitcoin 主网上用消费级硬件 solo 挖矿**完全不经济**——~500 MH/s 期望命中时间是 100 年级别。
  请连矿池，或者去挖低难度的 altchain / 私有链。
- 本软件按 MIT 协议提供，**不附带任何担保**。挖矿在某些司法辖区会涉及税务和合规问题，请自查。
- 默认矿池地址 `btccmine.top` 仅适用于 Bitcoin-Classic (BTCC) 链。**不能**把 BTC 钱包地址塞给它，反过来也不行——地址格式不兼容。

## 致谢

代码从 [Bitcoin-Classic](https://github.com/bitcoin-classic/bitcoin-classic) 仓库中的 macOS GPU 挖矿组件抽取并通用化而来。Metal 内核的"midstate + 只跑 tail 第二次 compress"结构是十几年来 cgminer / bfgminer / cpuminer 一直在用的成熟模式。

## License

MIT — 见 [LICENSE](LICENSE)。
