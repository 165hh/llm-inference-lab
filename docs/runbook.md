# 运行手册（Runbook）：从开机到出第一条基线

> 目标：**每次开机 ≤ 1 小时、只做一件事、产出一份可复现的数据，然后关机。**
> 现状快照与坑位见 `docs/environment.md`；实验协议见 `docs/experiments.md`。

## 0. 现状快照

| 项 | 值 |
|---|---|
| 本地仓库 | `F:/cs336/llmma.cpp_qwen4b`（分支 `master`） |
| 远端 | `origin` = `https://github.com/165hh/llm-inference-lab.git`（**public** → 实例上 clone 免认证；本地 HTTPS + Windows 凭据管理器，push 免密） |
| 平台 | 恒源云（GPUSHARE）RTX 3090 24G ¥0.98/h（已验证）；**当前实例在阿里云 ECS**（主机名 `iZ…`，按量 GPU 较贵，先看清单价） |
| 已实测 | 恒源云：Ubuntu 22.04.4 / 96 核 / 503G / CUDA 12.4 / nvcc ✅ / nsys ✅ / ncu ❌（`RmProfilingAdminOnly: 1`）<br>阿里云：CUDA 12.1 / driver 530.30.02 / nvcc ✅ / **ncu ❌ 同样无权限** / nsys 待查 |
| 项目阶段 | **M0 ✅**（llama.cpp CUDA 编译通过 + Qwen3-4B Q4_K_M 下载成功 + llama-server 能加载并监听 8080）<br>**E1 基线**：状态未知（`results/raw/bench_*.jsonl` 有没有出数需要确认）<br>**E1b 压测**：上一轮全部 `Connection refused`（服务未就绪就打请求）→ 无效，需重跑 |

## 1. 从「实例已关机」开始的完整顺序

### 1.0 先判断：有没有数据要救（**不用开机**）

问自己一句：**上次有没有跑出 `results/raw/bench_*.jsonl` 或 `serving_*.jsonl`，并且没 push？**

- **有** → 优先救数据（实例数据随时可能被清）：开机 → `cd /hy-tmp/llm-inference-lab && git status -s && git add -A && git commit -m "results: rescue" && git push` → 关机。≈5 分钟。
- **没有** → 什么都不用救。**模型和编译产物都能在 ~10 分钟内重建**，不要为它们开机。

### 1.1 本地准备（0 GPU 成本，先做完再开机）

1. `git pull` 拿最新脚本（`instance_setup.sh` 已带 GitHub 镜像回退；`run_server.sh` 会打印上下文预算与端口告警）。
2. **给这次开机定一个唯一目标**（写一行）：例如"完成 M0 + E1 基线"，不要顺手做压测。
3. 确认平台与单价：阿里云 GPU 按量通常比恒源云贵，**先看清每小时多少钱**再开机。

### 1.2 开机后的命令（复制粘贴，≈25 分钟）

```bash
# 0) 环境
export PATH=/usr/local/cuda/bin:$PATH
cd /hy-tmp                                    # 恒源云；阿里云可能是 /root，按实际数据盘路径

# 1) 拉仓库（public，免认证）
if [ -d llm-inference-lab ]; then cd llm-inference-lab && git pull; else
  git clone https://github.com/165hh/llm-inference-lab.git && cd llm-inference-lab; fi

# 2) 一键准备（幂等）：clone llama.cpp（失败自动换国内镜像）→ 编译 → 下模型
bash scripts/instance_setup.sh

# 3) 冒烟（预期：只有 ncu 一项 FAIL）
export MODEL=$PWD/models/Qwen3-4B-Q4_K_M.gguf
bash scripts/smoke.sh

# 4) E1 基线 + 汇总
TAG=baseline bash scripts/run_bench.sh
python scripts/collect_metrics.py

# 5) 服务压测（可选；★必须先等就绪，否则全是 Connection refused）
CTX=8192 NP=8 bash scripts/run_server.sh &
until curl -sf http://127.0.0.1:8080/health >/dev/null; do sleep 1; done; echo "server ready"
python benchmark/serving/sse_bench.py --base-url http://127.0.0.1:8080 \
    --concurrency 1,2,4,8 --requests-per-level 8 --prompt-tokens 512 --max-tokens 256
pkill -f llama-server

# 6) 写一行结论 → push → 关机
git add -A && git commit -m "results: M0 + E1 baseline" && git push
shutdown -h now
```

### 1.3 关机的正确姿势（停机 ≠ 释放）

| 平台 | 操作 | 注意 |
|---|---|---|
| 恒源云 | 控制台「实例管理 → 停止」或 `shutdown -h now` | 关机后不收实例费；`/hy-tmp` 是临时盘，**关机 24h 后可能被清**；连续关机 10 天实例被释放 |
| 阿里云 ECS | 控制台「停止」 | 若用**节省停机模式**，公网 IP 可能变化、部分资源回收，但**云盘保留**；**不要选"释放"**（会删盘） |

