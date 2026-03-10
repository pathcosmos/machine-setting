#!/usr/bin/env bash
# Verify AI environment: GPU, CUDA, key packages
# Usage: bash scripts/check-env.sh [venv-path]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# Detect venv path
VENV_PATH="${1:-${VIRTUAL_ENV:-$HOME/ai-env}}"
PY="$VENV_PATH/bin/python"

if [ ! -f "$PY" ]; then
    echo "Error: No venv found at $VENV_PATH"
    echo "Run: $REPO_DIR/scripts/setup-venv.sh"
    exit 1
fi

echo "=== AI Environment Check ==="
echo "  Venv: $VENV_PATH"
echo "  Python: $("$PY" --version 2>&1)"
echo ""

# Package count
TOTAL=$(uv pip list --python "$PY" 2>/dev/null | tail -n +3 | wc -l || echo "?")
echo "  Installed packages: $TOTAL"
echo ""

# Core checks
echo "--- Core Packages ---"
"$PY" -c "
import sys

def check(pkg, import_name=None):
    name = import_name or pkg
    try:
        m = __import__(name)
        v = getattr(m, '__version__', 'ok')
        print(f'  OK  {pkg} {v}')
        return True
    except ImportError:
        print(f'  MISS {pkg}')
        return False

ok = True
ok &= check('transformers')
ok &= check('datasets')
ok &= check('accelerate')
ok &= check('peft')
ok &= check('trl')
ok &= check('wandb')
ok &= check('sentencepiece')
ok &= check('numpy')

if not ok:
    print()
    print('Some core packages are missing.')
" 2>/dev/null

echo ""
echo "--- GPU Packages ---"
"$PY" -c "
import torch
backends = []
if torch.cuda.is_available():
    backends.append(f'CUDA {torch.version.cuda}')
    backends.append(f'{torch.cuda.device_count()} GPU(s)')
    backends.append(torch.cuda.get_device_name(0))
if hasattr(torch.backends, 'mps') and torch.backends.mps.is_available():
    backends.append('MPS (Apple Silicon)')
if not backends:
    backends.append('CPU only')
print(f'  torch {torch.__version__} ({", ".join(backends)})')
" 2>/dev/null || echo "  torch: not installed"

"$PY" -c "import flash_attn; print(f'  flash_attn {flash_attn.__version__}')" 2>/dev/null || echo "  flash_attn: not installed (GPU-only)"
"$PY" -c "import transformer_engine as te; print(f'  transformer_engine {te.__version__}')" 2>/dev/null || echo "  transformer_engine: not installed (NGC-only)"
"$PY" -c "import bitsandbytes; print(f'  bitsandbytes {bitsandbytes.__version__}')" 2>/dev/null || echo "  bitsandbytes: not installed"
"$PY" -c "import triton; print(f'  triton {triton.__version__}')" 2>/dev/null || echo "  triton: not installed"

echo ""

# NV symlink check
if [ -L "$VENV_PATH/lib/python"*"/site-packages/torch" ] 2>/dev/null; then
    echo "--- NV Symlinks ---"
    SITE=$("$PY" -c "import site; print(site.getsitepackages()[0])")
    for pkg in torch torchvision torchaudio flash_attn transformer_engine triton; do
        if [ -L "$SITE/$pkg" ]; then
            TARGET=$(readlink "$SITE/$pkg")
            echo "  $pkg -> $TARGET"
        fi
    done
    echo ""
fi

echo "=== Check Complete ==="
