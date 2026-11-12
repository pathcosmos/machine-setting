#!/usr/bin/env bash
# smoke-test.sh — Functional test of everything this project installs.
#
# Unlike doctor.sh (is it installed / configured?), this actually RUNS each feature:
#   GPU compute, cuDNN, ONNX Runtime, Docker + GPU container, monitoring metrics, Node, Java, vLLM.
#
# Usage:
#   ./scripts/smoke-test.sh            # quick tests (~1-2 min, light GPU use)
#   ./scripts/smoke-test.sh --full     # + vLLM: serve a tiny model and get a completion (downloads ~300MB)
#   ./scripts/smoke-test.sh --only gpu # one group: health|gpu|docker|monitoring|runtimes|vllm
#   ./scripts/smoke-test.sh --list     # list test groups
#
# Exit code: 0 = no failures, 1 = at least one failure. No sudo (uses `sudo -n` only if already allowed).
# Long-running GPU stability/performance test: ./scripts/gpu-burnin.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

[ -f "$HOME/.machine_setting_profile" ] && source "$HOME/.machine_setting_profile"
source "$REPO_DIR/config/default.conf"
[ -f "$REPO_DIR/config/machine.conf" ] && source "$REPO_DIR/config/machine.conf"

FULL=false
ONLY=""
GROUPS_ALL="health gpu docker monitoring runtimes vllm"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --full)    FULL=true; shift ;;
        --only)    ONLY="$2"; shift 2 ;;
        --list)    echo "$GROUPS_ALL" | tr ' ' '\n'; exit 0 ;;
        --help|-h) sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done
if [ -n "$ONLY" ] && [[ " $GROUPS_ALL " != *" $ONLY "* ]]; then
    echo "Unknown group: $ONLY ($GROUPS_ALL)"; exit 1
fi

export PATH="$HOME/.local/bin:$PATH"
VENV="${VENV_PATH:-${STATE_VENV_PATH:-$HOME/ai-env}}"
[ -x "$VENV/bin/python" ] || VENV="$HOME/ai-env"
PY="$VENV/bin/python"
VLLM_VENV="${VLLM_VENV_PATH:-$HOME/vllm-env}"
HAS_NVIDIA=false
command -v nvidia-smi &>/dev/null && nvidia-smi -L &>/dev/null && HAS_NVIDIA=true

N_PASS=0; N_FAIL=0; N_SKIP=0
FAILED=()
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass() { echo "  [PASS] $1"; N_PASS=$((N_PASS + 1)); }
fail() { echo "  [FAIL] $1"; N_FAIL=$((N_FAIL + 1)); FAILED+=("$1"); }
skip() { echo "  [SKIP] $1"; N_SKIP=$((N_SKIP + 1)); }
want() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }
# run "<name>" cmd...  — pass/fail on exit code; on failure show the last lines of output
run() {
    local name="$1"; shift
    if "$@" > "$TMP/out" 2>&1; then
        local note; note=$(grep -m1 '^RESULT: ' "$TMP/out" | sed 's/^RESULT: //')
        pass "$name${note:+ — $note}"
    else
        fail "$name"
        tail -5 "$TMP/out" | sed 's/^/           /'
    fi
}

echo "=== Smoke Test ($(hostname), $(date '+%Y-%m-%d %H:%M')) ==="

# ------------------------------------------------------------
# health: the existing status checks must not report failures
# ------------------------------------------------------------
if want health; then
    echo ""
    echo "── Health checks ──"
    if bash "$SCRIPT_DIR/doctor.sh" > "$TMP/doctor" 2>&1; then
        pass "doctor.sh — $(grep -m1 '^Summary:' "$TMP/doctor" | sed 's/^Summary: //')"
    else
        fail "doctor.sh — $(grep -m1 '^Summary:' "$TMP/doctor" | sed 's/^Summary: //')"
        grep '\[FAIL\]' "$TMP/doctor" | sed 's/^/         /'
    fi
    if [ -x "$PY" ]; then
        run "Python env imports (torch, transformers, numpy, pandas)" "$PY" -c "
import torch, transformers, numpy, pandas
print('RESULT: torch', torch.__version__, '| transformers', transformers.__version__)"
    else
        fail "Python venv missing at $VENV"
    fi
fi

# ------------------------------------------------------------
# gpu: real computation on every GPU
# ------------------------------------------------------------
if want gpu; then
    echo ""
    echo "── GPU compute ──"
    if [ "$HAS_NVIDIA" != true ]; then
        skip "No NVIDIA GPU"
    elif [ ! -x "$PY" ]; then
        fail "Python venv missing at $VENV"
    else
        run "nvidia-smi" bash -c 'echo "RESULT: $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader | head -1)"'
        run "PyTorch CUDA: matmul + result check on each GPU" "$PY" -c "