### 1.4 下次开机（E2/E3）会更快

基线已在 git 里 → `git pull` → `instance_setup.sh`（已做的步骤自动跳过）→ 只改 `benchmark/offline/matrix.txt` 或 `MODEL=` → 跑 → 收工。
**每次都要重新做**的只有：编译（如果 `/hy-tmp` 被清）和模型下载（~3 分钟）。

## 1.5 每次开机前的 30 秒纪律（防烧钱）

1. 这次要产出什么？（写一行 TODO，例如 "E1 基线：7 行矩阵出数"）
2. 预计多久？（> 1 小时就拆成两次；**抢卡窗口里最贵的是环境搭建**）
3. 结束动作固定：`shutdown -h now` + `git push`（把 `results/` 推回远端）

## 2. 一次完整的开机流程（复制粘贴）

### 2.1 环境与仓库

```bash
export PATH=/usr/local/cuda/bin:$PATH
cd /hy-tmp
git clone https://github.com/165hh/llm-inference-lab.git      # 若已存在：cd 进去 && git pull
cd llm-inference-lab
bash scripts/probe_platform.sh        # 首次/换机器时跑；本机已验证过，约 1 分钟
```

### 2.2 一键准备：llama.cpp + 编译 + 模型（幂等，重复跑只会跳过）

```bash
bash scripts/instance_setup.sh
```

它做三件事（已存在则跳过）：
1. `git clone --depth 1 .../llama.cpp third_party/llama.cpp`
2. `bash scripts/build.sh`（`CUDA_ARCH=86-real`，96 核约几分钟，产出 `results/raw/build_*.json`）
3. 下载 `Qwen3-4B-Q4_K_M.gguf` 到 `models/`（**已禁用 Xet**，否则会绕过镜像直连境外 CDN，实测只有 32 KB/s）

> 若第 3 步太慢：换 ModelScope（`pip install -U modelscope && modelscope download --model Qwen/Qwen3-4B-GGUF Qwen3-4B-Q4_K_M.gguf --local-dir models`），或本地下载后上传。

### 2.3 M0：冒烟（全 PASS 才继续）

```bash
export MODEL=$PWD/models/Qwen3-4B-Q4_K_M.gguf
bash scripts/smoke.sh
```

预期：nvidia-smi ✅ / nvcc ✅ / **ncu 抓包会 FAIL（本平台宿主限制，已知且接受）** / nsys ✅ / llama-bench 出数 ✅。

### 2.4 E1：基线矩阵（这是项目真正开始的地方）

```bash
TAG=baseline bash scripts/run_bench.sh       # 按 benchmark/offline/matrix.txt 跑 7 行
python scripts/collect_metrics.py            # → results/processed/bench_*.csv + 汇总表
```

要看的：pp128/512/2048/4096 的 tok/s、tg256 的 tok/s、`effBW`（有效带宽，判断离带宽上限还有多远）、每组的 stddev。

### 2.5 服务基线（同一次开机顺便做，可选）

```bash
# ① 上下文预算：n_ctx_slot = -c / -np，必须 ≥ (prompt_tokens + max_tokens)
#    例：prompt 512 + gen 256 = 768 → 取 CTX=8192 NP=8（1024/slot）或 CTX=4096 NP=4（1024/slot）
CTX=8192 NP=8 bash scripts/run_server.sh &          # 日志进 results/raw/server_*.log

# ② 等它就绪（模型加载要几秒到几十秒，不等就压测必然 Connection refused）
until curl -sf http://127.0.0.1:8080/health >/dev/null; do sleep 1; done; echo "server ready"
cat results/raw/server_*.log | tail -n 20 | grep -E 'n_ctx|slot'   # 核对 n_ctx_slot 是否符合预期

# ③ 压测
python benchmark/serving/sse_bench.py --base-url http://127.0.0.1:8080 \
       --concurrency 1,2,4,8 --requests-per-level 8 --prompt-tokens 512 --max-tokens 256

# ④ 收工前杀掉服务（否则下次启动会报 "couldn't bind HTTP server socket"）
pkill -f llama-server
```

**两个必踩的坑**（都见过）：

| 现象 | 原因 | 解法 |
|---|---|---|
| 压测全部 `Connection refused` | 服务还没加载完（模型加载 2~30 秒） | 先跑 ② 的就绪等待循环 |
| 第二次 `run_server.sh` 报 `couldn't bind HTTP server socket` | 上一次的 server 还挂着（`&` 起的没杀） | `ss -ltnp \| grep :8080` 找到 PID → `pkill -f llama-server` |
| 请求被截断 / 结果怪 | `n_ctx_slot = -c/-np` 小于 `prompt+gen` | 调大 `-c` 或调小 `-np`（日志里会打印 `n_ctx_slot`） |

