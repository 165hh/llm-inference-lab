# 结论台账

三条规则：
1. 每条结论必须引用 `results/raw/` 的文件名（可追溯）。
2. 被推翻的假设**不要删**，移到"已推翻"表 —— 这是判断力证据。
3. 标注适用范围（哪个 GPU / 哪个 commit / 哪个参数区间）。

**分工（重要）**：AI/工具可以做**机械劳动**（跑命令、算 effBW、把数字整理成表格行）；
但**解读必须自己写**——"为什么是这样、边界在哪、下一步验证什么"这三句只能用你自己的话写，
否则面试官追问三层就崩。写的时候标清 `[实测]` 与 `[推测]`。

## 已确认结论

| # | 结论 | 证据文件 | 适用范围 | 日期 |
|---|---|---|---|---|
| 1 | _(待填，示例：SM86 上 decode 阶段 MMVQ 占 kernel 时间 X%，带宽利用率 Y%)_ | `results/raw/...` | 3080Ti / SM86 / Q4_K_M | |

## 已推翻假设

| # | 假设 | 为什么错 | 证据文件 | 日期 |
|---|---|---|---|---|
| 1 | | | | |

## 待验证 / 未解释

| # | 问题 | 下一步 | 状态 |
|---|---|---|---|
| 1 | 并发 4 以上 TTFT 的 p95 跳变来自排队还是 prefill 抢占？ | 看 `serving_*.jsonl` 的 `ttft_ms - server_prompt_ms` | |
| 2 | | | |

---

## 最终报告大纲（§13 交付物⑤）

```
1. Problem          —— 一个请求慢在哪里？参数变化为什么改变性能？能不能改源码让它变快？
2. Architecture     —— llama.cpp / ggml / CUDA backend 分层与请求路径（见 docs/architecture.md）
3. Experimental setup —— 硬件、软件、模型、测量方法（见 docs/environment.md + experiments.md）
4. Baseline         —— llama-bench 与 serving 基线（含 σ、重复次数）
5. Profiling        —— nsys/ncu 结果，kernel 时间占比表
6. Bottleneck       —— 定位到的 hot path，以及**为什么**它是瓶颈（带宽/occupancy/寄存器/选择逻辑）
7. Optimization     —— 改动内容 + 为什么这样改
8. Evaluation       —— microbench + e2e 双层数字，正确性验证结果，负结果
9. Lessons learned  —— 包括失败的尝试与对上游设计的理解
```
