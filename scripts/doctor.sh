#!/usr/bin/env bash
# doctor.sh — Health Check & Recovery for machine_setting
# Usage:
#   ./scripts/doctor.sh                    # Full health check
#   ./scripts/doctor.sh --recover          # Auto-recover broken items
#   ./scripts/doctor.sh --recover python   # Recover specific component
#   ./scripts/doctor.sh --verify-packages  # Package integrity check
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PKG_DIR="$REPO_DIR/packages"

# --- Load checkpoint library ---
source "$SCRIPT_DIR/lib-checkpoint.sh"

# --- Load config ---
source "$REPO_DIR/config/default.conf"
[ -f "$REPO_DIR/config/machine.conf" ] && source "$REPO_DIR/config/machine.conf"
[ -f "$HOME/.machine_setting_profile" ] && source "$HOME/.machine_setting_profile"

# --- Parse arguments ---
MODE="check"       # check | recover | verify
RECOVER_TARGET=""   # empty = all failed, or specific component name

while [[ $# -gt 0 ]]; do
    case "$1" in
        --recover)
            MODE="recover"
            shift
            # Optional: specific component
            if [[ $# -gt 0 ]] && [[ "$1" != --* ]]; then
                RECOVER_TARGET="$1"
                shift
            fi
            ;;
        --verify-packages)
            MODE="verify"
            shift
            ;;
        --help|-h)
            echo "Usage: ./scripts/doctor.sh [options]"
            echo ""
            echo "  (no args)              Full health check"
            echo "  --recover [component]  Auto-recover (all or specific)"
            echo "  --verify-packages      Verify installed packages vs requirements"
            echo ""
            echo "Components: disk, hardware, nvidia, uv, python, venv, packages, node, java, shell, platform"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# --- Status counters ---
COUNT_OK=0
COUNT_FAIL=0
COUNT_WARN=0
COUNT_SKIP=0
FAILED_COMPONENTS=()

# --- Output helpers ---
status_ok()   { echo "  [OK]   $1"; COUNT_OK=$((COUNT_OK + 1)); }
status_fail() { echo "  [FAIL] $1"; COUNT_FAIL=$((COUNT_FAIL + 1)); FAILED_COMPONENTS+=("$2"); }
status_warn() { echo "  [WARN] $1"; COUNT_WARN=$((COUNT_WARN + 1)); }
status_skip() { echo "  [SKIP] $1"; COUNT_SKIP=$((COUNT_SKIP + 1)); }

# --- Read state ---
STATE_VENV_PATH=$(checkpoint_read_key "VENV_PATH")
STATE_PYTHON_VERSION=$(checkpoint_read_key "PYTHON_VERSION")
VENV_PATH="${STATE_VENV_PATH:-${VENV_DEFAULT_PATH:-$HOME/ai-env}}"
PYTHON_VER="${STATE_PYTHON_VERSION:-${PYTHON_VERSION:-3.12}}"

# ============================================================
# Health Check Functions
# ============================================================

check_disk_space() {
    local target_dir
    target_dir=$(dirname "$VENV_PATH")
    [ ! -d "$target_dir" ] && target_dir="$HOME"

    local avail_kb
    avail_kb=$(df -k "$target_dir" | awk 'NR==2 {print $4}')

    local avail_gb=$(( avail_kb / 1048576 ))
    local avail_mb=$(( avail_kb / 1024 ))

    if [ "$avail_mb" -lt 1024 ]; then
        status_fail "Disk space (${avail_mb}MB free — need at least 1GB)" "disk"
    else
        status_ok "Disk space (${avail_gb}GB free)"
    fi
}

check_hardware_profile() {
    local profile="$HOME/.machine_setting_profile"
    if [ ! -f "$profile" ]; then
        status_fail "Hardware profile (missing: $profile)" "hardware"
        return
    fi
    # Validate that key variables are present
    if grep -q "^HAS_GPU=" "$profile" && grep -q "^GPU_BACKEND=" "$profile"; then
        status_ok "Hardware profile"
    else
        status_fail "Hardware profile (corrupted: missing required variables)" "hardware"
    fi
}

check_uv() {
    if command -v uv &>/dev/null; then
        local ver
        ver=$(uv --version 2>/dev/null | head -1)
        status_ok "uv ($ver)"
    else
        status_fail "uv (not installed)" "uv"
    fi
}

check_python() {
    if command -v uv &>/dev/null; then
        local python_bin
        python_bin=$(uv python find "$PYTHON_VER" 2>/dev/null || true)
        if [ -n "$python_bin" ] && [ -x "$python_bin" ]; then
            local actual_ver
            actual_ver=$("$python_bin" --version 2>/dev/null)
            status_ok "Python ($actual_ver)"
        else
            status_fail "Python $PYTHON_VER (not found via uv)" "python"
        fi
    else
        # Fallback: check system python
        if command -v "python${PYTHON_VER}" &>/dev/null || command -v python3 &>/dev/null; then
            status_warn "Python (system python found, but uv-managed not available)"
        else
            status_fail "Python $PYTHON_VER (not found)" "python"
        fi
    fi
}

check_venv() {
    if [ ! -d "$VENV_PATH" ]; then
        status_fail "Virtual environment (missing: $VENV_PATH)" "venv"
        return
    fi
    if [ ! -x "$VENV_PATH/bin/python" ]; then
        status_fail "Virtual environment (broken: missing bin/python)" "venv"
        return
    fi
    if [ ! -f "$VENV_PATH/bin/activate" ]; then
        status_fail "Virtual environment (broken: missing bin/activate)" "venv"
        return
    fi
    local pkg_count
    pkg_count=$(uv pip list --python "$VENV_PATH/bin/python" 2>/dev/null | tail -n +3 | wc -l | tr -d ' ')
    status_ok "Virtual environment ($VENV_PATH, ${pkg_count} packages)"
}

check_key_packages() {
    if [ ! -x "$VENV_PATH/bin/python" ]; then
        status_skip "Key packages (no venv)"
        return
    fi

    local tmp_script result
    tmp_script=$(mktemp /tmp/doctor_pkg_XXXXXX.py)
    cat > "$tmp_script" << 'PYEOF'
import warnings; warnings.filterwarnings("ignore")
pkgs = [
    ("torch", "torch"), ("transformers", "transformers"), ("anthropic", "anthropic"),
    ("openai", "openai"), ("langchain", "langchain"), ("datasets", "datasets"),
    ("accelerate", "accelerate"), ("peft", "peft"), ("trl", "trl"),
    ("sentence_transformers", "sentence_transformers"),
    ("fastapi", "fastapi"), ("flask", "flask"), ("gradio", "gradio"),
    ("pandas", "pandas"), ("numpy", "numpy"), ("scipy", "scipy"),
    ("sklearn", "sklearn"), ("pydantic", "pydantic"),
    ("httpx", "httpx"), ("aiohttp", "aiohttp"), ("boto3", "boto3"),
    ("sqlalchemy", "sqlalchemy"), ("requests", "requests"),
    ("PIL", "PIL"), ("cv2", "cv2"),
    ("wandb", "wandb"),
]
ok = 0
fail_list = []
for name, mod in pkgs:
    try:
        __import__(mod)
        ok += 1
    except Exception:
        fail_list.append(name)
total = len(pkgs)
if fail_list:
    shown = ", ".join(fail_list[:5])
    suffix = "..." if len(fail_list) > 5 else ""
    print(f"FAIL {ok}/{total} (missing: {shown}{suffix})")
else:
    print(f"OK {ok}/{total}")
PYEOF
    result=$("$VENV_PATH/bin/python" "$tmp_script" 2>/dev/null) || result="FAIL 0/0 (cannot run python)"
    rm -f "$tmp_script"

    if [[ "$result" == OK* ]]; then
        status_ok "Key packages ($result)"
    else
        status_warn "Key packages ($result)"
    fi
}

check_gpu_packages() {
    if [ ! -x "$VENV_PATH/bin/python" ]; then
        return
    fi
    if [ "${HAS_GPU:-false}" != "true" ] || [ "${GPU_BACKEND:-none}" != "cuda" ]; then
        return
    fi

    local tmp_script result
    tmp_script=$(mktemp /tmp/doctor_gpu_XXXXXX.py)
    cat > "$tmp_script" << 'PYEOF'
import warnings; warnings.filterwarnings("ignore")
pkgs = [
    ("vllm", "vllm"), ("deepspeed", "deepspeed"), ("bitsandbytes", "bitsandbytes"),
    ("pytorch_lightning", "pytorch_lightning"), ("optimum", "optimum"),
    ("chromadb", "chromadb"), ("triton", "triton"),
]
ok = 0
fail_list = []
for name, mod in pkgs:
    try:
        __import__(mod)
        ok += 1
    except Exception:
        fail_list.append(name)
total = len(pkgs)
if fail_list:
    print(f"FAIL {ok}/{total} (missing: {', '.join(fail_list)})")
else:
    print(f"OK {ok}/{total}")
PYEOF
    result=$("$VENV_PATH/bin/python" "$tmp_script" 2>/dev/null) || result="FAIL 0/0"
    rm -f "$tmp_script"

    if [[ "$result" == OK* ]]; then
        status_ok "GPU packages ($result)"
    else
        status_warn "GPU packages ($result)"
    fi
}

check_gpu_functional() {
    if [ ! -x "$VENV_PATH/bin/python" ]; then
        return
    fi
    if [ "${HAS_GPU:-false}" != "true" ] || [ "${GPU_BACKEND:-none}" != "cuda" ]; then
        return
    fi

    local tmp_script result
    tmp_script=$(mktemp /tmp/doctor_func_XXXXXX.py)
    cat > "$tmp_script" << 'PYEOF'
import warnings; warnings.filterwarnings("ignore")
import torch
errors = []

if not torch.cuda.is_available():
    errors.append("CUDA not available")
else:
    try:
        a = torch.randn(256, 256, device="cuda")
        b = torch.randn(256, 256, device="cuda")
        c = torch.mm(a, b)
        del a, b, c
    except Exception as e:
        errors.append("matmul: " + str(e))

    if not torch.backends.cudnn.enabled:
        errors.append("cuDNN disabled")
    else:
        try:
            conv = torch.nn.Conv2d(3, 16, 3, padding=1).cuda()
            x = torch.randn(1, 3, 32, 32, device="cuda")
            _ = conv(x)
            del conv, x
        except Exception as e:
            errors.append("cuDNN conv: " + str(e))

    try:
        if not torch.cuda.nccl.is_available(torch.randn(1).cuda()):
            errors.append("NCCL not available")
    except Exception:
        errors.append("NCCL check failed")

torch.cuda.empty_cache()

if errors:
    print("FAIL (" + "; ".join(errors) + ")")
else:
    gpu = torch.cuda.get_device_name(0)
    cudnn_v = torch.backends.cudnn.version()
    print(f"OK ({gpu}, cuDNN {cudnn_v}, NCCL ok)")
PYEOF
    result=$("$VENV_PATH/bin/python" "$tmp_script" 2>/dev/null) || result="FAIL (torch import error)"
    rm -f "$tmp_script"

    if [[ "$result" == OK* ]]; then
        status_ok "GPU functional ($result)"
    else
        status_fail "GPU functional ($result)" "gpu_functional"
    fi
}

check_cloud_environment() {
    if [ "${IS_CLOUD:-false}" != "true" ]; then
        return
    fi

    local issues=()

    # Headless check
    if [ "$(uname -s)" = "Linux" ] && ! ldconfig -p 2>/dev/null | grep -q libGL.so.1; then
        # Verify headless opencv is usable
        if [ -x "$VENV_PATH/bin/python" ]; then
            if ! "$VENV_PATH/bin/python" -c "import cv2" 2>/dev/null; then
                issues+=("cv2 broken (need headless variant)")
            fi
        fi
    fi

    # nvcc stub vs real
    if [ -x /usr/local/cuda/bin/nvcc ]; then
        if grep -q "^#!/bin/sh" /usr/local/cuda/bin/nvcc 2>/dev/null; then
            # It's our stub — that's expected
            true
        fi
    elif [ "${HAS_GPU:-false}" = "true" ]; then
        issues+=("nvcc missing (deepspeed JIT compile unavailable)")
    fi

    # Python version mismatch
    if [ -x "$VENV_PATH/bin/python" ]; then
        local venv_py sys_py
        venv_py=$("$VENV_PATH/bin/python" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null)
        sys_py=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || echo "none")
        if [ "$venv_py" != "$sys_py" ] && [ "$sys_py" != "none" ]; then
            # Info only, not an error (our NV link fallback handles this)
            true
        fi
    fi

    if [ ${#issues[@]} -gt 0 ]; then
        local detail
        detail=$(IFS='; '; echo "${issues[*]}")
        status_warn "Cloud environment ($detail)"
    else
        status_ok "Cloud environment (${CLOUD_REASON:-detected})"
    fi
}

check_node() {
    local stage_state
    stage_state=$(checkpoint_get_state 5 NODE)
    if [ "$stage_state" = "skipped" ]; then
        status_skip "Node.js (not installed)"
        return
    fi

    local nvm_dir="${NVM_DIR:-$HOME/.nvm}"
    if [ ! -d "$nvm_dir" ]; then
        # Not installed and not expected
        if [ -z "$stage_state" ] || [ "$stage_state" = "pending" ]; then
            status_skip "Node.js (not installed)"
        else
            status_fail "Node.js (NVM directory missing: $nvm_dir)" "node"
        fi
        return
    fi

    # Load NVM and check
    [ -s "$nvm_dir/nvm.sh" ] && source "$nvm_dir/nvm.sh" 2>/dev/null
    if command -v node &>/dev/null; then
        local node_ver
        node_ver=$(node --version 2>/dev/null)
        status_ok "Node.js ($node_ver)"
    else
        status_fail "Node.js (NVM installed but no Node version active)" "node"
    fi
}

check_java() {
    local stage_state
    stage_state=$(checkpoint_get_state 6 JAVA)
    if [ "$stage_state" = "skipped" ]; then
        status_skip "Java (not installed)"
        return
    fi

    local sdk_dir="${SDKMAN_DIR:-$HOME/.sdkman}"
    if [ ! -d "$sdk_dir" ]; then
        if [ -z "$stage_state" ] || [ "$stage_state" = "pending" ]; then
            status_skip "Java (not installed)"
        else
            status_fail "Java (SDKMAN directory missing: $sdk_dir)" "java"
        fi
        return
    fi

    set +u
    [ -s "$sdk_dir/bin/sdkman-init.sh" ] && source "$sdk_dir/bin/sdkman-init.sh" 2>/dev/null
    set -u
    if command -v java &>/dev/null; then
        local java_ver
        java_ver=$(java -version 2>&1 | head -1)
        status_ok "Java ($java_ver)"
    else
        status_fail "Java (SDKMAN installed but no Java version active)" "java"
    fi
}

check_shell_integration() {
    local marker="# >>> machine_setting >>>"
    local has_integration=false

    for rc_file in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [ -f "$rc_file" ] && grep -qF "$marker" "$rc_file" 2>/dev/null; then
            has_integration=true
        fi
    done

    if [ "$has_integration" = true ]; then
        local shells=""
        [ -f "$HOME/.bashrc" ] && grep -qF "$marker" "$HOME/.bashrc" 2>/dev/null && shells+=".bashrc "
        [ -f "$HOME/.zshrc" ] && grep -qF "$marker" "$HOME/.zshrc" 2>/dev/null && shells+=".zshrc"
        status_ok "Shell integration ($shells)"
    else
        status_fail "Shell integration (marker block not found in RC files)" "shell"
    fi
}

check_nvidia_driver() {
    # Skip on non-Linux or non-GPU systems
    if [ "$(uname -s)" != "Linux" ] || [ "${HAS_GPU:-false}" != "true" ] || [ "${GPU_BACKEND:-none}" != "cuda" ]; then
        status_skip "NVIDIA driver (not applicable)"
        return
    fi

    local stage_state
    stage_state=$(checkpoint_get_state 2 NVIDIA)
    if [ "$stage_state" = "skipped" ]; then
        status_skip "NVIDIA driver (stage skipped)"
        return
    fi

    if command -v nvidia-smi &>/dev/null; then
        local driver_ver
        driver_ver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || true)
        if [ -n "$driver_ver" ]; then
            local gpu_info
            gpu_info=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)
            status_ok "NVIDIA driver ($driver_ver, $gpu_info)"
        else
            status_fail "NVIDIA driver (nvidia-smi present but cannot communicate with driver)" "nvidia"
        fi
    else
        status_fail "NVIDIA driver (nvidia-smi not found)" "nvidia"
    fi
}