### 2.6 收工：写结论 + 把数据带回家 + 关机

```bash
cd /hy-tmp/llm-inference-lab

# ① 写结论（这一步才是"产出"，前面的都是原始数据）
#    docs/findings.md →「已确认结论」表加一行：结论 / 证据文件 / 适用范围 / 日期
#    （可选）qwen3-inference-project/notes/<今天>.md 记一条，含关键数字

# ② 数据带回家
git add -A && git commit -m "results: baseline on RTX 3090 (Hengyuan)" && git push

# ③ 关机（停止计费；/hy-tmp 是临时盘，别指望过夜）
shutdown -h now
```

**这一步会产出什么**（下次开机你就是靠这些继续）：

| 文件 | 位置 | 作用 |
|---|---|---|
| `bench_*_baseline_*.jsonl` | `results/raw/` | 每矩阵行的原始测量（报告里每个数字的出处） |
| `bench_*.csv` | `results/processed/` | 汇总表（可重算） |
| `build_*.json` / `env_*.json` | `results/raw/` | llama.cpp commit / 编译参数 / 显卡驱动 / CUDA 版本 |
| `serving_*.jsonl` + `.csv` | `results/raw`、`results/processed` | 逐请求 TTFT/TPOT 原始记录 |
| `server_*.log` | `results/raw/` | 服务端启动日志（`n_ctx`/`n_slots`/KV 大小的证据） |
| `docs/findings.md` 新行 | `docs/` | 一条可追溯结论（**没有它，前面全白跑**） |

> 模型不进 git（已 gitignore）：下次开机重下只要 ~3 分钟（¥0.05），不值得为它折腾持久化。

## 3. 阶段进度表

| 阶段 | 命令 | 完成标志 |
|---|---|---|
| M0 跑通 | `instance_setup.sh` + `smoke.sh` | llama-bench 有数 |
| E1 基线 | `run_bench.sh` + `collect_metrics.py` | `results/raw/bench_*.jsonl` + CSV |
| E1b 服务基线 | `run_server.sh` + `sse_bench.py` | TTFT/TPOT 曲线 |
| E2 量化 | 换 `MODEL=` 各跑一次 E1 | 精度-速度四联表 |
| E3 context | `matrix.txt` 的 `d=` 扫描 | 深度-吞吐曲线 |
| E4 并发 | `sse_bench.py --concurrency 1,2,4,8` | 吞吐/延迟拐点 |
| E5 profiling | `nsys profile`（见 `experiments.md §6`） | **kernel 时间占比表** |
| E6 改动验证 | patch 前后各跑 E1+E4+`test-backend-ops` | microbench + e2e 双层数字 |

## 4. 本机（当前平台）的已知边界

| 能力 | 状态 | 影响 |
|---|---|---|
| nvcc 编译 | ✅ | 可以做 §10 源码改动 |
| nsys 时间线 | ✅ | §8 主产出（kernel 名/次数/耗时）成立 |
| ncu counters（occupancy/带宽/stall） | ❌ 宿主限制 | **报告必须写明**：瓶颈归因依据 = nsys 时间线 + effBW 反推 + 参数扫描 |
| 下载速度 | ⚠️ 取决于源 | 用 `HF_HUB_DISABLE_XET=1` 或 ModelScope；实测阿里云源 15.9 MB/s |
| `/hy-tmp` 持久性 | ⚠️ 关机 24h 后可能被清 | 代码走 git，数据每次都推回远端 |

## 5. 远程开发：别用 Jupyter 的终端硬扛

JupyterLab 的终端有两个硬伤：**一断线进程就死**、**复制/滚动/多标签都别扭**。正确姿势：

**① 实例上装 tmux（最重要，5 秒装完）**

```bash
apt-get install -y tmux
tmux new -s work          # 之后所有长任务都在这里面跑
# 断线/关浏览器后重新连上：
tmux attach -t work       # 简写 tmux a
tmux ls                   # 看有哪些会话
```
→ 有了 tmux，客户端随便断，`llama-bench`、编译、下载都不会被杀。

**② 客户端选一个（按推荐度）**

