#!/usr/bin/env bash
# 一键把实例准备好（幂等：已存在的步骤自动跳过）：clone llama.cpp → 编译 → 下模型。
# 每次开机只需要跑这一条，然后就能直接跑基线。
#
# 用法（在仓库根目录）：
#   bash scripts/instance_setup.sh
# 可覆盖的环境变量：
#   CUDA_ARCH=86-real          目标架构（3090/3080Ti/3060 都是 86；A100=80；4090=89；T4/2080Ti=75）
#   MODEL_REPO=Qwen/Qwen3-4B-GGUF  MODEL_FILE=Qwen3-4B-Q4_K_M.gguf
#   HF_ENDPOINT=https://hf-mirror.com
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD

LLAMA_DIR=${LLAMA_DIR:-third_party/llama.cpp}
MODEL_DIR=${MODEL_DIR:-models}
MODEL_FILE=${MODEL_FILE:-Qwen3-4B-Q4_K_M.gguf}
MODEL_REPO=${MODEL_REPO:-Qwen/Qwen3-4B-GGUF}
HF_ENDPOINT=${HF_ENDPOINT:-https://hf-mirror.com}
export CUDA_ARCH=${CUDA_ARCH:-86-real}

# CUDA toolkit 常不在默认 PATH
if [ -d /usr/local/cuda/bin ]; then
  case ":$PATH:" in *":/usr/local/cuda/bin:"*) ;; *) PATH="/usr/local/cuda/bin:$PATH";; esac
fi
export PATH

echo "[setup] 仓库根目录：$ROOT"

# 1) llama.cpp
if [ ! -d "$LLAMA_DIR/.git" ]; then
  echo "[setup] clone llama.cpp → $LLAMA_DIR"
  git clone --depth 1 https://github.com/ggml-org/llama.cpp "$LLAMA_DIR"
else
  echo "[setup] llama.cpp 已存在，跳过 clone（$(git -C "$LLAMA_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)）"
fi

# 2) 编译
if [ ! -x "$LLAMA_DIR/build/bin/llama-bench" ]; then
  echo "[setup] 编译 llama.cpp（CUDA_ARCH=$CUDA_ARCH）"
  bash scripts/build.sh
else
  echo "[setup] llama-bench 已存在，跳过编译"
fi

# 3) 模型
mkdir -p "$MODEL_DIR"
if [ ! -s "$MODEL_DIR/$MODEL_FILE" ]; then
  echo "[setup] 下载模型 $MODEL_REPO/$MODEL_FILE → $MODEL_DIR"
  pip install -q -U huggingface_hub hf_transfer >/dev/null 2>&1 || true
  # HF_HUB_DISABLE_XET=1：禁用 Xet，否则会绕过国内镜像直连境外 CDN（实测 32 KB/s → 见 docs/environment.md §4.6）
  if command -v hf >/dev/null 2>&1; then
    HF_ENDPOINT="$HF_ENDPOINT" HF_HUB_DISABLE_XET=1 HF_HUB_ENABLE_HF_TRANSFER=1 \
      hf download "$MODEL_REPO" "$MODEL_FILE" --local-dir "$MODEL_DIR"
  else
    HF_ENDPOINT="$HF_ENDPOINT" HF_HUB_DISABLE_XET=1 HF_HUB_ENABLE_HF_TRANSFER=1 \
      huggingface-cli download "$MODEL_REPO" "$MODEL_FILE" --local-dir "$MODEL_DIR"
  fi
else
  echo "[setup] 模型已存在，跳过下载（$(du -h "$MODEL_DIR/$MODEL_FILE" | cut -f1)）"
fi

echo
echo "[setup] 就绪。下一步："
echo "  export MODEL=$ROOT/$MODEL_DIR/$MODEL_FILE"
echo "  bash scripts/smoke.sh"
echo "  TAG=baseline bash scripts/run_bench.sh && python scripts/collect_metrics.py"
echo "  # 收工：/usr/bin/shutdown  （并把 results/ 提交推送回远端）"
