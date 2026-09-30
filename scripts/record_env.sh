#!/usr/bin/env bash
# 记录环境快照 → results/raw/env_<ts>.json（同时打印）。
# 报告里的"Experimental setup"一节直接引用这个文件。
set -euo pipefail

LLAMA_DIR=${LLAMA_DIR:-third_party/llama.cpp}
mkdir -p results/raw
TS=$(date +%Y%m%d-%H%M%S)
OUT="results/raw/env_${TS}.json"

have() { command -v "$1" >/dev/null 2>&1; }
flat() { tr '\n' ' ' | tr -s '  ' ' ' | sed -e 's/"/\\"/g' -e 's/[[:space:]]*$//'; }
try()  { "$@" 2>/dev/null || echo unknown; }

GPU=$(nvidia-smi --query-gpu=name,memory.total,driver_version,compute_cap --format=csv,noheader 2>/dev/null | flat || true)
if [[ -z "${GPU:-}" ]]; then
  GPU=$(nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null | flat || true)
fi
[[ -n "${GPU:-}" ]] || GPU="nvidia-smi unavailable"

OS=$([ -r /etc/os-release ] && sed -n 's/^PRETTY_NAME="\(.*\)"/\1/p' /etc/os-release | sed -n 1p || uname -s)
CUDA_HOME_V=${CUDA_HOME:-$(dirname "$(dirname "$(command -v nvcc 2>/dev/null || echo /usr/local/cuda/bin/nvcc)")")}
LATEST_BUILD=$(ls -1t results/raw/build_*.json 2>/dev/null | sed -n 1p || true)

{
  printf '{\n'
  printf '  "timestamp": "%s",\n' "$(date -Is)"
  printf '  "hostname": "%s",\n'  "$(hostname 2>/dev/null || echo unknown)"
  printf '  "os": "%s",\n'        "$OS"
  printf '  "kernel": "%s",\n'    "$(uname -r)"
  printf '  "cpu": "%s",\n'       "$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo 2>/dev/null | sed -n 1p || echo unknown)"
  printf '  "cpu_cores": "%s",\n' "$(nproc 2>/dev/null || echo unknown)"
  printf '  "mem_total": "%s",\n' "$(free -h 2>/dev/null | sed -n 's/^Mem:[[:space:]]*\([^ ]*\).*/\1/p' || echo unknown)"
  printf '  "gpu": "%s",\n'       "$GPU"
  printf '  "nvcc": "%s",\n'      "$(have nvcc && nvcc --version | sed -n '/release/p' | flat || echo 'nvcc not found')"
  printf '  "cuda_home": "%s",\n' "$CUDA_HOME_V"
  printf '  "cmake": "%s",\n'     "$(have cmake && cmake --version | sed -n 1p | flat || echo 'cmake not found')"
  printf '  "gcc": "%s",\n'       "$(have gcc && gcc --version | sed -n 1p | flat || echo 'gcc not found')"
  printf '  "python": "%s",\n'    "$(have python3 && python3 --version 2>&1 | flat || echo 'python3 not found')"
  printf '  "ncu": "%s",\n'       "$(have ncu && ncu --version | flat || echo 'ncu not found')"
  printf '  "nsys": "%s",\n'      "$(have nsys && nsys --version | flat || echo 'nsys not found')"
  printf '  "llama_commit": "%s",\n'   "$(try git -C "$LLAMA_DIR" rev-parse HEAD)"
  printf '  "llama_describe": "%s",\n' "$(try git -C "$LLAMA_DIR" describe --tags --always)"
  printf '  "build_record": "%s",\n'   "$LATEST_BUILD"
  printf '  "autodl_price_note": "以 AutoDL 站内实时价为准"\n'
  printf '}\n'
} > "$OUT"

cat "$OUT"
echo "[env] 已写入 $OUT"
echo "[env] 提示：同步更新 docs/environment.md §6 的表格。"
