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
echo "--- GPU Stack ---"
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
print(f'  torch {torch.__version__} ({\", \".join(backends)})')

# cuDNN status
if torch.backends.cudnn.is_available():
    print(f'  cuDNN {torch.backends.cudnn.version()} (enabled={torch.backends.cudnn.enabled})')
else:
    print(f'  cuDNN not available')

# NCCL status
try:
    v = torch.cuda.nccl.version()
    print(f'  NCCL {v[0]}.{v[1]}.{v[2]}')
except:
    print(f'  NCCL not available')
" 2>/dev/null || echo "  torch: not installed"

echo ""
echo "--- GPU Packages ---"
"$PY" -c "import flash_attn; print(f'  flash_attn {flash_attn.__version__}')" 2>/dev/null || echo "  flash_attn: not installed (GPU-only)"
"$PY" -c "import transformer_engine as te; print(f'  transformer_engine {te.__version__}')" 2>/dev/null || echo "  transformer_engine: not installed (NGC-only)"
"$PY" -c "import bitsandbytes; print(f'  bitsandbytes {bitsandbytes.__version__}')" 2>/dev/null || echo "  bitsandbytes: not installed"
"$PY" -c "import triton; print(f'  triton {triton.__version__}')" 2>/dev/null || echo "  triton: not installed"
"$PY" -c "import vllm; print(f'  vllm {vllm.__version__}')" 2>/dev/null || echo "  vllm: not installed"
"$PY" -c "import deepspeed; print(f'  deepspeed {deepspeed.__version__}')" 2>/dev/null || echo "  deepspeed: not installed"

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

# GPU functional test
"$PY" -c "
import torch
if torch.cuda.is_available():
    print('--- GPU Functional Test ---')
    # matmul
    a = torch.randn(512, 512, device='cuda')
    b = torch.randn(512, 512, device='cuda')
    c = torch.mm(a, b)
    print(f'  matmul (512x512): OK')

    # cuDNN conv2d
    conv = torch.nn.Conv2d(3, 64, 3, padding=1).cuda()
    x = torch.randn(1, 3, 64, 64, device='cuda')
    _ = conv(x)
    print(f'  cuDNN conv2d:     OK')

    # Memory
    props = torch.cuda.get_device_properties(0)
    print(f'  GPU memory:       {props.total_memory / 1024**3:.1f} GB')
    print(f'  Compute cap:      {torch.cuda.get_device_capability(0)}')

    torch.cuda.empty_cache()
    del a, b, c, conv, x
" 2>/dev/null || true

echo ""

# Environment info
echo "--- Environment ---"
if [ -f /.dockerenv ] || grep -qsE '(docker|containerd|kubepods)' /proc/1/cgroup 2>/dev/null; then
    echo "  Container: yes"
fi
if [ -x /usr/local/cuda/bin/nvcc ] && grep -q "^#!/bin/sh" /usr/local/cuda/bin/nvcc 2>/dev/null; then
    echo "  nvcc: stub (runtime only, no JIT compile)"
elif command -v nvcc &>/dev/null; then
    echo "  nvcc: $(nvcc --version 2>/dev/null | sed -n 's/.*release \([0-9]*\.[0-9]*\).*/\1/p')"
else
    echo "  nvcc: not found"
fi
if [ "$(uname -s)" = "Linux" ] && ! ldconfig -p 2>/dev/null | grep -q libGL.so.1; then
    echo "  Display: headless (no libGL)"
fi
echo ""

echo "=== Check Complete ==="
