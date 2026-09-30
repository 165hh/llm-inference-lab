# LLM Inference Performance Engineering：基于 llama.cpp 的端到端推理部署、性能分析与优化

固定基线：**Qwen3-4B / Q4_K_M**，本地 llama.cpp CUDA 源码构建，AutoDL 按量 GPU。
闭环：`部署 → 建立基线 → 定位瓶颈 → 提出假设 → 修改系统 → 性能验证 → 服务压测`

## 目录约定

| 路径 | 作用 |
|---|---|
| `docs/environment.md` | 租卡方案、预算、成本纪律、Day-1 验证清单、环境记录 |
| `docs/architecture.md` | 请求路径 + ggml-cuda 关键文件 + kernel 名反查方法 |
| `docs/experiments.md` | 实验协议（固定量/自变量/因变量、判据、命名规范） |
| `docs/findings.md` | 结论台账（每条必须能追到 `results/raw/` 文件）+ 最终报告大纲 |
| `docs/roadmap.md` | 本项目之后要补的能力（P1~P6）、排序规则、消融清单、岗位映射 |
| `scripts/smoke.sh` | **Day-1 体检**：GPU/nvcc/**ncu 权限**/编译/冒烟，任何一步失败都不要继续 |
| `scripts/build.sh` | llama.cpp CUDA 源码构建 + 记录 commit/编译信息 |
| `scripts/run_bench.sh` | 按 `benchmark/offline/matrix.txt` 跑 llama-bench 矩阵 → `results/raw/*.jsonl` |
| `scripts/collect_metrics.py` | 原始 jsonl → `results/processed/*.csv` + 打印汇总表 |
| `scripts/run_server.sh` | 起 llama-server（固定配置 + 日志） |
| `scripts/record_env.sh` | 环境快照 → `results/raw/env_*.json` |
| `benchmark/offline/matrix.txt` | llama-bench 矩阵定义（改这里，不改脚本） |
| `benchmark/serving/sse_bench.py` | 自写 SSE 压测客户端（TTFT/TPOT/并发扫描，仅用标准库） |
| `results/{raw,processed,figures}` | raw 只写不删；processed 可重生成；figures 放论文级图 |
| `patches/` | 对 llama.cpp 的改动（`git format-patch` 产物） |
| `third_party/llama.cpp` | 上游源码（独立 clone，不入本仓库） |

## 第 0 步：上机前的准备（本地 / 无卡模式，零 GPU 成本）

1. **把本仓库推到远程 git 托管**（AutoDL 上要 clone 它）：
   `git remote add origin <你的仓库 url> && git push -u origin HEAD`
2. **创建 AutoDL 实例**（按量 3080Ti 12G）→ 创建后**先关机**（按量精确到秒，早关早不烧钱）→
   再用**无卡模式开机**（统一 ¥0.1/h）下载模型：
   - **入口**：控制台「容器实例」→ 实例卡片上的「开机」区域 / 「更多」菜单里选 **「无卡模式开机」**
     （**必须先处于关机状态**；官方截图见 <https://www.autodl.com/docs/save_money/>）。
   - 无卡模式 = **0.5 核 / 2GB 内存 / 无 GPU** → 只能下载、传文件、写代码，**编译会 OOM，跑不了实验**。
   - 同一主账号**同时只能有 1 个**无卡模式实例；它会**释放 GPU**（别人可能抢走）。
   - 加速：`source /etc/network_turbo`（AutoDL 学术资源加速）后再下载，国内直连 HF 慢时用镜像：
   ```bash
   pip install -U huggingface_hub
   HF_ENDPOINT=https://hf-mirror.com huggingface-cli download Qwen/Qwen3-4B-GGUF \
       Qwen3-4B-Q4_K_M.gguf --local-dir /root/autodl-tmp/models   # 仓库/文件名以 HF 实际页面为准
   ```
   - 数据放数据盘 `/root/autodl-tmp/`（关机不丢；系统盘也不要放大模型）。
3. 下载完 → **关机 → 正常开机**（有 GPU）再跑 `smoke.sh`。
   ⚠️ 无卡模式释放 GPU 后，正常开机时若该主机空闲卡不足会开不了机 —— 用「克隆实例」换区解决（官方推荐）。
4. 正常开机后**保存镜像**（环境只装一次；换卡/换区时克隆实例）。
5. 顺便验证 Triton 能不能装能跑（为后续 P1 铺路，见 `docs/roadmap.md`）：`pip install triton` + 跑一个 vector-add。

## 快速开始（在 GPU 机器上，按顺序）

```bash
# 0. 一次性
git clone https://github.com/ggml-org/llama.cpp third_party/llama.cpp
mkdir -p models            # 放 Qwen3-4B-Q4_K_M.gguf（或在第 0 步已放到 /root/autodl-tmp/models/）

# 1. Day-1 体检（最重要：ncu 权限决定 §8 profiling 能不能做）
export MODEL=$PWD/models/Qwen3-4B-Q4_K_M.gguf
bash scripts/smoke.sh

# 2. 基线：llama-bench 矩阵 → results/raw/bench_*.jsonl
TAG=baseline bash scripts/run_bench.sh
python scripts/collect_metrics.py

# 3. 服务压测（新开一个终端）
bash scripts/run_server.sh            # 前台运行，日志在 results/raw/server_*.log
python benchmark/serving/sse_bench.py --base-url http://127.0.0.1:8080 \
       --concurrency 1,2,4,8 --requests-per-level 8 --prompt-tokens 512 --max-tokens 256

# 4. 收工（AutoDL 关机不计 GPU 费；忘关=烧钱）
/usr/bin/shutdown
```

## 纪律（违反任何一条，结论作废）

1. **一次开机只做一批实验**：开机前把 TODO 写进 `patches/`/`docs/`，做完再关机，`/usr/bin/shutdown` 收尾。
2. **基线配置冻结**：GPU 型号 / 模型 / 量化 / context / llama.cpp commit，任一改变即为新基线，必须重测对照组。
3. **每组实验 warmup + ≥5 次重复**，报 p50/p95/p99 与标准差，不只报均值（llama-bench 自带 `-r` 与 stddev）。
4. **`results/raw/` 只写不删**；任何写进报告的数字必须能指到 raw 文件的具体一行。
5. **改动必须双层验证**：microbenchmark（kernel 级）+ end-to-end（llama-bench / server），且过正确性检查（`test-backend-ops`）。
6. **失败实验也记录**（进 `docs/findings.md`），"试过但没用"是判断力证据。
