#!/usr/bin/env python3
"""Fetch fixed evaluation subsets into bench/data/ from the Hub's auto-converted parquet files.

  uv run --no-project --with pyarrow python bench/prepare_data.py

  kmmlu.jsonl  N seeded-random test rows of each of the 45 KMMLU subjects (Korean multiple choice)
  gsm8k.jsonl  M seeded-random test rows of GSM8K (English arithmetic word problems)

Sampling uses a fixed seed, so every model sees identical items.
"""
import argparse
import io
import json
import pathlib
import random
import time
import urllib.request

import pyarrow.parquet as pq

DATA = pathlib.Path(__file__).parent / "data"


def fetch(url):
    for attempt in range(8):
        try:
            with urllib.request.urlopen(url, timeout=120) as r:
                return r.read()
        except Exception:
            if attempt == 7:
                raise
            time.sleep(5 * (attempt + 1))


def sample_rows(url, n, seed=0):
    rows = pq.read_table(io.BytesIO(fetch(url))).to_pylist()
    return random.Random(seed).sample(rows, min(n, len(rows)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kmmlu-per-subject", type=int, default=10)
    ap.add_argument("--gsm8k", type=int, default=200)
    a = ap.parse_args()
    DATA.mkdir(exist_ok=True)

    index = json.loads(fetch("https://huggingface.co/api/datasets/HAERAE-HUB/KMMLU/parquet"))
    items = []
    for subj in sorted(index):
        for r in sample_rows(index[subj]["test"][0], a.kmmlu_per_subject):
            items.append({"subject": subj, "question": r["question"],
                          "choices": [r["A"], r["B"], r["C"], r["D"]], "gold": "ABCD"[int(r["answer"]) - 1]})
    (DATA / "kmmlu.jsonl").write_text("".join(json.dumps(i, ensure_ascii=False) + "\n" for i in items))
    print(f"kmmlu.jsonl: {len(items)} items from {len(index)} subjects")

    index = json.loads(fetch("https://huggingface.co/api/datasets/openai/gsm8k/parquet"))
    items = [{"question": r["question"], "gold": r["answer"].split("####")[-1].strip().replace(",", "")}
             for r in sample_rows(index["main"]["test"][0], a.gsm8k)]
    (DATA / "gsm8k.jsonl").write_text("".join(json.dumps(i, ensure_ascii=False) + "\n" for i in items))
    print(f"gsm8k.jsonl: {len(items)} items")


if __name__ == "__main__":
    main()
