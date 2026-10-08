# LLM Inference Performance Engineering：基于 llama.cpp 的端到端推理部署、性能分析与优化

固定基线：**Qwen3-4B / Q4_K_M** · llama.cpp **CUDA 源码构建** · 单卡 **RTX 3090 24G**（恒源云，按量 ¥0.98/h）

闭环：`部署 → 建立基线 → 定位瓶颈 → 提出假设 → 修改系统 → 性能验证 → 服务压测`

**仓库公开地址**（实例上直接 clone，**无需任何认证**）：<https://github.com/165hh/llm-inference-lab>

## 当前状态（2026-09-30）

| 项 | 状态 |
|---|---|
| 仓库 | ✅ 已推到 GitHub 且为 **public**；`origin` = `https://github.com/165hh/llm-inference-lab.git`（HTTPS，本地凭据已记住，push 免密） |
| 平台 | ✅ **恒源云** RTX 3090 24G 按量 **¥0.98/h**（Ubuntu 22.04.4 / 96 核 / 503 GiB / CUDA 12.4 / gcc 11.4 / cmake 3.22） |
| Profiling 能力 | **nsys ✅**（kernel 时间线已验证）；**ncu counters ❌**（宿主 `RmProfilingAdminOnly: 1`，容器内无解） |
| 进度 | ⬜ **M0 未完成** —— 还没在实例上编译过 llama.cpp、没出过 llama-bench 数据；下一步见「快速开始」 |
| 换平台/换机器 | 有 `scripts/probe_platform.sh` 可一键复检；实测记录见 `docs/environment.md §4.5` 与 §6 |

## 目录约定

| 路径 | 作用 |
|---|---|
| `docs/runbook.md` | **每次开机的完整流程**（开机 → 准备 → M0 → E1 → 收工）+ 排错速查 |
| `docs/environment.md` | 租卡方案、预算、成本纪律、镜像选择、下载方案、缺货预案、实测记录 |
| `docs/architecture.md` | 请求路径 + ggml-cuda 关键文件 + kernel 名反查方法 |
| `docs/experiments.md` | 实验协议（固定量/自变量/因变量、判据、命名规范） |
| `docs/findings.md` | 结论台账（每条必须能追到 `results/raw/` 文件）+ 最终报告大纲 |
| `docs/roadmap.md` | 本项目之后要补的能力（P1~P6）、排序规则、消融清单、岗位映射 |
| `scripts/probe_platform.sh` | 换平台/换机器时的**可用性首检**（2 分钟：GPU/nvcc 真编译/**ncu 抓包**/资源/网速） |
| `scripts/instance_setup.sh` | **一键准备**（幂等）：clone llama.cpp → 编译 → 下模型 |
| `scripts/smoke.sh` | **冒烟体检**：GPU/nvcc/**ncu 权限**/nsys/编译/llama-bench |
| `scripts/build.sh` | llama.cpp CUDA 源码构建 + 记录 commit/编译信息 |
| `scripts/run_bench.sh` | 按 `benchmark/offline/matrix.txt` 跑 llama-bench 矩阵 → `results/raw/*.jsonl` |
| `scripts/collect_metrics.py` | 原始 jsonl → `results/processed/*.csv` + 终端汇总/对比表 |
| `scripts/run_server.sh` | 起 llama-server（固定配置 + 日志） |
| `scripts/record_env.sh` | 环境快照 → `results/raw/env_*.json` |
| `benchmark/offline/matrix.txt` | llama-bench 矩阵定义（改这里，不改脚本） |
| `benchmark/serving/sse_bench.py` | 自写 SSE 压测客户端（TTFT/TPOT/并发扫描，仅标准库） |
| `results/{raw,processed,figures}` | raw 只写不删；processed 可重生成；figures 放论文级图 |
| `patches/` | 对 llama.cpp 的改动（`git format-patch` 产物） |
| `third_party/llama.cpp` | 上游源码（独立 clone，不入本仓库） |
| `qwen3-inference-project/` | **学习与展示层**：`notes/`（每日记录）、`concepts/`（KV Cache 等概念笔记）、`benchmarks/`（结论索引）、`scripts/`（入口说明）。代码与数据不复制到这里，仍以本仓库根为唯一来源 |

## 快速开始（开机后照抄，6 步，≈25 分钟 / ¥0.4）

