#!/usr/bin/env bash
# 启动 llama-server（固定配置 + 日志落盘）。前台运行；压测时用 `&` 或另开一个终端。
#
# 用法：
#   MODEL=/root/autodl-tmp/models/Qwen3-4B-Q4_K_M.gguf bash scripts/run_server.sh
#   CTX=8192 NP=8 CTK=q8_0 bash scripts/run_server.sh
#
# 注意：若某个 flag 在你的 commit 上不存在（--metrics / --slots / --log-file 都是较新特性），
#       llama-server 会立刻报 unknown argument，按 --help 删掉对应参数即可。
set -euo pipefail

MODEL=${MODEL:?用法：MODEL=/path/to/Qwen3-4B-Q4_K_M.gguf bash scripts/run_server.sh}
SERVER=${SERVER:-third_party/llama.cpp/build/bin/llama-server}
CTX=${CTX:-4096}
NGL=${NGL:-99}
FA=${FA:-on}          # on / off / auto
CTK=${CTK:-q8_0}
CTV=${CTV:-q8_0}
NP=${NP:-8}           # 并发 slot 数（压测的并发上限由它决定）
B=${B:-2048}
UB=${UB:-512}
PORT=${PORT:-8080}
HOST=${HOST:-127.0.0.1}
THREADS=${THREADS:-$(nproc 2>/dev/null || echo 8)}
EXTRA=${EXTRA:-}

if [[ ! -x "$SERVER" ]]; then echo "找不到 $SERVER —— 先跑 bash scripts/build.sh" >&2; exit 1; fi
if [[ ! -f "$MODEL" ]]; then echo "模型不存在：$MODEL" >&2; exit 1; fi
mkdir -p results/raw
LOG="results/raw/server_$(date +%Y%m%d-%H%M%S).log"

args=(-m "$MODEL" -c "$CTX" -ngl "$NGL" -fa "$FA" -ctk "$CTK" -ctv "$CTV" \
      -np "$NP" -b "$B" -ub "$UB" -t "$THREADS" \
      --host "$HOST" --port "$PORT" --metrics --slots)
if [[ -n "$EXTRA" ]]; then
  read -r -a extra_args <<< "$EXTRA"
  args+=("${extra_args[@]}")
fi

echo "[server] log  : $LOG"
echo "[server] url  : http://${HOST}:${PORT}   (压测并发上限 = -np $NP)"
echo "[server] model: $MODEL  ctx=$CTX ngl=$NGL fa=$FA ctk=$CTK ctv=$CTV slots=$NP"
echo "[server] 注意 : -c $CTX / -np $NP → **每个 slot 只有 $((CTX / NP)) tokens**；"\
"压测的 (--prompt-tokens + --max-tokens) 必须小于它，否则请求会被截断/报错。"
echo "[server] 就绪 : until curl -sf http://${HOST}:${PORT}/health >/dev/null; do sleep 1; done"

# 端口占用体检（8080 被上一个没杀干净的 server 占着是最常见的启动失败原因）
if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ":${PORT} "; then
  echo "[server] 警告: 端口 ${PORT} 已被占用（可能是上一次没关掉的 llama-server）——"
  echo "[server]       查看: ss -ltnp | grep :${PORT} ；清理: pkill -f llama-server"
fi

echo "[server] cmd  : $SERVER ${args[*]}"
"$SERVER" "${args[@]}" --log-file "$LOG"