import torch
assert torch.cuda.is_available(), 'CUDA not available'
names = []
for i in range(torch.cuda.device_count()):
    d = torch.device(f'cuda:{i}')
    g = torch.Generator(device='cpu').manual_seed(0)
    a = torch.randn(1024, 1024, generator=g, dtype=torch.float64)
    ref = (a @ a)
    out = (a.to(d) @ a.to(d)).cpu()
    err = (out - ref).abs().max().item() / ref.abs().max().item()
    assert err < 1e-9, f'GPU {i} result mismatch vs CPU (rel err {err:.2e})'
    names.append(torch.cuda.get_device_name(i))
print('RESULT:', len(names), 'GPU(s), results match CPU')"
        run "cuDNN: convolution forward/backward" "$PY" -c "
import torch
assert torch.backends.cudnn.is_available()
m = torch.nn.Conv2d(3, 32, 3, padding=1).cuda()
x = torch.randn(8, 3, 128, 128, device='cuda', requires_grad=True)
m(x).mean().backward()
assert torch.isfinite(x.grad).all()
print('RESULT: cuDNN', torch.backends.cudnn.version())"
        run "Mixed precision (AMP) training step" "$PY" -c "
import torch
net = torch.nn.Sequential(torch.nn.Linear(512, 1024), torch.nn.GELU(), torch.nn.Linear(1024, 10)).cuda()
opt = torch.optim.AdamW(net.parameters())
x = torch.randn(256, 512, device='cuda'); y = torch.randint(0, 10, (256,), device='cuda')
l0 = None
for _ in range(20):
    with torch.autocast('cuda', dtype=torch.bfloat16):
        loss = torch.nn.functional.cross_entropy(net(x), y)
    opt.zero_grad(); loss.backward(); opt.step()
    l0 = l0 or loss.item()
assert loss.item() < l0, 'loss did not decrease'
print(f'RESULT: loss {l0:.3f} -> {loss.item():.3f}')"
        run "ONNX Runtime GPU provider" "$PY" -c "
import onnxruntime as ort
p = ort.get_available_providers()
assert 'CUDAExecutionProvider' in p, f'CUDA provider missing: {p}'
print('RESULT:', ', '.join(x.replace('ExecutionProvider','') for x in p))"
    fi
fi

