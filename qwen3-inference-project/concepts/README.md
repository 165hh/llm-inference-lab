# 概念笔记

**每篇的固定结构**（四段，缺一不可）：

1. **定义 / 原理** —— 它解决什么问题，代价是什么
2. **在 llama.cpp 里对应什么** —— 哪个参数、哪个文件、哪段逻辑（能指到代码/日志）
3. **我实测到的数字** —— 引用 `results/raw/` 的文件名；没实测就写"待测"
4. **未解决的疑问** —— 这一栏最有价值，别留空

**与 `docs/architecture.md` 的分工**：那边是"代码地图"（请求路径、kernel→文件），
这里是"概念理解"（为什么这样设计、边界在哪）。

## 索引

| 笔记 | 主题 | 状态 |
|---|---|---|
| [kv-cache.md](kv-cache.md) | KV Cache：显存公式、llama.cpp 的实现方式、与并发/context 的关系 | 初稿（数字待实测校对） |
| scheduler.md | 调度：slot / continuous batching / chunked prefill 与 vLLM 的差别 | 待写 |
| prefill-vs-decode.md | 为什么 prefill 吃算力、decode 吃带宽（roofline） | 待写（E1 出数后写） |
| quantization.md | GGUF 量化（K-quant / IQ）与 kernel 的对应（MMQ/MMVQ/DP4A/MMA） | 待写（E2 出数后写） |
| profiling.md | nsys/ncu 能回答什么问题、counters 的权限门槛 | 待写（E5 出数后写） |
