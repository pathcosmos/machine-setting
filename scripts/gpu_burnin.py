#!/usr/bin/env python3
"""GPU burn-in: sustained mixed workloads + health monitoring + performance report.

Run through scripts/gpu-burnin.sh (it picks the venv, output directory and handles --detach).

Each round runs, in order:
  matmul FP32 / FP16 (peak compute + power), ResNet-50 training (cuDNN, AMP), Transformer training
  (attention, AMP), ResNet-50 inference, VRAM integrity (fill most of the memory with a pattern and
  read it back), host<->GPU transfer (PCIe), DataLoader + training (CPU workers + GPU together),
  a bit-exact determinism check, then a short idle (thermal cycling).
Rounds repeat until the time budget is used. A monitor thread samples temperature, power, clocks,
throttle reasons, fan and PCIe link state the whole time.

Verdict:
  FAIL  kernel Xid / GPU lost, VRAM pattern mismatch, non-deterministic results, workload crash,
        temperature abort, performance collapse (> 20 % drop over the run)
  WARN  thermal / hardware throttling seen, performance drift > 5 %, unstable throughput,
        PCIe link change or replay errors, well below the stored baseline for this GPU model
  PASS  none of the above
"""
import argparse
import csv
import datetime
import hashlib
import json
import os
import re
import signal
import statistics
import subprocess
import sys
import threading
import time


def parse_args():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--hours", type=float, default=6.0, help="total duration (default 6)")
    p.add_argument("--minutes", type=float, default=None, help="total duration in minutes (overrides --hours)")
    p.add_argument("--phase-seconds", type=float, default=240.0, help="seconds per compute workload per round")
    p.add_argument("--idle-seconds", type=float, default=45.0, help="idle time at the end of each round")
    p.add_argument("--gpu", type=int, default=0, help="GPU index (nvidia-smi order)")
    p.add_argument("--out", required=True, help="output directory")
    p.add_argument("--vram-fraction", type=float, default=0.90, help="share of free VRAM used by the integrity test")
    p.add_argument("--max-temp", type=float, default=None, help="abort at this GPU temperature in C (default: shutdown threshold - 5)")
    p.add_argument("--interval", type=float, default=2.0, help="monitor sampling interval in seconds")
    p.add_argument("--baselines", default=None, help="JSON file with per-model reference numbers")
    p.add_argument("--save-baseline", action="store_true", help="store this run's averages as the reference for this GPU model (PASS only)")
    p.add_argument("--force", action="store_true", help="run even if other processes are using the GPU")
    p.add_argument("--self-test", action="store_true", help="tiny CPU run that only validates this script")
    return p.parse_args()


ARGS = parse_args()
if not ARGS.self_test:
    os.environ["CUDA_DEVICE_ORDER"] = "PCI_BUS_ID"
    os.environ["CUDA_VISIBLE_DEVICES"] = str(ARGS.gpu)

import torch  # noqa: E402
import torch.nn as nn  # noqa: E402
import torch.nn.functional as F  # noqa: E402

try:
    import pynvml
except ImportError:  # monitoring degrades, workloads still run
    pynvml = None

TINY = ARGS.self_test
DEV = torch.device("cpu" if TINY else "cuda:0")
STOP = threading.Event()        # set on signal, abort, or deadline handled by callers
STATE = {"phase": "init", "round": 0, "stop_reason": None}



def _pow2_floor(x, lo, hi):
    v = lo
    while v * 2 <= min(x, hi):
        v *= 2
    return v


def workload_sizes():
    """Scale every workload to the GPU model: sizes follow the card's total VRAM, so an 8 GB card and
    a 48 GB card are both loaded close to their capacity (and the same model always gets the same
    sizes, which keeps runs comparable with the stored reference). Out-of-memory still halves a batch."""
    if TINY:
        return {"vram_gib": 0, "matmul_fp32_n": 256, "matmul_fp16_n": 256, "resnet_train_batch": 4,
                "resnet_infer_batch": 4, "transformer_batch": 2, "loader_batch": 8, "amp": "off"}
    gib = torch.cuda.get_device_properties(0).total_memory / 2 ** 30
    amp = "bf16" if torch.cuda.is_bf16_supported() else "off"
    k = 1.0 if amp != "off" else 0.5                     # full precision needs about twice the memory
    return {
        "vram_gib": round(gib, 1),
        "matmul_fp32_n": 8192 if gib >= 6 else 4096,     # 3 matrices: 0.8 GiB / 0.2 GiB
        "matmul_fp16_n": 16384 if gib >= 6 else 8192,
        "resnet_train_batch": _pow2_floor(gib * 5 * k, 8, 512),      # 24 GiB -> 64, 32 GiB -> 128, 80 GiB -> 256
        "resnet_infer_batch": _pow2_floor(gib * 12 * k, 16, 1024),
        "transformer_batch": _pow2_floor(gib * 1.2 * k, 2, 64),      # 12 layers, 768 wide, 512 tokens
        "loader_batch": _pow2_floor(gib * 10 * k, 16, 256),
        "amp": amp,
    }


SIZES = workload_sizes()

THROTTLE_BITS = {
    0x1: ("idle", "info"), 0x2: ("app clock setting", "info"), 0x4: ("power cap", "info"),
    0x8: ("hardware slowdown", "warn"), 0x10: ("sync boost", "info"), 0x20: ("software thermal slowdown", "warn"),
    0x40: ("hardware thermal slowdown", "warn"), 0x80: ("power brake slowdown", "warn"), 0x100: ("display clock setting", "info"),
}