# ------------------------------------------------------------
# docker: engine works, containers can use the GPU
# ------------------------------------------------------------
# Pick a way to reach the Docker daemon that works in this session
DOCKER=()
docker_cmd() {
    [ ${#DOCKER[@]} -gt 0 ] && return 0
    command -v docker &>/dev/null || return 1
    if docker info &>/dev/null; then DOCKER=(docker)
    elif id -nG "$USER" | tr ' ' '\n' | grep -qx docker && sg docker -c "docker info" &>/dev/null; then DOCKER=(sg docker -c)
    elif sudo -n docker info &>/dev/null; then DOCKER=(sudo -n docker)
    else return 2; fi
}
dk() {  # dk <docker args...>
    if [ "${DOCKER[0]}" = "sg" ]; then sg docker -c "docker $(printf '%q ' "$@")"; else "${DOCKER[@]}" "$@"; fi
}

if want docker; then
    echo ""
    echo "── Docker ──"
    docker_cmd; rc=$?
    if [ $rc -eq 1 ]; then
        skip "Docker not installed (./setup.sh --server)"
    elif [ $rc -eq 2 ]; then
        skip "Docker installed but not reachable from this session (log in again for docker group, or run with sudo)"
    else
        run "Run a container" dk run --rm ubuntu:24.04 sh -c 'echo "RESULT: $(. /etc/os-release; echo $PRETTY_NAME) container ran"'
        if [ "$HAS_NVIDIA" = true ]; then
            run "GPU inside a container (--gpus all)" dk run --rm --gpus all ubuntu:24.04 \
                sh -c 'echo "RESULT: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1) visible in container"'
        fi
        run "Docker Compose plugin" dk compose version
    fi
fi

# ------------------------------------------------------------
# monitoring: metrics are actually being collected
# ------------------------------------------------------------
if want monitoring; then
    echo ""
    echo "── Monitoring ──"
    bind=$(grep -s '^MONITORING_BIND=' "$REPO_DIR/monitoring/.env" | cut -d= -f2)
    bind="${bind:-127.0.0.1}"; [ "$bind" = "0.0.0.0" ] && bind="127.0.0.1"
    prom="http://${bind}:9090"
    if ! curl -fs -m 3 "$prom/-/healthy" >/dev/null; then
        skip "Monitoring stack not running (./setup.sh --server)"
    else
        pq() { curl -fs -m 5 --data-urlencode "query=$1" "$prom/api/v1/query" | "${PY:-python3}" -c "
import json, sys
r = json.load(sys.stdin)['data']['result']
assert r, 'no samples'
print('RESULT:', sys.argv[1] % float(r[0]['value'][1]))" "$2"; }
        run "Prometheus: host metrics collected" pq 'node_memory_MemTotal_bytes / 2^30' 'RAM %.0f GiB reported'
        if [ "$HAS_NVIDIA" = true ]; then
            run "Prometheus: GPU metrics collected (DCGM)" pq 'max(DCGM_FI_DEV_GPU_TEMP)' 'GPU temperature %.0f C'
        fi
        # the comparison returns no samples when any target is down -> the test fails
        run "Prometheus: all scrape targets up" pq 'count(up) == count(up == 1)' '%.0f target(s)'
        run "Grafana: healthy" bash -c "curl -fs -m 5 http://${bind}:3000/api/health | grep -q '\"database\": *\"ok\"' && echo 'RESULT: database ok'"
    fi
fi

# ------------------------------------------------------------
# runtimes: Node and Java actually execute code
# ------------------------------------------------------------
if want runtimes; then
    echo ""
    echo "── Runtimes ──"
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
    if [ -s "$NVM_DIR/nvm.sh" ]; then
        run "Node.js: run script + npm" bash -c "source '$NVM_DIR/nvm.sh' >/dev/null 2>&1; \
            node -e 'if ([1,2,3].map(x=>x*2).join() !== \"2,4,6\") process.exit(1)' && echo \"RESULT: node \$(node -v), npm \$(npm -v)\""
    elif command -v node &>/dev/null; then
        run "Node.js: run script" bash -c 'node -e "process.exit(0)" && echo "RESULT: node $(node -v)"'
    else
        skip "Node.js not installed"
    fi
    export SDKMAN_DIR="${SDKMAN_DIR:-$HOME/.sdkman}"
    JAVA_BIN=""
    [ -x "$SDKMAN_DIR/candidates/java/current/bin/java" ] && JAVA_BIN="$SDKMAN_DIR/candidates/java/current/bin/java"
    [ -z "$JAVA_BIN" ] && command -v java &>/dev/null && JAVA_BIN="$(command -v java)"
    if [ -n "$JAVA_BIN" ]; then
        cat > "$TMP/Smoke.java" <<'JEOF'
public class Smoke {
    public static void main(String[] a) {
        int s = java.util.stream.IntStream.rangeClosed(1, 100).sum();
        if (s != 5050) System.exit(1);
        System.out.println("RESULT: java " + Runtime.version() + ", compiled and ran");
    }
}
JEOF
        run "Java: compile + run" "$JAVA_BIN" "$TMP/Smoke.java"
    else
        skip "Java not installed"
    fi
    if command -v uv &>/dev/null; then
        run "uv: create a throwaway venv" bash -c "uv venv -q '$TMP/venv' && '$TMP/venv/bin/python' -c 'print(1)' >/dev/null && echo \"RESULT: \$(uv --version)\""
    else
        skip "uv not installed"
    fi
fi

# ------------------------------------------------------------
# vllm: import always; real serving only with --full
# ------------------------------------------------------------
if want vllm; then
    echo ""
    echo "── vLLM ──"
    if [ ! -x "$VLLM_VENV/bin/python" ]; then
        skip "vLLM not installed (./setup.sh --vllm)"
    else
        run "vLLM import + CUDA" "$VLLM_VENV/bin/python" -c "
import importlib.metadata as md, torch
assert torch.cuda.is_available()
print('RESULT: vllm', md.version('vllm'), '| torch', torch.__version__)"
        if [ "$FULL" != true ]; then
            skip "vLLM serving test (run with --full; downloads a ~300MB model)"
        else
            MODEL="${SMOKE_VLLM_MODEL:-HuggingFaceTB/SmolLM2-135M-Instruct}"
            PORT="${SMOKE_VLLM_PORT:-18001}"
            "$VLLM_VENV/bin/vllm" serve "$MODEL" --host 127.0.0.1 --port "$PORT" \
                --gpu-memory-utilization "${SMOKE_VLLM_GPU_FRACTION:-0.10}" --max-model-len 2048 > "$TMP/vllm.log" 2>&1 &
            VPID=$!
            ready=false
            for _ in $(seq 1 90); do
                kill -0 "$VPID" 2>/dev/null || break
                curl -fs -m 2 "http://127.0.0.1:$PORT/health" >/dev/null && { ready=true; break; }
                sleep 2
            done
            if [ "$ready" = true ]; then
                run "vLLM: serve $MODEL and answer a chat completion" bash -c "
                    curl -fs -m 60 http://127.0.0.1:$PORT/v1/chat/completions -H 'Content-Type: application/json' \
                      -d '{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello.\"}],\"max_tokens\":16}' \
                    | '$PY' -c \"
import json, sys
r = json.load(sys.stdin)
t = r['choices'][0]['message']['content'].strip()
assert t, 'empty completion'
print('RESULT:', r['usage']['completion_tokens'], 'tokens generated')\""
            else
                fail "vLLM: server did not become ready within 3 min"
                tail -5 "$TMP/vllm.log" | sed 's/^/           /'
            fi
            kill "$VPID" 2>/dev/null; wait "$VPID" 2>/dev/null
        fi
    fi
fi

# ------------------------------------------------------------
echo ""
echo "Summary: $N_PASS passed, $N_FAIL failed, $N_SKIP skipped"
if [ "$N_FAIL" -gt 0 ]; then
    printf '  failed: %s\n' "${FAILED[@]}"
    exit 1
fi
exit 0
