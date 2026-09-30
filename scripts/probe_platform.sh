#!/usr/bin/env bash
# 平台首检：判断"这台机器能不能拿来做本项目"。不依赖本仓库、不依赖模型，2 分钟内跑完。
#
# 用法（实例上）：
#   bash probe_platform.sh
#   # 或者直接在终端粘贴 README/对话里的 heredoc 版本
#
# 判定线（详见 docs/environment.md §5）：
#   nvidia-smi 可用                      → 基础
#   nvcc 可用 + 能编译并跑 CUDA 程序      → 必需（llama.cpp 源码构建）
#   ncu 能抓包（不是只装了）              → §8 profiling 的生死线
#   nsys 可用                            → 强烈建议
#   计算能力 CC                          → 决定 build.sh 的 CUDA_ARCH
#   目录布局（/hy-tmp、个人数据盘）        → 决定数据放哪（防"关机被清"）
set -uo pipefail

# CUDA toolkit 常不在默认 PATH（各平台不一致）→ 补上，否则 nvcc/nsys 会误报"缺失"
if [ -d /usr/local/cuda/bin ]; then
  case ":$PATH:" in *":/usr/local/cuda/bin:"*) ;; *) PATH="/usr/local/cuda/bin:$PATH";; esac
fi
export PATH

PASS=0; WARN=0; FAIL=0; CC=""
ok()   { printf '[ PASS ] %s\n' "$1"; PASS=$((PASS+1)); }
warn() { printf '[ WARN ] %s\n' "$1"; WARN=$((WARN+1)); }
bad()  { printf '[ FAIL ] %s\n' "$1"; FAIL=$((FAIL+1)); }
info() { printf '[ info ] %s\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

echo "=== 0. 机器标识 ==="
info "host=$(hostname 2>/dev/null)  user=$(whoami)  date=$(date -Is)"
if [ -r /etc/os-release ]; then
  info "系统: $(sed -n 's/^PRETTY_NAME="\(.*\)"/\1/p' /etc/os-release | sed -n 1p)"
fi
info "内核: $(uname -r)"

echo
echo "=== 1. GPU ==="
if have nvidia-smi; then
  if nvidia-smi --query-gpu=name,memory.total,driver_version,compute_cap --format=csv,noheader 2>/dev/null; then
    CC=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | sed -n 1p | tr -d '.')
  else
    nvidia-smi | sed -n '1,12p'
  fi
  ok "nvidia-smi 可用"
  info "注意：nvidia-smi 里的 'CUDA Version' 是驱动支持上限，不是镜像内 toolkit 版本"
  info "GPU 数量: $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l)"
else
  bad "没有 nvidia-smi"
fi
[ -n "$CC" ] || CC=86
info "compute capability → 建议 CUDA_ARCH=${CC}-real"

echo
echo "=== 2. 编译链 ==="
if have nvcc; then
  nvcc --version | sed -n '/release/p'
  ok "nvcc 在 PATH"
elif [ -x /usr/local/cuda/bin/nvcc ]; then
  warn "nvcc 在 /usr/local/cuda/bin 但不在 PATH → export PATH=/usr/local/cuda/bin:\$PATH"
else
  bad "找不到 nvcc：无法源码编译 llama.cpp"
fi
have gcc   && info "gcc: $(gcc --version | sed -n 1p)"            || warn "没有 gcc"
have cmake && info "cmake: $(cmake --version | sed -n 1p)"        || warn "没有 cmake（可 apt 装）"
have ninja && info "ninja: $(ninja --version)"                     || info "没有 ninja（用 make 也行，慢些）"
have git   && info "git: $(git --version)"                         || warn "没有 git"

echo
echo "=== 3. 真编译 + 真在 GPU 上跑（最重要的单一验证）==="
TMPD=$(mktemp -d)
PROBE_BIN=""
if have nvcc; then
  cat > "$TMPD/t.cu" <<'CU'
#include <cstdio>
__global__ void probe_kernel(const float * a, const float * b, float * c, int n) {
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
    probe_kernel<<<(n + 255) / 256, 256>>>(a, b, c, n);
    cudaDeviceSynchronize();
    printf("sum=%f\n", c[n - 1]);
    return 0;
}
CU
  if nvcc -O2 -arch="sm_${CC}" -o "$TMPD/t" "$TMPD/t.cu" 2>"$TMPD/build.log" && "$TMPD/t" > "$TMPD/run.log" 2>&1; then
    PROBE_BIN="$TMPD/t"
    ok "nvcc 编译通过，且 CUDA 程序在 GPU 上执行成功（sm_${CC}）"
    sed -n 1p "$TMPD/run.log" | sed 's/^/       /'
  else
    bad "编译或执行失败"
    sed -n '1,6p' "$TMPD/build.log" 2>/dev/null | sed 's/^/       /'
  fi
