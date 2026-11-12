#!/usr/bin/env bash
# gpu-burnin.sh — Long GPU stability + performance test (default: 6 hours of mixed workloads).
#
# What it does: repeats rounds of matmul (FP32/FP16), ResNet-50 training and inference, Transformer
# training, VRAM integrity, host<->GPU transfer, DataLoader+training and a bit-exact determinism
# check, while logging temperature, power, clocks, throttling, fan and PCIe link state. Workload
# sizes are chosen from the GPU's VRAM, so every model is loaded close to its capacity.
# Ends with REPORT.md: PASS / WARN / FAIL, throughput per workload, drift over time, thermals.
#
# Usage:
#   ./scripts/gpu-burnin.sh                    # 6 hours, foreground
#   ./scripts/gpu-burnin.sh --detach           # 6 hours in the background (survives logout)
#   ./scripts/gpu-burnin.sh --hours 1          # shorter run
#   ./scripts/gpu-burnin.sh --quick            # 10-minute check (30 s per workload)
#   ./scripts/gpu-burnin.sh --status           # progress of the running / last test
#   ./scripts/gpu-burnin.sh --report           # print the last report
#   ./scripts/gpu-burnin.sh --stop             # stop a background run (a partial report is written)
#   ./scripts/gpu-burnin.sh --gpu 1            # one GPU only (default: all GPUs, in parallel)
#   ./scripts/gpu-burnin.sh --save-baseline    # after a PASS, store the averages as the reference for this GPU model
#   ./scripts/gpu-burnin.sh --force            # run although other processes use the GPU
#   ./scripts/gpu-burnin.sh --self-test        # 40 s CPU run that only validates the script
#
# Results: ~/.machine_setting/burnin/<timestamp>/gpu<N>/ (REPORT.md, summary.json, samples.csv, run.log)
# Reference numbers per GPU model: config/gpu-baselines.json. No sudo needed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

[ -f "$HOME/.machine_setting_profile" ] && source "$HOME/.machine_setting_profile"
source "$REPO_DIR/config/default.conf"
[ -f "$REPO_DIR/config/machine.conf" ] && source "$REPO_DIR/config/machine.conf"

BASE_DIR="${BURNIN_DIR:-$HOME/.machine_setting/burnin}"
VENV="${VENV_PATH:-$HOME/ai-env}"
[ -x "$VENV/bin/python" ] || VENV="$HOME/ai-env"
PY="$VENV/bin/python"

MODE="run"; DETACH=false; GPU=""; SELF_TEST=false
PY_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --hours)         PY_ARGS+=(--hours "$2"); shift 2 ;;
        --minutes)       PY_ARGS+=(--minutes "$2"); shift 2 ;;
        --quick)         PY_ARGS+=(--minutes 10 --phase-seconds 30 --idle-seconds 15); shift ;;
        --phase-seconds) PY_ARGS+=(--phase-seconds "$2"); shift 2 ;;
        --max-temp)      PY_ARGS+=(--max-temp "$2"); shift 2 ;;
        --gpu)           GPU="$2"; shift 2 ;;
        --force)         PY_ARGS+=(--force); shift ;;
        --save-baseline) PY_ARGS+=(--save-baseline); shift ;;
        --self-test)     SELF_TEST=true; PY_ARGS+=(--self-test); shift ;;
        --detach)        DETACH=true; shift ;;
        --status)        MODE="status"; shift ;;
        --report)        MODE="report"; shift ;;
        --stop)          MODE="stop"; shift ;;
        --foreground-in) MODE="worker"; RUN_DIR="$2"; shift 2 ;;   # internal (used by --detach)
        --help|-h)       sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

latest_dir() { [ -L "$BASE_DIR/latest" ] && readlink -f "$BASE_DIR/latest"; }
running_pid() {
    local d; d=$(latest_dir) || return 1
    [ -f "$d/pid" ] || return 1
    local pid; pid=$(cat "$d/pid")
    kill -0 "$pid" 2>/dev/null && echo "$pid"
}

