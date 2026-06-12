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
默认矿池：`stratum+tcp://pool.btc-classic.org:63101`。

`start_stratum.sh` 的参数顺序是 `<地址> [worker | URL] [URL]`，脚本会按
"以 `stratum` 开头的就是 URL，否则就是 worker 名" 自动判别；任何 `--` 开头的
参数会原样转发给 `stratum_miner.py`：

```bash
# 自定义矿工名（默认是机器主机名）
./scripts/start_stratum.sh cc1q.... m2-laptop

# 默认 worker + 自定义矿池
./scripts/start_stratum.sh cc1q.... stratum+tcp://your.pool:3333

# 同时自定义 worker 和矿池
./scripts/start_stratum.sh cc1q.... m2-laptop stratum+tcp://your.pool:3333

# 直接透传 GPU 调参
./scripts/start_stratum.sh cc1q.... --gpu-target-seconds 0.3
```

### 3.3 连本地节点 solo 挖

先把 Bitcoin Core 兼容的节点跑起来（这部分不在本项目范围）。然后：

```bash
RPCHOST=127.0.0.1 RPCPORT=28476 RPCUSER=user RPCPASSWORD=pass \
    ADDRESS=cc1qyouraddress \
    ./scripts/start_solo.sh
```

`start_solo.sh` 默认 RPC 端口 `28476`（BTCC）；BTC 主网用 `8332`。

或直接调 Python：

```bash
python3 src/gbt_miner.py \
    --rpchost 127.0.0.1 --rpcport 28476 \
    --rpcuser user --rpcpassword pass \
    --address cc1qyouraddress \
    --gpu --gpu-binary src/metal_nonce_finder
```

---

## 4. CPU vs GPU 性能

| 后端 | M2 (10 核 GPU) | M2 Pro/Max（估计） | 备注 |
|---|---|---|---|
| 纯 Python CPU | ~40–80 KH/s | ~50–100 KH/s | 仅作 fallback / 演示 |
| Metal GPU（自动调参） | **~178–180 MH/s** 持续 | ~400–800 MH/s | 默认参数（双 cb 流水线） |

GPU 路径相对 Python CPU 提升约 **2000–5000 倍**。

> 启动时 stderr 会打印一行类似  
> `[metal] device="Apple M2" gpu_cores=10 threadExecutionWidth=32 maxTPT=576 threadgroup=576 per_dispatch=20971520 (20.0M) [auto]`，  
> 表明自动检测出的 GPU 核数和挑选的 threadgroup / per-dispatch。  
> 持久化 helper 让 Metal shader 整个会话只编译一次（约 0.5 s），不再每个 batch 都付一次。

---

## 5. 参数调优（默认即最优，一般不用动）

GPU 三个参数全部默认 `0 = auto`，**M 系列芯片不需要指定型号**：

| 参数 | 默认 | 自动行为 |
|---|---|---|
| `--gpu-batch` | `0` | 按观测算力自调，让单次搜索≈ `--gpu-target-seconds` 秒 |
| `--gpu-target-seconds` | stratum `1.0` / solo `2.0` | 越小切 job 越快，越大开销摊得越薄 |
| `--gpu-per-dispatch` | `0` | 用 IOKit 拿到的 GPU 核数算（基本上 `cores × 2 M`，4 M~64 M 之间） |
| `--gpu-threadgroup` | `0` | Metal pipeline 自己报告的 `maxTotalThreadsPerThreadgroup`（M2 上 SHA-256d 内核 = 576） |

如果你确实想手工锁定某个值，正整数就是手动锁定，`0` 就是恢复 auto：

```bash
# 手动锁 batch=128M（不再自动调整）
./scripts/start_stratum.sh cc1q.... --gpu-batch 134217728

# 让一次 batch 大约 0.3 秒（job 切换更快）
./scripts/start_stratum.sh cc1q.... --gpu-target-seconds 0.3
```

### 5.1 CPU 后端

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