check_cuda_toolkit() {
    if [ "$(uname -s)" != "Linux" ] || [ "${HAS_GPU:-false}" != "true" ] || [ "${GPU_BACKEND:-none}" != "cuda" ]; then
        return
    fi

    local stage_state
    stage_state=$(checkpoint_get_state 2 NVIDIA)
    if [ "$stage_state" = "skipped" ]; then
        return
    fi

    if [ -x /usr/local/cuda/bin/nvcc ]; then
        # Detect stub vs real nvcc
        if grep -q "^#!/bin/sh" /usr/local/cuda/bin/nvcc 2>/dev/null; then
            local stub_ver
            stub_ver=$(/usr/local/cuda/bin/nvcc -V 2>/dev/null | sed -n 's/.*release \([0-9]*\.[0-9]*\).*/\1/p' || true)
            status_warn "CUDA Toolkit (stub nvcc ${stub_ver} — runtime only, no JIT compile)"
        else
            local cuda_ver
            cuda_ver=$(/usr/local/cuda/bin/nvcc --version 2>/dev/null | sed -n 's/.*release \([0-9]*\.[0-9]*\).*/\1/p' || true)
            status_ok "CUDA Toolkit ($cuda_ver)"
        fi
    elif command -v nvcc &>/dev/null; then
        local cuda_ver
        cuda_ver=$(nvcc --version 2>/dev/null | sed -n 's/.*release \([0-9]*\.[0-9]*\).*/\1/p' || true)
        status_ok "CUDA Toolkit ($cuda_ver)"
    else
        status_warn "CUDA Toolkit (nvcc not found)"
    fi
}

