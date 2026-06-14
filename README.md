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
  Stratum 模式还会按芯片型号自动向矿池建议合适的 share difficulty。
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
python3 tests/smoke_metal_nonce_finder.py     # 期望 4 个 [OK]

# 3. 开挖
./scripts/start_stratum.sh <你的BTCC收款地址>
```

默认矿池：`stratum+tcp://pool.btc-classic.org:63101`（Bitcoin-Classic 当前推荐公矿池）。
尽量指定矿池 `scripts/start_stratum.sh xxxx stratum+tcp://pool.btc-classic.org:63101`

### `start_stratum.sh` 的几种调用方式

脚本会自动识别哪个参数是 worker、哪个是矿池 URL（以 `stratum` 开头就是 URL）；
任何 `--` 开头的参数都会原样转发给 `stratum_miner.py`。

```bash
# 默认矿池 + worker = 主机名
./scripts/start_stratum.sh cc1q....


# 默认 worker + 自定义矿池
./scripts/start_stratum.sh cc1q....  stratum+tcp://your.pool:3333

# worker + 矿池都自定义
./scripts/start_stratum.sh cc1q....  m2-laptop  stratum+tcp://your.pool:3333

# 顺手带上 GPU/网络等额外参数（透传给 stratum_miner.py）
./scripts/start_stratum.sh cc1q....  --gpu-target-seconds 0.3

# 手动建议 share difficulty；不传时按芯片自动建议
./scripts/start_stratum.sh cc1q....  --suggest-difficulty 16

# 完全关闭建议，接受矿池默认 share difficulty
./scripts/start_stratum.sh cc1q....  --suggest-difficulty 0

# 用环境变量也行
POOL_URL=stratum+tcp://your.pool:3333 ./scripts/start_stratum.sh cc1q....
```

### 直接调 `stratum_miner.py`（不走脚本）

```bash
python3 src/stratum_miner.py \
    --url  stratum+tcp://pool.btc-classic.org:63101 \
    --user cc1q....your_btcc_address.m2-laptop \
    --pass x \
    --suggest-difficulty 16 \
    --gpu --gpu-binary src/metal_nonce_finder
```

### 典型日志

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

`SHARE ACCEPTED` 就代表你的算力已经被矿池记录、参与分账。第一行 `[metal] device=...`
是 GPU helper 启动时报告的自动检测结果，看一眼可以确认 threadgroup / per-dispatch
被自动设成了合理值。

## Solo 模式（连自己的节点）

你需要先自己跑一个 Bitcoin Core 兼容的节点（`bitcoind` / `btccd` / …），然后：

```bash
RPCHOST=127.0.0.1 RPCPORT=28476 RPCUSER=user RPCPASSWORD=pass \
    ADDRESS=cc1qyouraddress \
    ./scripts/start_solo.sh
```

`start_solo.sh` 默认值（来自环境变量）：
- `RPCHOST=127.0.0.1`
- `RPCPORT=28476`（BTCC 默认 RPC 端口；BTC 主网用 `8332`）
- `RPCUSER=user` / `RPCPASSWORD=pass`
- `ADDRESS` 留空时会调节点的 `getnewaddress` 自动建一个

或者直接调 `gbt_miner.py`：

```bash
python3 src/gbt_miner.py \
    --rpchost 127.0.0.1 --rpcport 28476 \
    --rpcuser user --rpcpassword pass \
    --address cc1qyouraddress \
    --gpu --gpu-binary src/metal_nonce_finder
```

## 调参（一般不需要动）

默认情况下所有 GPU 参数都是 `auto`：

| 参数 | 默认（`0` = auto） | 自动行为 |
|---|---|---|
| `--gpu-batch` | `0` | 按观测算力调整，让单次搜索约 `--gpu-target-seconds` 秒 |
| `--gpu-target-seconds` | stratum `1.0` / solo `2.0` | 越小切换 job 越快，越大开销摊得越薄 |
| `--gpu-per-dispatch` | `0` | 按 IOKit 读到的 GPU 核数缩放（≈ `cores × 2 M`，clamp 到 4 M~64 M） |
| `--gpu-threadgroup` | `0` | 用 Metal pipeline 自报的 `maxTotalThreadsPerThreadgroup`（M2 上 SHA-256d 内核 = 576） |
| `--suggest-difficulty` | `-1` | Stratum share difficulty 建议值；`-1` 按芯片自动建议，`0` 关闭建议，正数手动指定 |

启动时 stderr 会打印一行实际选用的值，方便确认：

