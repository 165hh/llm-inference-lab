# 性能结论索引

**这里不放数据**，只放"结论 + 指路"。原始数据与汇总的位置是**唯一来源**：

| 内容 | 位置 |
|---|---|
| llama-bench 原始输出（每矩阵行一个 jsonl） | `results/raw/bench_<ts>_<TAG>_<row>.jsonl` |
| llama-bench 汇总 | `results/processed/bench_<ts>.csv`（由 `scripts/collect_metrics.py` 生成，可重算） |
| 服务压测逐请求记录 | `results/raw/serving_<ts>.jsonl` |
| 服务压测分档汇总 | `results/processed/serving_<ts>.csv` |
| 环境与构建快照 | `results/raw/env_*.json`、`results/raw/build_*.json` |
| 图 | `results/figures/` |

## 指标口径（不要在这里重新定义，见 `docs/experiments.md §2`）

- **Prefill**：prompt tokens/s（llama-bench `pp*` 行）
- **Decode**：generation tokens/s（`tg*` 行），另看 **effBW = 模型字节数 × tok/s**（离带宽上限多远）
- **服务**：TTFT（含排队）/ TPOT（只含解码间隔）/ 吞吐 / p50-p99
- **判据**：±2σ 之外才算变化；e2e < 2% 视为噪声

## 结论表（M0/E1 跑完后逐行填，每条必须带文件名）

| # | 结论 | 证据文件 | 环境 | 日期 |
|---|---|---|---|---|
| — | _(待填：例如"3090 上 Qwen3-4B Q4_K_M decode = xx tok/s，effBW = yy GB/s（上限 936）"）_ | `results/raw/bench_*.jsonl` | 3090 / sm_86 / CUDA 12.4 | |
| — | _(待填：prefill 从 128→4096 的 token 吞吐曲线形状与拐点)_ | | | |

## 与其它文档的关系

- 实验怎么做：`docs/experiments.md`（协议、判据、命名）
- 结论台账（含被推翻的假设）：`docs/findings.md`
- 平台与本机边界：`docs/environment.md §4.5 §6`
- 每日过程：`qwen3-inference-project/notes/`
