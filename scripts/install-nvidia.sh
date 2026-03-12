#!/usr/bin/env bash
# install-nvidia.sh — NVIDIA Driver, CUDA Toolkit, cuDNN, NCCL & Enterprise Tools
# Usage:
#   ./scripts/install-nvidia.sh                    # Auto-detect and install
#   ./scripts/install-nvidia.sh --driver-only      # Driver only
#   ./scripts/install-nvidia.sh --no-driver        # Skip driver (CUDA/cuDNN/NCCL only)
#   ./scripts/install-nvidia.sh --enterprise       # Include enterprise tools (DCGM, Fabric Manager, etc.)
#   ./scripts/install-nvidia.sh --uninstall        # Remove NVIDIA stack
#   ./scripts/install-nvidia.sh --dry-run          # Show what would be installed
#
# Requires: Ubuntu/Debian, x86_64, NVIDIA GPU detected
# Called from: setup.sh Stage 2 (NVIDIA)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# --- Load hardware profile ---
[ -f "$HOME/.machine_setting_profile" ] && source "$HOME/.machine_setting_profile"

# --- Load config ---
source "$REPO_DIR/config/default.conf"
[ -f "$REPO_DIR/config/machine.conf" ] && source "$REPO_DIR/config/machine.conf"

# --- Parse arguments ---
OPT_DRIVER=true
OPT_CUDA=true
OPT_CUDNN=true
OPT_NCCL=true
OPT_ENTERPRISE=false
OPT_CONTAINER_TOOLKIT=true
OPT_SYSTEM_TOOLS=true
OPT_KERNEL_TUNING=true
OPT_UNINSTALL=false
OPT_DRY_RUN=false
OPT_DRIVER_VERSION="${NVIDIA_DRIVER_VERSION:-}"   # empty = auto (recommended)
OPT_CUDA_VERSION="${NVIDIA_CUDA_VERSION:-}"       # empty = latest
OPT_OPEN_KERNEL="${NVIDIA_OPEN_KERNEL:-auto}"     # auto | true | false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --driver-only)       OPT_CUDA=false; OPT_CUDNN=false; OPT_NCCL=false; OPT_ENTERPRISE=false; OPT_CONTAINER_TOOLKIT=false; shift ;;
        --no-driver)         OPT_DRIVER=false; shift ;;
        --enterprise)        OPT_ENTERPRISE=true; shift ;;
        --no-enterprise)     OPT_ENTERPRISE=false; shift ;;
        --no-cuda)           OPT_CUDA=false; OPT_CUDNN=false; OPT_NCCL=false; shift ;;
        --no-cudnn)          OPT_CUDNN=false; shift ;;
        --no-nccl)           OPT_NCCL=false; shift ;;
        --no-container-toolkit) OPT_CONTAINER_TOOLKIT=false; shift ;;
        --no-system-tools)   OPT_SYSTEM_TOOLS=false; shift ;;
        --no-kernel-tuning)  OPT_KERNEL_TUNING=false; shift ;;
        --driver-version)    OPT_DRIVER_VERSION="$2"; shift 2 ;;
        --cuda-version)      OPT_CUDA_VERSION="$2"; shift 2 ;;
        --open-kernel)       OPT_OPEN_KERNEL=true; shift ;;
        --proprietary)       OPT_OPEN_KERNEL=false; shift ;;
        --uninstall)         OPT_UNINSTALL=true; shift ;;
        --dry-run)           OPT_DRY_RUN=true; shift ;;
        --help|-h)
            echo "Usage: ./scripts/install-nvidia.sh [options]"
            echo ""
            echo "Installation options:"
            echo "  --driver-only           Install NVIDIA driver only"
            echo "  --no-driver             Skip driver (CUDA/cuDNN/NCCL only)"
            echo "  --enterprise            Include enterprise tools (DCGM, Fabric Manager, etc.)"
            echo "  --no-cuda               Skip CUDA toolkit (and cuDNN/NCCL)"
            echo "  --no-cudnn              Skip cuDNN"
            echo "  --no-nccl              Skip NCCL"
            echo "  --no-container-toolkit  Skip NVIDIA Container Toolkit"
            echo "  --no-system-tools       Skip system utilities (numactl, hwloc, etc.)"
            echo "  --no-kernel-tuning      Skip kernel/sysctl tuning"
            echo "  --driver-version <ver>  Specific driver version (default: auto/recommended)"
            echo "  --cuda-version <ver>    Specific CUDA version, e.g. 13-0 (default: latest)"
            echo "  --open-kernel           Force open kernel modules"
            echo "  --proprietary           Force proprietary kernel modules"
            echo ""
            echo "Other options:"
            echo "  --uninstall             Remove NVIDIA stack"
            echo "  --dry-run               Show what would be installed"
            echo "  --help                  Show this help"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ============================================================
