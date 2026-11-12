#!/usr/bin/env bash
# post-install-verify.sh — Close the install cycle: reboot status -> GPU-dependent parts -> functional test.
#
# setup.sh runs this at the end. When setup had to ask for a reboot it leaves a marker instead, and
# you run this after logging back in:   ./setup.sh --verify
#
# Steps:
#   1. Reboot check   — stops here (exit 10) while a reboot is still pending
#   2. Finish parts that need a loaded NVIDIA driver (hardware profile, GPU metrics exporter)
#   3. Functional test (scripts/smoke-test.sh): GPU compute, cuDNN, Docker + GPU container,
#      monitoring metrics, Node/Java/uv, vLLM
#   4. Points to the long GPU burn-in if this GPU has never passed one
#
# Usage:
#   ./scripts/post-install-verify.sh           # all steps
#   ./scripts/post-install-verify.sh --full    # functional test including real vLLM serving
#   ./scripts/post-install-verify.sh --no-fix  # do not touch anything (skip step 2), just test
# Exit: 0 = verified, 1 = a test failed, 10 = reboot first.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
[ -f "$HOME/.machine_setting_profile" ] && source "$HOME/.machine_setting_profile"
source "$REPO_DIR/config/default.conf"
[ -f "$REPO_DIR/config/machine.conf" ] && source "$REPO_DIR/config/machine.conf"

PENDING_FILE="$HOME/.machine_setting/verify-pending"
SMOKE_ARGS=(); FIX=true; FROM_SETUP=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --full)       SMOKE_ARGS+=(--full); shift ;;
        --no-fix)     FIX=false; shift ;;
        --from-setup) FROM_SETUP=true; shift ;;
        --help|-h)    sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

echo "=== Post-install verification ==="

# ---- 1. reboot status ----
echo ""
echo "── 1. Reboot status ──"
OUT=$(bash "$SCRIPT_DIR/reboot-check.sh"); RC=$?
echo "$OUT"
if [ "$RC" -eq 10 ]; then
    mkdir -p "$(dirname "$PENDING_FILE")"; [ -f "$PENDING_FILE" ] || date -Iseconds > "$PENDING_FILE"
    echo ""
    echo "  A reboot is still pending, so the GPU cannot be verified yet."
    echo "  Run 'sudo reboot', log back in, then: $REPO_DIR/setup.sh --verify"
    exit 10
fi

# ---- 2. parts that needed the driver to be loaded ----
HAS_NVIDIA=false
command -v nvidia-smi &>/dev/null && nvidia-smi -L &>/dev/null && HAS_NVIDIA=true
if [ "$FIX" = true ] && [ "$HAS_NVIDIA" = true ]; then
    echo ""
    echo "── 2. GPU-dependent parts ──"
    did=false
    # Hardware profile written before the driver/toolkit existed (no CUDA build suffix yet)
    if [[ "${CUDA_SUFFIX:-}" != cu* ]] || [ "${GPU_BACKEND:-none}" != "cuda" ]; then
        echo "  Refreshing hardware profile (GPU is now visible)..."
        bash "$SCRIPT_DIR/detect-hardware.sh" "$HOME/.machine_setting_profile" >/dev/null && source "$HOME/.machine_setting_profile"
        echo "  [OK]    GPU backend: ${GPU_BACKEND:-?}, PyTorch build: ${CUDA_SUFFIX:-?}"
        did=true
    fi
    # Monitoring was deployed before the reboot without the GPU exporter
    bind=$(grep -s '^MONITORING_BIND=' "$REPO_DIR/monitoring/.env" | cut -d= -f2 || true)
    bind="${bind:-127.0.0.1}"; [ "$bind" = "0.0.0.0" ] && bind="127.0.0.1"
    if curl -fs -m 3 "http://$bind:9090/-/healthy" >/dev/null 2>&1; then
        if ! curl -fs -m 5 --data-urlencode 'query=DCGM_FI_DEV_GPU_TEMP' "http://$bind:9090/api/v1/query" 2>/dev/null | grep -q '"value"'; then
            echo "  GPU metrics are not being collected — enabling the GPU exporter (sudo)..."
            if bash "$SCRIPT_DIR/install-server.sh" --only monitoring; then
                echo "  Waiting for the first GPU scrape..."
                for _ in $(seq 1 12); do
                    curl -fs -m 5 --data-urlencode 'query=DCGM_FI_DEV_GPU_TEMP' "http://$bind:9090/api/v1/query" 2>/dev/null | grep -q '"value"' && break
                    sleep 5
                done
            else
                echo "  [WARN]  Could not enable the GPU exporter — run: ./setup.sh --server --only monitoring"
            fi
            did=true
        fi
    fi
    [ "$did" = false ] && echo "  [OK]    Nothing left to finish"
fi

# ---- 3. functional test ----
echo ""
echo "── 3. Functional test ──"
bash "$SCRIPT_DIR/smoke-test.sh" "${SMOKE_ARGS[@]}"
TEST_RC=$?

echo ""
if [ "$TEST_RC" -eq 0 ]; then
    rm -f "$PENDING_FILE"
    echo "  [OK]    Installation verified."
    if [ "$RC" -eq 11 ]; then
        echo "  Note:   tests that need the new group membership were skipped — log out and back in, then run 'make test'."
    fi
    if [ "$HAS_NVIDIA" = true ] && ! grep -qs '"verdict": "PASS"' "$HOME"/.machine_setting/burnin/*/gpu*/summary.json 2>/dev/null; then
        echo "  Next:   this GPU has not passed a long burn-in yet. Before putting it into service:"
        echo "            make burnin          (6 hours in the background; 'make burnin-status' to follow)"
        echo "            ./scripts/gpu-burnin.sh --quick   (10-minute check)"
    fi
else
    mkdir -p "$(dirname "$PENDING_FILE")"; [ -f "$PENDING_FILE" ] || date -Iseconds > "$PENDING_FILE"
    echo "  [FAIL]  Some tests failed (see above). Fix, then run: ./setup.sh --verify"
    echo "          Diagnose: make doctor      Auto-repair: ./setup.sh --recover"
fi
exit "$TEST_RC"
