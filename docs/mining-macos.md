# macOS（Apple Silicon）GPU 挖矿详细指南

本文档是 [README.md](../README.md) 的扩展版，覆盖：

1. 编译 GPU 内核（`metal_nonce_finder`）
2. 连矿池开挖（`stratum_miner.py`）
3. 连本地节点 solo 挖（`gbt_miner.py`）
4. 调参 / 性能 / 故障排查

> 仅适用于 macOS。Linux / Windows 用户可参考 `src/gbt_miner.py` 的 CPU 路径，但本仓库不针对它优化。

---

## 1. 系统要求

- macOS 12+（推荐 14+）
- Apple Silicon（M1 / M2 / M3） — Intel Mac 的核显也能跑 Metal，但算力低
- Xcode Command Line Tools：`xcode-select --install`
- Python 3.9+（macOS 自带；只用标准库）

---

## 2. 项目结构

```
apple-gpu-miner/
├── src/
│   ├── metal_nonce_finder.mm   GPU SHA-256d 内核（Objective-C++）
│   ├── stratum_miner.py        Stratum v1 矿池客户端
│   └── gbt_miner.py            GBT solo 客户端
├── scripts/
│   ├── build_metal.sh          编译 GPU helper
│   ├── start_stratum.sh        一键连矿池
│   └── start_solo.sh           一键连本地节点
└── tests/
    └── smoke_metal_nonce_finder.py
```

---

## 3. 快速开始

### 3.1 编译 GPU 矿工（一次性，几秒）

```bash
./scripts/build_metal.sh
```

完成后会得到 `src/metal_nonce_finder`。

可选——验证 Metal kernel 与 Python `sha256d` 字节级一致：

```bash
python3 tests/smoke_metal_nonce_finder.py
```

应当看到 4 个 `[OK]`。

### 3.2 连矿池开挖（推荐）

```bash
./scripts/start_stratum.sh <你的BTCC收款地址>
```

不需要 `bitcoind`，不需要同步区块。看到 `SHARE ACCEPTED` 就代表算力已经被矿池记录。

可选参数：

```bash
# 自定义矿工名（默认是机器主机名）
./scripts/start_stratum.sh cc1q.... m2-laptop

# 切到自己的矿池
./scripts/start_stratum.sh cc1q.... m2-laptop stratum+tcp://your.pool:3333

# 调 GPU batch
./scripts/start_stratum.sh cc1q.... m2-laptop "" --gpu-batch 67108864
```

### 3.3 连本地节点 solo 挖

先把 Bitcoin Core 兼容的节点跑起来（这部分不在本项目范围）。然后：

```bash
RPCHOST=127.0.0.1 RPCPORT=8332 RPCUSER=user RPCPASSWORD=pass \
    ADDRESS=bc1qyouraddress \
    ./scripts/start_solo.sh
```

或直接调 Python：

```bash
python3 src/gbt_miner.py \
    --rpchost 127.0.0.1 --rpcport 8332 \
    --rpcuser user --rpcpassword pass \
    --address bc1qyouraddress \
    --gpu --gpu-binary src/metal_nonce_finder \
    --gpu-batch $((1<<28))
```

---

## 4. CPU vs GPU 性能

| 后端 | M2 (10 核 GPU) | M2 Pro/Max（估计） | 备注 |
|---|---|---|---|
| 纯 Python CPU | ~40–80 KH/s | ~50–100 KH/s | 仅作 fallback / 演示 |
| Metal GPU | **~180–250 MH/s** | ~400–800 MH/s | 默认参数 |

GPU 路径相对 Python CPU 提升约 **2000–5000 倍**。

> 实际数字会因 `--gpu-batch`、`--gpu-per-dispatch`、热降频、并发负载而浮动。
> 第一次启动有约 0.5 秒的 Metal shader 编译开销，之后每 batch 是稳定的。

---

## 5. 参数调优

矿工脚本默认参数已经比较合理。需要调时直接在启动命令后追加，会透传到 Python 矿工：

```bash
./scripts/start_stratum.sh cc1q.... m2-test "" \
    --gpu-batch 134217728 \         # 每次 GPU 子进程扫多少 nonce（默认 128M）
    --gpu-per-dispatch 33554432 \   # 单次 Metal dispatch 大小（默认 16M）
    --gpu-threadgroup 256           # threadgroup 大小，多数情况 256 最佳
```

### 5.1 `--gpu-batch` 怎么选？

- **越大** → GPU 利用率越高（启动开销摊薄），但**对 job 切换的响应越慢**。
- **越小** → 越早能感知到新 job，但启动开销占比变高。

经验值：让一次 batch 大约 1 秒。500 MH/s × 1s ≈ `--gpu-batch 536870912`（512M）。

主网每 10 分钟一个块，矿池每秒就有新 share，batch 用 128M（默认）很合理。

### 5.2 CPU 后端

不带 `--gpu`，或者 `gbt_miner.py` 不传 `--gpu`，就是纯 Python CPU 路径。仅推荐用于：

- regtest / 私有链流程验证
- GPU helper 不可用时的兜底

---

## 6. 故障排查

### 6.1 `metal_nonce_finder: Metal compile error: ...`
Metal 着色器在运行时编译。多半是 macOS 版本太老（< 12）或 Xcode CLT 没装好。

### 6.2 `xcrun: error: invalid active developer path`
说明 Xcode Command Line Tools 路径丢了。修复：

```bash
sudo xcode-select --reset
xcode-select --install
```

### 6.3 矿工提示 `GPU returned nonce=... but CPU verify says hash > target`
矿工在 GPU 找到候选 nonce 后会用 Python SHA-256d **再校验一遍**才提交——出现这个警告意味着 GPU 内核结果跟 CPU 不一致（理论上不应发生）。请把以下信息附上提 issue：

- `uname -a`
- 启动命令完整参数
- GPU helper 的命令行（在矿工日志里）
- 警告里的 nonce + hash 值

### 6.4 矿池连接被拒 / 频繁断开
Stratum 客户端默认会指数退避自动重连（5s → 10s → ... → 60s 上限）。如果一直连不上：

- 检查矿池地址和端口是否正确
- 检查网络（公司/学校 NAT 可能屏蔽 stratum 端口）
- 检查地址前缀是不是这条链的（BTCC 是 `cc1...`，BTC 是 `bc1...`，不通用）

### 6.5 长时间挖一段时间后算力下降
M 系列芯片在持续高负载下会热降频。解决：

- 把笔记本垫高、改善通风
- 加小风扇
- `pmset -a powermode 0` 关掉低功耗模式（会让芯片更愿意维持高频）

---

## 7. 现实提醒

- 在 Bitcoin 主网上，单台 M2 的算力（~250 MH/s）相对于专业 ASIC（百 TH/s 级）几乎可忽略。
  这套实现适合：
  - 矿池贡献份额拿小奖励
  - regtest / signet / 私有链测试
  - 早期 / 低难度 altchain
  - 教学、研究
- 长时间满载会让 M 系列发烫并降频，建议外接散热或限制时间。
- 项目源码完全开源（MIT），欢迎在此基础上做扩展（更多内核优化、persistent threads、`simd_*` 内置函数等）。
