# Qwen3 推理性能工程（项目总结）

> 这是**学习与展示层**：笔记、概念、结论索引。
> **代码与原始数据的唯一来源仍在仓库根**（`scripts/`、`benchmark/`、`results/`），此处不复制任何代码或数据，
> 否则会出现两套口径。映射关系见下表。

## 一句话

在单卡 RTX 3090（恒源云，按量 ¥0.98/h）上，对 llama.cpp 做**端到端推理性能工程**：
部署 → 建立基线 → 定位瓶颈 → 提出假设 → 修改系统 → 性能验证 → 服务压测。

固定基线：**Qwen3-4B / Q4_K_M**，llama.cpp **CUDA 源码构建**，单卡。

## 目录导航

| 目录 | 内容 | 与仓库根的关系 |
|---|---|---|
| `notes/` | 每日学习与实验记录（含当天数字与结论） | 新增，无重复 |
| `concepts/` | KV Cache、Scheduler 等知识笔记（定义 → 在 llama.cpp 里对应什么 → 我实测到的数字） | 与 `docs/architecture.md` 互补：那边是"代码地图"，这里是"概念理解" |
| `benchmarks/` | 性能结论索引（数据不动，只索引） | **原始数据在 `results/raw/`，汇总在 `results/processed/`** |
| `scripts/` | 入口说明（**不放代码**） | 实际代码在仓库根 `scripts/`（单一来源） |

仓库根的其他部分：

| 路径 | 作用 |
|---|---|
| `README.md` | 当前状态 + 开机 6 步 + 纪律 |
| `docs/runbook.md` | 每次开机的完整流程与排错 |
| `docs/environment.md` | 算账、平台决策、镜像/下载方案、实测记录 |
| `docs/experiments.md` | 测量口径（TTFT/TPOT）与判据（±2σ、<2% 视噪声） |
| `docs/findings.md` | 结论台账（每条必须能追到 `results/raw/` 的文件） |
| `docs/architecture.md` | 请求路径 + kernel 名 → 源文件反查 |
| `docs/roadmap.md` | 本项目之后补什么（P1~P6） |

## 进度

| 阶段 | 状态 |
|---|---|
| M0 跑通（编译 + llama-bench 出数） | ⬜ 未完成 |
| E1 离线基线 | ⬜ |
| E1b 服务基线（TTFT/TPOT） | ⬜ |
| E2 量化 / E3 context / E4 并发 | ⬜ |
| E5 profiling（nsys 时间线） | ⬜ |
| E6 源码改动 + 双层验证 | ⬜ |

## 最终总结（待数据齐全后写，结构固定）

```
1. Problem          —— 一个请求慢在哪里？参数变化为什么改变性能？能否改源码让它变快？
2. Architecture     —— llama.cpp / ggml / CUDA 分层与请求路径
3. Setup            —— 硬件、软件、模型、测量方法（环境以 results/raw/env_*.json 为准）
4. Baseline         —— llama-bench 与 serving 基线（含 σ 与重复次数）
5. Profiling        —— nsys kernel 时间占比表
6. Bottleneck       —— 定位到的 hot path，以及为什么它是瓶颈
7. Optimization     —— 改了什么、为什么这么改
8. Evaluation       —— microbench + e2e 双层数字 + 正确性验证 + 负结果
9. Lessons learned  —— 包括失败的尝试
```

**写作纪律**：每个数字都要能指到 `results/raw/` 的具体文件；负结果照样写。