| 工具 | 适合 | 说明 |
|---|---|---|
| **VS Code + Remote-SSH** | 本项目首选 | 一个窗口同时解决：编辑 `/hy-tmp` 上的文件、集成终端、拖拽传文件、git diff。装 "Remote - SSH" 扩展 + 一条连接配置即可，免费 |
| **Windows Terminal + 系统自带 ssh** | 纯命令行党 | `ssh root@<IP>`，多标签、配色好、复制粘贴正常（把连接写成 profile 一键连） |
| **MobaXterm（免费版）** | 要 SFTP 面板 | 左侧文件树 + 右侧多标签终端，拖拽上传下模型很方便 |
| **Xshell + Xftp（学生免费）** | 国内习惯 | 中文、稳定，Xftp 传文件 |
| **Termius / WindTerm** | 跨平台 / 开源 | Termius 手机也能用；WindTerm 免费且功能全 |
| JupyterLab | 只当"网盘" | 保留它来**上传/下载大文件**（模型、结果包），别在里面跑长任务 |

**③ 连不上怎么排查（按顺序，90% 在这几条里）**

| 症状 | 原因 | 解法 |
|---|---|---|
| 连不上/超时 | **公网 IP 变了**（阿里云"节省停机模式"重启后会换 IP） | 控制台看当前公网 IP，更新 `~/.ssh/config` 或连接命令 |
| 22 端口不通 | 安全组没放行 | 云控制台 → 安全组 → 入方向加规则：TCP **22**，源 `你的家庭宽带 IP/32` |
| 22 通但 `Permission denied` | 没设密码 / 没绑密钥 | 控制台"重置实例密码"（阿里云重置后需**重启实例**生效）；或绑定密钥对 |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | 换过机器/IP 复用 | 本地执行 `ssh-keygen -R <IP>` 后重连 |
| VS Code 卡在 **Downloading VS Code Server** | 远端从 `update.code.visualstudio.com` 拉 server 失败（国内常见） | 用国内 CDN 手动装：把报错里的 **commit id** 抄出来，本地下载 `https://vscode.cdn.azure.cn/stable/<commit>/vscode-server-linux-x64.tar.gz`，上传到实例后解压到 `~/.vscode-server/bin/<commit>/`（并 `touch ~/.vscode-server/bin/<commit>/0`） |

**本地自检三步**（PowerShell）：

```powershell
ipconfig | findstr IPv4                      # 你的公网出口（安全组要按这个放行）
Test-NetConnection <实例公网IP> -Port 22     # True=端口通
ssh -v root@<实例公网IP>                     # 看卡在哪一步：连接/认证/server 下载
```

**④ 传文件的三种方式**：VS Code 拖拽 / MobaXterm · Xftp 的 SFTP / `scp -r 本地路径 root@IP:/hy-tmp/`（本地 PowerShell 也能跑 scp）。

## 6. 排错速查

| 现象 | 原因 | 解法 |
|---|---|---|
| Python 脚本报 `SyntaxError: f-string: unterminated string` | 脚本用了 Python 3.12 才允许的"同种引号嵌套"，而实例的 Python ≤3.11 | `git pull` 拿修复版；仓库脚本已在 **Python 3.9 与 3.12 双版本验证**（最低要求 3.8） |
| `ncu` 报 `ERR_NVGPUCTRPERM` | 宿主驱动 `RmProfilingAdminOnly: 1` | 容器内无解；用 nsys，报告注明 counters 不可用 |
| `nsys` 报 `Illegal --force-overwrite option-argument` | 2023.4 的该参数是布尔 | `--force-overwrite true`，或换个新输出名 |
| `which nvcc/nsys` 找不到但实际已装 | `/usr/local/cuda/bin` 不在 PATH | `export PATH=/usr/local/cuda/bin:$PATH`（脚本已内置） |
| 下载 32 KB/s | HF Xet 绕过镜像缓存 | `HF_HUB_DISABLE_XET=1`，或换 ModelScope |
| `git push` 提示 non-fast-forward | 远端建仓库时初始化了 README | `git pull --rebase origin master` 后再 push |
| `git push` 一直要密码 | 忘了 token / 用了登录密码 | 用 PAT（fine-grained，只授权本仓库）；GCM 会记住 |
| `git clone` GitHub 报 `GnuTLS recv error (-110)` / 超时 | 国内实例直连 GitHub 不稳 | `git clone --depth 1 https://gitclone.com/github.com/ggml-org/llama.cpp`（`instance_setup.sh` 已内置自动回退）；或本地 clone 后 `scp -r` 上传 |
| **实例卡在「启动中」，停止/关机按钮点不动** | 该主机空闲卡被占（按量**不预留 GPU**），调度在等卡；或前端状态未刷新 | ① 刷新/重登控制台；② 等 10~15 分钟看是否自动回落到"已关机/启动失败"；③ 仍卡住就**找平台客服强制停止**，并**要求从启动时刻起不计费**（按量是"进入已关机才停表"）；④ 该状态下的实例**可以安全放弃**——数据都在 git 与本地，实例上没有值钱东西 |
