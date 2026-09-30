#!/usr/bin/env python3
"""自写 SSE 压测客户端：TTFT / TPOT / 并发扫描。仅标准库。

为什么自己写一次：TTFT 的定义（含排队 + prefill）、TPOT 的首尾差值口径、以及
"客户端计时 vs 服务端 timings" 的交叉校验，只有自己实现过才算真懂。

用法：
    python benchmark/serving/sse_bench.py --base-url http://127.0.0.1:8080 \
        --concurrency 1,2,4,8 --requests-per-level 8 --prompt-tokens 512 --max-tokens 256
    python benchmark/serving/sse_bench.py --api chat --concurrency 4 --requests-per-level 16

输出：
    results/raw/serving_<ts>.jsonl       逐请求原始记录（含服务端 timings）
    results/processed/serving_<ts>.csv   分档位汇总（p50/p95/p99 + 吞吐）

关键测量口径：
    TTFT  = 请求发出 → 第一个非空 content chunk（含排队 + 网络 + prefill）
    TPOT  = (t_last - t_first) / (n_tokens - 1)，只含解码间隔，不含 prefill
    queue = TTFT - 服务端 prompt_ms（并发 >1 时这个量必须被解释；服务端未返回 timings 则为 None）
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import math
import os
import statistics
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid

FILLER = "The quick brown fox jumps over the lazy dog while the engineer profiles the kernel. "
CSV_FIELDS = [
    "concurrency", "n_ok", "n_err", "ttft_p50", "ttft_p95", "ttft_p99",
    "tpot_p50", "tpot_p95", "tpot_p99", "e2e_p50", "e2e_p95", "e2e_p99",
    "queue_p50", "out_tokens", "wall_s", "out_tokens_per_s", "req_per_s",
]


# ---------------------------------------------------------------- 测量

def build_payload(api: str, prompt: str, max_tokens: int) -> dict:
    common = {"stream": True, "temperature": 0.0, "top_k": 1, "ignore_eos": True,
              "cache_prompt": False}
    if api == "completion":
        return {"prompt": prompt, "n_predict": max_tokens, **common}
    return {"messages": [{"role": "user", "content": prompt}],
            "max_tokens": max_tokens, **common}


def url_for(base_url: str, api: str) -> str:
    base = base_url.rstrip("/")
    return base + ("/completion" if api == "completion" else "/v1/chat/completions")


def extract_text(obj: dict, api: str) -> str:
    """兼容 llama.cpp 原生 /completion 与 OpenAI 风格两种流格式。"""
    if api == "completion":
        c = obj.get("content")
        return c if isinstance(c, str) else ""
    choices = obj.get("choices") or []
    if not choices:
        return ""
    ch = choices[0]
    if isinstance(ch.get("text"), str):          # /v1/completions
        return ch["text"]
    delta = ch.get("delta") or {}                # /v1/chat/completions
    c = delta.get("content")
    return c if isinstance(c, str) else ""


def stream_one(base_url: str, api: str, prompt: str, max_tokens: int, timeout: float) -> dict:
    url = url_for(base_url, api)
    body = json.dumps(build_payload(api, prompt, max_tokens)).encode("utf-8")
    req = urllib.request.Request(
        url, data=body,
        headers={"Content-Type": "application/json", "Accept": "text/event-stream"})

    rec = {"ok": False, "error": None, "http_status": None,
           "ttft_ms": None, "tpot_ms": None, "e2e_ms": None,
           "client_chunks": 0, "client_tokens": None,
           "server_prompt_n": None, "server_prompt_ms": None,
           "server_predicted_n": None, "server_predicted_ms": None,
           "server_decode_tps": None, "queue_ms": None}

    t0 = time.perf_counter()
    t_first = t_last = None
    chunks = 0
    timings = None
    usage = None
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            rec["http_status"] = resp.status
            for raw in resp:                       # 逐行读，流式（不整体缓冲）
                if not raw:
                    continue
                line = raw.decode("utf-8", "replace").strip()
                if not line or line.startswith(":"):
                    continue
                if line.startswith("data:"):
                    line = line[5:].strip()
                if line == "[DONE]":
                    break
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(obj, dict) and obj.get("error"):
                    raise RuntimeError(str(obj["error"])[:300])
                if isinstance(obj, dict) and isinstance(obj.get("timings"), dict):
                    timings = obj["timings"]
                if isinstance(obj, dict) and isinstance(obj.get("usage"), dict):
                    usage = obj["usage"]
                text = extract_text(obj, api) if isinstance(obj, dict) else ""
                now = time.perf_counter()
                if text:
                    if t_first is None:
                        t_first = now
                    t_last = now
                    chunks += 1
        t_end = time.perf_counter()
    except Exception as exc:                        # noqa: BLE001 —— 记录任何失败，不让线程挂掉
        t_end = time.perf_counter()
        rec["error"] = f"{type(exc).__name__}: {exc}"[:300]
        rec["e2e_ms"] = (t_end - t0) * 1000.0
        return rec

    n_tokens = None
    if timings:
        n_tokens = timings.get("predicted_n")
        rec["server_prompt_n"] = timings.get("prompt_n")
        rec["server_prompt_ms"] = timings.get("prompt_ms")
        rec["server_predicted_n"] = timings.get("predicted_n")
        rec["server_predicted_ms"] = timings.get("predicted_ms")
        if timings.get("predicted_n") and timings.get("predicted_ms"):
            rec["server_decode_tps"] = timings["predicted_n"] / (timings["predicted_ms"] / 1000.0)
    if n_tokens is None and usage:
        n_tokens = usage.get("completion_tokens")

    rec["client_chunks"] = chunks
    rec["client_tokens"] = n_tokens if n_tokens is not None else chunks
    rec["e2e_ms"] = (t_end - t0) * 1000.0
    if t_first is not None:
        rec["ttft_ms"] = (t_first - t0) * 1000.0
    if rec["server_prompt_ms"] is not None and rec["ttft_ms"] is not None:
        rec["queue_ms"] = rec["ttft_ms"] - rec["server_prompt_ms"]
    eff_tokens = rec["client_tokens"] or 0
    if t_first is not None and t_last is not None and eff_tokens > 1:
        rec["tpot_ms"] = (t_last - t_first) * 1000.0 / (eff_tokens - 1)
    rec["ok"] = t_first is not None and rec["error"] is None
    if not rec["ok"] and rec["error"] is None:
        rec["error"] = "no content chunk received"
    return rec


# ---------------------------------------------------------------- 并发档位

def run_level(base_url: str, api: str, level: int, per_level: int, prompt: str,
              max_tokens: int, timeout: float, use_nonce: bool) -> tuple[list[dict], float]:
    results: list[dict] = []
    lock = threading.Lock()
    barrier = threading.Barrier(level)

    def worker(wid: int) -> None:
        try:
            barrier.wait(timeout=60)
        except threading.BrokenBarrierError:
            pass
        for i in range(per_level):
            text = prompt
            if use_nonce:
                text = f"[{uuid.uuid4().hex[:12]}] " + prompt   # 破坏 prefix cache，保证每次都真 prefill
            rec = stream_one(base_url, api, text, max_tokens, timeout)
            rec.update(concurrency=level, worker=wid, req_idx=i)
            with lock:
                results.append(rec)

    threads = [threading.Thread(target=worker, args=(w,), daemon=True) for w in range(level)]
    t_start = time.perf_counter()
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    wall = time.perf_counter() - t_start
    return results, wall


def pct(values: list[float], p: float) -> float:
    if not values:
        return float("nan")
    s = sorted(values)
    k = max(0, min(len(s) - 1, math.ceil(p / 100.0 * len(s)) - 1))
    return s[k]


def mean(values: list[float]) -> float:
    return statistics.fmean(values) if values else float("nan")


def fmt(v, spec=".1f") -> str:
    if v is None or (isinstance(v, float) and math.isnan(v)):
        return "-"
    return format(float(v), spec)


def summarize(level: int, recs: list[dict], wall: float) -> dict:
    ok = [r for r in recs if r["ok"]]
    ttft = [r["ttft_ms"] for r in ok if r["ttft_ms"] is not None]
    tpot = [r["tpot_ms"] for r in ok if r["tpot_ms"] is not None]
    e2e = [r["e2e_ms"] for r in ok if r["e2e_ms"] is not None]
    queue = [r["queue_ms"] for r in ok if r["queue_ms"] is not None]
    out_tokens = sum(r["client_tokens"] or 0 for r in ok)
    return {
        "concurrency": level,
        "n_ok": len(ok),
        "n_err": len(recs) - len(ok),
        "ttft_p50": pct(ttft, 50), "ttft_p95": pct(ttft, 95), "ttft_p99": pct(ttft, 99),
        "tpot_p50": pct(tpot, 50), "tpot_p95": pct(tpot, 95), "tpot_p99": pct(tpot, 99),
        "e2e_p50": pct(e2e, 50), "e2e_p95": pct(e2e, 95), "e2e_p99": pct(e2e, 99),
        "queue_p50": pct(queue, 50),
        "out_tokens": out_tokens,
        "wall_s": wall,
        "out_tokens_per_s": (out_tokens / wall) if wall > 0 else float("nan"),
        "req_per_s": (len(ok) / wall) if wall > 0 else float("nan"),
    }


# ---------------------------------------------------------------- main

def main() -> int:
    ap = argparse.ArgumentParser(description="llama-server SSE 压测客户端")
    ap.add_argument("--base-url", default="http://127.0.0.1:8080")
    ap.add_argument("--api", choices=["completion", "chat"], default="completion",
                    help="completion=llama.cpp 原生 /completion；chat=/v1/chat/completions")
    ap.add_argument("--concurrency", default="1,2,4,8")
    ap.add_argument("--requests-per-level", type=int, default=8,
                    help="每个 worker 发多少个请求（总请求数 = 并发 × 该值）")
    ap.add_argument("--prompt-tokens", type=int, default=512,
                    help="近似 prompt token 数（用重复句子凑；真实值以服务端 prompt_n 为准）")
    ap.add_argument("--prompt-file", default=None, help="直接用文件内容作 prompt（覆盖 --prompt-tokens）")
    ap.add_argument("--max-tokens", type=int, default=256)
    ap.add_argument("--warmup", type=int, default=1, help="正式开始前的串行预热请求数")
    ap.add_argument("--timeout", type=float, default=600.0)
    ap.add_argument("--no-nonce", action="store_true",
                    help="不插入随机前缀（默认插入，用于破坏 prefix cache）")
    ap.add_argument("--raw-dir", default="results/raw")
    ap.add_argument("--processed-dir", default="results/processed")
    ap.add_argument("--no-health-check", action="store_true")
    args = ap.parse_args()

    # prompt 构造：凑长度；真实 token 数由服务端 timings.prompt_n 给出
    if args.prompt_file:
        with open(args.prompt_file, encoding="utf-8") as fh:
            prompt = fh.read()
    else:
        approx_per_filler = max(1, len(FILLER) // 4)
        prompt = FILLER * max(1, math.ceil(args.prompt_tokens / approx_per_filler))

    base = args.base_url.rstrip("/")
    if not args.no_health_check:
        try:
            with urllib.request.urlopen(base + "/health", timeout=10) as resp:
                print(f"[sse] health: {resp.status} {resp.read(200).decode('utf-8', 'replace').strip()}")
        except Exception as exc:  # noqa: BLE001
            print(f"[sse] 警告：/health 不可达（{type(exc).__name__}: {exc}）—— 继续尝试压测", file=sys.stderr)

    levels = [int(x) for x in str(args.concurrency).replace(" ", "").split(",") if x]
    ts = f"{dt.datetime.now():%Y%m%d-%H%M%S}"
    os.makedirs(args.raw_dir, exist_ok=True)
    os.makedirs(args.processed_dir, exist_ok=True)
    raw_path = os.path.join(args.raw_dir, f"serving_{ts}.jsonl")
    csv_path = os.path.join(args.processed_dir, f"serving_{ts}.csv")

    print(f"[sse] url={base} api={args.api} prompt≈{args.prompt_tokens}tok "
          f"max_tokens={args.max_tokens} levels={levels} "
          f"per_worker={args.requests_per_level} nonce={not args.no_nonce}")

    for _ in range(max(0, args.warmup)):
        warm = stream_one(base, args.api, "[warmup] " + prompt, args.max_tokens, args.timeout)
        print(f"[sse] warmup: ok={warm['ok']} ttft={fmt(warm['ttft_ms'])}ms "
              f"err={warm['error']}")

    summaries = []
    with open(raw_path, "w", encoding="utf-8") as raw_fh:
        for level in levels:
            recs, wall = run_level(base, args.api, level, args.requests_per_level,
                                   prompt, args.max_tokens, args.timeout, not args.no_nonce)
            for rec in recs:
                rec["level_ts"] = ts
                raw_fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
            raw_fh.flush()
            row = summarize(level, recs, wall)
            summaries.append(row)
            print(f"[sse] c={level:<3} ok={row['n_ok']:<3} err={row['n_err']:<3} "
                  f"ttft p50/p95/p99 = {fmt(row['ttft_p50'])}/{fmt(row['ttft_p95'])}/{fmt(row['ttft_p99'])} ms  "
                  f"tpot p50/p95 = {fmt(row['tpot_p50'])}/{fmt(row['tpot_p95'])} ms  "
                  f"thr = {fmt(row['out_tokens_per_s'])} tok/s")
            if row["n_err"]:
                errs = [r["error"] for r in recs if not r["ok"]]
                print(f"[sse]   错误示例：{errs[0]}")

    with open(csv_path, "w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=CSV_FIELDS)
        writer.writeheader()
        for row in summaries:
            writer.writerow({k: ("" if row.get(k) is None else row.get(k)) for k in CSV_FIELDS})

    print()
    print(f"[sse] raw : {raw_path}")
    print(f"[sse] csv : {csv_path}")
    print("[sse] 提示：并发升高时看 queue_p50（= TTFT - 服务端 prompt_ms）判断是排队还是 prefill 抢占。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
