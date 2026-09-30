# 实验协议

## 0. 一条原则

**任何数字都必须能追到 `results/raw/` 里的某个文件。** 报告里的每个结论都标注来源文件。

## 1. 变量

**固定量（基线冻结，改任一即为新基线）**

```
GPU 型号与数量 = 单卡
模型 = Qwen3-4B, Q4_K_M
llama.cpp commit
构建参数（CUDA_ARCH / GGML_CUDA / 其它 -D）
推理参数（-ngl -t -fa -ctk -ctv -b -ub）
```

**自变量（一次只动一个）**

| 实验 | 自变量 | 取值 |
|---|---|---|
| E2 量化 | 模型量化 | Q8_0 / Q6_K / Q5_K_M / Q4_K_M / IQ4_XS |
| E3 context | KV 深度 `-d` | 2K / 4K / 8K / 16K / 32K |
| E4 并发 | 服务端并发 | 1 / 2 / 4 / 8 |
| E5 prefill 长度 | `-p` | 128 / 512 / 2048 / 4096 |
| E6 改动验证 | patch before/after | 同一个二进制参数下 A/B |

**因变量**

```
Prefill: prompt tokens/s          （llama-bench 的 pp* 行）
Decode:  generation tokens/s      （llama-bench 的 tg* 行）
服务:    TTFT / TPOT / 吞吐 / p50 p95 p99
显存:    nvidia-smi 峰值 / llama-server 启动日志估算
```

## 2. 测量定义

- **TTFT** = 从发出请求到收到第一个有内容的 chunk（包含排队 + 网络 + prefill）。
- **TPOT** = `(t_last - t_first) / (n_tokens - 1)`，即首尾 chunk 之间的平均间隔，**只统计解码间隔**，不含 prefill。
- **服务端交叉校验**：llama-server 在流末尾返回 `timings`（`prompt_n/prompt_ms/predicted_n/predicted_ms`），客户端记录它们，用于区分
  `TTFT - prompt_ms ≈ 排队时间`（并发 > 1 时这个量必须被解释）。
- **吞吐** = 一个并发档位内所有请求的输出 token 总数 ÷ 该档位墙钟时间。
- **百分位**：最近秩法（nearest-rank），样本 < 20 时 p99 无意义，报告里注明样本数。

## 3. 判据（防止自欺）

1. 每组配置 **warmup + ≥5 次重复**（llama-bench 用 `-r 5`；服务压测先跑 `--warmup 1`）。
2. llama-bench 自带 stddev：**两组均值差异必须在 ±2σ 之外**才认为有变化。
3. 端到端收益 **< 2% 视为噪声**，除非 microbench 有明确且可解释的提升 —— 此时结论写作"microbench +X%，端到端未观察到显著变化，原因是该 kernel 仅占 e2e 的 Y%"。
4. **负结果照样入库**：写进 `docs/findings.md`，不进报告正文也要进附录。

## 4. 命名与落盘

```
results/raw/bench_<YYYYmmdd-HHMMSS>_<TAG>_<row_tag>.jsonl   # llama-bench（每矩阵行一个）
results/raw/build_<ts>.json                                 # 构建/commit/参数
results/raw/env_<ts>.json                                   # 环境快照
results/raw/server_<ts>.log                                 # llama-server 日志
results/raw/serving_<ts>.jsonl                              # 逐请求原始记录（含 timings）
results/processed/bench_<ts>.csv                            # collect_metrics.py 产出
results/processed/serving_<ts>.csv                          # sse_bench.py 产出（分档汇总）
results/figures/                                            # 报告用图
```

`TAG` 是实验标识（`baseline` / `fa-on` / `patch-xxx`），**同一批 A/B 必须能只靠 TAG 区分**。

## 5. 实验清单

| # | 实验 | 命令 | 完成标准 |
|---|---|---|---|
| E1 | 基线 | `TAG=baseline bash scripts/run_bench.sh` | pp128/512/2048/4096 + tg256 全部有数，σ 稳定 |
| E1b | 深度解码 | 同上（矩阵含 `d=8192/32768` 行） | 得到 context↑→decode 变化的曲线 |
| E2 | 量化 | 换 `MODEL=`，逐量化各跑一次 E1 | VRAM / pp / tg / (服务侧 TTFT 可选) 四联表 |
| E3 | context | 矩阵 `-d` 扫描 | KV 显存与 decode 吞吐的关系 |
| E4 | 并发 | `sse_bench.py --concurrency 1,2,4,8` | 吞吐曲线 + TTFT/TPOT 的 p95 拐点 |
| E5 | profiling | `nsys profile` + `ncu` 抓 pp/tg 两个 phase | **一张"时间花在哪几个 kernel"的表**（§8 唯一产出） |
| E6 | 改动验证 | patch 前后各跑 E1 + E4 + `test-backend-ops` | microbench 与 e2e 双层数字 + 正确性通过 |

## 6. E5（profiling）的最小操作序列

```bash
# 1) 先看整体：kernel 时间占比、有没有明显的空洞（launch 间隙）
nsys profile -o results/raw/nsys_tg --force-overwrite \
  third_party/llama.cpp/build/bin/llama-bench -m $MODEL -p 0 -n 128 -r 1 -ngl 99
nsys stats results/raw/nsys_tg.nsys-rep

# 2) 再看细节：对单个最热 kernel 抓一次 counters（ncu 会 replay，很慢，务必限制次数）
ncu --target-processes all --launch-skip 20 --launch-count 1 \
    --set full -o results/raw/ncu_hot1 --force-overwrite \
    third_party/llama.cpp/build/bin/llama-bench -m $MODEL -p 0 -n 32 -r 1 -ngl 99

# 3) kernel 名 → 源文件，见 docs/architecture.md §3
```

**注意**：profiling 会改变时序，`nsys`/`ncu` 下的绝对速度**不作为性能结论**，只用于定位。性能结论一律来自不挂 profiler 的 `run_bench.sh` / `sse_bench.py`。
