#!/usr/bin/env python3
"""把 results/raw 里的 llama-bench 原始输出（-o jsonl）汇总成 tidy CSV + 终端汇总表。

用法：
    python scripts/collect_metrics.py
    python scripts/collect_metrics.py --tag baseline
    python scripts/collect_metrics.py --glob 'bench_*patch*.jsonl' --out results/processed/bench_patch.csv

产出：
    results/processed/bench_<ts>.csv   —— 一行一次测量，含派生指标
    终端汇总表                          —— 按 (TAG, test, KV 深度, KV 类型, FA) 聚合，含 decode 的有效带宽

只依赖标准库。
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import glob as globmod
import json
import os
import re
import sys
from collections import defaultdict

CSV_FIELDS = [
    "source", "tag", "row_tag", "run_ts", "test", "n_prompt", "n_gen", "n_depth",
    "tokens", "tokens_per_s", "tokens_per_s_stddev", "t_s", "eff_bw_GBps",
    "model", "model_size_bytes", "params", "backend",
    "n_gpu_layers", "n_batch", "n_ubatch", "type_k", "type_v", "flash_attn",
    "threads", "commit", "gpu",
]

_SIZE_RE = re.compile(r"^\s*([0-9.]+)\s*([KMGTP]?i?B?)\s*$", re.IGNORECASE)
_SIZE_UNITS = {"": 1, "B": 1, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12, "PB": 1e15,
               "KIB": 2**10, "MIB": 2**20, "GIB": 2**30, "TIB": 2**40, "PIB": 2**50}


def parse_size(value) -> float | None:
    """llama-bench 的 model_size 可能是数字（字节）或 '2.50 GiB' 这类字符串。"""
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    m = _SIZE_RE.match(str(value))
    if not m:
        return None
    return float(m.group(1)) * _SIZE_UNITS.get(m.group(2).upper(), 1)


def parse_file(path: str) -> list[dict]:
    """兼容 -o jsonl（每行一个对象）与 -o json（整体数组）。"""
    with open(path, encoding="utf-8", errors="replace") as fh:
        text = fh.read().strip()
    if not text:
        return []
    if text.startswith("["):
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            return []
    rows = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            continue  # 忽略进度/警告等非 json 行
    return rows


def split_name(path: str) -> tuple[str, str, str]:
    """bench_<ts>_<TAG>_<row_tag>.jsonl → (ts, TAG, row_tag)。"""
    base = os.path.basename(path)
    if base.endswith(".jsonl"):
        base = base[: -len(".jsonl")]
    parts = base.split("_")
    if len(parts) >= 4 and parts[0] == "bench":
        return parts[1], parts[2], "_".join(parts[3:])
    return "", "unknown", base


def normalize(obj: dict, source: str, run_ts: str, tag: str, row_tag: str) -> dict:
    test = str(obj.get("test", ""))
    n_prompt = obj.get("n_prompt")
    n_gen = obj.get("n_gen")
    if n_prompt is None and test.startswith("pp"):
        n_prompt = int(re.sub(r"\D", "", test) or 0)
    if n_gen is None and test.startswith("tg"):
        n_gen = int(re.sub(r"\D", "", test) or 0)

    size_bytes = parse_size(obj.get("model_size"))
    tps = obj.get("avg_ts")
    eff_bw = None
    # decode 阶段每生成一个 token 要把权重读一遍 → 有效带宽 ≈ model_size × tok/s
    if size_bytes and tps and test.startswith("tg"):
        eff_bw = size_bytes * float(tps) / 1e9

    return {
        "source": os.path.basename(source),
        "tag": tag,
        "row_tag": row_tag,
        "run_ts": run_ts,
        "test": test,
        "n_prompt": n_prompt,
        "n_gen": n_gen,
        "n_depth": obj.get("n_depth"),
        "tokens": obj.get("n_tokens"),
        "tokens_per_s": tps,
        "tokens_per_s_stddev": obj.get("stddev_ts"),
        "t_s": (obj.get("avg_ns") / 1e9) if obj.get("avg_ns") else None,
        "eff_bw_GBps": eff_bw,
        "model": obj.get("model_filename"),
        "model_size_bytes": size_bytes,
        "params": obj.get("model_n_params"),
        "backend": obj.get("backends"),
        "n_gpu_layers": obj.get("n_gpu_layers"),
        "n_batch": obj.get("n_batch"),
        "n_ubatch": obj.get("n_ubatch"),
        "type_k": obj.get("type_k"),
        "type_v": obj.get("type_v"),
        "flash_attn": obj.get("flash_attn"),
        "threads": obj.get("n_threads"),
        "commit": obj.get("build_commit"),
        "gpu": obj.get("gpu_info"),
    }


def mean(values: list[float]) -> float:
    return sum(values) / len(values) if values else float("nan")


def fmt(v, spec=".1f") -> str:
    if v is None:
        return "-"
    if isinstance(v, float) and v != v:  # nan
        return "-"
    try:
        return format(float(v), spec)
    except (TypeError, ValueError):
        return str(v)


def main() -> int:
    ap = argparse.ArgumentParser(description="汇总 llama-bench 原始结果")
    ap.add_argument("--raw-dir", default="results/raw")
    ap.add_argument("--glob", default="bench_*.jsonl")
    ap.add_argument("--tag", default=None, help="只保留该 TAG（run_bench.sh 的 TAG 变量）")
    ap.add_argument("--out", default=None, help="CSV 输出路径（默认 results/processed/bench_<ts>.csv）")
    args = ap.parse_args()

    files = sorted(globmod.glob(os.path.join(args.raw_dir, args.glob)))
    if not files:
        print(f"[metrics] 在 {args.raw_dir}/{args.glob} 没找到任何原始结果", file=sys.stderr)
        print("[metrics] 先跑： MODEL=/path/model.gguf TAG=baseline bash scripts/run_bench.sh", file=sys.stderr)
        return 2

    rows: list[dict] = []
    skipped: list[str] = []
    for path in files:
        run_ts, tag, row_tag = split_name(path)
        objs = parse_file(path)
        if not objs:
            skipped.append(os.path.basename(path))
            continue
        for obj in objs:
            if not isinstance(obj, dict):
                continue
            rows.append(normalize(obj, path, run_ts, tag, row_tag))

    if args.tag:
        rows = [r for r in rows if r["tag"] == args.tag]

    if not rows:
        print("[metrics] 没有可用数据（全部文件为空或格式不符）", file=sys.stderr)
        return 2

    out = args.out or os.path.join(
        "results", "processed", f"bench_{dt.datetime.now():%Y%m%d-%H%M%S}.csv")
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    with open(out, "w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=CSV_FIELDS)
        writer.writeheader()
        for r in rows:
            writer.writerow({k: ("" if r.get(k) is None else r.get(k)) for k in CSV_FIELDS})

    # ---- 终端汇总 ----
    # 同一 (TAG, test) 下还可能存在不同 KV 深度/类型/FA 的配置，因此全部纳入分组键，
    # 否则会把 "d=0 的 tg256" 和 "d=8192 的 tg256" 平均成一个没有意义的数。
    def gkey(r: dict) -> tuple:
        return (r["tag"], r["test"], r["n_depth"], r["type_k"], r["type_v"], r["flash_attn"])

    groups: dict[tuple, list[dict]] = defaultdict(list)
    for r in rows:
        groups[gkey(r)].append(r)

    print(f"[metrics] {len(rows)} 条测量 / {len(groups)} 个配置组合")
    if skipped:
        print(f"[metrics] 跳过 {len(skipped)} 个无法解析的文件：{', '.join(skipped[:5])}"
              + (" ..." if len(skipped) > 5 else ""))
    print()
    print(f"{'TAG':<12} {'test':<12} {'depth':>7} {'kv':<11} {'fa':<5} "
          f"{'tok/s':>9} {'max±':>7} {'n':>3} {'effBW':>8}")
    print("-" * 90)
    for key in sorted(groups, key=lambda k: (k[0], k[1], k[2] if k[2] is not None else 0)):
        tag, test, depth, type_k, type_v, fa = key
        g = groups[key]
        tps = [float(r["tokens_per_s"]) for r in g if r["tokens_per_s"]]
        sds = [float(r["tokens_per_s_stddev"]) for r in g if r["tokens_per_s_stddev"]]
        bws = [float(r["eff_bw_GBps"]) for r in g if r["eff_bw_GBps"]]
        print(f"{tag:<12} {test:<12} {str(depth if depth is not None else '-'):>7} "
              f"{f'{type_k or "-"}/{type_v or "-"}':<11} {str(fa if fa is not None else '-'):<5} "
              f"{fmt(mean(tps), '9.1f')} {fmt(max(sds) if sds else None, '7.2f')} {len(g):>3} "
              f"{fmt(mean(bws), '8.1f')}")

    # ---- A/B 对比（仅同 test/depth/KV/FA 之间可比）----
    tags = sorted({r["tag"] for r in rows})
    if len(tags) >= 2:
        print()
        print("[metrics] TAG 对比（相对第一个 TAG 的变化；只有同 test/depth/KV/FA 才可比）")
        base = tags[0]
        for key in sorted(groups, key=lambda k: (k[0], k[1], k[2] if k[2] is not None else 0)):
            if key[0] != base:
                continue
            base_vals = [float(r["tokens_per_s"]) for r in groups[key] if r["tokens_per_s"]]
            if not base_vals:
                continue
            _, test, depth, type_k, type_v, fa = key
            line = (f"  {test:<14} d={depth if depth is not None else '-'} "
                    f"{type_k or '-'}/{type_v or '-'} fa={fa}  base={mean(base_vals):.1f}")
            for tag in tags[1:]:
                vals = [float(r["tokens_per_s"])
                        for r in groups.get((tag, test, depth, type_k, type_v, fa), [])
                        if r["tokens_per_s"]]
                if not vals:
                    continue
                line += f"  {tag}={mean(vals):.1f}({(mean(vals) / mean(base_vals) - 1) * 100:+.1f}%)"
            print(line)
        print("  提醒：差异是否显著要对比 stddev；<2% 视为噪声（见 docs/experiments.md §3）。")

    print()
    print(f"[metrics] CSV: {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