# Validation
# ============================================================

# Must be Linux x86_64
if [ "$(uname -s)" != "Linux" ]; then
    echo "  [SKIP] NVIDIA installation is Linux-only (detected: $(uname -s))"
    exit 0
fi

if [ "$(uname -m)" != "x86_64" ]; then
    echo "  [SKIP] NVIDIA installation requires x86_64 (detected: $(uname -m))"
    exit 0
fi

# Must have NVIDIA GPU
if [ "${HAS_GPU:-false}" != "true" ] || [ "${GPU_BACKEND:-none}" != "cuda" ]; then
    echo "  [SKIP] No NVIDIA GPU detected"
    exit 0
fi

# Must be Ubuntu/Debian
if ! command -v apt-get &>/dev/null; then
    echo "  [ERROR] Only Ubuntu/Debian supported (apt-get not found)"
    exit 1
fi

# Detect Ubuntu version
UBUNTU_VERSION=""
UBUNTU_CODENAME=""
if [ -f /etc/os-release ]; then
    UBUNTU_VERSION=$(. /etc/os-release && echo "${VERSION_ID:-}")
    UBUNTU_CODENAME=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
fi

# ============================================================
# Helpers
# ============================================================

log_info()  { echo "  [INFO]  $1"; }
log_warn()  { echo "  [WARN]  $1"; }
log_ok()    { echo "  [OK]    $1"; }
log_error() { echo "  [ERROR] $1"; }
log_dry()   { echo "  [DRY]   $1"; }

run_sudo() {
    if [ "$OPT_DRY_RUN" = true ]; then
        log_dry "sudo $*"
        return 0
    fi
    sudo "$@"
}

# Detect GPU tier: consumer | professional | datacenter
detect_gpu_tier() {
    local gpu_name="${GPU_NAME:-}"
    case "$gpu_name" in
        *A100*|*H100*|*H200*|*B100*|*B200*|*L40*|*A30*|*A40*|*V100*)
            echo "datacenter" ;;
        *RTX?A*|*RTX?L*|*Quadro*|*Tesla*)
            echo "professional" ;;
        *)
            echo "consumer" ;;
    esac
}

# Detect if GPU supports open kernel modules (Turing+ = arch >= 7.5)
supports_open_kernel() {
    local gpu_name="${GPU_NAME:-}"
    # Open kernel modules: Turing (RTX 20xx, T4) and newer
    # Consumer: RTX 20xx, 30xx, 40xx, 50xx
    # Datacenter: T4, A100, H100, B200, L40
    case "$gpu_name" in
        *RTX*|*T4*|*A100*|*A30*|*A40*|*H100*|*H200*|*B100*|*B200*|*L40*|*Quadro?RTX*)
            return 0 ;;
        *GTX?16[0-9][0-9]*|*GTX?1650*|*GTX?1660*)
            return 0 ;;  # Turing GTX
        *)
            return 1 ;;  # Pre-Turing or unknown — use proprietary
    esac
}

# Check if Secure Boot is enabled
is_secure_boot() {
    if command -v mokutil &>/dev/null; then
        mokutil --sb-state 2>/dev/null | grep -qi "enabled"
    else
        return 1
    fi
}

# Get NVIDIA apt repo URL component for this Ubuntu version
get_repo_arch_string() {
    local ver="${UBUNTU_VERSION:-24.04}"
    local ver_nodot="${ver//.}"
    echo "ubuntu${ver_nodot}"
}

# ============================================================
# Uninstall
# ============================================================

