#!/usr/bin/env bash
# Create venv and install packages based on hardware profile
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PKG_DIR="$REPO_DIR/packages"

# --- Load config ---
source "$REPO_DIR/config/default.conf"
[ -f "$REPO_DIR/config/machine.conf" ] && source "$REPO_DIR/config/machine.conf"

# --- Parse arguments ---
VENV_PATH="$VENV_DEFAULT_PATH"
PROFILE_FILE=""
NV_LINK="${NV_LINK:-false}"
NV_LINK_PACKAGES="${NV_LINK_PACKAGES:-torch torchvision torchaudio triton flash_attn transformer_engine}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --global)   VENV_PATH="$HOME/ai-env"; shift ;;
        --local)    VENV_PATH="./.venv"; shift ;;
        --path)     VENV_PATH="$2"; shift 2 ;;
        --python)   PYTHON_VERSION="$2"; shift 2 ;;
        --profile)  PROFILE_FILE="$REPO_DIR/profiles/$2.conf"; shift 2 ;;
        --nv-link)  NV_LINK=true; shift ;;
        *)          echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Load profile if specified
if [ -n "$PROFILE_FILE" ] && [ -f "$PROFILE_FILE" ]; then
    source "$PROFILE_FILE"
fi

# --- Load hardware profile ---
HW_PROFILE="$HOME/.machine_setting_profile"
if [ ! -f "$HW_PROFILE" ]; then
    echo "Running hardware detection..."
    bash "$SCRIPT_DIR/detect-hardware.sh" "$HW_PROFILE"
fi
source "$HW_PROFILE"

echo "=== Virtual Environment Setup ==="
echo "  Path: $VENV_PATH"
echo "  Python: $PYTHON_VERSION"
echo "  Hardware: GPU=$HAS_GPU Backend=${GPU_BACKEND:-none} Suffix=$CUDA_SUFFIX"

# --- Create venv ---
if [ -d "$VENV_PATH" ]; then
    echo ""
    if [ -t 0 ]; then
        # Interactive: ask user
        read -rp "  Venv already exists at $VENV_PATH. Recreate? [y/N]: " RECREATE
        if [[ "$RECREATE" =~ ^[Yy]$ ]]; then
            rm -rf "$VENV_PATH"
        else
            echo "  Keeping existing venv. Installing missing packages only."
        fi
    else
        # Non-interactive: keep existing
        echo "  Venv exists at $VENV_PATH. Keeping (non-interactive mode)."
    fi
fi

if [ ! -d "$VENV_PATH" ]; then
    echo "  Creating venv..."
    uv venv "$VENV_PATH" --python "$PYTHON_VERSION"
fi

# Use uv pip for installation
UV_PIP="uv pip"
INSTALL_ARGS="--python $VENV_PATH/bin/python"

# --- Install package groups ---
for group in $PACKAGE_GROUPS; do
    REQ_FILE="$PKG_DIR/requirements-${group}.txt"
    if [ -f "$REQ_FILE" ]; then
        echo ""
        echo "  Installing $group packages..."

        # cx-Oracle requires setuptools at build time (uv build isolation issue)
        if grep -q "cx-Oracle" "$REQ_FILE" 2>/dev/null; then
            $UV_PIP install $INSTALL_ARGS setuptools 2>&1 | tail -1
            $UV_PIP install $INSTALL_ARGS cx-Oracle --no-build-isolation 2>&1 | tail -1
        fi

        $UV_PIP install $INSTALL_ARGS -r "$REQ_FILE" 2>&1 | tail -1
    else
        echo "  Warning: $REQ_FILE not found, skipping"
    fi
done

# --- GPU/CPU packages (platform-dependent) ---
echo ""
GPU_BACKEND="${GPU_BACKEND:-none}"

if [ "$NV_LINK" = true ] && [ "$GPU_BACKEND" = "cuda" ]; then
    # NGC container mode: skip PyPI GPU packages, will symlink NV builds later
    echo "  NV link mode: skipping PyPI GPU packages (will symlink system builds)"