```
[metal] device="Apple M2" gpu_cores=10 threadExecutionWidth=32 maxTPT=576 \
        threadgroup=576 per_dispatch=20971520 (20.0M) [auto]
```

如果你确实想手工锁定，所有参数都接受正整数；传 `0` 就回到 auto。例如想让
job 切换更灵敏：

```bash
./scripts/start_stratum.sh cc1q....  --gpu-target-seconds 0.3
```

### Share difficulty 建议

矿池最终下发的 `mining.set_difficulty` 才是实际 share 难度；本参数只是通过
`mining.suggest_difficulty` 向矿池提出建议，矿池可以接受、忽略或按自己的最小值钳制。
默认 BTCC 公矿池当前最低 share difficulty 是 `16`，所以自动建议不会低于 `16`。

默认不传 `--suggest-difficulty` 时，矿工会根据 `sysctl machdep.cpu.brand_string`
识别到的芯片型号自动建议：

| 芯片 | 自动建议 |
|---|---:|
| CPU fallback | `16` |
| M1 | `16` |
| M2 / M3 / M4 base | `16` |
| M Pro | `32` |
| M Max | `64` |
| M Ultra | `128` |

想手动覆盖：

```bash
./scripts/start_stratum.sh cc1q.... --suggest-difficulty 16
```

想完全使用矿池默认值：

```bash
./scripts/start_stratum.sh cc1q.... --suggest-difficulty 0
```

降低 share difficulty 会让本地更快出现 `SHARE ACCEPTED`、矿池后台更快看到矿工在线，
但不会提高实际收益。矿池会按 share difficulty 给 share 计权，例如 1 个 diff=16 的
share 约等于 16 个 diff=1 的 share。状态日志里的 `avg_share=...` 会按当前算力和
矿池实际下发的 difficulty 估算平均多久出一个 share。

## 连接故障排查

> 「`telnet` / `nc` 连得上矿池，但跑项目报 connection error / 一直卡在 connecting」？
> 这是 Python 矿工最常见的"IPv6 优先卡死"问题。

### 一句话原因

`telnet` 通常只挑解析到的第一个地址用（多半是 IPv4），而 Python 的
`socket.create_connection` 会**按 `getaddrinfo` 返回顺序逐个试**。如果矿池
有 AAAA 记录但你这边的 IPv6 路径不通（家用路由没开 v6、运营商不发 v6、
公司 NAT 挡 v6），Python 会先在 IPv6 上挂满超时再回退到 IPv4，对外表现
就是"连接失败 / 一直 connecting"。

### 现版本的处理

从 v0.2 起项目**默认 IPv4 优先**，并且每次连接尝试都会打印一行日志，
所以正常情况下你不会再遇到这个问题。如果你看到的日志类似：

```
[stratum] IPv4 connect to ('1.2.3.4', 63101) failed: [Errno 65] No route to host
[stratum] IPv6 connect to ('2001:...', 63101) failed: [Errno 65] No route to host
```

说明 **v4 / v6 都不通**，是真的网络 / 矿池问题。这时按下面顺序排查：

```bash
# 1. v4 / v6 分别用 nc 测，确认到底哪条路径通
nc -4 -vz pool.btc-classic.org 63101    # 应该秒通
nc -6 -vz pool.btc-classic.org 63101    # 这条不通也无所谓

# 2. 看 DNS 解析
python3 -c "import socket; [print(a[4]) for a in socket.getaddrinfo('pool.btc-classic.org', 63101, type=socket.SOCK_STREAM)]"

# 3. 跑矿工时把详细错误打出来
./scripts/start_stratum.sh <地址> 2>&1 | tee miner.log
grep -E '\[stratum\]|Error' miner.log
```

### 常见错误对照表

| 日志关键词 | 真实原因 | 怎么修 |
|---|---|---|
| `IPv6 connect to ... failed` 后接 `IPv4 connect ... succeeded` | IPv6 路径不通，已自动回退 | 不用管，能跑就行 |
| `connection error: [Errno 61] Connection refused` | 端口错 / 矿池真没开 | 检查 `--url` 端口号 |
| `connection error: [Errno 65] No route to host` | 防火墙 / 公司 NAT 挡 | 换网络，或矿池换 443 等常用端口 |
| `bad JSON line: b'\x16\x03\x01...'` | 矿池要求 SSL/TLS | 项目目前**不支持 TLS**，换 plain TCP 端口 |
| `subscribe failed: ...` | 矿池协议变种 | 看 error 详细字段 |
| `authorize_failed` | 用户名 / 钱包地址非法 | 确认地址前缀（BTCC = `cc1...`），worker 名只用字母数字横线 |
| `socket recv error: ... timed out` | 连上但矿池没 push job | 多半是地址前缀对不上链 |

