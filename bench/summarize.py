#!/usr/bin/env python3
"""Build results/SUMMARY.md from the per-model result files written by run_bench.py."""
import argparse
import json
import pathlib

HERE = pathlib.Path(__file__).resolve().parent


def fmt(v, spec="{:.0f}"):
    return spec.format(v) if isinstance(v, (int, float)) else "–"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", default=str(HERE / "results"))
    a = ap.parse_args()
    root = pathlib.Path(a.results)
    stats = [json.loads(p.read_text()) for p in sorted(root.glob("*/status.json"))]
    L = ["# vLLM benchmark summary", ""]

    L += ["## Speed (random-token prompts, 512 output tokens, total output tok/s across all streams)", "",
          "| model | precision | load s | in512 c1 | c4 | c16 | c32 | in4096 c1 | c16 | c32 | TTFT p50 ms (in4096 c1) |",
          "|---|---|---|---|---|---|---|---|---|---|---|"]
    for s in stats:
        sp = {(r["input_len"], r["concurrency"]): r for r in s.get("speed", [])}
        tp = lambda i, c: fmt(sp.get((i, c), {}).get("output_throughput"))
        L.append(f"| {s['alias']} | {s['precision']} | {fmt(s.get('ready_s'))} | {tp(512, 1)} | {tp(512, 4)} | "
                 f"{tp(512, 16)} | {tp(512, 32)} | {tp(4096, 1)} | {tp(4096, 16)} | {tp(4096, 32)} | "
                 f"{fmt(sp.get((4096, 1), {}).get('median_ttft_ms'))} |")

    L += ["", "## Quality (final-answer accuracy; `empty` = no final answer within the token budget)", "",
          "| model | mode | KMMLU acc | GSM8K acc | reasoning used | avg output tok (KMMLU / GSM8K) | empty | errors | eval wall s |",
          "|---|---|---|---|---|---|---|---|---|"]
    for s in stats:
        for qf in sorted((root / s["alias"]).glob("quality_*.json")):
            q = json.loads(qf.read_text())
            k, g = q["tasks"].get("kmmlu", {}), q["tasks"].get("gsm8k", {})
            L.append(f"| {s['alias']} | {q['mode']} | {fmt(k.get('accuracy'), '{:.1%}')} (n={k.get('n', 0)}) | "
                     f"{fmt(g.get('accuracy'), '{:.1%}')} (n={g.get('n', 0)}) | "
                     f"{fmt(k.get('reasoning_frac'), '{:.0%}')} | {fmt(k.get('avg_completion_tokens'))} / "
                     f"{fmt(g.get('avg_completion_tokens'))} | {k.get('empty', 0) + g.get('empty', 0)} | "
                     f"{k.get('errors', 0) + g.get('errors', 0)} | {fmt(k.get('wall_s', 0) + g.get('wall_s', 0))} |")

    failed = [s for s in stats if not s.get("ok")]
    if failed:
        L += ["", "## Failures", ""] + [f"- **{s['alias']}**: {s.get('error', '?')}" for s in failed]
    (root / "SUMMARY.md").write_text("\n".join(L) + "\n")
    print("\n".join(L))


if __name__ == "__main__":
    main()
