# 脚本入口（说明，不放代码）

**代码的唯一来源是仓库根的 `scripts/`** —— 这里刻意不复制任何脚本，避免出现两套实现、
两套 TTFT 口径（这正是项目纪律第 4 条要防的事）。

## 常用入口（在仓库根执行）

```bash
# 换平台/换机器的 2 分钟可用性首检
bash scripts/probe_platform.sh

# 一键准备（幂等）：clone llama.cpp → 编译 → 下模型
bash scripts/instance_setup.sh

# 冒烟体检（ncu 那一项在本平台会 FAIL：宿主限制，已知）
export MODEL=$PWD/models/Qwen3-4B-Q4_K_M.gguf && bash scripts/smoke.sh

# E1 基线：矩阵 → jsonl → CSV + 汇总表
TAG=baseline bash scripts/run_bench.sh
python scripts/collect_metrics.py

# 服务压测
bash scripts/run_server.sh &
python benchmark/serving/sse_bench.py --concurrency 1,2,4,8
```

## 每个脚本干什么

| 脚本 | 作用 |
|---|---|
| `probe_platform.sh` | GPU / nvcc 真编译 / **ncu 抓包权限** / CPU·盘·网速 → "这台机器能不能用" |
| `instance_setup.sh` | 幂等准备：clone llama.cpp → `build.sh` → 下模型 |
| `build.sh` | CUDA 源码构建 + 写 `results/raw/build_*.json` |
| `smoke.sh` | GPU / nvcc / ncu / nsys / 构建 / llama-bench 全查 → PASS/FAIL 汇总 |
| `run_bench.sh` | 按 `benchmark/offline/matrix.txt` 跑矩阵，每行一个 jsonl（带 TAG，便于 A/B） |
| `collect_metrics.py` | raw jsonl → CSV + 汇总表（含 effBW、按 depth/KV/FA 分组、TAG 对比） |
| `run_server.sh` | 起 llama-server（固定参数 + 日志） |
| `record_env.sh` | 环境快照 → `results/raw/env_*.json` |