check_cudnn() {
    if [ "$(uname -s)" != "Linux" ] || [ "${HAS_GPU:-false}" != "true" ] || [ "${GPU_BACKEND:-none}" != "cuda" ]; then
        return
    fi

    local stage_state
    stage_state=$(checkpoint_get_state 2 NVIDIA)
    if [ "$stage_state" = "skipped" ]; then
        return
    fi

    # Check system package first
    local cudnn_ver
    cudnn_ver=$(dpkg -l 'cudnn9-*' 2>/dev/null | grep '^ii' | awk '{print $3}' | head -1 || true)
    [ -z "$cudnn_ver" ] && cudnn_ver=$(dpkg -l 'libcudnn*' 2>/dev/null | grep '^ii' | awk '{print $3}' | head -1 || true)

    # Also check torch runtime cuDNN (works even without system package)
    local torch_cudnn=""
    if [ -x "$VENV_PATH/bin/python" ]; then
        torch_cudnn=$("$VENV_PATH/bin/python" -W ignore -c "import torch; print(f'enabled v{torch.backends.cudnn.version()}' if torch.backends.cudnn.is_available() else 'disabled')" 2>/dev/null || true)
    fi

    if [ -n "$cudnn_ver" ] && [[ "$torch_cudnn" == enabled* ]]; then
        status_ok "cuDNN (system: $cudnn_ver, torch: $torch_cudnn)"
    elif [[ "$torch_cudnn" == enabled* ]]; then
        status_ok "cuDNN (torch bundled: $torch_cudnn)"
    elif [ -n "$cudnn_ver" ]; then
        status_warn "cuDNN (system: $cudnn_ver, but torch reports: ${torch_cudnn:-unknown})"
    else
        status_warn "cuDNN (not detected)"
    fi
}