### 强制 IPv6 优先 / 调连接超时

```bash
# 我就要用 IPv6
./scripts/start_stratum.sh <地址> --prefer-ipv6

# IPv6 路径慢，让 v4 fallback 来得更快（默认 15s）
./scripts/start_stratum.sh <地址> --connect-timeout 5
```

## 后台运行 / 长时间挂机

矿工是个长期运行的进程，关掉终端 / SSH 断线 / 笔记本休眠都会让它停下来。
下面几种姿势按"简单 → 省心"递进，挑一个用就行。

### 方案一：`nohup` + 日志文件（最简单）

把日志重定向到文件，进程脱离当前终端在后台跑：

```bash
# 1. 启动（关掉终端也不会被 SIGHUP 杀掉）
nohup ./scripts/start_stratum.sh cc1q.... > miner.log 2>&1 &
echo $! > miner.pid       # 记下 PID 方便后面停

# 2. 看实时日志
tail -f miner.log

# 3. 停掉
kill "$(cat miner.pid)"
# 兜底：按命令名一把杀
pkill -f stratum_miner.py
pkill -f metal_nonce_finder
```

### 方案二：`caffeinate` 防睡眠（笔记本必备）

macOS 笔记本合盖 / 没插电时默认会睡，一睡 GPU 就停。用 `caffeinate -i`
（`-i` = 防止系统空闲休眠）把矿工包起来：

```bash
nohup caffeinate -i ./scripts/start_stratum.sh cc1q.... > miner.log 2>&1 &
echo $! > miner.pid
```

> `caffeinate -i` 只阻止"空闲休眠"，**合盖还是会睡**。想合盖也跑：在
> "系统设置 → 显示器 → 高级 → 合盖时阻止 Mac 自动进入睡眠"打勾，或者用
> `caffeinate -dis`（外接显示器接电时才生效）。

### 方案三：`tmux` / `screen`（SSH 远程挖最舒服）

通过 SSH 跑矿机时强烈推荐——断线不会丢进程，回头还能 attach 看实时输出。

```bash
# 装一次（自带的话跳过）
brew install tmux

# 新建一个 tmux session
tmux new -s miner
# 在 tmux 里启动矿工（前台跑就行，日志直接打屏幕上）
caffeinate -i ./scripts/start_stratum.sh cc1q....

# 按 Ctrl-b 然后按 d，detach 出来，进程继续跑
# 再回来看：
tmux attach -t miner
# 列出所有 session：
tmux ls
```

### 方案四：开机自启（launchd，进阶）

想让矿工开机就跑、崩了自动拉起，写一个 launchd plist。把下面内容存为
`~/Library/LaunchAgents/com.local.apple-gpu-miner.plist`，把 `<address>`
和路径改成你自己的：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>            <string>com.local.apple-gpu-miner</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/caffeinate</string>
        <string>-i</string>
        <string>/Users/YOU/Documents/apple-gpu-miner/scripts/start_stratum.sh</string>
        <string>cc1q....</string>
    </array>
    <key>WorkingDirectory</key> <string>/Users/YOU/Documents/apple-gpu-miner</string>
    <key>RunAtLoad</key>        <true/>
    <key>KeepAlive</key>        <true/>
    <key>StandardOutPath</key>  <string>/tmp/apple-gpu-miner.log</string>
    <key>StandardErrorPath</key><string>/tmp/apple-gpu-miner.log</string>
</dict>
</plist>
```

加载 / 卸载 / 看状态：

```bash
launchctl load   ~/Library/LaunchAgents/com.local.apple-gpu-miner.plist
launchctl list | grep apple-gpu-miner
launchctl unload ~/Library/LaunchAgents/com.local.apple-gpu-miner.plist
tail -f /tmp/apple-gpu-miner.log
```

### 检查矿工还活着没

```bash
# 进程在不在
pgrep -fl stratum_miner.py