if [ "$OPT_UNINSTALL" = true ]; then
    echo "=== NVIDIA Stack Uninstall ==="

    log_info "Removing NVIDIA packages..."
    run_sudo apt-get purge -y 'nvidia-*' 'libnvidia-*' 'cuda-*' 'libcuda*' \
        'cudnn*' 'libcudnn*' 'libnccl*' 'nccl*' \
        'datacenter-gpu-manager' 'nvidia-fabricmanager*' \
        nvidia-container-toolkit 2>/dev/null || true

    run_sudo apt-get autoremove -y 2>/dev/null || true

    # Remove CUDA symlink and directories
    if [ -L /usr/local/cuda ]; then
        run_sudo rm -f /usr/local/cuda
        log_ok "Removed /usr/local/cuda symlink"
    fi

    # Remove NVIDIA apt repo
    run_sudo rm -f /etc/apt/sources.list.d/cuda*.list 2>/dev/null || true
    run_sudo rm -f /etc/apt/sources.list.d/nvidia-container-toolkit*.list 2>/dev/null || true
    run_sudo rm -f /usr/share/keyrings/nvidia-cuda-archive-keyring.gpg 2>/dev/null || true

    # Remove kernel tuning
    if [ -f /etc/sysctl.d/99-machine-setting-gpu.conf ]; then
        run_sudo rm -f /etc/sysctl.d/99-machine-setting-gpu.conf
        log_ok "Removed GPU sysctl config"
    fi
    if [ -f /etc/security/limits.d/99-machine-setting-gpu.conf ]; then
        run_sudo rm -f /etc/security/limits.d/99-machine-setting-gpu.conf
        log_ok "Removed GPU limits config"
    fi

    run_sudo apt-get update -qq 2>/dev/null || true

    log_ok "NVIDIA stack removed"
    echo "  Note: Reboot recommended after driver removal."
    exit 0
fi

# ============================================================
# Pre-flight
# ============================================================

echo "=== NVIDIA Stack Installation ==="

GPU_TIER=$(detect_gpu_tier)
log_info "GPU: ${GPU_NAME:-Unknown} (${GPU_COUNT:-1}x, tier: ${GPU_TIER})"

# Auto-enable enterprise for datacenter GPUs
if [ "$GPU_TIER" = "datacenter" ] && [ "$OPT_ENTERPRISE" = false ]; then
    log_info "Datacenter GPU detected — auto-enabling enterprise tools"
    OPT_ENTERPRISE=true
fi

# Resolve open vs proprietary kernel modules
USE_OPEN_KERNEL=false
if [ "$OPT_OPEN_KERNEL" = "auto" ]; then
    if supports_open_kernel; then
        USE_OPEN_KERNEL=true
    fi
elif [ "$OPT_OPEN_KERNEL" = true ]; then
    USE_OPEN_KERNEL=true
fi

# Secure Boot warning
if is_secure_boot; then
    log_warn "Secure Boot is ENABLED"
    log_warn "DKMS modules require MOK enrollment after installation"
    log_warn "You will need to reboot and enroll the key in MOK Manager"
fi

# Sudo check
if [ "$OPT_DRY_RUN" = false ]; then
    if ! sudo -n true 2>/dev/null; then
        log_info "sudo access required for NVIDIA installation"
        sudo -v || { log_error "Failed to obtain sudo access"; exit 1; }
    fi
    # Keep sudo alive
    while true; do sudo -n true; sleep 50; kill -0 "$$" || exit; done 2>/dev/null &
    SUDO_KEEPER_PID=$!
    trap 'kill $SUDO_KEEPER_PID 2>/dev/null || true' EXIT
fi

# Dry run summary
if [ "$OPT_DRY_RUN" = true ]; then
    echo ""
    echo "  Dry run — would install:"
    [ "$OPT_DRIVER" = true ]            && echo "    - NVIDIA Driver (${OPT_DRIVER_VERSION:-recommended}, open=${USE_OPEN_KERNEL})"
    [ "$OPT_CUDA" = true ]              && echo "    - CUDA Toolkit (${OPT_CUDA_VERSION:-latest})"
    [ "$OPT_CUDNN" = true ]             && echo "    - cuDNN 9.x"
    [ "$OPT_NCCL" = true ]              && echo "    - NCCL (multi-GPU communication)"
    [ "$OPT_ENTERPRISE" = true ]        && echo "    - Enterprise: DCGM, Fabric Manager, GDS, nvidia-peermem"
    [ "$OPT_CONTAINER_TOOLKIT" = true ] && echo "    - NVIDIA Container Toolkit"
    [ "$OPT_SYSTEM_TOOLS" = true ]      && echo "    - System tools: numactl, hwloc, lm-sensors, nvtop, build-essential, cmake"
    [ "$OPT_KERNEL_TUNING" = true ]     && echo "    - Kernel/sysctl tuning"
    echo ""
    echo "  GPU tier: ${GPU_TIER}"
    echo "  Multi-GPU: ${GPU_COUNT:-1}x"
    exit 0