check_nccl() {
    if [ "$(uname -s)" != "Linux" ] || [ "${HAS_GPU:-false}" != "true" ] || [ "${GPU_BACKEND:-none}" != "cuda" ]; then
        return
    fi

    # Check system package
    local nccl_ver
    nccl_ver=$(dpkg -l 'libnccl2' 2>/dev/null | grep '^ii' | awk '{print $3}' | head -1 || true)

    # Also check torch runtime NCCL
    local torch_nccl=""
    if [ -x "$VENV_PATH/bin/python" ]; then
        torch_nccl=$("$VENV_PATH/bin/python" -W ignore -c "
import torch
try:
    v = torch.cuda.nccl.version()
    print(str(v[0])+'.'+str(v[1])+'.'+str(v[2]))
except Exception:
    print('unavailable')
" 2>/dev/null || true)
    fi

    if [ -n "$nccl_ver" ] && [ -n "$torch_nccl" ] && [ "$torch_nccl" != "unavailable" ]; then
        status_ok "NCCL (system: $nccl_ver, torch: $torch_nccl)"
    elif [ -n "$torch_nccl" ] && [ "$torch_nccl" != "unavailable" ]; then
        status_ok "NCCL (torch bundled: $torch_nccl)"
    elif [ -n "$nccl_ver" ]; then
        status_ok "NCCL (system: $nccl_ver)"
    elif [ "${GPU_COUNT:-1}" -gt 1 ]; then
        status_warn "NCCL (not detected — recommended for multi-GPU)"
    fi
}

check_gpu_kernel_tuning() {
    if [ "$(uname -s)" != "Linux" ] || [ "${HAS_GPU:-false}" != "true" ]; then
        return
    fi

    # Skip in cloud/container — kernel tuning requires host-level access
    if [ "${IS_CLOUD:-false}" = "true" ]; then
        status_skip "GPU kernel tuning (cloud/container — managed by host)"
        return
    fi

    if [ -f /etc/sysctl.d/99-machine-setting-gpu.conf ]; then
        status_ok "GPU kernel tuning (sysctl configured)"
    else
        status_warn "GPU kernel tuning (not configured — run setup.sh to apply)"
    fi
}

check_platform_specific() {
    if [ "$(uname -s)" = "Darwin" ]; then
        if xcode-select -p &>/dev/null; then
            status_ok "Xcode CLT"
        else
            status_fail "Xcode CLT (not installed)" "platform"
        fi
    else
        status_ok "Platform (Linux)"
    fi
}

# ============================================================
# Recovery Functions
# ============================================================

recover_hardware() {
    echo "  Recovering hardware profile..."
    bash "$SCRIPT_DIR/detect-hardware.sh" "$HOME/.machine_setting_profile"
    echo "  Done."
}

recover_uv() {
    echo "  Recovering uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
    echo "  Done."
}

recover_python() {
    echo "  Recovering Python $PYTHON_VER..."
    if ! command -v uv &>/dev/null; then
        recover_uv
    fi
    uv python install "$PYTHON_VER"
    echo "  Done."
}

recover_venv() {
    echo "  Recovering virtual environment..."
    if ! command -v uv &>/dev/null; then
        recover_uv
    fi
    bash "$SCRIPT_DIR/setup-venv.sh" --path "$VENV_PATH" --python "$PYTHON_VER"
    echo "  Done."
}

recover_packages() {
    echo "  Recovering missing packages..."
    recover_venv
}

recover_node() {
    echo "  Recovering Node.js..."
    bash "$SCRIPT_DIR/install-node.sh" "${NODE_VERSION:-lts}"
    echo "  Done."
}

recover_java() {
    echo "  Recovering Java..."
    bash "$SCRIPT_DIR/install-java.sh" "${JAVA_VERSION:-21}"
    echo "  Done."
}

recover_shell() {
    echo "  Recovering shell integration..."
    bash "$REPO_DIR/shell/install-shell.sh"
    echo "  Done."
}

recover_nvidia() {
    echo "  Recovering NVIDIA stack..."
    if [ -f "$SCRIPT_DIR/install-nvidia.sh" ]; then
        bash "$SCRIPT_DIR/install-nvidia.sh"
    else
        echo "  install-nvidia.sh not found. Re-clone the repository."
    fi
    echo "  Done. A reboot may be required."
}

recover_platform() {
    if [ "$(uname -s)" = "Darwin" ]; then
        echo "  Please run: xcode-select --install"
    else
        echo "  Platform-specific recovery: no automated fix available."
    fi
}

recover_disk() {
    echo "  Disk space is too low. Please free up disk space manually."
}

# Map component name to recovery function
run_recovery() {
    local component="$1"
    case "$component" in
        disk)       recover_disk ;;
        hardware)   recover_hardware ;;
        nvidia)     recover_nvidia ;;
        uv)         recover_uv ;;
        python)     recover_python ;;
        venv)       recover_venv ;;
        packages)   recover_packages ;;
        node)       recover_node ;;
        java)       recover_java ;;
        shell)      recover_shell ;;
        platform)   recover_platform ;;
        *)          echo "  Unknown component: $component" ;;
    esac
}