def log(msg):
    print(f"[{datetime.datetime.now():%H:%M:%S}] {msg}", flush=True)


def request_stop(reason):
    if STATE["stop_reason"] is None:
        STATE["stop_reason"] = reason
    STOP.set()


# --------------------------------------------------------------------------------------
# Monitoring
# --------------------------------------------------------------------------------------
class Monitor(threading.Thread):
    FIELDS = ["time", "elapsed_s", "round", "phase", "temp_c", "power_w", "util_pct", "mem_used_mib",
              "fan_pct", "clock_mhz", "throttle", "pcie_gen", "pcie_width", "cpu_temp_c", "ram_used_pct"]

    def __init__(self, index, csv_path, interval, max_temp):
        super().__init__(daemon=True)
        self.index, self.csv_path, self.interval, self.max_temp = index, csv_path, interval, max_temp
        self.samples = []
        self.info = {}
        self.ok = False
        self.done = threading.Event()
        self.t0 = time.time()
        self.h = None
        if pynvml is None:
            return
        try:
            pynvml.nvmlInit()
            self.h = pynvml.nvmlDeviceGetHandleByIndex(index)
            self.ok = True
            self.info = self._static()
        except Exception as e:  # noqa: BLE001
            self.info = {"error": f"NVML unavailable: {e}"}

    def _try(self, fn, *a, default=None):
        try:
            return fn(*a)
        except Exception:  # noqa: BLE001
            return default

    def _static(self):
        h, n = self.h, pynvml
        name = n.nvmlDeviceGetName(h)
        mem = n.nvmlDeviceGetMemoryInfo(h)
        info = {
            "name": name.decode() if isinstance(name, bytes) else name,
            "vram_total_mib": mem.total // 2**20,
            "driver": self._try(lambda: n.nvmlSystemGetDriverVersion()),
            "power_limit_w": self._try(lambda: n.nvmlDeviceGetPowerManagementLimit(h) / 1000),
            "temp_slowdown_c": self._try(n.nvmlDeviceGetTemperatureThreshold, h, n.NVML_TEMPERATURE_THRESHOLD_SLOWDOWN),
            "temp_shutdown_c": self._try(n.nvmlDeviceGetTemperatureThreshold, h, n.NVML_TEMPERATURE_THRESHOLD_SHUTDOWN),
            "pcie_max_gen": self._try(n.nvmlDeviceGetMaxPcieLinkGeneration, h),
            "pcie_max_width": self._try(n.nvmlDeviceGetMaxPcieLinkWidth, h),
            "pcie_replay_start": self._try(n.nvmlDeviceGetPcieReplayCounter, h),
        }
        if isinstance(info["driver"], bytes):
            info["driver"] = info["driver"].decode()
        return info

    def other_processes(self):
        if not self.ok:
            return []
        procs = self._try(pynvml.nvmlDeviceGetComputeRunningProcesses, self.h, default=[]) or []
        return [(p.pid, (p.usedGpuMemory or 0) // 2**20) for p in procs if p.pid != os.getpid()]

    def _sample(self):
        h, n = self.h, pynvml
        thr = self._try(n.nvmlDeviceGetCurrentClocksEventReasons, h)
        if thr is None:
            thr = self._try(n.nvmlDeviceGetCurrentClocksThrottleReasons, h, default=0)
        util = n.nvmlDeviceGetUtilizationRates(h)          # raises if the GPU is gone
        row = {
            "time": datetime.datetime.now().isoformat(timespec="seconds"),
            "elapsed_s": round(time.time() - self.t0, 1),
            "round": STATE["round"], "phase": STATE["phase"],
            "temp_c": n.nvmlDeviceGetTemperature(h, n.NVML_TEMPERATURE_GPU),
            "power_w": round(self._try(n.nvmlDeviceGetPowerUsage, h, default=0) / 1000, 1),
            "util_pct": util.gpu,
            "mem_used_mib": n.nvmlDeviceGetMemoryInfo(h).used // 2**20,
            "fan_pct": self._try(n.nvmlDeviceGetFanSpeed, h, default=""),
            "clock_mhz": self._try(n.nvmlDeviceGetClockInfo, h, n.NVML_CLOCK_GRAPHICS, default=""),
            "throttle": int(thr or 0),
            "pcie_gen": self._try(n.nvmlDeviceGetCurrPcieLinkGeneration, h, default=""),
            "pcie_width": self._try(n.nvmlDeviceGetCurrPcieLinkWidth, h, default=""),
            "cpu_temp_c": "", "ram_used_pct": "",
        }
        try:
            import psutil
            row["ram_used_pct"] = psutil.virtual_memory().percent
            temps = psutil.sensors_temperatures()
            for key in ("coretemp", "k10temp", "zenpower"):
                if key in temps and temps[key]:
                    row["cpu_temp_c"] = max(t.current for t in temps[key])
                    break
        except Exception:  # noqa: BLE001
            pass
        return row

    def run(self):
        if not self.ok:
            return
        errors = 0
        with open(self.csv_path, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=self.FIELDS)
            w.writeheader()
            while not self.done.is_set():
                try:
                    row = self._sample()
                    errors = 0
                    self.samples.append(row)
                    w.writerow(row)
                    f.flush()
                    if self.max_temp and row["temp_c"] >= self.max_temp:
                        request_stop(f"temperature {row['temp_c']} C reached the abort limit ({self.max_temp:.0f} C)")
                except Exception as e:  # noqa: BLE001
                    errors += 1
                    if errors >= 5:
                        request_stop(f"GPU stopped answering NVML queries ({e})")
                        return
                self.done.wait(self.interval)

    def finish(self):
        self.done.set()
        if self.ok:
            self.join(timeout=10)
            self.info["pcie_replay_end"] = self._try(pynvml.nvmlDeviceGetPcieReplayCounter, self.h)


# --------------------------------------------------------------------------------------
# Workload helpers
# --------------------------------------------------------------------------------------
def sync():
    if DEV.type == "cuda":
        torch.cuda.synchronize()


def cleanup():
    import gc
    gc.collect()
    if DEV.type == "cuda":
        torch.cuda.empty_cache()


def timed_loop(step, seconds, units_per_step, warmup=3, sync_every=10):
    """Run step() for `seconds`; return units/second (excluding warm-up)."""
    for _ in range(warmup):
        step()
    sync()
    n, t0 = 0, time.perf_counter()
    while time.perf_counter() - t0 < seconds and not STOP.is_set():
        step()
        n += 1
        if n % sync_every == 0:
            sync()
    sync()
    dt = time.perf_counter() - t0
    return n * units_per_step / dt if n else 0.0


def with_batch(fn, batch, min_batch=1):
    """Call fn(batch); halve the batch on out-of-memory."""
    while True:
        try:
            return fn(batch), batch
        except torch.OutOfMemoryError:
            cleanup()
            if batch // 2 < min_batch:
                raise
            batch //= 2
            log(f"    out of memory, retrying with batch {batch}")


def autocast():
    return torch.autocast("cuda", dtype=torch.bfloat16, enabled=DEV.type == "cuda" and SIZES["amp"] == "bf16")


# --------------------------------------------------------------------------------------
# Workloads — each returns {metric: value}
# --------------------------------------------------------------------------------------
def wl_matmul(seconds, dtype, name):
    n = SIZES["matmul_fp16_n"] if dtype == torch.float16 else SIZES["matmul_fp32_n"]
    if TINY:
        dtype = torch.float32
    a = torch.randn(n, n, device=DEV, dtype=dtype)
    b = torch.randn(n, n, device=DEV, dtype=dtype)
    out = torch.empty_like(a)

    def step():
        torch.matmul(a, b, out=out)

    flops = timed_loop(step, seconds, 2.0 * n ** 3)
    if not torch.isfinite(out[:8, :8].float()).all():
        raise RuntimeError("matmul produced non-finite values")
    return {name: flops / 1e12}


def _resnet(kind):
    import torchvision
    return getattr(torchvision.models, kind)(weights=None)


def wl_resnet_train(seconds):
    res = 32 if TINY else 224

    def run(batch):
        model = _resnet("resnet18" if TINY else "resnet50").to(DEV, memory_format=torch.channels_last)
        opt = torch.optim.SGD(model.parameters(), lr=0.01, momentum=0.9)
        x = torch.randn(batch, 3, res, res, device=DEV).contiguous(memory_format=torch.channels_last)
        y = torch.randint(0, 1000, (batch,), device=DEV)
        last = {}

        def step():
            with autocast():
                loss = F.cross_entropy(model(x), y)
            opt.zero_grad(set_to_none=True)
            loss.backward()
            opt.step()
            last["loss"] = loss

        rate = timed_loop(step, seconds, batch)
        if not torch.isfinite(last["loss"]):
            raise RuntimeError("ResNet training loss is not finite")
        return rate

    rate, used = with_batch(run, SIZES["resnet_train_batch"])
    SIZES["resnet_train_batch"] = used                   # keep a size that fits for the following rounds
    return {"resnet50_train_img_s": rate}


def wl_resnet_infer(seconds):
    res = 32 if TINY else 224

    def run(batch):
        model = _resnet("resnet18" if TINY else "resnet50").to(DEV, memory_format=torch.channels_last).eval()
        x = torch.randn(batch, 3, res, res, device=DEV).contiguous(memory_format=torch.channels_last)

        def step():
            with torch.no_grad(), autocast():
                model(x)

        return timed_loop(step, seconds, batch)

    rate, used = with_batch(run, SIZES["resnet_infer_batch"])
    SIZES["resnet_infer_batch"] = used
    return {"resnet50_infer_img_s": rate}


class TinyGPT(nn.Module):
    def __init__(self, vocab, d, heads, layers, seq):
        super().__init__()
        self.tok = nn.Embedding(vocab, d)
        self.pos = nn.Embedding(seq, d)
        layer = nn.TransformerEncoderLayer(d, heads, 4 * d, dropout=0.0, batch_first=True, norm_first=True)
        self.body = nn.TransformerEncoder(layer, layers, enable_nested_tensor=False)
        self.head = nn.Linear(d, vocab, bias=False)
        self.register_buffer("mask", nn.Transformer.generate_square_subsequent_mask(seq))

    def forward(self, idx):
        x = self.tok(idx) + self.pos(torch.arange(idx.shape[1], device=idx.device))
        return self.head(self.body(x, mask=self.mask, is_causal=True))


def wl_transformer_train(seconds):
    vocab, d, heads, layers, seq = (256, 64, 4, 2, 32) if TINY else (32000, 768, 12, 12, 512)

    def run(batch):
        model = TinyGPT(vocab, d, heads, layers, seq).to(DEV)
        opt = torch.optim.AdamW(model.parameters(), lr=1e-4)
        idx = torch.randint(0, vocab, (batch, seq), device=DEV)
        last = {}

        def step():
            with autocast():
                logits = model(idx)
                loss = F.cross_entropy(logits[:, :-1].reshape(-1, vocab).float(), idx[:, 1:].reshape(-1))
            opt.zero_grad(set_to_none=True)
            loss.backward()
            opt.step()
            last["loss"] = loss

        rate = timed_loop(step, seconds, batch * seq, sync_every=5)
        if not torch.isfinite(last["loss"]):
            raise RuntimeError("Transformer training loss is not finite")
        return rate

    rate, used = with_batch(run, SIZES["transformer_batch"])
    SIZES["transformer_batch"] = used
    return {"transformer_train_tok_s": rate}


class _RandomImages(torch.utils.data.Dataset):
    def __init__(self, res):
        self.res = res

    def __len__(self):
        return 10 ** 9

    def __getitem__(self, i):
        return torch.randint(0, 256, (3, self.res, self.res), dtype=torch.uint8), i % 1000


def wl_dataloader_train(seconds):
    """CPU workers produce images while the GPU trains: host CPU + RAM + PCIe + GPU at once."""
    res = 32 if TINY else 224
    batch = SIZES["loader_batch"]
    workers = 2 if TINY else max(2, min(8, (os.cpu_count() or 4) // 2))
    model = _resnet("resnet18").to(DEV, memory_format=torch.channels_last)
    opt = torch.optim.SGD(model.parameters(), lr=0.01, momentum=0.9)
    loader = torch.utils.data.DataLoader(_RandomImages(res), batch_size=batch, num_workers=workers,
                                         pin_memory=DEV.type == "cuda", prefetch_factor=2)
    it = iter(loader)
    n, t0 = 0, None
    try:
        for i, (x, y) in enumerate(it):
            if i == 3:                                   # warm-up done
                sync()
                n, t0 = 0, time.perf_counter()
            x = x.to(DEV, non_blocking=True).float().div_(255).contiguous(memory_format=torch.channels_last)
            y = y.to(DEV, non_blocking=True)
            with autocast():
                loss = F.cross_entropy(model(x), y)
            opt.zero_grad(set_to_none=True)
            loss.backward()
            opt.step()
            n += 1
            if t0 is not None and (time.perf_counter() - t0 >= seconds or STOP.is_set()):
                break
        sync()
        dt = time.perf_counter() - (t0 or time.perf_counter())
    finally:
        del it, loader
    return {"dataloader_resnet18_img_s": n * batch / dt if dt > 0 else 0.0}


def wl_transfer(seconds):
    """Host <-> GPU copy speed (PCIe)."""
    size = 2 ** 24 if TINY else 2 ** 30
    host = torch.empty(size, dtype=torch.uint8)
    if DEV.type == "cuda":
        host = host.pin_memory()
    host.fill_(7)
    gpu = host.to(DEV)
    back = torch.empty_like(host)
    gib = size / 2 ** 30
    half = max(0.2, min(seconds, 20.0) / 2)
    h2d = timed_loop(lambda: gpu.copy_(host), half, gib, warmup=1, sync_every=1)
    d2h = timed_loop(lambda: back.copy_(gpu), half, gib, warmup=1, sync_every=1)
    if int(back[-1]) != 7:
        raise RuntimeError("data read back from the GPU differs from what was sent")
    return {"h2d_gib_s": h2d, "d2h_gib_s": d2h}


_PATTERN_A, _PATTERN_B = 6364136223846793005, 1000003       # products wrap around in int64 (intended)


def _pattern(i, n):
    return torch.arange(n, device=DEV, dtype=torch.int64) * _PATTERN_A + (i + 1) * _PATTERN_B


def wl_vram_integrity(seconds):
    """Fill most of the free VRAM with a known pattern, keep it while the GPU computes, read it back."""
    n = 2 ** 17 if TINY else 2 ** 25                    # elements per chunk (8 bytes each -> 256 MiB)
    chunk_bytes = n * 8
    if DEV.type == "cuda":
        cleanup()
        free, _ = torch.cuda.mem_get_info()
        target = int(free * ARGS.vram_fraction) - 4 * chunk_bytes     # head-room for verification temporaries
    else:
        target = 16 * chunk_bytes
    count = max(1, target // chunk_bytes)
    chunks = []
    try:
        for i in range(count):
            chunks.append(_pattern(i, n))
            if STOP.is_set():
                break
    except torch.OutOfMemoryError:
        pass                                             # verify what we got
    hold = min(max(seconds / 4, 1.0), 60.0)
    m = 256 if TINY else 2048
    a = torch.randn(m, m, device=DEV)
    t0 = time.perf_counter()
    while time.perf_counter() - t0 < hold and not STOP.is_set():
        a = F.normalize(a @ a, dim=0)
        sync()
    bad = 0
    for i, c in enumerate(chunks):
        bad += int((c != _pattern(i, n)).sum().item())
    tested = len(chunks) * chunk_bytes / 2 ** 30
    del chunks, a
    return {"vram_tested_gib": tested, "vram_errors": bad}


def wl_determinism(_seconds):
    """Same input, same code -> the result must be bit-identical every round."""
    m = 256 if TINY else 4096
    g = torch.Generator(device="cpu").manual_seed(1234)
    a = torch.randn(m, m, generator=g).to(DEV)
    x = a
    for _ in range(24):
        x = x @ a
        x = x / x.norm()
    digest = hashlib.sha256(x.cpu().numpy().tobytes()).hexdigest()[:16]
    return {"determinism_digest": digest}


def wl_idle(seconds):
    t0 = time.time()
    while time.time() - t0 < seconds and not STOP.is_set():
        time.sleep(0.5)
    return {}


def build_plan():
    ps, idle = ARGS.phase_seconds, ARGS.idle_seconds
    return [
        ("matmul_fp32", lambda: wl_matmul(ps, torch.float32, "matmul_fp32_tflops")),
        ("matmul_fp16", lambda: wl_matmul(ps, torch.float16, "matmul_fp16_tflops")),
        ("resnet50_train", lambda: wl_resnet_train(ps)),
        ("transformer_train", lambda: wl_transformer_train(ps)),
        ("resnet50_infer", lambda: wl_resnet_infer(ps * 0.75)),
        ("vram_integrity", lambda: wl_vram_integrity(ps)),
        ("transfer", lambda: wl_transfer(ps)),
        ("dataloader_train", lambda: wl_dataloader_train(ps)),
        ("determinism", lambda: wl_determinism(0)),
        ("idle", lambda: wl_idle(idle)),
    ]


# --------------------------------------------------------------------------------------
# Kernel log
# --------------------------------------------------------------------------------------
def kernel_gpu_events(since_epoch):
    """Returns (checked, critical_lines, warning_lines)."""
    try:
        out = subprocess.run(["journalctl", "-k", "--no-pager", "-o", "short-iso", "--since", f"@{int(since_epoch)}"],
                             capture_output=True, text=True, timeout=60)
        if out.returncode != 0:
            raise RuntimeError(out.stderr.strip())
        lines = out.stdout.splitlines()
    except Exception:  # noqa: BLE001
        try:
            out = subprocess.run(["dmesg", "--time-format", "iso"], capture_output=True, text=True, timeout=30)
            if out.returncode != 0:
                return False, [], []
            lines = out.stdout.splitlines()        # cannot filter by time reliably; best effort
        except Exception:  # noqa: BLE001
            return False, [], []
    crit = [l for l in lines if re.search(r"NVRM: Xid|fallen off the bus|GPU has fallen|NVRM: .*GPU.*lost", l)]
    warn = [l for l in lines if re.search(r"AER: .*(error|Error)|PCIe Bus Error|Machine check|mce: \[Hardware Error\]|thermal.*throttl", l)]
    return True, crit, warn


# --------------------------------------------------------------------------------------
# Report
# --------------------------------------------------------------------------------------
METRIC_LABELS = {
    "matmul_fp32_tflops": ("Matrix multiply FP32", "TFLOPS"),
    "matmul_fp16_tflops": ("Matrix multiply FP16", "TFLOPS"),
    "resnet50_train_img_s": ("ResNet-50 training (AMP)", "img/s"),
    "transformer_train_tok_s": ("Transformer training (12L/768d, AMP)", "tokens/s"),
    "resnet50_infer_img_s": ("ResNet-50 inference (AMP)", "img/s"),
    "dataloader_resnet18_img_s": ("DataLoader + ResNet-18 training", "img/s"),
    "h2d_gib_s": ("Host to GPU copy (pinned)", "GiB/s"),
    "d2h_gib_s": ("GPU to host copy", "GiB/s"),
}


def summarize(rounds, mon, started, planned_s, errors):
    fails, warns, notes = [], [], []
    elapsed = time.time() - started
    info = dict(mon.info)

    # ---- performance ----
    perf = {}
    for key in METRIC_LABELS:
        vals = [r["metrics"][key] for r in rounds if key in r["metrics"] and r["metrics"][key] > 0]
        if not vals:
            continue
        mean = statistics.fmean(vals)
        cv = (statistics.pstdev(vals) / mean * 100) if len(vals) > 1 and mean else 0.0
        drift = None
        if len(vals) >= 6:
            k = len(vals) // 3
            drift = (statistics.fmean(vals[-k:]) / statistics.fmean(vals[:k]) - 1) * 100
        elif len(vals) >= 2:
            drift = (vals[-1] / vals[0] - 1) * 100
        perf[key] = {"mean": mean, "min": min(vals), "max": max(vals), "cv_pct": cv, "drift_pct": drift, "n": len(vals)}
        label = METRIC_LABELS[key][0]
        cpu_bound = key in ("dataloader_resnet18_img_s", "h2d_gib_s", "d2h_gib_s")   # noisier, host dependent
        if TINY:
            continue                                     # self-test numbers are noise
        if drift is not None and len(vals) >= 3:
            if drift < -20 and not cpu_bound:
                fails.append(f"{label}: throughput fell {abs(drift):.1f} % during the run")
            elif drift < (-10 if cpu_bound else -5):
                warns.append(f"{label}: throughput fell {abs(drift):.1f} % during the run")
        if len(vals) >= 3 and cv > (15 if cpu_bound else 5):
            warns.append(f"{label}: unstable throughput (variation {cv:.1f} %)")

    # ---- correctness ----
    vram_errors = sum(r["metrics"].get("vram_errors", 0) for r in rounds)
    vram_max = max((r["metrics"].get("vram_tested_gib", 0) for r in rounds), default=0)
    if vram_errors:
        fails.append(f"VRAM integrity: {vram_errors} corrupted value(s) read back")
    digests = [r["metrics"]["determinism_digest"] for r in rounds if "determinism_digest" in r["metrics"]]
    if len(set(digests)) > 1:
        fails.append(f"Determinism: identical computation gave {len(set(digests))} different results over {len(digests)} rounds")
    for e in errors:
        fails.append(f"Workload error in round {e['round']} ({e['phase']}): {e['error']}")

    # ---- monitoring ----
    s = mon.samples
    thermal = {}
    if s:
        load = [x for x in s if x["phase"] not in ("idle", "init", "determinism")] or s
        thermal = {
            "temp_max_c": max(x["temp_c"] for x in s),
            "temp_mean_load_c": statistics.fmean(x["temp_c"] for x in load),
            "power_max_w": max(x["power_w"] for x in s),
            "power_mean_load_w": statistics.fmean(x["power_w"] for x in load),
            "util_mean_load_pct": statistics.fmean(x["util_pct"] for x in load),
            "util_max_pct": max(x["util_pct"] for x in s),
            "mem_max_mib": max(x["mem_used_mib"] for x in s),
            "fan_max_pct": max((x["fan_pct"] for x in s if x["fan_pct"] != ""), default=None),
            "cpu_temp_max_c": max((x["cpu_temp_c"] for x in s if x["cpu_temp_c"] != ""), default=None),
            "energy_kwh": sum(x["power_w"] for x in s) * mon.interval / 3.6e6,
            "samples": len(s),
        }
        seen = {}
        for x in s:
            for bit, (name, level) in THROTTLE_BITS.items():
                if x["throttle"] & bit and name != "idle":
                    seen.setdefault((name, level), 0)
                    seen[(name, level)] += 1
        thermal["throttle"] = {name: {"level": level, "samples": c} for (name, level), c in seen.items()}
        for (name, level), c in seen.items():
            pct = c / len(s) * 100
            if level == "warn":
                warns.append(f"Throttling: {name} active in {pct:.1f} % of samples")
            else:
                notes.append(f"{name} active in {pct:.1f} % of samples (normal when running at the power limit)")
        links = {(x["pcie_gen"], x["pcie_width"]) for x in s if x["pcie_gen"] != ""}
        thermal["pcie_links"] = sorted(f"Gen{g} x{w}" for g, w in links)
        widths = {w for _, w in links}
        if len(widths) > 1:
            warns.append(f"PCIe link width changed during the run: {', '.join(thermal['pcie_links'])}")
        elif len(links) > 1:
            notes.append(f"PCIe link speed varied ({', '.join(thermal['pcie_links'])}); speed changes at idle are normal with link power management")
        if info.get("pcie_max_width") and widths and max(widths) < info["pcie_max_width"]:
            warns.append(f"PCIe link runs at x{max(widths)}, the card supports x{info['pcie_max_width']}")
        if not TINY and thermal["util_max_pct"] < 90:
            warns.append(f"GPU utilisation never exceeded {thermal['util_max_pct']} %")
        slow = info.get("temp_slowdown_c")
        if slow and thermal["temp_max_c"] >= slow - 3:
            warns.append(f"Peak temperature {thermal['temp_max_c']} C is within 3 C of the slowdown threshold ({slow} C)")
    elif not TINY:
        warns.append("No monitoring samples (NVML unavailable): " + str(info.get("error", "")))
    r0, r1 = info.get("pcie_replay_start"), info.get("pcie_replay_end")
    if r0 is not None and r1 is not None and r1 > r0:
        warns.append(f"PCIe replay counter increased by {r1 - r0} (link-level retransmissions)")

    # ---- kernel log ----
    checked, crit, kwarn = kernel_gpu_events(started - 5)
    if crit:
        fails.append(f"Kernel reported {len(crit)} NVIDIA Xid / GPU-lost event(s)")
    if kwarn:
        warns.append(f"Kernel reported {len(kwarn)} PCIe/hardware error line(s)")
    if not checked:
        notes.append("Kernel log could not be read (not in the adm group?) — Xid errors were not checked")

    # ---- run completeness ----
    if STATE["stop_reason"] and STATE["stop_reason"] not in ("time budget used",):
        (fails if ("temperature" in STATE["stop_reason"] or "NVML" in STATE["stop_reason"]) else notes).append(
            "Stopped early: " + STATE["stop_reason"])
    complete = elapsed >= planned_s * 0.98 or STATE["stop_reason"] == "time budget used"

    # ---- baseline ----
    baseline, base_cmp = None, {}
    if ARGS.baselines and os.path.exists(ARGS.baselines) and info.get("name"):
        try:
            with open(ARGS.baselines) as f:
                baseline = json.load(f).get(info["name"])
        except Exception as e:  # noqa: BLE001
            notes.append(f"Baseline file unreadable: {e}")
    if baseline:
        for key, ref in baseline.get("metrics", {}).items():
            if key in perf and ref:
                ratio = perf[key]["mean"] / ref * 100
                base_cmp[key] = {"reference": ref, "pct": ratio}
                if ratio < 85 and key not in ("dataloader_resnet18_img_s", "h2d_gib_s", "d2h_gib_s"):
                    warns.append(f"{METRIC_LABELS[key][0]}: {ratio:.0f} % of the reference for {info['name']}")
    elif info.get("name") and not TINY:
        notes.append(f"No stored reference for '{info['name']}' — absolute performance was not compared "
                     f"(save one from a healthy run with --save-baseline)")

    verdict = "FAIL" if fails else ("WARN" if warns else "PASS")
    if not complete and verdict != "FAIL":
        verdict = "INCOMPLETE"
    return {
        "verdict": verdict, "complete": complete, "fails": fails, "warnings": warns, "notes": notes,
        "started": datetime.datetime.fromtimestamp(started).isoformat(timespec="seconds"),
        "elapsed_s": round(elapsed), "planned_s": round(planned_s), "rounds": len(rounds),
        "gpu": info, "perf": perf, "thermal": thermal, "baseline": base_cmp,
        "baseline_source": (baseline or {}).get("source"),
        "vram": {"tested_gib": vram_max, "errors": vram_errors, "passes": sum(1 for r in rounds if "vram_errors" in r["metrics"])},
        "determinism": {"rounds": len(digests), "distinct": len(set(digests))},
        "kernel": {"checked": checked, "critical": crit[:20], "warnings": kwarn[:20]},
        "torch": torch.__version__, "self_test": TINY, "sizes": dict(SIZES),
    }


def fmt(v, digits=1):
    if v is None or v == "":
        return "-"
    if isinstance(v, float):
        return f"{v:,.{digits}f}"
    return f"{v:,}" if isinstance(v, int) else str(v)


def write_report(summary, path):
    g, t = summary["gpu"], summary["thermal"]
    h, m = divmod(summary["elapsed_s"] // 60, 60)
    L = [f"# GPU Burn-in Report — {summary['verdict']}", ""]
    if summary["self_test"]:
        L += ["> Self-test on CPU with tiny workloads: validates the script only, numbers are meaningless.", ""]
    L += [
        f"- **GPU**: {g.get('name', 'unknown')} ({fmt(g.get('vram_total_mib'))} MiB, driver {g.get('driver', '-')})",
        f"- **Started**: {summary['started']}   **Ran**: {h} h {m:02d} min of {summary['planned_s'] / 3600:.2f} h planned"
        f"   **Rounds**: {summary['rounds']}",
        f"- **PyTorch**: {summary['torch']}",
        "",
    ]
    for title, items in (("Failures", summary["fails"]), ("Warnings", summary["warnings"]), ("Notes", summary["notes"])):
        if items:
            L += [f"## {title}", ""] + [f"- {i}" for i in items] + [""]
    L += ["## Performance", ""]
    has_base = bool(summary["baseline"])
    L += ["| Workload | Mean | Min | Max | Variation | Drift over run |" + (" vs reference |" if has_base else ""),
          "|---|---:|---:|---:|---:|---:|" + ("---:|" if has_base else "")]
    for key, (label, unit) in METRIC_LABELS.items():
        p = summary["perf"].get(key)
        if not p:
            continue
        drift = "-" if p["drift_pct"] is None else f"{p['drift_pct']:+.1f} %"
        row = f"| {label} | {fmt(p['mean'])} {unit} | {fmt(p['min'])} | {fmt(p['max'])} | {p['cv_pct']:.1f} % | {drift} |"
        if has_base:
            b = summary["baseline"].get(key)
            row += f" {b['pct']:.0f} % |" if b else " - |"
        L.append(row)
    L.append("")
    z = summary["sizes"]
    L += [f"Workload sizes chosen for this GPU ({z['vram_gib']} GiB VRAM): matmul {z['matmul_fp32_n']}² FP32 / {z['matmul_fp16_n']}² FP16, "
          f"ResNet-50 batch {z['resnet_train_batch']} (train) / {z['resnet_infer_batch']} (inference), "
          f"Transformer batch {z['transformer_batch']} × 512 tokens, DataLoader batch {z['loader_batch']}, mixed precision {z['amp']}.", ""]
    if has_base and summary.get("baseline_source"):
        L += [f"Reference: {summary['baseline_source']}", ""]
    L += ["## Correctness", "",
          f"- VRAM integrity: {summary['vram']['passes']} pass(es), up to {summary['vram']['tested_gib']:.1f} GiB per pass, "
          f"**{summary['vram']['errors']} error(s)**",
          f"- Determinism: {summary['determinism']['rounds']} round(s), "
          f"**{summary['determinism']['distinct']} distinct result(s)** (expected 1)",
          f"- Kernel log: " + (f"{len(summary['kernel']['critical'])} Xid/GPU-lost, {len(summary['kernel']['warnings'])} PCIe/hardware line(s)"
                               if summary["kernel"]["checked"] else "not readable"), ""]
    for line in summary["kernel"]["critical"] + summary["kernel"]["warnings"]:
        L.append(f"  - `{line[:200]}`")
    if t:
        L += ["", "## Thermal and power", "",
              "| | Value |", "|---|---:|",
              f"| Peak temperature | {t['temp_max_c']} C (slowdown at {fmt(g.get('temp_slowdown_c'))} C, shutdown at {fmt(g.get('temp_shutdown_c'))} C) |",
              f"| Mean temperature under load | {t['temp_mean_load_c']:.1f} C |",
              f"| Peak power | {t['power_max_w']:.0f} W (limit {fmt(g.get('power_limit_w'), 0)} W) |",
              f"| Mean power under load | {t['power_mean_load_w']:.0f} W |",
              f"| Mean utilisation under load | {t['util_mean_load_pct']:.0f} % |",
              f"| Peak VRAM used | {fmt(t['mem_max_mib'])} MiB |",
              f"| Peak fan speed | {fmt(t['fan_max_pct'])} % |",
              f"| Peak CPU temperature | {fmt(t['cpu_temp_max_c'])} C |",
              f"| Energy used by the GPU | {t['energy_kwh']:.2f} kWh |",
              f"| PCIe link | {', '.join(t.get('pcie_links', [])) or '-'} |", ""]
    L += ["Raw data: `samples.csv` (monitor), `rounds.jsonl` (per-round results), `summary.json`.", ""]
    with open(path, "w") as f:
        f.write("\n".join(L))


# --------------------------------------------------------------------------------------
def main():
    os.makedirs(ARGS.out, exist_ok=True)
    planned_s = (ARGS.minutes * 60) if ARGS.minutes is not None else ARGS.hours * 3600
    if TINY:
        planned_s = min(planned_s, 40)
        ARGS.phase_seconds, ARGS.idle_seconds = 1.0, 1.0
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda s, _f: request_stop(f"interrupted (signal {s})"))

    if not TINY and not torch.cuda.is_available():
        log("ERROR: CUDA is not available in this environment")
        return 2

    max_temp = ARGS.max_temp
    mon = Monitor(ARGS.gpu, os.path.join(ARGS.out, "samples.csv"), ARGS.interval, None)
    if max_temp is None and mon.info.get("temp_shutdown_c"):
        max_temp = mon.info["temp_shutdown_c"] - 5
    mon.max_temp = None if TINY else (max_temp or 95)

    others = mon.other_processes()
    if others and not TINY and not ARGS.force:
        log("ERROR: other processes are using this GPU: " + ", ".join(f"pid {p} ({m} MiB)" for p, m in others))
        log("       Stop them first, or pass --force (results will be distorted and they may run out of memory).")
        return 2

    if DEV.type == "cuda":
        torch.backends.cudnn.benchmark = True
    log("Workload sizes for this GPU: " + ", ".join(f"{k}={v}" for k, v in SIZES.items()))
    log(f"GPU burn-in: {mon.info.get('name', DEV)} | planned {planned_s / 3600:.2f} h | "
        f"{ARGS.phase_seconds:.0f} s per workload | abort at {mon.max_temp} C | output {ARGS.out}")
    started = time.time()
    mon.t0 = started
    mon.start()
    deadline = started + planned_s
    plan = build_plan()
    rounds, errors = [], []
    rounds_path = os.path.join(ARGS.out, "rounds.jsonl")

    while not STOP.is_set() and time.time() < deadline:
        STATE["round"] += 1
        rnd = {"round": STATE["round"], "start_s": round(time.time() - started), "metrics": {}}
        for name, fn in plan:
            # the first round always runs completely so that every workload is measured at least once
            if STOP.is_set() or (time.time() >= deadline and STATE["round"] > 1):
                break
            STATE["phase"] = name
            try:
                res = fn()
            except Exception as e:  # noqa: BLE001
                msg = f"{type(e).__name__}: {str(e).splitlines()[0][:200] if str(e) else ''}"
                errors.append({"round": STATE["round"], "phase": name, "error": msg})
                log(f"  round {STATE['round']} {name}: ERROR {msg}")
                res = {}
                if "CUDA" in msg and "out of memory" not in msg.lower():
                    request_stop(f"CUDA error in {name}")           # device state is no longer trustworthy
            finally:
                cleanup() if not STOP.is_set() or DEV.type == "cpu" else None
            rnd["metrics"].update(res)
            if res:
                shown = ", ".join(f"{k}={v:,.2f}" if isinstance(v, float) else f"{k}={v}" for k, v in res.items())
                last = mon.samples[-1] if mon.samples else {}
                log(f"  round {STATE['round']} {name}: {shown}"
                    + (f"  [{last.get('temp_c')} C, {last.get('power_w')} W]" if last else ""))
        rounds.append(rnd)
        with open(rounds_path, "a") as f:
            f.write(json.dumps(rnd) + "\n")
        left = max(0, deadline - time.time())
        log(f"round {STATE['round']} done — {left / 3600:.2f} h left")

    if STATE["stop_reason"] is None:
        STATE["stop_reason"] = "time budget used"
    STATE["phase"] = "done"
    mon.finish()
    summary = summarize(rounds, mon, started, planned_s, errors)
    with open(os.path.join(ARGS.out, "summary.json"), "w") as f:
        json.dump(summary, f, indent=2)
    report = os.path.join(ARGS.out, "REPORT.md")
    write_report(summary, report)

    if ARGS.save_baseline and ARGS.baselines and not TINY:
        if summary["verdict"] == "PASS" and summary["gpu"].get("name"):
            data = {}
            if os.path.exists(ARGS.baselines):
                with open(ARGS.baselines) as f:
                    data = json.load(f)
            data[summary["gpu"]["name"]] = {
                "source": f"measured by gpu-burnin on {datetime.date.today()} "
                          f"({summary['elapsed_s'] / 3600:.1f} h, driver {summary['gpu'].get('driver')}, torch {torch.__version__})",
                "sizes": summary["sizes"],
                "metrics": {k: round(v["mean"], 2) for k, v in summary["perf"].items()},
            }
            with open(ARGS.baselines, "w") as f:
                json.dump(data, f, indent=2, sort_keys=True)
                f.write("\n")
            log(f"Baseline for '{summary['gpu']['name']}' saved to {ARGS.baselines}")
        else:
            log(f"Baseline NOT saved (verdict {summary['verdict']}; only a PASS run is stored)")

    log(f"VERDICT: {summary['verdict']}  ({len(summary['fails'])} failure(s), {len(summary['warnings'])} warning(s))")
    for line in summary["fails"]:
        log(f"  FAIL  {line}")
    for line in summary["warnings"]:
        log(f"  WARN  {line}")
    log(f"Report: {report}")
    return 1 if summary["verdict"] == "FAIL" else 0


if __name__ == "__main__":
    sys.exit(main())