elif [ "$GPU_BACKEND" = "cuda" ] && [ -f "$PKG_DIR/requirements-gpu.txt" ]; then
    # Linux NVIDIA: install CUDA-specific wheels
    INDEX_URL=""
    while IFS='=' read -r key val; do
        [ -z "$key" ] || [[ "$key" =~ ^# ]] && continue
        if [ "$key" = "$CUDA_SUFFIX" ]; then
            INDEX_URL="$val"
            break
        fi
    done < "$REPO_DIR/config/gpu-index-urls.conf"

    if [ -n "$INDEX_URL" ]; then
        echo "  Installing GPU packages (CUDA $CUDA_VERSION, index: $INDEX_URL)..."
        $UV_PIP install $INSTALL_ARGS -r "$PKG_DIR/requirements-gpu.txt" \
            --index-url "$INDEX_URL" \
            --extra-index-url "https://pypi.org/simple" 2>&1 | tail -1
    else
        echo "  Warning: No index URL found for $CUDA_SUFFIX, skipping GPU packages"
    fi

elif [ "$GPU_BACKEND" = "mps" ] && [ -f "$PKG_DIR/requirements-mps.txt" ]; then
    # macOS Apple Silicon: standard PyTorch includes MPS
    echo "  Installing MPS packages (Apple Silicon)..."
    $UV_PIP install $INSTALL_ARGS -r "$PKG_DIR/requirements-mps.txt" 2>&1 | tail -1

elif [ -f "$PKG_DIR/requirements-cpu.txt" ]; then
    # CPU-only fallback
    echo "  Installing CPU packages..."
    $UV_PIP install $INSTALL_ARGS -r "$PKG_DIR/requirements-cpu.txt" --index-url "https://download.pytorch.org/whl/cpu" 2>&1 | tail -1
fi

# --- NV Custom Build Symlinks (NGC container mode) ---
if [ "$NV_LINK" = true ]; then
    echo ""
    echo "  Linking NV custom packages from system site-packages..."

    VENV_SITE=$("$VENV_PATH/bin/python" -c "import site; print(site.getsitepackages()[0])")
    # Detect system site-packages
    SYS_PYTHON=$(command -v python3 || true)
    SYS_SITE=""
    if [ -n "$SYS_PYTHON" ]; then
        SYS_SITE=$("$SYS_PYTHON" -c "import site; print(site.getsitepackages()[0])" 2>/dev/null || true)
    fi
    # Debian/Ubuntu fallback
    if [ -z "$SYS_SITE" ] || [ ! -d "$SYS_SITE" ]; then
        SYS_PY_VER=$("$SYS_PYTHON" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || echo "$PYTHON_VERSION")
        for candidate in "/usr/local/lib/python${SYS_PY_VER}/dist-packages" "/usr/lib/python3/dist-packages"; do
            if [ -d "$candidate" ]; then
                SYS_SITE="$candidate"
                break
            fi
        done
    fi

    if [ -z "$SYS_SITE" ] || [ ! -d "$SYS_SITE" ]; then
        echo "  Warning: Could not detect system site-packages. Skipping NV link."
    else
        echo "  System site-packages: $SYS_SITE"
        LINKED=0
        for pkg in $NV_LINK_PACKAGES; do
            if [ -d "$SYS_SITE/$pkg" ]; then
                # Remove pip-installed version if exists (to replace with symlink)
                [ -d "$VENV_SITE/$pkg" ] && [ ! -L "$VENV_SITE/$pkg" ] && rm -rf "$VENV_SITE/$pkg"
                ln -sfn "$SYS_SITE/$pkg" "$VENV_SITE/$pkg"
                # Also link dist-info directories
                for dist_info in "$SYS_SITE"/${pkg}-*.dist-info "$SYS_SITE"/${pkg//_/-}-*.dist-info; do
                    if [ -d "$dist_info" ]; then
                        ln -sfn "$dist_info" "$VENV_SITE/$(basename "$dist_info")"
                    fi
                done
                LINKED=$((LINKED + 1))
                echo "    Linked: $pkg"
            else
                echo "    Skip: $pkg (not in system)"
            fi
        done
        echo "  Linked $LINKED NV packages"
    fi
fi

# --- Verify ---
echo ""
TOTAL=$(uv pip list --python "$VENV_PATH/bin/python" 2>/dev/null | tail -n +3 | wc -l)
echo "  Installed: $TOTAL packages"

# Quick sanity checks
echo "  Verifying key packages..."
"$VENV_PATH/bin/python" -c "
import torch
backends = []
if hasattr(torch.backends, 'mps') and torch.backends.mps.is_available():
    backends.append('MPS')
if torch.cuda.is_available():
    backends.append(f'CUDA {torch.version.cuda}')
if not backends:
    backends.append('CPU only')
print(f'    torch {torch.__version__} ({", ".join(backends)})')
" 2>/dev/null || echo "    torch: not installed"
"$VENV_PATH/bin/python" -c "import transformers; print(f'    transformers {transformers.__version__}')" 2>/dev/null || echo "    transformers: not installed"
"$VENV_PATH/bin/python" -c "import anthropic; print(f'    anthropic {anthropic.__version__}')" 2>/dev/null || echo "    anthropic: not installed"

echo ""
echo "Done! Activate with: source $VENV_PATH/bin/activate"