fi

# ============================================================
# 1. NVIDIA APT Repository Setup
# ============================================================

setup_nvidia_repo() {
    log_info "Setting up NVIDIA CUDA repository..."

    local repo_arch
    repo_arch=$(get_repo_arch_string)

    # Download and install keyring
    local keyring_url="https://developer.download.nvidia.com/compute/cuda/repos/${repo_arch}/x86_64/cuda-keyring_1.1-1_all.deb"
    local tmp_deb
    tmp_deb=$(mktemp /tmp/cuda-keyring-XXXXX.deb)

    if wget -qO "$tmp_deb" "$keyring_url" 2>/dev/null || curl -fsSL -o "$tmp_deb" "$keyring_url" 2>/dev/null; then
        run_sudo dpkg -i "$tmp_deb"
        rm -f "$tmp_deb"
        log_ok "NVIDIA CUDA repository configured"
    else
        log_error "Failed to download NVIDIA CUDA keyring"
        rm -f "$tmp_deb"
        return 1
    fi

    run_sudo apt-get update -qq
}

# ============================================================
# 2. NVIDIA Driver Installation
# ============================================================

install_driver() {
    [ "$OPT_DRIVER" = true ] || return 0

    log_info "Installing NVIDIA driver..."

    # Check if driver is already installed and working
    if command -v nvidia-smi &>/dev/null; then
        local existing_ver
        existing_ver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || true)
        if [ -n "$existing_ver" ]; then
            if [ -n "$OPT_DRIVER_VERSION" ] && [ "$existing_ver" != "$OPT_DRIVER_VERSION" ]; then
                log_info "Existing driver $existing_ver differs from requested $OPT_DRIVER_VERSION"
                log_info "Removing existing driver first..."
                run_sudo apt-get purge -y 'nvidia-driver-*' 'nvidia-dkms-*' 'libnvidia-*' 2>/dev/null || true
                run_sudo apt-get autoremove -y 2>/dev/null || true
            else
                log_ok "NVIDIA driver already installed ($existing_ver)"
                return 0
            fi
        fi
    fi

    # Determine driver package
    local driver_pkg
    if [ -n "$OPT_DRIVER_VERSION" ]; then
        # Specific version requested
        if [ "$USE_OPEN_KERNEL" = true ]; then
            driver_pkg="nvidia-driver-${OPT_DRIVER_VERSION}-open"
        else
            driver_pkg="nvidia-driver-${OPT_DRIVER_VERSION}"
        fi
    else
        # Auto-detect recommended driver
        if command -v ubuntu-drivers &>/dev/null; then
            local recommended
            recommended=$(ubuntu-drivers devices 2>/dev/null | grep 'recommended' | awk '{print $3}' | head -1 || true)
            if [ -n "$recommended" ]; then
                driver_pkg="$recommended"
                # Switch to open variant if supported
                if [ "$USE_OPEN_KERNEL" = true ] && [[ "$driver_pkg" != *"-open"* ]]; then
                    driver_pkg="${driver_pkg}-open"
                fi
                log_info "Recommended driver: $driver_pkg"
            fi
        fi

        # Fallback: install latest available
        if [ -z "${driver_pkg:-}" ]; then
            run_sudo apt-get install -y ubuntu-drivers-common 2>/dev/null || true
            if command -v ubuntu-drivers &>/dev/null; then
                log_info "Auto-installing recommended driver..."
                run_sudo ubuntu-drivers install 2>/dev/null || true
                if command -v nvidia-smi &>/dev/null; then
                    log_ok "Driver installed via ubuntu-drivers"
                    return 0
                fi
            fi
            # Last resort: use cuda-drivers meta-package
            driver_pkg="cuda-drivers"
            if [ "$USE_OPEN_KERNEL" = true ]; then
                driver_pkg="cuda-drivers-open"
            fi
        fi
    fi

    log_info "Installing package: $driver_pkg"
    run_sudo apt-get install -y "$driver_pkg"

    # Verify installation
    if dpkg -l | grep -q "nvidia-driver\|cuda-drivers"; then
        local installed_ver
        installed_ver=$(dpkg -l 'nvidia-driver-*' 2>/dev/null | grep '^ii' | awk '{print $3}' | head -1 || echo "installed")
        log_ok "NVIDIA driver installed ($installed_ver)"
    else
        log_warn "Driver package installed but could not verify"
    fi

    # Secure Boot: MOK enrollment hint
    if is_secure_boot; then
        echo ""
        log_warn "=== SECURE BOOT ACTION REQUIRED ==="
        log_warn "DKMS modules need MOK enrollment to load."
        log_warn "After setup completes, reboot and enroll the key in MOK Manager."
        log_warn "If prompted for a password during DKMS, remember it for MOK enrollment."
        echo ""
    fi
}

