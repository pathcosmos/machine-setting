#!/usr/bin/env python3
"""Generative accuracy eval against an OpenAI-compatible chat endpoint (run with the vLLM venv python).

Scores the final answer only; reasoning is taken from the server's `reasoning` field or stripped
from <think>...</think>. A response whose final answer is empty (e.g. token budget spent on
reasoning) counts as wrong and is reported under `empty`.
"""
import os
import argparse
import asyncio
import json
import pathlib
import re
import time

from openai import AsyncOpenAI

DATA = pathlib.Path(__file__).parent / "data"
THINK_RE = re.compile(r"<think>.*?</think>", re.S)
NUM_RE = re.compile(r"-?\d[\d,]*\.?\d*")


def kmmlu_prompt(it):
    opts = "\n".join(f"{l}. {c}" for l, c in zip("ABCD", it["choices"]))
    return (f"다음 객관식 문제를 풀어 주세요.\n\n문제: {it['question']}\n{opts}\n\n"
            "마지막 줄에 반드시 '정답: X' 형식으로 답하세요. (X는 A, B, C, D 중 하나)")


def kmmlu_parse(text):
    m = re.findall(r"정답\s*[::]?\s*\**\(?([ABCD])\b", text)
    if m:
        return m[-1]
    m = re.findall(r"\b([ABCD])\b", text)
    return m[-1] if m else None


def gsm_prompt(it):
    return (f"Solve the following problem.\n\n{it['question']}\n\n"
            "End your reply with a final line of the form 'Answer: <number>'.")


def gsm_parse(text):
    m = re.findall(r"Answer\s*[::]\s*\**\s*\$?\s*(-?\d[\d,]*\.?\d*)", text)
    if not m:
        m = NUM_RE.findall(text)
    return m[-1].replace(",", "").rstrip(".") if m else None


def gsm_match(pred, gold):
    try:
        return abs(float(pred) - float(gold)) < 1e-6
    except (TypeError, ValueError):
        return False


TASKS = {
    "kmmlu": ("kmmlu.jsonl", kmmlu_prompt, kmmlu_parse, lambda p, g: p == g),
    "gsm8k": ("gsm8k.jsonl", gsm_prompt, gsm_parse, gsm_match),
}


async def run_task(client, a, name, body):
    fname, mk_prompt, parse, match = TASKS[name]
    items = [json.loads(l) for l in open(DATA / fname)]
    if a.limit:
        items = items[: a.limit]
    sem = asyncio.Semaphore(a.concurrency)
    sys_msgs = [{"role": "system", "content": a.system}] if a.system else []
    stats = {"n": len(items), "correct": 0, "errors": 0, "empty": 0, "with_reasoning": 0,
             "completion_tokens": 0, "latency_s": 0.0}
    records = []

    async def one(i, it):
        async with sem:
            t0 = time.perf_counter()
            try:
                params = {k: v for k, v in body.items() if k in ("temperature", "top_p", "reasoning_effort")}
                extra = {k: v for k, v in body.items() if k not in params}
                r = await client.chat.completions.create(
                    model=a.model, messages=sys_msgs + [{"role": "user", "content": mk_prompt(it)}],
                    max_tokens=a.max_tokens, seed=0, extra_body=extra or None, **params)
            except Exception as e:
                stats["errors"] += 1
                records.append({"i": i, "error": str(e)[:300]})
                return
            dt = time.perf_counter() - t0
            msg = r.choices[0].message
            extra_fields = msg.model_extra or {}
            reasoning = extra_fields.get("reasoning") or extra_fields.get("reasoning_content") or ""
            raw = msg.content or ""
            if "<think>" in raw:
                reasoning = reasoning or "inline"
            content = THINK_RE.sub("", raw)
            if "<think>" in content:  # unterminated think block: no final answer was produced
                content = ""
            content = content.strip()
            pred = parse(content) if content else None
            ok = bool(pred is not None and match(pred, it["gold"]))
            stats["correct"] += ok
            stats["empty"] += not content
            stats["with_reasoning"] += bool(reasoning)
            stats["completion_tokens"] += r.usage.completion_tokens if r.usage else 0
            stats["latency_s"] += dt
            records.append({"i": i, "gold": it["gold"], "pred": pred, "ok": ok,
                            "finish": r.choices[0].finish_reason, "tail": content[-160:]})

    t0 = time.perf_counter()
    await asyncio.gather(*(one(i, it) for i, it in enumerate(items)))
    done = max(1, stats["n"] - stats["errors"])
    return {
        "n": stats["n"], "accuracy": round(stats["correct"] / max(1, stats["n"]), 4),
        "errors": stats["errors"], "empty": stats["empty"],
        "reasoning_frac": round(stats["with_reasoning"] / done, 3),
        "avg_completion_tokens": round(stats["completion_tokens"] / done, 1),
        "avg_latency_s": round(stats["latency_s"] / done, 2),
        "wall_s": round(time.perf_counter() - t0, 1),
        "records": sorted(records, key=lambda r: r["i"]),
    }


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", default="http://127.0.0.1:8001/v1")
    ap.add_argument("--model", required=True)
    ap.add_argument("--mode", default="default")
    ap.add_argument("--body", default="{}", help="JSON merged into each request")
    ap.add_argument("--system", default="", help="optional system prompt")
    ap.add_argument("--tasks", default="kmmlu,gsm8k")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--concurrency", type=int, default=32)
    ap.add_argument("--max-tokens", type=int, default=8192)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    client = AsyncOpenAI(base_url=a.base_url, api_key=os.environ.get("OPENAI_API_KEY", "EMPTY"), timeout=1800, max_retries=1)
    body = json.loads(a.body)
    out = {"model": a.model, "mode": a.mode, "body": body, "max_tokens": a.max_tokens, "tasks": {}}
    for t in a.tasks.split(","):
        out["tasks"][t] = await run_task(client, a, t, body)
        s = out["tasks"][t]
        print(f"  [{a.mode}] {t}: acc={s['accuracy']:.3f} n={s['n']} err={s['errors']} empty={s['empty']} "
              f"reasoning={s['reasoning_frac']} avg_tok={s['avg_completion_tokens']} wall={s['wall_s']}s", flush=True)
    pathlib.Path(a.out).write_text(json.dumps(out, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    asyncio.run(main())
