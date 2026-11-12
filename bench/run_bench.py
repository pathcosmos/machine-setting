#!/usr/bin/env python3
"""Serve each model in models.yaml with vLLM, one at a time, and benchmark speed + quality.

Usage (run with the vLLM venv python):
  ~/vllm-env/bin/python bench/run_bench.py                      # all models
  ~/vllm-env/bin/python bench/run_bench.py --models qwen35-9b   # subset
  ~/vllm-env/bin/python bench/run_bench.py --skip-quality       # speed only
  ~/vllm-env/bin/python bench/summarize.py                      # build results/SUMMARY.md

Per model: start server -> wait for /health (includes download) -> speed sweep (`vllm bench serve`,
random-token prompts, fixed 512 output tokens) -> quality eval per mode -> stop server -> wait for
VRAM release. Finished models are skipped on re-run unless --force. A failure (OOM, unsupported
arch, ...) is recorded in status.json and the run continues with the next model.
"""
import argparse
import json
import os
import pathlib
import signal
import subprocess
import sys
import time
import urllib.request

import yaml

HERE = pathlib.Path(__file__).resolve().parent
VENV_BIN = pathlib.Path(sys.executable).parent
VLLM = str(VENV_BIN / "vllm")


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def gpu_used_mib():
    out = subprocess.run(["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits"],
                         capture_output=True, text=True).stdout
    return int(out.split()[0]) if out.strip() else -1


def healthy(port):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=3) as r:
            return r.status == 200
    except Exception:
        return False


def stop(proc):
    if proc.poll() is None:
        os.killpg(proc.pid, signal.SIGTERM)
        try:
            proc.wait(60)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
    for _ in range(60):  # wait for VRAM to be released before the next model
        if gpu_used_mib() < 1500:
            return
        time.sleep(2)
    log("  WARNING: GPU memory not released after stop")