case "$MODE" in
    status)
        d=$(latest_dir) || { echo "No burn-in run found in $BASE_DIR"; exit 0; }
        if pid=$(running_pid); then echo "Burn-in RUNNING (pid $pid) — $d"; else echo "Burn-in not running — last run: $d"; fi
        for log in "$d"/gpu*/run.log; do
            [ -f "$log" ] || continue
            echo "── $(basename "$(dirname "$log")") ──"
            grep -E 'GPU burn-in:|done —|VERDICT|ERROR|FAIL|WARN' "$log" | tail -6
            tail -1 "$log"
        done
        command -v nvidia-smi &>/dev/null && nvidia-smi --query-gpu=index,temperature.gpu,power.draw,utilization.gpu,memory.used --format=csv,noheader
        exit 0 ;;
    report)
        d=$(latest_dir) || { echo "No burn-in run found in $BASE_DIR"; exit 1; }
        found=false
        for r in "$d"/gpu*/REPORT.md; do [ -f "$r" ] && { cat "$r"; echo; found=true; }; done
        [ "$found" = true ] || { echo "No report yet in $d (still running? ./scripts/gpu-burnin.sh --status)"; exit 1; }
        exit 0 ;;
    stop)
        if pid=$(running_pid); then
            pkill -TERM -P "$pid" 2>/dev/null     # workers write their partial reports on SIGTERM
            echo "Stop requested (pid $pid). Partial report: ./scripts/gpu-burnin.sh --report"
        else
            echo "No burn-in is running"
        fi
        exit 0 ;;
esac

# ---------------- run ----------------
if [ ! -x "$PY" ]; then
    echo "  [ERROR] Python venv not found at $VENV — run ./setup.sh first"; exit 1
fi
if [ "$SELF_TEST" = false ]; then
    if ! command -v nvidia-smi &>/dev/null || ! nvidia-smi -L &>/dev/null; then
        echo "  [SKIP] No NVIDIA GPU — nothing to burn in"; exit 0
    fi
    if [ "$MODE" = "run" ] && pid=$(running_pid); then
        echo "  [ERROR] A burn-in is already running (pid $pid). See --status, or --stop it first."; exit 1
    fi
fi

if [ "$MODE" = "run" ]; then
    RUN_DIR="$BASE_DIR/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$RUN_DIR"
    ln -sfn "$RUN_DIR" "$BASE_DIR/latest"
    if [ "$DETACH" = true ]; then
        ARGS_Q=$(printf '%q ' "${PY_ARGS[@]}")
        # shellcheck disable=SC2086
        setsid nohup bash "${BASH_SOURCE[0]}" --foreground-in "$RUN_DIR" ${GPU:+--gpu "$GPU"} $ARGS_Q > "$RUN_DIR/launcher.log" 2>&1 < /dev/null &
        sleep 3
        echo "Burn-in started in the background: $RUN_DIR"
        echo "  Progress: ./scripts/gpu-burnin.sh --status      Stop: ./scripts/gpu-burnin.sh --stop"
        cat "$RUN_DIR/launcher.log" 2>/dev/null | head -5
        exit 0
    fi
fi

echo $$ > "$RUN_DIR/pid"
if [ "$SELF_TEST" = true ]; then
    GPUS="0"
elif [ -n "$GPU" ]; then
    GPUS="$GPU"
else
    GPUS=$(nvidia-smi --query-gpu=index --format=csv,noheader | tr '\n' ' ')
fi

PIDS=()
trap 'kill -TERM "${PIDS[@]}" 2>/dev/null' INT TERM
for g in $GPUS; do
    out="$RUN_DIR/gpu$g"
    mkdir -p "$out"
    if [ "$(echo "$GPUS" | wc -w)" -gt 1 ] || [ "$MODE" = "worker" ]; then
        "$PY" -u "$SCRIPT_DIR/gpu_burnin.py" --gpu "$g" --out "$out" --baselines "$REPO_DIR/config/gpu-baselines.json" "${PY_ARGS[@]}" > "$out/run.log" 2>&1 &
    else
        "$PY" -u "$SCRIPT_DIR/gpu_burnin.py" --gpu "$g" --out "$out" --baselines "$REPO_DIR/config/gpu-baselines.json" "${PY_ARGS[@]}" 2>&1 | tee "$out/run.log" &
    fi
    PIDS+=($!)
done

RC=0
for pid in "${PIDS[@]}"; do
    while kill -0 "$pid" 2>/dev/null; do wait "$pid"; rc=$?; [ $rc -lt 128 ] && break; done   # keep waiting after a forwarded signal
    [ "${rc:-0}" -ne 0 ] && RC=1
done
rm -f "$RUN_DIR/pid"
echo ""
for g in $GPUS; do
    [ -f "$RUN_DIR/gpu$g/summary.json" ] && echo "GPU $g: $(grep -m1 '"verdict"' "$RUN_DIR/gpu$g/summary.json" | cut -d'"' -f4) — $RUN_DIR/gpu$g/REPORT.md"
done
exit $RC