# ============================================================
# Package Verification
# ============================================================

verify_packages() {
    echo "=== Package Verification ==="
    echo ""

    if [ ! -x "$VENV_PATH/bin/python" ]; then
        echo "  [FAIL] No venv found at $VENV_PATH"
        echo "  Run './scripts/doctor.sh --recover venv' first."
        exit 1
    fi

    # Get currently installed packages (lowercase name=version)
    local installed_tmp
    installed_tmp=$(mktemp)
    uv pip freeze --python "$VENV_PATH/bin/python" 2>/dev/null | \
        awk -F'==' '{print tolower($1)}' | sort > "$installed_tmp"

    local missing_count=0
    local extra_count=0
    local required_tmp
    required_tmp=$(mktemp)

    # Collect all required package names from requirements files
    for req_file in "$PKG_DIR"/requirements-*.txt; do
        [ -f "$req_file" ] || continue
        grep -v '^#' "$req_file" | grep -v '^$' | grep -v '^\-' | \
            sed 's/[>=<!\[].*//; s/[[:space:]]*$//' | awk '{print tolower($1)}' >> "$required_tmp"
    done
    sort -u "$required_tmp" -o "$required_tmp"

    # Find missing (required but not installed)
    local missing
    missing=$(comm -23 "$required_tmp" "$installed_tmp")
    if [ -n "$missing" ]; then
        echo "  Missing packages (required but not installed):"
        echo "$missing" | while read -r pkg; do echo "    - $pkg"; done
        missing_count=$(echo "$missing" | wc -l | tr -d ' ')
    fi

    # Find extra (installed but not in any requirements)
    local extra
    extra=$(comm -13 "$required_tmp" "$installed_tmp")
    if [ -n "$extra" ]; then
        extra_count=$(echo "$extra" | wc -l | tr -d ' ')
        echo ""
        echo "  Extra packages (installed but not in requirements): $extra_count"
        echo "  (This is normal — they may be transitive dependencies)"
    fi

    rm -f "$installed_tmp" "$required_tmp"

    echo ""
    if [ "$missing_count" -gt 0 ]; then
        echo "  Result: $missing_count missing package(s)"
        echo "  Run './scripts/doctor.sh --recover venv' to install missing packages."
        return 1
    else
        echo "  Result: All required packages are installed."
        return 0
    fi
}

