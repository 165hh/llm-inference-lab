#!/usr/bin/env bash
# llama.cpp CUDA 源码构建（非 Docker）+ 记录 commit / 编译参数。
#
# 用法：
#   bash scripts/build.sh
#   CUDA_ARCH=86-real bash scripts/build.sh                          # 默认 86 = Ampere(3060/3080Ti/3090/A4000)
#   CUDA_ARCH="86-real;75-real" bash scripts/build.sh                # 跨架构对比时一次编多架构
#   EXTRA_CMAKE_ARGS="-DGGML_CUDA_FA_ALL_QUANTS=ON" bash scripts/build.sh
set -euo pipefail

LLAMA_DIR=${LLAMA_DIR:-third_party/llama.cpp}
BUILD_DIR=${BUILD_DIR:-$LLAMA_DIR/build}
CUDA_ARCH=${CUDA_ARCH:-86-real}
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}

log() { printf '[build] %s\n' "$*"; }

if [[ ! -d "$LLAMA_DIR" ]]; then
  echo "缺少 $LLAMA_DIR —— 先执行：" >&2
  echo "  git clone https://github.com/ggml-org/llama.cpp $LLAMA_DIR" >&2
  exit 1
fi
command -v nvcc  >/dev/null || { echo "找不到 nvcc（需要 CUDA toolkit，注意 /usr/local/cuda/bin 是否在 PATH）" >&2; exit 1; }
command -v cmake >/dev/null || { echo "找不到 cmake" >&2; exit 1; }

extra_args=()
if [[ -n "${EXTRA_CMAKE_ARGS:-}" ]]; then
  read -r -a extra_args <<< "$EXTRA_CMAKE_ARGS"
fi

COMMIT=$(git -C "$LLAMA_DIR" rev-parse HEAD 2>/dev/null || echo unknown)
DESCRIBE=$(git -C "$LLAMA_DIR" describe --tags --always 2>/dev/null || echo unknown)
NVCC_VER=$(nvcc --version | sed -n '/release/p' | tr -d '\r')
CM_VER=$(cmake --version | sed -n '1p' | tr -d '\r')

log "llama.cpp : $LLAMA_DIR @ $DESCRIBE ($COMMIT)"
log "$NVCC_VER"
log "CUDA_ARCH=$CUDA_ARCH  JOBS=$JOBS"

cmake -B "$BUILD_DIR" -S "$LLAMA_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_CUDA=ON \
  -DGGML_NATIVE=ON \
  -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH" \
  "${extra_args[@]}"

cmake --build "$BUILD_DIR" --config Release -j "$JOBS" \
  --target llama-bench llama-server llama-cli

mkdir -p results/raw
TS=$(date +%Y%m%d-%H%M%S)
OUT="results/raw/build_${TS}.json"
{
  printf '{\n'
  printf '  "timestamp": "%s",\n' "$(date -Is)"
  printf '  "llama_dir": "%s",\n' "$LLAMA_DIR"
  printf '  "commit": "%s",\n' "$COMMIT"
  printf '  "describe": "%s",\n' "$DESCRIBE"
  printf '  "cuda_arch": "%s",\n' "$CUDA_ARCH"
  printf '  "nvcc": "%s",\n' "$(printf '%s' "$NVCC_VER" | sed 's/"/\\"/g')"
  printf '  "cmake": "%s",\n' "$(printf '%s' "$CM_VER" | sed 's/"/\\"/g')"
  printf '  "extra_cmake_args": "%s",\n' "${EXTRA_CMAKE_ARGS:-}"
  printf '  "build_dir": "%s"\n' "$BUILD_DIR"
  printf '}\n'
} > "$OUT"

log "二进制：$(ls "$BUILD_DIR/bin" | tr '\n' ' ')"
log "构建信息已写入 $OUT"
log "提示：把 $OUT 与 docs/environment.md §6 的表格同步一次。"