```bash
# 1) 环境 + 拉仓库（仓库是 public，clone 免认证；已存在则更新）
export PATH=/usr/local/cuda/bin:$PATH          # CUDA toolkit 常不在默认 PATH
cd /hy-tmp
if [ -d llm-inference-lab ]; then cd llm-inference-lab && git pull; else
  git clone https://github.com/165hh/llm-inference-lab.git && cd llm-inference-lab; fi

# 2) 一键准备（幂等）：clone llama.cpp → 编译（96 核约几分钟）→ 下模型
bash scripts/instance_setup.sh

# 3) M0 冒烟（ncu 那一项会 FAIL —— 本平台宿主限制，已知且接受）
export MODEL=$PWD/models/Qwen3-4B-Q4_K_M.gguf
bash scripts/smoke.sh

# 4) E1 基线：llama-bench 矩阵 → results/raw/*.jsonl → CSV + 汇总表
TAG=baseline bash scripts/run_bench.sh
python scripts/collect_metrics.py

# 5) 服务基线（可选，同一次开机顺便做）
bash scripts/run_server.sh &                       # 前台起服务；另开一个终端跑下面这条
python benchmark/serving/sse_bench.py --base-url http://127.0.0.1:8080 \
       --concurrency 1,2,4,8 --requests-per-level 8 --prompt-tokens 512 --max-tokens 256

# 6) 收工：写结论 → 数据带回家 → 关机
#    ① docs/findings.md 的「已确认结论」表加一行（必须写 raw 文件名）
#    ② 需要时在 qwen3-inference-project/notes/ 记一条（含数字）
git add -A && git commit -m "results: baseline on RTX 3090" && git push
shutdown -h now
```

| 步 | 做什么 | 产出 / 通过标准 |
|---|---|---|
| 1 | 环境 + 拉仓库 | 本地有 `scripts/`、`docs/` 全套 |
| 2 | `instance_setup.sh` | `third_party/llama.cpp/build/bin/llama-bench` + `models/*.gguf` |
| 3 | `smoke.sh` | 全 PASS（**除 ncu 一项：已知 FAIL，接受**） |
| 4 | `run_bench.sh` + `collect_metrics.py` | `results/raw/bench_*.jsonl` + `results/processed/bench_*.csv` |
| 5（可选） | 服务压测 | TTFT/TPOT 表 + `results/raw/serving_*.jsonl` |
| 6 | 写结论 + push + 关机 | `docs/findings.md` 多一行可追溯结论；数据回到远端；**停止计费** |

逐步说明与排错见 **`docs/runbook.md`**；算钱与换平台见 **`docs/environment.md`**。

## 纪律（违反任何一条，结论作废）

1. **一次开机只做一批实验**：开机前把 TODO 写进 `patches/`/`docs/`，做完就关机（`shutdown -h now`）。
2. **基线配置冻结**：GPU 型号 / 模型 / 量化 / context / llama.cpp commit，任一改变即为新基线，必须重测对照组。
3. **每组实验 warmup + ≥5 次重复**，报 p50/p95/p99 与标准差，不只报均值（llama-bench 自带 `-r` 与 stddev）。
4. **`results/raw/` 只写不删**；任何写进报告的数字必须能指到 raw 文件的具体一行。
5. **改动必须双层验证**：microbenchmark（kernel 级）+ end-to-end（llama-bench / server），且过正确性检查（`test-backend-ops`）。
6. **失败实验也记录**（进 `docs/findings.md`），"试过但没用"是判断力证据。

---

## 附录：换平台 / 换机器时再做（当前不用管）

### A. 新平台可用性首检（2 分钟，最便宜的决策点）

```bash
git clone https://github.com/165hh/llm-inference-lab.git && cd llm-inference-lab
bash scripts/probe_platform.sh
```

判定：**nvcc 必须 ✅**（否则编译不了 llama.cpp）；**ncu 能抓包最好**，退而求其次 nsys 也能支撑 §8
（报告里必须注明 counters 不可用）；CPU 核数 < 8 会污染 TTFT/并发测量。

### B. 仓库认证与远端

- 当前：**public 仓库**，实例上 `git clone` **免认证**（最省事）。
- 若改用私有仓库：**HTTPS + fine-grained PAT**（只授权本仓库、Contents: Read and write、1 年有效期），
  Windows 凭据管理器会记住；**不要用 SSH**（国内 22 端口常被墙 + Windows 权限坑）。
- 双远端（GitHub 展示 + Gitee 国内加速）：
  `git remote add gitee https://gitee.com/<用户名>/llm-inference-lab.git && git push gitee HEAD`
- Windows SSH 报 `Bad permissions` 的修法：
  `icacls "$env:USERPROFILE\.ssh\id_rsa" /inheritance:r /grant:r "$($env:USERNAME):(F)"`

### C. 租新实例（AutoDL / 恒源云 / 其他）

- **计费**：创建即开始计费，且**只跟开机时长有关**（与 GPU 是否在算无关）；AutoDL 有 ¥0.1/h 无卡模式，恒源云没有。
- **镜像**：选 **Ubuntu 20.04+、CUDA ≥ 11.8 且 ≤ 宿主驱动上限**（细则 `docs/environment.md §4.3`）。
- **下载慢**：`HF_HUB_DISABLE_XET=1` 或换 ModelScope（`docs/environment.md §4.6`）。
- **抢不到卡**：替代型号 / 双卡实例只跑一张卡 / 库存监控 / 免费额度边界，见 `docs/environment.md §4.1 §4.2`。