# ============================================================
# 3. CUDA Toolkit
# ============================================================

install_cuda() {
    [ "$OPT_CUDA" = true ] || return 0

    log_info "Installing CUDA Toolkit..."

    # Check existing CUDA
    if command -v nvcc &>/dev/null; then
        local existing_cuda
        existing_cuda=$(nvcc --version 2>/dev/null | sed -n 's/.*release \([0-9]*\.[0-9]*\).*/\1/p' || true)
        if [ -n "$existing_cuda" ]; then
            if [ -n "$OPT_CUDA_VERSION" ]; then
                local requested_dotted="${OPT_CUDA_VERSION//-/.}"
                if [ "$existing_cuda" = "$requested_dotted" ]; then
                    log_ok "CUDA Toolkit already installed ($existing_cuda)"
                    return 0
                fi
                log_info "Existing CUDA $existing_cuda differs from requested $requested_dotted"
            else
                log_ok "CUDA Toolkit already installed ($existing_cuda)"
                return 0
            fi
        fi
    fi

    local cuda_pkg
    if [ -n "$OPT_CUDA_VERSION" ]; then
        cuda_pkg="cuda-toolkit-${OPT_CUDA_VERSION}"
    else
        cuda_pkg="cuda-toolkit"
    fi

    log_info "Installing package: $cuda_pkg"
    run_sudo apt-get install -y "$cuda_pkg"

    # Set up /usr/local/cuda symlink if not present
    if [ ! -L /usr/local/cuda ] && [ ! -d /usr/local/cuda ]; then
        local cuda_dir
        cuda_dir=$(ls -d /usr/local/cuda-* 2>/dev/null | sort -V | tail -1 || true)
        if [ -n "$cuda_dir" ] && [ -d "$cuda_dir" ]; then
            run_sudo ln -sf "$cuda_dir" /usr/local/cuda
            log_ok "Created symlink /usr/local/cuda -> $cuda_dir"
        fi
    fi

    # Verify
    if [ -x /usr/local/cuda/bin/nvcc ]; then
        local cuda_ver
        cuda_ver=$(/usr/local/cuda/bin/nvcc --version 2>/dev/null | sed -n 's/.*release \([0-9]*\.[0-9]*\).*/\1/p' || echo "installed")
        log_ok "CUDA Toolkit installed ($cuda_ver)"
    else
        log_warn "CUDA Toolkit package installed but nvcc not found at /usr/local/cuda/bin/"
    fi
}

# ============================================================
# 4. cuDNN
# ============================================================

