#!/usr/bin/env bash
# Day-1 体检：GPU / nvcc / ncu 权限 / nsys / llama.cpp 构建 / llama-bench 冒烟 / 环境记录。
# 任何一项 FAIL 都不要开始做实验（尤其 ncu：它决定 §8 profiling 能不能做）。
#
# 用法： export MODEL=/root/autodl-tmp/models/Qwen3-4B-Q4_K_M.gguf
#        bash scripts/smoke.sh
set -uo pipefail   # 故意不用 -e：要跑完全部检查再汇总

MODEL=${MODEL:-}
BENCH=${BENCH:-third_party/llama.cpp/build/bin/llama-bench}
SERVER_BIN=${SERVER_BIN:-third_party/llama.cpp/build/bin/llama-server}
NGL=${NGL:-99}
FAILED=0
N_PASS=0; N_FAIL=0; N_SKIP=0

ok()   { printf '[ PASS ] %s\n' "$1"; N_PASS=$((N_PASS+1)); }
bad()  { printf '[ FAIL ] %s\n' "$1"; N_FAIL=$((N_FAIL+1)); FAILED=1; }
skip() { printf '[ SKIP ] %s\n' "$1"; N_SKIP=$((N_SKIP+1)); }
info() { printf '[ info ] %s\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

echo "=== 1. GPU ==="
if have nvidia-smi; then
  GPU_LINE=$(nvidia-smi --query-gpu=name,memory.total,driver_version,compute_cap --format=csv,noheader 2>/dev/null || true)
  if [[ -z "$GPU_LINE" ]]; then
    GPU_LINE=$(nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null || true)
  fi
  if [[ -n "$GPU_LINE" ]]; then
    echo "$GPU_LINE"
    ok "nvidia-smi 可用"
    GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l)
    [[ "$GPU_COUNT" -ge 1 ]] || bad "没有可见 GPU"
  else
    bad "nvidia-smi 无输出（驱动/容器问题）"
  fi
else
  bad "没有 nvidia-smi"
fi

echo
echo "=== 2. CUDA toolkit ==="
if have nvcc; then
  nvcc --version | sed -n '/release/p'
  ok "nvcc 可用"
else
  if [[ -x /usr/local/cuda/bin/nvcc ]]; then
    info "nvcc 在 /usr/local/cuda/bin，但不在 PATH —— 执行： export PATH=/usr/local/cuda/bin:\$PATH"
    bad "nvcc 不在 PATH"
  else
    bad "找不到 nvcc（需要 CUDA toolkit）"
  fi
fi

echo
echo "=== 3. Profiling 权限（最致命的一项）==="
CC=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | sed -n 1p | tr -d '.')
if [[ -z "${CC:-}" ]]; then
  info "无法从 nvidia-smi 取 compute_cap，按 8.6 兜底"
  CC=86
fi
if have nvcc; then
  cat > /tmp/ncu_probe.cu <<'CU'
#include <cstdio>
__global__ void vector_add_kernel(const float * a, const float * b, float * c, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) { c[i] = a[i] + b[i]; }
}
int main() {
    const int n = 1 << 20;
    float * a; float * b; float * c;
    cudaMallocManaged(&a, n * sizeof(float));
    cudaMallocManaged(&b, n * sizeof(float));
    cudaMallocManaged(&c, n * sizeof(float));
    for (int i = 0; i < n; ++i) { a[i] = 1.0f; b[i] = 2.0f; }
    vector_add_kernel<<<(n + 255) / 256, 256>>>(a, b, c, n);
    cudaDeviceSynchronize();
    printf("probe sum=%f\n", c[n - 1]);
    cudaFree(a); cudaFree(b); cudaFree(c);
    return 0;
}
CU
  if nvcc -O2 -arch="sm_${CC}" -o /tmp/ncu_probe_bin /tmp/ncu_probe.cu 2>/tmp/ncu_probe_build.log; then
    ok "probe 二进制编译成功（arch=sm_${CC}）"
    if have ncu; then
      if ncu --launch-count 1 --kernel-name regex:vector_add --target-processes all \
             -o /tmp/ncu_probe_report --force-overwrite /tmp/ncu_probe_bin >/tmp/ncu_probe_run.log 2>&1; then
        ok "ncu 抓包成功 → /tmp/ncu_probe_report.ncu-rep（§8 profiling 可做）"
        grep -m1 -i 'error\|ERR_NVGPUCTRPERM' /tmp/ncu_probe_run.log || true
      else
        bad "ncu 无法抓包 —— §8 直接做不了"
        echo "      --- ncu 输出 ----"
        sed -n '1,20p' /tmp/ncu_probe_run.log
        echo "      -----------------"
        info "常见原因：ERR_NVGPUCTRPERM（驱动限制 profiling 给非 root）。"
        info "对策：以 root 运行 / 宿主设 NVreg_RestrictProfilingToAdminUsers=0 / 换主机。云平台通常需要开工单。"
      fi
    else
      bad "找不到 ncu（Nsight Compute 未安装）"
    fi
  else
    bad "probe 编译失败，看 /tmp/ncu_probe_build.log"
    sed -n '1,20p' /tmp/ncu_probe_build.log
  fi
else
  skip "跳过 profiling 检查（没有 nvcc）"
fi

echo
echo "=== 4. Nsight Systems ==="
if have nsys; then
  nsys --version | sed -n 1p
  ok "nsys 可用"
else
  bad "找不到 nsys（system-level timeline 缺失，§8 只剩 ncu 一半）"
fi

echo
echo "=== 5. llama.cpp 构建 ==="
if [[ -x "$BENCH" && -x "$SERVER_BIN" ]]; then
  ok "llama-bench / llama-server 存在"
  LLAMA_DIR=${LLAMA_DIR:-third_party/llama.cpp}
  info "commit: $(git -C "$LLAMA_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
else
  bad "缺少 $BENCH 或 $SERVER_BIN —— 先跑： bash scripts/build.sh"
fi

echo
echo "=== 6. llama-bench 冒烟（-p 128 -n 32 -r 1）==="
if [[ -z "$MODEL" ]]; then
  skip "未设置 MODEL，跳过（export MODEL=/path/to/model.gguf 后再跑）"
elif [[ ! -f "$MODEL" ]]; then
  bad "MODEL 指向的文件不存在：$MODEL"
elif [[ ! -x "$BENCH" ]]; then
  skip "llama-bench 不存在"
else
  if "$BENCH" -m "$MODEL" -ngl "$NGL" -p 128 -n 32 -r 1 2>&1 | tee /tmp/bench_smoke.log; then
    ok "llama-bench 出数"
  else
    bad "llama-bench 失败，详见 /tmp/bench_smoke.log"
  fi
fi

echo
echo "=== 7. 环境记录 ==="
if bash scripts/record_env.sh >/tmp/env_record.log 2>&1; then
  ok "环境快照已写入（results/raw/env_*.json）"
else
  bad "record_env.sh 失败，详见 /tmp/env_record.log"
fi

echo
echo "================ 汇总 ================"
printf 'PASS=%d  FAIL=%d  SKIP=%d\n' "$N_PASS" "$N_FAIL" "$N_SKIP"
if [[ "$FAILED" -eq 0 ]]; then
  echo "全部通过 → 可以开始 E1 基线： TAG=baseline bash scripts/run_bench.sh"
else
  echo "存在 FAIL：先解决再开始实验（尤其第 3 项 profiling 权限）。"
fi
exit "$FAILED"