def run_model(m, defaults, a, out):
    out.mkdir(parents=True, exist_ok=True)
    status = {"alias": m["alias"], "repo": m["repo"], "precision": m.get("precision", "?"), "ok": False}
    max_len = a.max_model_len or m.get("max_model_len", defaults.get("max_model_len", 16384))
    cmd = [VLLM, "serve", m["repo"], "--served-model-name", m["alias"], "--host", "127.0.0.1",
           "--port", str(a.port), "--max-model-len", str(max_len),
           "--gpu-memory-utilization", str(m.get("gpu_memory_utilization", defaults.get("gpu_memory_utilization", 0.93))),
           *map(str, m.get("serve_args", []))]
    status["serve_cmd"] = " ".join(cmd)
    log(f"== {m['alias']}  ({m['repo']})")
    t0 = time.time()
    with open(out / "serve.log", "w") as lf:
        # MAX_JOBS caps flashinfer's JIT kernel build; an uncapped build was OOM-killed (18 x ~5 GB compilers).
        proc = subprocess.Popen(cmd, stdout=lf, stderr=subprocess.STDOUT, start_new_session=True,
                                env={**os.environ, "MAX_JOBS": os.environ.get("MAX_JOBS", "4")})
    try:
        while not healthy(a.port):
            if proc.poll() is not None:
                tail = (out / "serve.log").read_text(errors="replace")[-1500:]
                status["error"] = f"server exited rc={proc.returncode} during startup"
                status["log_tail"] = tail
                log(f"  FAILED to start: rc={proc.returncode}")
                return status
            if time.time() - t0 > a.startup_timeout:
                status["error"] = "startup timeout"
                log("  FAILED: startup timeout")
                return status
            time.sleep(3)
        status["ready_s"] = round(time.time() - t0)
        status["gpu_used_mib"] = gpu_used_mib()
        log(f"  ready in {status['ready_s']}s, GPU {status['gpu_used_mib']} MiB")

        if not a.skip_speed:
            status["speed"] = []
            for in_len in a.input_lens:
                for conc in a.concurrency:
                    name = f"speed_in{in_len}_c{conc}.json"
                    n = max(16, conc * 6) if not a.quick else max(4, conc * 2)
                    bcmd = [VLLM, "bench", "serve", "--backend", "openai",
                            "--base-url", f"http://127.0.0.1:{a.port}", "--model", m["alias"],
                            "--tokenizer", m["repo"], "--dataset-name", "random",
                            "--random-input-len", str(in_len), "--random-output-len", "512", "--ignore-eos",
                            "--max-concurrency", str(conc), "--num-prompts", str(n), "--seed", "0",
                            "--save-result", "--result-dir", str(out), "--result-filename", name]
                    with open(out / "bench.log", "a") as bl:
                        try:
                            rc = subprocess.run(bcmd, stdout=bl, stderr=subprocess.STDOUT, timeout=3600).returncode
                        except subprocess.TimeoutExpired:
                            rc = "timeout"
                    row = {"input_len": in_len, "concurrency": conc, "rc": rc}
                    if rc == 0 and (out / name).exists():
                        r = json.loads((out / name).read_text())
                        for k in ("completed", "failed", "output_throughput", "request_throughput",
                                  "median_ttft_ms", "p99_ttft_ms", "median_tpot_ms", "median_e2el_ms"):
                            row[k] = r.get(k)
                        log(f"  speed in={in_len} c={conc}: {row.get('output_throughput') or 0:.0f} tok/s, "
                            f"TTFT p50 {row.get('median_ttft_ms') or 0:.0f} ms")
                    else:
                        log(f"  speed in={in_len} c={conc}: FAILED rc={rc} (see bench.log)")
                    status["speed"].append(row)
                    if proc.poll() is not None:
                        status["error"] = "server died during speed bench"
                        return status

        if not a.skip_quality:
            status["quality_modes"] = []
            for mode in m.get("modes", [{"name": "default", "body": {}}]):
                if a.modes and mode["name"] not in a.modes:
                    continue
                qout = out / f"quality_{mode['name']}.json"
                qcmd = [sys.executable, str(HERE / "quality_eval.py"), "--base-url", f"http://127.0.0.1:{a.port}/v1",
                        "--model", m["alias"], "--mode", mode["name"], "--body", json.dumps(mode.get("body", {})),
                        "--max-tokens", str(min(a.quality_max_tokens, max_len - 2048)), "--out", str(qout)]
                if mode.get("system"):
                    qcmd += ["--system", mode["system"]]
                if a.quick:
                    qcmd += ["--limit", "12"]
                try:
                    rc = subprocess.run(qcmd, timeout=6 * 3600).returncode
                except subprocess.TimeoutExpired:
                    rc = "timeout"
                status["quality_modes"].append({"mode": mode["name"], "rc": rc})
                if proc.poll() is not None:
                    status["error"] = "server died during quality eval"
                    return status
        bad = [q["mode"] for q in status.get("quality_modes", []) if q["rc"] != 0]
        if bad:
            status["error"] = f"quality eval failed for modes: {', '.join(bad)}"
            return status
        status["ok"] = True
        return status
    finally:
        stop(proc)
        status["total_s"] = round(time.time() - t0)
        (out / "status.json").write_text(json.dumps(status, ensure_ascii=False, indent=1))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=str(HERE / "models.yaml"))
    ap.add_argument("--results", default=str(HERE / "results"))
    ap.add_argument("--models", default="", help="comma-separated aliases (default: all)")
    ap.add_argument("--port", type=int, default=8001)
    ap.add_argument("--concurrency", type=lambda s: [int(x) for x in s.split(",")], default=[1, 4, 16, 32])
    ap.add_argument("--input-lens", type=lambda s: [int(x) for x in s.split(",")], default=[512, 4096])
    ap.add_argument("--startup-timeout", type=int, default=4 * 3600, help="seconds; includes model download")
    ap.add_argument("--max-model-len", type=int, default=0, help="override max_model_len for every model")
    ap.add_argument("--quality-max-tokens", type=int, default=8192, help="output-token budget per quality request")
    ap.add_argument("--modes", type=lambda s: [x for x in s.split(",") if x], default=[],
                    help="only run these quality modes (default: all)")
    ap.add_argument("--skip-speed", action="store_true")
    ap.add_argument("--skip-quality", action="store_true")
    ap.add_argument("--quick", action="store_true", help="tiny request counts, for testing the harness")
    ap.add_argument("--force", action="store_true", help="re-run models that already have status.json ok")
    a = ap.parse_args()

    cfg = yaml.safe_load(open(a.config))
    want = [x for x in a.models.split(",") if x]
    models = [m for m in cfg["models"] if not want or m["alias"] in want]
    if healthy(a.port) or gpu_used_mib() > 1500:
        sys.exit(f"Port {a.port} is serving or the GPU is in use ({gpu_used_mib()} MiB) — stop it first.")
    if not a.skip_quality and not (HERE / "data" / "kmmlu.jsonl").exists():
        sys.exit("bench/data is missing — run bench/prepare_data.py first.")

    for m in models:
        out = pathlib.Path(a.results) / m["alias"]
        sf = out / "status.json"
        if sf.exists() and json.loads(sf.read_text()).get("ok") and not a.force:
            log(f"== {m['alias']}: already done, skipping")
            continue
        st = run_model(m, cfg.get("defaults", {}), a, out)
        log(f"  -> {'OK' if st['ok'] else 'FAILED: ' + st.get('error', '?')} ({st.get('total_s')}s)")
    log("ALL DONE")


if __name__ == "__main__":
    main()
