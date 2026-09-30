#!/usr/bin/env bash
# 按 benchmark/offline/matrix.txt 跑 llama-bench 矩阵；每个矩阵行输出一个 jsonl。
#
# 用法：
#   MODEL=/root/autodl-tmp/models/Qwen3-4B-Q4_K_M.gguf bash scripts/run_bench.sh
#   MODEL=... TAG=fa-off bash scripts/run_bench.sh          # A/B 对比靠 TAG 区分
#   NGL=99 THREADS=12 MATRIX=benchmark/offline/matrix.txt bash scripts/run_bench.sh
set -euo pipefail

MODEL=${MODEL:?用法：MODEL=/path/to/Qwen3-4B-Q4_K_M.gguf bash scripts/run_bench.sh}
MATRIX=${MATRIX:-benchmark/offline/matrix.txt}
BENCH=${BENCH:-third_party/llama.cpp/build/bin/llama-bench}
LLAMA_DIR=${LLAMA_DIR:-third_party/llama.cpp}
NGL=${NGL:-99}
THREADS=${THREADS:-$(nproc 2>/dev/null || echo 8)}
TAG=${TAG:-baseline}
OUTDIR=${OUTDIR:-results/raw}

if [[ ! -x "$BENCH" ]]; then
  echo "找不到可执行文件 $BENCH —— 先跑 bash scripts/build.sh" >&2
  exit 1
fi
if [[ ! -f "$MODEL" ]]; then echo "模型不存在：$MODEL" >&2; exit 1; fi
if [[ ! -f "$MATRIX" ]]; then echo "矩阵文件不存在：$MATRIX" >&2; exit 1; fi
mkdir -p "$OUTDIR"

COMMIT=$(git -C "$LLAMA_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)
GPU=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | sed -n 1p || echo unknown)
GPU=${GPU:-unknown}
echo "[bench] gpu=$GPU  commit=$COMMIT  tag=$TAG  threads=$THREADS  model=$MODEL"

run_row() {
  local tag=$1 p=$2 n=$3 d=$4 fa=$5 ctk=$6 ctv=$7 b=$8 ub=$9 reps=${10} idx=${11}
  local out args=()
  # 文件名里带行号：即使矩阵里出现重复 tag，也不会互相覆盖
  out="$OUTDIR/bench_$(date +%Y%m%d-%H%M%S)_${TAG}_${tag}_$(printf '%02d' "$idx").jsonl"

  args=(-m "$MODEL" -ngl "$NGL" -t "$THREADS" -r "$reps" -o jsonl)
  if [[ $p   != "-" ]]; then args+=(-p   "$p");   fi
  if [[ $n   != "-" ]]; then args+=(-n   "$n");   fi
  if [[ $d   != "-" ]]; then args+=(-d   "$d");   fi
  if [[ $fa  != "-" ]]; then args+=(-fa  "$fa");  fi
  if [[ $ctk != "-" ]]; then args+=(-ctk "$ctk"); fi
  if [[ $ctv != "-" ]]; then args+=(-ctv "$ctv"); fi
  if [[ $b   != "-" ]]; then args+=(-b   "$b");   fi
  if [[ $ub  != "-" ]]; then args+=(-ub  "$ub");  fi

  echo "[bench] $tag -> $out"
  echo "[bench]   ${args[*]}"
  "$BENCH" "${args[@]}" > "$out"

  python - "$out" "$tag" <<'PY'
import json, sys
path, tag = sys.argv[1], sys.argv[2]
rows = []
with open(path, encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if line:
            rows.append(json.loads(line))
if not rows:
    sys.exit(f"[bench]   FAIL: {path} 没有产出任何结果")
tests = [r.get("test") for r in rows]
ts = [r.get("avg_ts") for r in rows]
print(f"[bench]   ok [{tag}]: {len(rows)} 行  tests={tests}  avg_ts={['%.1f' % t for t in ts if t is not None]}")
PY
}

n=0
while read -r tag p n2 d fa ctk ctv b ub reps; do
  case "${tag:-}" in ''|\#*) continue;; esac
  n=$((n + 1))
  # 列缺失时给默认值；"-" 表示不传该 flag
  run_row "$tag" "${p:--}" "${n2:--}" "${d:--}" "${fa:--}" "${ctk:--}" "${ctv:--}" "${b:--}" "${ub:--}" "${reps:-5}" "$n"
done < "$MATRIX"

echo "[bench] 完成 $n 行 → $OUTDIR"
echo "[bench] 下一步：python scripts/collect_metrics.py"
echo "[bench] 收工记得：/usr/bin/shutdown"
