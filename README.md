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

## 快速开始（在 GPU 机器上，按顺序）

```bash
# 0. 一次性
git clone https://github.com/ggml-org/llama.cpp third_party/llama.cpp
mkdir -p models && # 放 Qwen3-4B-Q4_K_M.gguf 进来

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