install_cudnn() {
    [ "$OPT_CUDNN" = true ] || return 0

    log_info "Installing cuDNN..."

    # Detect CUDA major version for cuDNN package naming
    local cuda_major=""
    if [ -x /usr/local/cuda/bin/nvcc ]; then
        cuda_major=$(/usr/local/cuda/bin/nvcc --version 2>/dev/null | sed -n 's/.*release \([0-9]*\)\..*/\1/p' || true)
    fi

    if [ -z "$cuda_major" ]; then
        # Try from apt
        cuda_major=$(dpkg -l 'cuda-toolkit-*' 2>/dev/null | grep '^ii' | awk '{print $2}' | sed -n 's/cuda-toolkit-\([0-9]*\)-.*/\1/p' | sort -rn | head -1 || true)
    fi

    if [ -z "$cuda_major" ]; then
        log_warn "Cannot determine CUDA version for cuDNN installation"
        return 1
    fi

    # cuDNN 9.x uses: cudnn9-cuda-XX (e.g. cudnn9-cuda-13)
    local cudnn_pkg="cudnn9-cuda-${cuda_major}"

    # Check if already installed
    if dpkg -l "$cudnn_pkg" 2>/dev/null | grep -q '^ii'; then
        local cudnn_ver
        cudnn_ver=$(dpkg -l "$cudnn_pkg" 2>/dev/null | grep '^ii' | awk '{print $3}' | head -1)
        log_ok "cuDNN already installed ($cudnn_ver)"
        return 0
    fi

    log_info "Installing package: $cudnn_pkg"
    run_sudo apt-get install -y "$cudnn_pkg" || {
        # Fallback: try libcudnn9-dev
        log_warn "cudnn9 meta-package failed, trying libcudnn9-dev..."
        run_sudo apt-get install -y "libcudnn9-dev-cuda-${cuda_major}" || {
            log_warn "cuDNN installation failed — may need manual install"
            return 1
        }
    }

    log_ok "cuDNN installed for CUDA $cuda_major"
}

# ============================================================
# 5. NCCL (Multi-GPU Communication)
# ============================================================

install_nccl() {
    [ "$OPT_NCCL" = true ] || return 0

    # Only install if multi-GPU or datacenter tier
    if [ "${GPU_COUNT:-1}" -le 1 ] && [ "$GPU_TIER" != "datacenter" ]; then
        log_info "Single GPU detected — skipping NCCL (use --nccl to force)"
        return 0
    fi

    log_info "Installing NCCL (multi-GPU communication)..."

    local cuda_major=""
    if [ -x /usr/local/cuda/bin/nvcc ]; then
        cuda_major=$(/usr/local/cuda/bin/nvcc --version 2>/dev/null | sed -n 's/.*release \([0-9]*\)\..*/\1/p' || true)
    fi

    if [ -z "$cuda_major" ]; then
        log_warn "Cannot determine CUDA version for NCCL"
        return 1
    fi

    local nccl_pkg="libnccl2 libnccl-dev"

    if dpkg -l libnccl2 2>/dev/null | grep -q '^ii'; then
        local nccl_ver
        nccl_ver=$(dpkg -l libnccl2 2>/dev/null | grep '^ii' | awk '{print $3}' | head -1)
        log_ok "NCCL already installed ($nccl_ver)"
        return 0
    fi

    log_info "Installing packages: $nccl_pkg"
    run_sudo apt-get install -y $nccl_pkg || {
        log_warn "NCCL installation failed — may not be available for this CUDA version"
        return 0
    }

    log_ok "NCCL installed"
}

# ============================================================
# 6. Enterprise Tools
# ============================================================

install_enterprise_tools() {
    [ "$OPT_ENTERPRISE" = true ] || return 0

    log_info "Installing enterprise GPU tools..."

    # DCGM (Data Center GPU Manager)
    log_info "Installing DCGM..."
    run_sudo apt-get install -y datacenter-gpu-manager 2>/dev/null || {
        log_warn "DCGM not available — skipping"
    }

    # Fabric Manager (for NVSwitch/NVLink multi-GPU)
    if [ "${GPU_COUNT:-1}" -gt 1 ]; then
        log_info "Installing Fabric Manager (multi-GPU NVSwitch)..."
        local fm_pkg
        fm_pkg=$(apt-cache search 'nvidia-fabricmanager' 2>/dev/null | awk '{print $1}' | sort -V | tail -1 || true)
        if [ -n "$fm_pkg" ]; then
            run_sudo apt-get install -y "$fm_pkg" || log_warn "Fabric Manager installation failed"
        else
            log_warn "Fabric Manager package not found"
        fi
    fi

    # GPUDirect Storage
    log_info "Installing GPUDirect Storage (GDS)..."
    run_sudo apt-get install -y nvidia-gds 2>/dev/null || {
        log_warn "GPUDirect Storage not available — skipping"
    }

    # nvidia-peermem (GPU RDMA for InfiniBand)
    log_info "Installing nvidia-peermem (GPU RDMA)..."
    run_sudo apt-get install -y nvidia-peermem 2>/dev/null || {
        log_warn "nvidia-peermem not available — skipping"
    }

    log_ok "Enterprise tools installation complete"
}