# ============================================================
# Main
# ============================================================

if [ "$MODE" = "verify" ]; then
    verify_packages
    exit $?
fi

echo "=== Machine Setting Doctor ==="
echo ""

# Run all checks
check_disk_space
check_hardware_profile
check_cloud_environment
check_nvidia_driver
check_cuda_toolkit
check_cudnn
check_nccl
check_gpu_kernel_tuning
check_uv
check_python
check_venv
check_key_packages
check_gpu_packages
check_gpu_functional
check_node
check_java
check_shell_integration
check_platform_specific

echo ""
echo "Summary: $COUNT_OK ok, $COUNT_FAIL failed, $COUNT_WARN warnings, $COUNT_SKIP skipped"

if [ "$COUNT_FAIL" -gt 0 ]; then
    echo ""
    echo "Issues found: $COUNT_FAIL"

    if [ "$MODE" = "recover" ]; then
        echo ""
        if [ -n "$RECOVER_TARGET" ]; then
            echo "Recovering: $RECOVER_TARGET"
            run_recovery "$RECOVER_TARGET"
        else
            echo "Auto-recovering all failed components..."
            for comp in "${FAILED_COMPONENTS[@]}"; do
                echo ""
                run_recovery "$comp"
            done
        fi
        echo ""
        echo "Recovery complete. Run './scripts/doctor.sh' to verify."
    else
        echo "Run './scripts/doctor.sh --recover' to fix."
    fi
    exit 1
elif [ "$COUNT_WARN" -gt 0 ]; then
    echo "Warnings found but no critical issues."
    exit 0
else
    echo "All checks passed!"
    exit 0
fi
