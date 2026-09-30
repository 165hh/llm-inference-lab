# 系统结构（llama.cpp / ggml / CUDA backend）

> 文件名为 2026-09-29 从 upstream `ggml/src/ggml-cuda/`（共 162 个文件）核对过的结果；
> **以你 clone 下来的 commit 为准**，用 `ls ggml/src/ggml-cuda` 复核一次。

## 1. 一个请求的路径

```
client (SSE)
  │  HTTP /completion | /v1/chat/completions
  ▼
tools/server            ← HTTP 解析、slot 调度、continuous batching、prompt cache
  │  llama_decode(...)
  ▼
src/llama-graph.cpp     ← 构建 ggml 计算图（一次 decode 一张图）
  ▼
ggml/src/ggml-backend.cpp ← 张量分配到 backend、图切分、异步执行
  ▼
ggml/src/ggml-cuda/     ← 真正的 kernel 实现（本项目的战场）
  ▼
GPU
```

两个阶段的算子特征完全不同，必须分开测量：

| 阶段 | 特征 | 主要 kernel | 主要瓶颈 |
|---|---|---|---|
| **Prefill**（一次性处理 prompt） | batch 维度大（`n_tokens` 大） | `mul_mat_q`（MMQ，量化 GEMM）、flash attention | 算力（tensor core）+ 带宽混合 |
| **Decode**（逐 token 生成） | batch 维度小（batch=1 或并发 slot 数） | `mul_mat_vec_q`（MMVQ）、flash attention | **带宽**（每 token 要把权重读一遍） |

→ 这就是为什么 `docs/environment.md` 里"单位工作量成本"按带宽算：decode 阶段模型权重读取量 ≈ 模型大小，与 batch 无关。

## 2. ggml-cuda 里会反复出现的文件

| 文件 | 作用 |
|---|---|
| `mmq.cu` / `mmq.cuh` / `mmq-vec-dot.cuh` / `mmq-load-tiles.cuh` | 量化矩阵乘（大 batch / prefill 主力） |
| `mmq-config-ampere.cuh` | **Ampere（含 SM86：3060/3080Ti/3090/A4000/A5000/A40）的 tile/参数表** |
| `mmq-config-pascal-*.cuh` / `mmq-config-blackwell.cuh` / `mmq-config-{gcn,cdna,rdna*}.cuh` | 其他架构的配置表（注意：**架构分支是显式表格化的**，改表就能改行为） |
| `mmvq.cu` / `mmvq.cuh` | 量化矩阵乘向量（小 batch / decode 主力） |
| `fattn.cu` / `fattn.cuh` / `fattn-common.cuh` | flash attention 的**调度与选择逻辑**（选哪个 kernel、按什么条件） |
| `fattn-tile.cu` / `fattn-tile.cuh` | tile 版 FA（覆盖性最好） |
| `fattn-vec.cuh` | vec 版 FA（小 `ncols`/decode 场景） |
| `fattn-mma-f16.cuh` | 基于 tensor core MMA 的 FA（SM75+） |
| `common.cuh` / `common.cu` | warp 规约等公共设施 |
| `vendors/`、`template-instances/` | 厂商头文件、模板实例化 |

**这意味着本项目的第一个可落地改动类型，是"配置/启发式的选择逻辑"而不是"从零写 kernel"**——`mmq-config-*.cuh` 和 `fattn.cu` 的调度分支是可读、可改、可用 llama-bench 验证的。

## 3. kernel 名 → 源文件（profiling 之后必做的一步）

`ncu` / `nsys` 输出的是 mangled kernel 名，用名字反查文件：

```bash
# 例：在 nsys stats 里看到 mul_mat_q 相关的最热 kernel
grep -rn "mul_mat_q\|mul_mat_vec_q" third_party/llama.cpp/ggml/src/ggml-cuda --include=*.cu --include=*.cuh

# 只看某类 kernel 的落点
grep -rln "flash_attn" third_party/llama.cpp/ggml/src/ggml-cuda
```

llama.cpp 的 CUDA kernel 普遍是**模板 + 按 CC 分支**，所以：
- 同一个操作在不同 CC 上可能落到不同 kernel（这正是 §12 跨架构对比的素材）；
- `GGML_CUDA_FORCE_MMQ=ON` 之类的环境变量能强制走某条路径，可用来快速验证"是不是选择逻辑的问题"（是**诊断手段**，不是最终结论）。

## 4. 正确性验证（改 kernel 后必跑）

```bash
# 全量后端算子正确性测试（耗时几十分钟量级，别在计时窗口里跑）
third_party/llama.cpp/build/bin/test-backend-ops -b CUDA0

# 改动涉及的算子可以只跑子集
third_party/llama.cpp/build/bin/test-backend-ops -b CUDA0 -o MUL_MAT
```

外加 `scripts/smoke.sh` 里的冒烟 + `scripts/run_bench.sh` 的数值合理性检查（pp/tg 不该出现数量级变化）。

## 5. 本项目的三层验证栈

| 层 | 工具 | 证明什么 |
|---|---|---|
| 系统层 | `nsys`（timeline、kernel 时间占比）、`ncu`（occupancy/带宽/寄存器/stall） | **瓶颈在哪**（§8 的唯一产出） |
| 算子层 | `test-backend-ops`、改动前后的 kernel 耗时（ncu 或自建 microbench） | 改动**确实变快且不出错** |
| 端到端层 | `scripts/run_bench.sh`（llama-bench）+ `benchmark/serving/sse_bench.py`（TTFT/TPOT） | 改动**在服务上真的有收益** |

三层缺一不可：只有 microbench 的收益叫"未兑现"，只有 e2e 的收益叫"不可归因"。