else
  bad "跳过（无 nvcc）"
fi

echo
echo "=== 4. Profiling 工具（§8 的生死线）==="
if have ncu; then
  info "ncu: $(ncu --version 2>/dev/null | sed -n 1p)"
  if [ -n "$PROBE_BIN" ]; then
    if ncu --launch-count 1 --kernel-name regex:probe_kernel --target-processes all \
           -o "$TMPD/ncu_rep" --force-overwrite "$PROBE_BIN" > "$TMPD/ncu.log" 2>&1; then
      ok "ncu 抓包成功 → profiling 权限可用（可以做 §8）"
    else
      bad "ncu 抓包失败（多半是 ERR_NVGPUCTRPERM / 驱动限制）→ §8 做不了"
      sed -n '1,8p' "$TMPD/ncu.log" | sed 's/^/       /'
    fi
  else
    warn "没有可用的 probe 二进制，无法验证 ncu 抓包权限"
  fi
else
  bad "没有 ncu（Nsight Compute）→ §8 profiling 做不了"
fi
have nsys && ok "nsys: $(nsys --version 2>/dev/null | sed -n 1p)" || warn "没有 nsys（system-level timeline 缺失）"

echo
echo "=== 5. CPU / 内存 / 磁盘 ==="
NPROC=$(nproc 2>/dev/null || echo 1)
info "CPU: ${NPROC} 核  $(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo 2>/dev/null | sed -n 1p)"
info "内存: $(free -h 2>/dev/null | sed -n 's/^Mem:[[:space:]]*\([^ ]*\).*/\1/p')"
if [ "$NPROC" -ge 8 ]; then
  ok "CPU 核数 ≥ 8（编译不慢，采样/HTTP 线程不易成瓶颈）"
else
  warn "CPU 核数 < 8：编译慢，且 llama-server 的采样/HTTP 线程可能污染 TTFT/并发测量（报告里必须注明 -t 与核数）"
fi
info "目录布局（数据放哪，决定了关机后会不会被清）："
for p in / /hy-tmp /hy-nas /root/autodl-tmp /root/autodl-fs /root/shared-nvme /workspace; do
  if [ -d "$p" ]; then
    printf '       %-20s %s\n' "$p" "$(df -hT "$p" 2>/dev/null | sed -n 2p | awk '{print $2", 已用 "$3", 可用 "$5}')"
  fi
done

echo
echo "=== 6. 网络（模型下载速度，粗测 50MB）==="
if have curl; then
  SPEED=$(curl -sL --max-time 25 -r 0-52428799 -o /dev/null -w '%{speed_download}' \
          "https://hf-mirror.com/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf" 2>/dev/null || echo 0)
  SPEED=${SPEED:-0}
  MBPS=$(awk -v s="$SPEED" 'BEGIN{printf "%.2f", s/1048576}')
  if awk -v s="$SPEED" 'BEGIN{exit !(s > 1048576)}'; then
    ok "hf-mirror 下载 ≈ ${MBPS} MB/s（2.5GB 的 GGUF ≈ $(awk -v s="$SPEED" 'BEGIN{printf "%.0f", 2500/(s/1048576)*1.05}') 秒）"
  else
    warn "hf-mirror 实测 ≈ ${MBPS} MB/s（过慢或不可达）→ 试 ModelScope，或先问平台有没有加速通道"
  fi
else
  warn "没有 curl，跳过网速测试"
fi

echo
echo "================ 结论 ================"
printf 'PASS=%d  WARN=%d  FAIL=%d\n' "$PASS" "$WARN" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "这台机器**可以用**。下一步（需要本仓库）："
  echo "  bash scripts/build.sh            # 默认 CUDA_ARCH=86-real，按上面 CC 调整"
  echo "  TAG=baseline bash scripts/run_bench.sh && python scripts/collect_metrics.py"
else
  echo "存在 FAIL —— 先解决再投钱。关键项是 nvcc（编译）与 ncu（profiling 权限）。"
fi
echo "提示：本脚本自身耗时 < 2 分钟；用完立刻关机（按量关机即停表）。"
rm -rf "$TMPD" 2>/dev/null || true
