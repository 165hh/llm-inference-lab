# KV Cache

## 1. 定义 / 原理

自回归生成时，第 t 个 token 的注意力需要前面所有 token 的 K、V。如果每一步都重算，
复杂度是 O(n²) 次重算；因此把历史 K/V 缓存下来，代价是**显存**。

显存公式（单序列、单层）：

```
bytes = 2 × n_layer × n_kv_heads × head_dim × n_ctx × dtype_size
        └─ K 和 V ─┘
```

- `n_kv_heads` 是 **GQA/MQA 的关键**：KV heads 越少，KV cache 越小，这是现代模型能做长上下文的前提。
- dtype：`f16`（2 B/元素）→ `q8_0`（约 1.06 B/元素）→ `q4_0`（约 0.56 B/元素），KV 量化能近似线性省显存。
- KV 与**并发数**的关系：每个并发 slot 各有一份 KV，所以 `-np` 越大，总 KV 越大。

## 2. 在 llama.cpp 里对应什么

| 参数 / 机制 | 含义 |
|---|---|
| `-c / --ctx-size` | **所有 slot 共享**的总上下文容量（不是单请求上限） |
| `-np / --parallel` | 并发 slot 数；每个 slot 分到 `-c / -np` |
| `-ctk / -ctv` | KV cache 数据类型（本基线用 `q8_0`，可为 K/V 分别设置） |
| `--cache-reuse` | 前缀复用：相同前缀不重复 prefill（会直接影响 TTFT，压测时必须注意） |
| context shift / defrag | 上下文写满时的搬移与碎片整理（llama.cpp 是**连续 KV + slot 分配**，不是 vLLM 的分页 KV） |
| 启动日志 | llama-server 启动时会打印 KV cache 大小（这才是**实测值**，用它校对上面的公式） |

看代码：`src/llama-context.cpp`（KV cache 分配与 slot 管理）、`ggml/src/ggml-cuda/fattn*.cuh`（读写 KV 的注意力 kernel）。

## 3. 我实测到的数字

**待测**（M0 完成后补）。计划实测：

- [ ] `llama-server` 启动日志里的 KV 大小 vs 公式推算（Qwen3-4B：36 层 / 8 KV heads / head_dim 128
      → **144 KiB/token（f16）**，32K 上下文约 **4.5 GiB**；`q8_0` 约 **2.4 GiB**）
- [ ] `-c` 固定、`-np` 从 1 扫到 8：总 KV 与每 slot 上下文的变化
- [ ] `-ctk/-ctv` 从 `q8_0` 换 `f16`：显存差与 tok/s 差（进 E2/E3）
- [ ] `nvidia-smi` 观察到的实际占用 vs 公式

## 4. 未解决的疑问

- [ ] `q8_0` KV 对 4B 模型的输出质量影响有多大？（需要一个小 eval 集才能回答，暂缺）
- [ ] 并发 >1 时，slot 之间的 KV 是**预分配**还是**按需增长**？这决定了 `-np=8` 是否一开就吃掉 8 份显存。
- [ ] context shift 触发后，延迟毛刺有多大？（E4 并发扫描时用 p99 观察）
