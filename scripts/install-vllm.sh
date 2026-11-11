#!/usr/bin/env bash
# install-vllm.sh — vLLM (LLM inference server) in its OWN virtual environment
#
# Why separate: vLLM pins torch/torchvision/torchaudio/numba to exact versions (e.g. vllm 0.33.0 ->
# torch==2.14.0). Installing it into the main AI env would downgrade torch and everything built on it.
#
# Usage:
#   ./scripts/install-vllm.sh                 # install / upgrade to VLLM_VERSION (default: latest)
#   ./scripts/install-vllm.sh --version 0.33.0
#   ./scripts/install-vllm.sh --path ~/vllm-env
#   ./scripts/install-vllm.sh --check         # show status only
#   ./scripts/install-vllm.sh --uninstall     # remove the vLLM venv
#
# No sudo. Called from: setup.sh (--vllm, or INSTALL_VLLM=true in config/profile).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

[ -f "$HOME/.machine_setting_profile" ] && source "$HOME/.machine_setting_profile"
source "$REPO_DIR/config/default.conf"
[ -f "$REPO_DIR/config/machine.conf" ] && source "$REPO_DIR/config/machine.conf"

VENV_PATH="${VLLM_VENV_PATH:-$HOME/vllm-env}"
VERSION="${VLLM_VERSION:-}"
PY_VERSION="${VLLM_PYTHON_VERSION:-${PYTHON_VERSION:-3.12}}"
MODE="install"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)   VERSION="$2"; shift 2 ;;
        --path)      VENV_PATH="$2"; shift 2 ;;
        --python)    PY_VERSION="$2"; shift 2 ;;
        --check)     MODE="check"; shift ;;
        --uninstall) MODE="uninstall"; shift ;;
        --help|-h)   sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

export PATH="$HOME/.local/bin:$PATH"

vllm_status() {
    if [ ! -x "$VENV_PATH/bin/python" ]; then
        echo "  vLLM: not installed ($VENV_PATH missing)"
        return 1
    fi
    "$VENV_PATH/bin/python" - <<'PYEOF' 2>/dev/null || { echo "  vLLM: venv exists but vllm/torch not importable"; return 1; }
import importlib.metadata as md, warnings
warnings.filterwarnings("ignore")
import torch
print(f"  vLLM {md.version('vllm')}  |  torch {torch.__version__}  |  CUDA available: {torch.cuda.is_available()}")
PYEOF
}

if [ "$MODE" = "check" ]; then
    vllm_status
    exit $?
fi

if [ "$MODE" = "uninstall" ]; then
    if [ -d "$VENV_PATH" ] && [ -f "$VENV_PATH/pyvenv.cfg" ]; then
        rm -rf "$VENV_PATH"
        echo "  Removed $VENV_PATH"
    else
        echo "  Nothing to remove at $VENV_PATH"
    fi
    exit 0
fi

echo "=== vLLM Setup ==="

if [ "$(uname -s)" != "Linux" ]; then
    echo "  [SKIP] vLLM supports Linux only"
    exit 0
fi
if [ "${GPU_BACKEND:-none}" != "cuda" ]; then
    echo "  [SKIP] vLLM needs an NVIDIA GPU (detected backend: ${GPU_BACKEND:-none})"
    exit 0
fi
if ! command -v uv &>/dev/null; then
    echo "  [ERROR] uv not found — run scripts/install-python.sh first"
    exit 1
fi

SPEC="vllm"
[ -n "$VERSION" ] && SPEC="vllm==$VERSION"
echo "  Path: $VENV_PATH"
echo "  Package: $SPEC (Python $PY_VERSION)"

if [ ! -x "$VENV_PATH/bin/python" ]; then
    uv venv "$VENV_PATH" --python "$PY_VERSION" 2>&1 | tail -1
fi

# vLLM pins an exact torch release, and not every PyTorch CUDA index carries it (e.g. torch 2.14.0
# exists for cu130 but not cu132). Try the system's CUDA build first, then older ones; a build for
# an older CUDA minor still runs on a newer driver. (`--torch-backend auto` is avoided: it can mix
# +cuXXX torch with a +cpu torchaudio.)
CANDIDATES=()
[[ "${CUDA_SUFFIX:-}" == cu* ]] && CANDIDATES+=("$CUDA_SUFFIX")
while read -r s; do
    [[ " ${CANDIDATES[*]} " == *" $s "* ]] && continue
    # only builds at or below the system CUDA version
    if [[ "${CUDA_SUFFIX:-}" != cu* ]] || [ "${s#cu}" -le "${CUDA_SUFFIX#cu}" ]; then
        CANDIDATES+=("$s")
    fi
done < <(grep -oE '^cu[0-9]+' "$REPO_DIR/config/gpu-index-urls.conf" | sort -t u -k2 -rn)

INSTALLED_BACKEND=""
for backend in "${CANDIDATES[@]}"; do
    echo "  Trying PyTorch build: $backend ..."
    if uv pip install --python "$VENV_PATH/bin/python" --upgrade "$SPEC" --torch-backend "$backend" > "$VENV_PATH/.install.log" 2>&1; then
        INSTALLED_BACKEND="$backend"
        break
    fi
    echo "    not available for $backend ($(grep -m1 -iE 'no solution|not found|unsatisfiable|error' "$VENV_PATH/.install.log" | cut -c1-110))"
done

if [ -z "$INSTALLED_BACKEND" ]; then
    echo "  [ERROR] Could not install $SPEC with any of: ${CANDIDATES[*]}"
    echo "          Last log: $VENV_PATH/.install.log"
    exit 1
fi

echo "  Installed with PyTorch build: $INSTALLED_BACKEND"
vllm_status || true
echo ""
echo "  Activate:  vllmenv            (or: source $VENV_PATH/bin/activate)"
echo "  Serve:     vllm serve <hf-model-id> --host 127.0.0.1 --port 8001"