# ============================================================
# 7. NVIDIA Container Toolkit
# ============================================================

install_container_toolkit() {
    [ "$OPT_CONTAINER_TOOLKIT" = true ] || return 0

    # Only if Docker is installed
    if ! command -v docker &>/dev/null; then
        log_info "Docker not found — skipping NVIDIA Container Toolkit"
        return 0
    fi

    log_info "Installing NVIDIA Container Toolkit..."

    # Check if already installed
    if command -v nvidia-ctk &>/dev/null; then
        log_ok "NVIDIA Container Toolkit already installed"
        return 0
    fi

    # Add NVIDIA container toolkit repo
    local repo_gpg="/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
    if [ ! -f "$repo_gpg" ]; then
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
            run_sudo gpg --dearmor -o "$repo_gpg" 2>/dev/null || true

        curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
            sed "s#deb https://#deb [signed-by=$repo_gpg] https://#g" | \
            run_sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null 2>/dev/null || true

        run_sudo apt-get update -qq 2>/dev/null || true
    fi

    run_sudo apt-get install -y nvidia-container-toolkit 2>/dev/null || {
        log_warn "NVIDIA Container Toolkit installation failed"
        return 0
    }

    # Configure Docker runtime
    run_sudo nvidia-ctk runtime configure --runtime=docker 2>/dev/null || true

    log_ok "NVIDIA Container Toolkit installed"
    log_info "Restart Docker to apply: sudo systemctl restart docker"
}

# ============================================================
# 8. System Tools & Build Dependencies
# ============================================================

install_system_tools() {
    [ "$OPT_SYSTEM_TOOLS" = true ] || return 0

    log_info "Installing system tools and build dependencies..."

    # Build essentials (needed for compiling CUDA extensions, flash-attn, etc.)
    local build_pkgs="build-essential cmake ninja-build pkg-config"

    # GPU monitoring and system utilities
    local monitoring_pkgs="nvtop lm-sensors"

    # NUMA and topology tools (important for multi-GPU)
    local numa_pkgs="numactl hwloc"

    # Storage benchmarking and CPU tools
    local storage_pkgs="fio linux-tools-common"

    # All packages
    local all_pkgs="$build_pkgs $monitoring_pkgs $numa_pkgs $storage_pkgs"

    # Add enterprise monitoring if applicable
    if [ "$OPT_ENTERPRISE" = true ]; then
        all_pkgs="$all_pkgs smartmontools"
    fi

    log_info "Installing: $all_pkgs"
    run_sudo apt-get install -y $all_pkgs 2>/dev/null || {
        # Try individually if batch fails
        log_warn "Batch install failed, trying individually..."
        for pkg in $all_pkgs; do
            run_sudo apt-get install -y "$pkg" 2>/dev/null || log_warn "  Failed: $pkg"
        done
    }

    log_ok "System tools installed"
}

# ============================================================
# 9. Kernel & Sysctl Tuning
# ============================================================