# 算力还在不在（看 [stratum] mining ~XXX MH/s 这行的更新时间）
tail -n 20 miner.log
```

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
- 默认矿池 `pool.btc-classic.org:63101` 仅适用于 Bitcoin-Classic (BTCC) 链。
  收款地址必须是 BTCC 的 `cc1...` 前缀——**不能**把 BTC `bc1...` 地址塞给它，
  反过来也不行，地址格式不兼容。挖 BTC 主网请自己换 `--url` / `--user`。

## 致谢

代码从 [Bitcoin-Classic](https://github.com/bitcoin-classic/bitcoin-classic) 仓库中的 macOS GPU 挖矿组件抽取并通用化而来。Metal 内核的"midstate + 只跑 tail 第二次 compress"结构是十几年来 cgminer / bfgminer / cpuminer 一直在用的成熟模式。

## 更新日志

### 2026-06-14 — Stratum share difficulty 自动建议

这次更新补了 Stratum 的 share difficulty 建议逻辑，并把相关运行信息和文档一起补齐。

新增 / 改动：

- **`--suggest-difficulty` 参数**：`stratum_miner.py` 现在支持手动指定 share difficulty 建议值。
  传正数会主动向矿池发送 `mining.suggest_difficulty`；传 `0` 则关闭建议，完全接受矿池默认。
- **按芯片自动建议**：如果不传 `--suggest-difficulty`，矿工会根据 `sysctl machdep.cpu.brand_string`
  自动判断 Apple 芯片型号，并给出保守的建议值。默认 BTCC 公矿池当前最低 share difficulty 是 `16`，
  所以自动建议不会低于 `16`。当前映射是：
  - M1：`16`
  - M2 / M3 / M4 base：`16`
  - M Pro：`32`
  - M Max：`64`
  - M Ultra：`128`
  - CPU fallback：`16`
- **Stratum 会话日志增强**：状态行现在会显示 `avg_share=...`，用于估算当前算力和实际 share difficulty
  下平均多久能出一个 share；找到候选 share 时也会先打印完整的提交参数，方便排查 submit 问题。
- **nonce 提交字节序修正**：`mining.submit` 现在提交的是 header 中 nonce 的 4 个原始字节，而不是整数格式化后的
  大端字符串，避免池端把 share 误判为无效。
- **README 更新**：中文和英文文档都补了 `--suggest-difficulty` 的用法、默认行为和示例，并明确说明降低 share
  difficulty 只会让 `SHARE ACCEPTED` 更快出现，不会提高真实收益。

### 2026-06-12 — 释放全部 GPU 性能 / M 系列零调参

针对 M 系列芯片完全自动调优，**不再需要指定芯片型号**。

新增 / 改动：

- **GPU 自动检测**：通过 IOKit (`AGXAccelerator/gpu-core-count`) 在运行时
  读出 GPU 核数，per-dispatch 按核数自动缩放（基本上 `cores × 2 M`，clamp
  到 4 M ~ 64 M）。M1 / M2 / M3 / M4 base / Pro / Max / Ultra 一份二进制
  通吃。
- **threadgroup 自动调优**：直接采用 Metal pipeline 自己报告的
  `maxTotalThreadsPerThreadgroup`（M2 上 SHA-256d 内核 = 576），比旧版
  写死的 256 在 M2 上多 ~3 MH/s。
- **持久化 helper**（`metal_nonce_finder --persistent`）：从 stdin 读 JSON
  任务、stdout 写 JSON 结果。Metal shader **整个挖矿会话只编译一次**
  （~0.5 s），不再像旧版本每个 batch fork-exec 都付一次。
- **双命令缓冲区流水线**：commit 完新 cb 再 wait 上一个，GPU 在 host 准备
  下一批参数时不空转。
- **Python 端自适应批量**：`--gpu-batch=0`（默认）时按观测算力把单次搜索
  调成约 `--gpu-target-seconds` 秒（stratum 1.0 s / solo 2.0 s），新增
  `--gpu-target-seconds` 参数控制延迟 / 吞吐权衡。
- 所有 GPU 调参默认 `0 = auto`；想手动锁定就传正整数，传 `0` 就回到 auto。
- 启动时 stderr 打印一行 `[metal] device=... gpu_cores=... threadgroup=...
  per_dispatch=... [auto]`，方便确认自动选择是否合理。
- 新文件 `src/metal_helper.py`：`MetalGpuHelper` 类，stratum 与 solo 共用
  持久化 helper。
- `scripts/build_metal.sh` 新增 `-framework IOKit` 链接。
- 完整向后兼容：旧的一次性 CLI（`--header-prefix --target ...`）保留，
  smoke test 不变。

实测（M2 base，10 核 GPU，自动调参，无外部冷却）：

```
fresh auto-tune defaults: avg=179.2 MH/s  runs=['177.1', '179.3', '180.2', '179.6', '179.7']
```

### 之前的版本

初始版本：Metal SHA-256d nonce 搜索 + Stratum v1 矿池客户端 + GBT solo 客户端。

## License

MIT — 见 [LICENSE](LICENSE)。