apply_kernel_tuning() {
    [ "$OPT_KERNEL_TUNING" = true ] || return 0

    log_info "Applying kernel/sysctl tuning for GPU workloads..."

    # Compute RAM-based shared memory limits
    local ram_bytes
    ram_bytes=$(awk '/MemTotal/ {print $2 * 1024}' /proc/meminfo 2>/dev/null || echo 0)
    local shmmax="${ram_bytes:-68719476736}"
    local shmall=$(( ${ram_bytes:-68719476736} / 4096 ))

    # Sysctl settings for GPU/ML workloads
    local sysctl_conf="/etc/sysctl.d/99-machine-setting-gpu.conf"
    run_sudo tee "$sysctl_conf" > /dev/null <<SYSCTL
# Machine Setting - GPU/ML workload optimizations
# Applied by install-nvidia.sh on $(date -I)

# === Memory ===
# Max memory map areas — PyTorch mmap, large model loading
vm.max_map_count = 1048576

# Shared memory limits (sized to this machine's RAM)
kernel.shmmax = ${shmmax}
kernel.shmall = ${shmall}

# Reduce swappiness for GPU workloads (keep data in RAM)
vm.swappiness = 10

# === File Descriptors ===
fs.file-max = 2097152

# Increase inotify limits (large projects, many files)
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 8192

# === Network (distributed training — NCCL/Gloo over TCP) ===
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 1048576 16777216
net.ipv4.tcp_wmem = 4096 1048576 16777216
net.core.netdev_max_backlog = 65536
net.core.somaxconn = 65535
SYSCTL

    # Apply immediately
    run_sudo sysctl --system -q 2>/dev/null || true

    # Security limits for GPU workloads
    local limits_conf="/etc/security/limits.d/99-machine-setting-gpu.conf"
    local current_user
    current_user=$(whoami)
    run_sudo tee "$limits_conf" > /dev/null <<LIMITS
# Machine Setting - GPU/ML workload limits
# Applied by install-nvidia.sh on $(date -I)

# Unlimited memlock (required for GPU pinned memory / RDMA)
*                soft  memlock  unlimited
*                hard  memlock  unlimited
root             soft  memlock  unlimited
root             hard  memlock  unlimited

# Increase open file limits
*                soft  nofile   1048576
*                hard  nofile   1048576
root             soft  nofile   1048576
root             hard  nofile   1048576

# Increase process/thread limits
*                soft  nproc    1048576
*                hard  nproc    1048576
LIMITS

    # Set CPU governor to performance (if cpupower available)
    if command -v cpupower &>/dev/null; then
        log_info "Setting CPU governor to performance..."
        run_sudo cpupower frequency-set -g performance 2>/dev/null || true
    fi

    log_ok "Kernel/sysctl tuning applied"
}

# ============================================================
# Main Installation Flow
# ============================================================

# Step 1: Set up NVIDIA apt repository
setup_nvidia_repo

# Step 2: Install driver
install_driver

# Step 3: Install CUDA Toolkit
install_cuda

# Step 4: Install cuDNN
install_cudnn

# Step 5: Install NCCL
install_nccl

# Step 6: Enterprise tools (datacenter GPUs)
install_enterprise_tools

# Step 7: NVIDIA Container Toolkit
install_container_toolkit

# Step 8: System tools and build dependencies
install_system_tools

# Step 9: Kernel/sysctl tuning
apply_kernel_tuning

# ============================================================
# Summary
# ============================================================

echo ""
echo "  === NVIDIA Installation Summary ==="
echo "  GPU: ${GPU_NAME:-Unknown} (${GPU_COUNT:-1}x, tier: ${GPU_TIER})"

if [ "$OPT_DRIVER" = true ] && command -v nvidia-smi &>/dev/null; then
    echo "  Driver: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo 'installed (reboot may be required)')"
fi
if [ "$OPT_CUDA" = true ] && [ -x /usr/local/cuda/bin/nvcc ]; then
    echo "  CUDA: $(/usr/local/cuda/bin/nvcc --version 2>/dev/null | sed -n 's/.*release \([0-9]*\.[0-9]*\).*/\1/p' || echo 'installed')"
fi
if [ "$OPT_CUDNN" = true ]; then
    local cudnn_ver
    cudnn_ver=$(dpkg -l 'cudnn9-*' 2>/dev/null | grep '^ii' | awk '{print $3}' | head -1 || true)
    [ -n "$cudnn_ver" ] && echo "  cuDNN: $cudnn_ver"
fi
if [ "$OPT_NCCL" = true ]; then
    local nccl_ver
    nccl_ver=$(dpkg -l 'libnccl2' 2>/dev/null | grep '^ii' | awk '{print $3}' | head -1 || true)
    [ -n "$nccl_ver" ] && echo "  NCCL: $nccl_ver"
fi

echo ""

# Reboot hint
if [ "$OPT_DRIVER" = true ]; then
    if ! nvidia-smi &>/dev/null; then
        log_warn "nvidia-smi not working — a REBOOT is required to load the new driver"
        if is_secure_boot; then
            log_warn "Secure Boot is enabled — enroll MOK key during reboot"
        fi
    fi
fi
