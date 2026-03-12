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

# ============================================================
# Dry Run Diagnostic System
# ============================================================

# Color codes for dry-run report
_C_RESET="\033[0m"
_C_GREEN="\033[0;32m"
_C_YELLOW="\033[0;33m"
_C_RED="\033[0;31m"
_C_CYAN="\033[0;36m"
_C_BOLD="\033[1m"
_C_DIM="\033[2m"

_tag_ok()      { printf "  ${_C_GREEN}[OK]${_C_RESET}      %s\n" "$1"; }
_tag_install() { printf "  ${_C_CYAN}[INSTALL]${_C_RESET} %s\n" "$1"; }
_tag_upgrade() { printf "  ${_C_CYAN}[UPGRADE]${_C_RESET} %s\n" "$1"; }
_tag_skip()    { printf "  ${_C_DIM}[SKIP]${_C_RESET}    %s\n" "$1"; }
_tag_warn()    { printf "  ${_C_YELLOW}[WARN]${_C_RESET}    %s\n" "$1"; }
_tag_fail()    { printf "  ${_C_RED}[FAIL]${_C_RESET}    %s\n" "$1"; }
_tag_conflict(){ printf "  ${_C_RED}[CONFLICT]${_C_RESET}%s\n" " $1"; }
_section()     { printf "\n${_C_BOLD}── %s ──${_C_RESET}\n" "$1"; }

run_dry_run_diagnostic() {
    local blocking_issues=0

    echo ""
    printf "${_C_BOLD}══════════════════════════════════════════════════════════${_C_RESET}\n"
    printf "${_C_BOLD}  NVIDIA Stack Dry-Run Diagnostic Report${_C_RESET}\n"
    printf "${_C_BOLD}══════════════════════════════════════════════════════════${_C_RESET}\n"

    # ==================================================================
    # 1. System Readiness Check
    # ==================================================================
    _section "1. System Readiness"

    # OS detection
    local os_id="" os_ver="" os_codename="" os_name=""
    if [ -f /etc/os-release ]; then
        os_id=$(. /etc/os-release && echo "${ID:-unknown}")
        os_ver=$(. /etc/os-release && echo "${VERSION_ID:-unknown}")
        os_codename=$(. /etc/os-release && echo "${VERSION_CODENAME:-unknown}")
        os_name=$(. /etc/os-release && echo "${PRETTY_NAME:-unknown}")
    fi
    case "$os_id" in
        ubuntu|debian)
            _tag_ok "OS: $os_name ($os_id $os_ver / $os_codename)" ;;
        *)
            _tag_fail "Unsupported OS: $os_name (need Ubuntu/Debian)"
            blocking_issues=$((blocking_issues + 1)) ;;
    esac

    # Architecture
    local arch
    arch=$(uname -m)
    if [ "$arch" = "x86_64" ]; then
        _tag_ok "Architecture: $arch"
    else
        _tag_fail "Unsupported architecture: $arch (need x86_64)"
        blocking_issues=$((blocking_issues + 1))
    fi

    # Disk space
    local avail_mb needed_mb=6000
    avail_mb=$(df -BM /usr 2>/dev/null | awk 'NR==2{gsub(/M/,"",$4); print $4}' || echo "0")
    if [ "$OPT_ENTERPRISE" = true ]; then needed_mb=8000; fi
    if [ "${avail_mb:-0}" -ge "$needed_mb" ]; then
        _tag_ok "Disk space: ${avail_mb}MB available (need ~${needed_mb}MB)"
    else
        _tag_warn "Disk space: ${avail_mb}MB available, estimated ~${needed_mb}MB needed"
    fi

    # Internet connectivity to NVIDIA repos
    local nvidia_reachable=false
    if command -v wget &>/dev/null; then
        if wget -q --spider --timeout=5 "https://developer.download.nvidia.com" 2>/dev/null; then
            nvidia_reachable=true
        fi
    elif command -v curl &>/dev/null; then
        if curl -fsSL --connect-timeout 5 -o /dev/null "https://developer.download.nvidia.com" 2>/dev/null; then
            nvidia_reachable=true
        fi
    fi
    if [ "$nvidia_reachable" = true ]; then
        _tag_ok "Internet: NVIDIA repos reachable"
    else
        _tag_fail "Internet: Cannot reach developer.download.nvidia.com"
        blocking_issues=$((blocking_issues + 1))
    fi

    # apt lock check
    if fuser /var/lib/dpkg/lock-frontend &>/dev/null 2>&1 || fuser /var/lib/apt/lists/lock &>/dev/null 2>&1; then
        _tag_fail "apt lock: Another package manager is running"
        blocking_issues=$((blocking_issues + 1))
    else
        _tag_ok "apt lock: No package manager lock detected"
    fi

    # Kernel headers
    local running_kernel
    running_kernel=$(uname -r)
    if dpkg -l "linux-headers-${running_kernel}" 2>/dev/null | grep -q '^ii'; then
        _tag_ok "Kernel headers: linux-headers-${running_kernel} installed"
    else
        _tag_warn "Kernel headers: linux-headers-${running_kernel} NOT installed (needed for DKMS)"
    fi

    # ==================================================================
    # 2. Current Installation State Detection
    # ==================================================================
    _section "2. Current Installation State"

    # --- NVIDIA Driver ---
    local cur_driver_ver="" driver_loaded=false nvidia_smi_ok=false
    if command -v nvidia-smi &>/dev/null; then
        nvidia_smi_ok=true
        cur_driver_ver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || true)
    fi
    if lsmod 2>/dev/null | grep -q '^nvidia '; then
        driver_loaded=true
    fi
    local driver_pkg_ver=""
    driver_pkg_ver=$(dpkg -l 'nvidia-driver-*' 2>/dev/null | grep '^ii' | head -1 | awk '{print $2 " (" $3 ")"}' || true)

    printf "  %-22s" "NVIDIA Driver:"
    if [ -n "$cur_driver_ver" ]; then
        printf "installed (v%s)" "$cur_driver_ver"
        [ "$driver_loaded" = true ] && printf ", module loaded" || printf ", module NOT loaded"
        [ "$nvidia_smi_ok" = true ] && printf ", nvidia-smi OK" || printf ", nvidia-smi FAIL"
        printf "\n"
        [ -n "$driver_pkg_ver" ] && printf "  %-22s%s\n" "" "package: $driver_pkg_ver"
    else
        printf "not installed\n"
    fi

    # --- CUDA Toolkit ---
    local cur_cuda_ver="" nvcc_path="" cuda_symlink_target=""
    if command -v nvcc &>/dev/null; then
        nvcc_path=$(command -v nvcc)
        cur_cuda_ver=$(nvcc --version 2>/dev/null | sed -n 's/.*release \([0-9]*\.[0-9]*\).*/\1/p' || true)
    elif [ -x /usr/local/cuda/bin/nvcc ]; then
        nvcc_path="/usr/local/cuda/bin/nvcc"
        cur_cuda_ver=$(/usr/local/cuda/bin/nvcc --version 2>/dev/null | sed -n 's/.*release \([0-9]*\.[0-9]*\).*/\1/p' || true)
    fi
    if [ -L /usr/local/cuda ]; then
        cuda_symlink_target=$(readlink -f /usr/local/cuda 2>/dev/null || true)
    fi

    printf "  %-22s" "CUDA Toolkit:"
    if [ -n "$cur_cuda_ver" ]; then
        printf "installed (v%s)" "$cur_cuda_ver"
        [ -n "$nvcc_path" ] && printf ", nvcc: %s" "$nvcc_path"
        printf "\n"
        [ -n "$cuda_symlink_target" ] && printf "  %-22s/usr/local/cuda -> %s\n" "" "$cuda_symlink_target"
    else
        printf "not installed\n"
    fi

    # --- cuDNN ---
    local cur_cudnn_ver="" cur_cudnn_pkg=""
    cur_cudnn_pkg=$(dpkg -l 'cudnn9-*' 2>/dev/null | grep '^ii' | head -1 | awk '{print $2}' || true)
    if [ -n "$cur_cudnn_pkg" ]; then
        cur_cudnn_ver=$(dpkg -l "$cur_cudnn_pkg" 2>/dev/null | grep '^ii' | awk '{print $3}' | head -1 || true)
    fi
    # Also check libcudnn
    if [ -z "$cur_cudnn_pkg" ]; then
        cur_cudnn_pkg=$(dpkg -l 'libcudnn*' 2>/dev/null | grep '^ii' | head -1 | awk '{print $2}' || true)
        if [ -n "$cur_cudnn_pkg" ]; then
            cur_cudnn_ver=$(dpkg -l "$cur_cudnn_pkg" 2>/dev/null | grep '^ii' | awk '{print $3}' | head -1 || true)
        fi
    fi

    printf "  %-22s" "cuDNN:"
    if [ -n "$cur_cudnn_ver" ]; then
        printf "installed (v%s, pkg: %s)\n" "$cur_cudnn_ver" "$cur_cudnn_pkg"
    else
        printf "not installed\n"
    fi

    # --- NCCL ---
    local cur_nccl_ver=""
    cur_nccl_ver=$(dpkg -l 'libnccl2' 2>/dev/null | grep '^ii' | awk '{print $3}' | head -1 || true)

    printf "  %-22s" "NCCL:"
    if [ -n "$cur_nccl_ver" ]; then
        printf "installed (v%s)\n" "$cur_nccl_ver"
    else
        printf "not installed\n"
    fi

    # --- Container Toolkit ---
    local ctk_installed=false docker_present=false
    command -v nvidia-ctk &>/dev/null && ctk_installed=true
    command -v docker &>/dev/null && docker_present=true

    printf "  %-22s" "Container Toolkit:"
    if [ "$ctk_installed" = true ]; then
        printf "installed"
    else
        printf "not installed"
    fi
    if [ "$docker_present" = true ]; then
        printf ", Docker present\n"
    else
        printf ", Docker NOT present\n"
    fi

    # --- Enterprise Tools ---
    printf "  %-22s" "Enterprise Tools:"
    local ent_parts=()
    dpkg -l datacenter-gpu-manager 2>/dev/null | grep -q '^ii' && ent_parts+=("DCGM") || true
    dpkg -l 'nvidia-fabricmanager*' 2>/dev/null | grep -q '^ii' && ent_parts+=("FabricMgr") || true
    dpkg -l nvidia-gds 2>/dev/null | grep -q '^ii' && ent_parts+=("GDS") || true
    dpkg -l nvidia-peermem 2>/dev/null | grep -q '^ii' && ent_parts+=("peermem") || true
    if [ ${#ent_parts[@]} -gt 0 ]; then
        local IFS=", "
        printf "%s\n" "${ent_parts[*]}"
    else
        printf "none installed\n"
    fi

    # --- System Tools ---
    printf "  %-22s" "System Tools:"
    local sys_tools_list=("build-essential" "cmake" "ninja-build" "numactl" "hwloc" "nvtop" "lm-sensors" "fio")
    local sys_installed=() sys_missing=()
    for pkg in "${sys_tools_list[@]}"; do
        if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
            sys_installed+=("$pkg")
        else
            sys_missing+=("$pkg")
        fi
    done
    if [ ${#sys_installed[@]} -gt 0 ]; then
        local IFS=", "
        printf "installed: %s" "${sys_installed[*]}"
    fi
    if [ ${#sys_missing[@]} -gt 0 ]; then
        local IFS=", "
        [ ${#sys_installed[@]} -gt 0 ] && printf "\n  %-22s" ""
        printf "missing: %s" "${sys_missing[*]}"
    fi
    printf "\n"

    # --- Kernel Tuning ---
    local sysctl_exists=false cur_max_map="" cur_memlock=""
    [ -f /etc/sysctl.d/99-machine-setting-gpu.conf ] && sysctl_exists=true
    cur_max_map=$(sysctl -n vm.max_map_count 2>/dev/null || echo "unknown")
    cur_memlock=$(ulimit -l 2>/dev/null || echo "unknown")

    printf "  %-22s" "Kernel Tuning:"
    if [ "$sysctl_exists" = true ]; then
        printf "sysctl file exists"
    else
        printf "sysctl file NOT present"
    fi
    printf ", vm.max_map_count=%s, memlock=%s\n" "$cur_max_map" "$cur_memlock"

    # ==================================================================
    # 3. Action Plan
    # ==================================================================
    _section "3. Action Plan"

    # Driver
    if [ "$OPT_DRIVER" = true ]; then
        if [ -n "$cur_driver_ver" ]; then
            if [ -n "$OPT_DRIVER_VERSION" ] && [ "$cur_driver_ver" != "$OPT_DRIVER_VERSION" ]; then
                _tag_upgrade "NVIDIA Driver: $cur_driver_ver -> $OPT_DRIVER_VERSION (open=${USE_OPEN_KERNEL})"
            else
                _tag_ok "NVIDIA Driver: $cur_driver_ver already installed"
            fi
        else
            _tag_install "NVIDIA Driver (${OPT_DRIVER_VERSION:-recommended}, open=${USE_OPEN_KERNEL})"
        fi
    else
        _tag_skip "NVIDIA Driver (--no-driver)"
    fi

    # CUDA
    if [ "$OPT_CUDA" = true ]; then
        if [ -n "$cur_cuda_ver" ]; then
            if [ -n "$OPT_CUDA_VERSION" ]; then
                local requested_dotted="${OPT_CUDA_VERSION//-/.}"
                if [ "$cur_cuda_ver" = "$requested_dotted" ]; then
                    _tag_ok "CUDA Toolkit: $cur_cuda_ver already installed"
                else
                    _tag_upgrade "CUDA Toolkit: $cur_cuda_ver -> $requested_dotted"
                fi
            else
                _tag_ok "CUDA Toolkit: $cur_cuda_ver already installed"
            fi
        else
            _tag_install "CUDA Toolkit (${OPT_CUDA_VERSION:-latest})"
        fi
    else
        _tag_skip "CUDA Toolkit (disabled)"
    fi

    # cuDNN
    if [ "$OPT_CUDNN" = true ]; then
        if [ -n "$cur_cudnn_ver" ]; then
            _tag_ok "cuDNN: $cur_cudnn_ver already installed ($cur_cudnn_pkg)"
        else
            _tag_install "cuDNN 9.x"
        fi
    else
        _tag_skip "cuDNN (disabled)"
    fi

    # NCCL
    if [ "$OPT_NCCL" = true ]; then
        if [ "${GPU_COUNT:-1}" -le 1 ] && [ "$GPU_TIER" != "datacenter" ]; then
            _tag_skip "NCCL (single GPU, non-datacenter)"
        elif [ -n "$cur_nccl_ver" ]; then
            _tag_ok "NCCL: $cur_nccl_ver already installed"
        else
            _tag_install "NCCL (multi-GPU communication)"
        fi
    else
        _tag_skip "NCCL (disabled)"
    fi

    # Enterprise
    if [ "$OPT_ENTERPRISE" = true ]; then
        local ent_install=()
        dpkg -l datacenter-gpu-manager 2>/dev/null | grep -q '^ii' || ent_install+=("DCGM")
        dpkg -l 'nvidia-fabricmanager*' 2>/dev/null | grep -q '^ii' || ent_install+=("FabricMgr")
        dpkg -l nvidia-gds 2>/dev/null | grep -q '^ii' || ent_install+=("GDS")
        dpkg -l nvidia-peermem 2>/dev/null | grep -q '^ii' || ent_install+=("peermem")
        if [ ${#ent_install[@]} -gt 0 ]; then
            local IFS=", "
            _tag_install "Enterprise tools: ${ent_install[*]}"
        else
            _tag_ok "Enterprise tools: all already installed"
        fi
    else
        _tag_skip "Enterprise tools (disabled)"
    fi

    # Container Toolkit
    if [ "$OPT_CONTAINER_TOOLKIT" = true ]; then
        if [ "$docker_present" = false ]; then
            _tag_skip "Container Toolkit (Docker not installed)"
        elif [ "$ctk_installed" = true ]; then
            _tag_ok "Container Toolkit: already installed"
        else
            _tag_install "NVIDIA Container Toolkit"
        fi
    else
        _tag_skip "Container Toolkit (disabled)"
    fi

    # System Tools
    if [ "$OPT_SYSTEM_TOOLS" = true ]; then
        if [ ${#sys_missing[@]} -gt 0 ]; then
            local IFS=", "
            _tag_install "System tools: ${sys_missing[*]}"
        else
            _tag_ok "System tools: all already installed"
        fi
    else
        _tag_skip "System tools (disabled)"
    fi

    # Kernel Tuning
    if [ "$OPT_KERNEL_TUNING" = true ]; then
        if [ "$sysctl_exists" = true ]; then
            _tag_ok "Kernel tuning: config already present"
        else
            _tag_install "Kernel/sysctl tuning (GPU optimizations)"
        fi
    else
        _tag_skip "Kernel tuning (disabled)"
    fi

    # ==================================================================
    # 4. Compatibility Matrix
    # ==================================================================
    _section "4. Compatibility Matrix"

    # Driver <-> CUDA version compatibility
    # CUDA 12.x needs driver >= 525, CUDA 13.x needs driver >= 560
    if [ -n "$cur_driver_ver" ] && [ -n "$cur_cuda_ver" ]; then
        local driver_major
        driver_major=$(echo "$cur_driver_ver" | cut -d. -f1)
        local cuda_major
        cuda_major=$(echo "$cur_cuda_ver" | cut -d. -f1)
        local compat_ok=true
        if [ "$cuda_major" -ge 13 ] 2>/dev/null && [ "$driver_major" -lt 560 ] 2>/dev/null; then
            _tag_fail "Driver $cur_driver_ver may be too old for CUDA $cur_cuda_ver (need >= 560.x)"
            compat_ok=false
            blocking_issues=$((blocking_issues + 1))
        elif [ "$cuda_major" -ge 12 ] 2>/dev/null && [ "$driver_major" -lt 525 ] 2>/dev/null; then
            _tag_fail "Driver $cur_driver_ver may be too old for CUDA $cur_cuda_ver (need >= 525.x)"
            compat_ok=false
            blocking_issues=$((blocking_issues + 1))
        fi
        if [ "$compat_ok" = true ]; then
            _tag_ok "Driver $cur_driver_ver <-> CUDA $cur_cuda_ver compatibility"
        fi
    elif [ -n "$cur_driver_ver" ] || [ -n "$cur_cuda_ver" ]; then
        _tag_ok "Partial stack present; compatibility will be validated on install"
    else
        _tag_ok "Fresh install; repo will provide compatible versions"
    fi

    # cuDNN <-> CUDA compatibility
    if [ -n "$cur_cudnn_pkg" ] && [ -n "$cur_cuda_ver" ]; then
        local cudnn_cuda_suffix=""
        cudnn_cuda_suffix=$(echo "$cur_cudnn_pkg" | sed -n 's/.*cuda-\([0-9]*\).*/\1/p')
        local cur_cuda_major
        cur_cuda_major=$(echo "$cur_cuda_ver" | cut -d. -f1)
        if [ -n "$cudnn_cuda_suffix" ] && [ "$cudnn_cuda_suffix" != "$cur_cuda_major" ]; then
            _tag_warn "cuDNN package $cur_cudnn_pkg targets CUDA $cudnn_cuda_suffix but CUDA $cur_cuda_ver is installed"
        else
            _tag_ok "cuDNN <-> CUDA $cur_cuda_ver compatibility"
        fi
    fi

    # GPU architecture <-> driver support
    local gpu_name="${GPU_NAME:-}"
    if [ -n "$gpu_name" ]; then
        # Pre-Kepler GPUs (very old) not supported by modern drivers
        case "$gpu_name" in
            *GT?[2-6][0-9][0-9]*|*GTX?[2-6][0-9][0-9]*)
                _tag_warn "GPU $gpu_name may be too old for latest drivers (pre-Maxwell)"
                ;;
            *)
                _tag_ok "GPU $gpu_name supported by current drivers"
                ;;
        esac
    fi

    # Open kernel module support
    if [ "$USE_OPEN_KERNEL" = true ]; then
        if supports_open_kernel; then
            _tag_ok "Open kernel modules supported (Turing+)"
        else
            _tag_warn "Open kernel modules requested but GPU may not support them (pre-Turing)"
        fi
    else
        _tag_ok "Using proprietary kernel modules"
    fi

    # Secure Boot implications
    if is_secure_boot; then
        _tag_warn "Secure Boot enabled: MOK enrollment will be required after driver install"
    else
        _tag_ok "Secure Boot not enabled (no MOK enrollment needed)"
    fi

    # ==================================================================
    # 5. Conflict & Overlap Detection
    # ==================================================================
    _section "5. Conflict & Overlap Detection"

    local conflicts_found=0

    # Check for manually installed NVIDIA packages vs repo
    local manual_nvidia=""
    manual_nvidia=$(dpkg -l 'nvidia-*' 2>/dev/null | grep '^ii' | grep -v "$(get_repo_arch_string)" | awk '{print $2}' | head -5 || true)
    # Check for PPA sources conflicting with official repo
    local ppa_nvidia=""
    ppa_nvidia=$(grep -rl 'ppa.*nvidia\|graphics-drivers' /etc/apt/sources.list.d/ 2>/dev/null | head -3 || true)
    if [ -n "$ppa_nvidia" ]; then
        _tag_conflict "PPA sources found that may conflict with official NVIDIA repo:"
        for ppa in $ppa_nvidia; do
            printf "  %-22s%s\n" "" "$ppa"
        done
        conflicts_found=$((conflicts_found + 1))
    else
        _tag_ok "No conflicting PPA sources detected"
    fi

    # Multiple CUDA versions
    local cuda_dirs=""
    cuda_dirs=$(ls -d /usr/local/cuda-* 2>/dev/null | sort -V || true)
    local cuda_count=0
    if [ -n "$cuda_dirs" ]; then
        cuda_count=$(echo "$cuda_dirs" | wc -l)
    fi
    if [ "$cuda_count" -gt 1 ]; then
        _tag_warn "Multiple CUDA versions detected:"
        for d in $cuda_dirs; do
            printf "  %-22s%s\n" "" "$d"
        done
    elif [ "$cuda_count" -eq 1 ]; then
        _tag_ok "Single CUDA installation: $cuda_dirs"
    else
        _tag_ok "No existing CUDA installations in /usr/local/"
    fi

    # Broken /usr/local/cuda symlink
    if [ -L /usr/local/cuda ]; then
        if [ ! -e /usr/local/cuda ]; then
            _tag_conflict "Broken symlink: /usr/local/cuda -> $(readlink /usr/local/cuda 2>/dev/null)"
            conflicts_found=$((conflicts_found + 1))
        else
            _tag_ok "/usr/local/cuda symlink OK -> $(readlink -f /usr/local/cuda 2>/dev/null)"
        fi
    elif [ -d /usr/local/cuda ]; then
        _tag_warn "/usr/local/cuda is a directory (not a symlink) — may cause issues"
    else
        _tag_ok "No /usr/local/cuda symlink (will be created on install)"
    fi

    # Leftover config files from previous installs
    local leftover_configs=()
    [ -f /etc/apt/sources.list.d/cuda-ubuntu*.list ] 2>/dev/null && leftover_configs+=("/etc/apt/sources.list.d/cuda-*.list")
    for f in /etc/modprobe.d/nvidia*.conf /etc/modprobe.d/blacklist-nvidia*.conf; do
        [ -f "$f" ] && leftover_configs+=("$f")
    done
    if [ ${#leftover_configs[@]} -gt 0 ]; then
        _tag_warn "Leftover config files detected:"
        for f in "${leftover_configs[@]}"; do
            printf "  %-22s%s\n" "" "$f"
        done
    else
        _tag_ok "No leftover config files detected"
    fi

    if [ "$conflicts_found" -gt 0 ]; then
        _tag_warn "$conflicts_found conflict(s) found — consider --uninstall before proceeding"
    fi

    # ==================================================================
    # 6. Risk Assessment & Warnings
    # ==================================================================
    _section "6. Risk Assessment"

    # Reboot required?
    local reboot_needed=false
    if [ "$OPT_DRIVER" = true ]; then
        if [ -z "$cur_driver_ver" ]; then
            _tag_warn "Reboot REQUIRED after driver installation"
            reboot_needed=true
        elif [ -n "$OPT_DRIVER_VERSION" ] && [ "$cur_driver_ver" != "$OPT_DRIVER_VERSION" ]; then
            _tag_warn "Reboot REQUIRED after driver upgrade"
            reboot_needed=true
        fi
    fi
    if [ "$reboot_needed" = false ]; then
        _tag_ok "No reboot expected"
    fi

    # Secure Boot MOK
    if is_secure_boot && [ "$OPT_DRIVER" = true ]; then
        _tag_warn "Secure Boot: MOK enrollment step required at reboot"
    fi

    # Kernel module conflicts
    if lsmod 2>/dev/null | grep -q '^nouveau '; then
        _tag_warn "nouveau module loaded — will be blacklisted during driver install"
    else
        _tag_ok "No conflicting nouveau module loaded"
    fi

    # Running GPU processes
    if [ "$nvidia_smi_ok" = true ]; then
        local gpu_procs=""
        gpu_procs=$(nvidia-smi --query-compute-apps=pid,name --format=csv,noheader 2>/dev/null || true)
        if [ -n "$gpu_procs" ]; then
            _tag_warn "Active GPU processes (will be interrupted by driver changes):"
            echo "$gpu_procs" | while IFS= read -r line; do
                printf "  %-22s%s\n" "" "$line"
            done
        else
            _tag_ok "No active GPU compute processes"
        fi
    fi

    # Estimated installation time
    local est_time="5-10 minutes"
    if [ "$OPT_ENTERPRISE" = true ]; then est_time="10-20 minutes"; fi
    if [ -z "$cur_driver_ver" ] && [ "$OPT_DRIVER" = true ]; then est_time="10-25 minutes (includes driver DKMS build)"; fi
    _tag_ok "Estimated installation time: $est_time"

    # ==================================================================
    # 7. Summary Report
    # ==================================================================
    _section "7. Summary"

    printf "\n"
    printf "  %-24s %s\n" "GPU:" "${GPU_NAME:-Unknown} (${GPU_COUNT:-1}x, tier: ${GPU_TIER})"
    printf "  %-24s %s\n" "OS:" "${os_name:-Unknown}"
    printf "  %-24s %s\n" "Kernel:" "$(uname -r)"
    printf "  %-24s %s\n" "Open kernel modules:" "$USE_OPEN_KERNEL"
    printf "\n"

    # Build summary table
    printf "  ${_C_BOLD}%-24s %-14s %s${_C_RESET}\n" "Component" "Status" "Detail"
    printf "  %-24s %-14s %s\n" "────────────────────────" "──────────────" "──────────────────────"

    # Helper to print one summary row
    _summary_row() {
        local component="$1" status="$2" detail="$3"
        local color=""
        case "$status" in
            OK)       color="$_C_GREEN" ;;
            INSTALL)  color="$_C_CYAN" ;;
            UPGRADE)  color="$_C_CYAN" ;;
            SKIP)     color="$_C_DIM" ;;
            WARN)     color="$_C_YELLOW" ;;
            FAIL)     color="$_C_RED" ;;
        esac
        printf "  %-24s ${color}%-14s${_C_RESET} %s\n" "$component" "[$status]" "$detail"
    }

    # Driver row
    if [ "$OPT_DRIVER" = true ]; then
        if [ -n "$cur_driver_ver" ]; then
            if [ -n "$OPT_DRIVER_VERSION" ] && [ "$cur_driver_ver" != "$OPT_DRIVER_VERSION" ]; then
                _summary_row "NVIDIA Driver" "UPGRADE" "$cur_driver_ver -> $OPT_DRIVER_VERSION"
            else
                _summary_row "NVIDIA Driver" "OK" "v$cur_driver_ver"
            fi
        else
            _summary_row "NVIDIA Driver" "INSTALL" "${OPT_DRIVER_VERSION:-recommended}"
        fi
    else
        _summary_row "NVIDIA Driver" "SKIP" "--no-driver"
    fi

    # CUDA row
    if [ "$OPT_CUDA" = true ]; then
        if [ -n "$cur_cuda_ver" ]; then
            if [ -n "$OPT_CUDA_VERSION" ]; then
                local req="${OPT_CUDA_VERSION//-/.}"
                if [ "$cur_cuda_ver" = "$req" ]; then
                    _summary_row "CUDA Toolkit" "OK" "v$cur_cuda_ver"
                else
                    _summary_row "CUDA Toolkit" "UPGRADE" "$cur_cuda_ver -> $req"
                fi
            else
                _summary_row "CUDA Toolkit" "OK" "v$cur_cuda_ver"
            fi
        else
            _summary_row "CUDA Toolkit" "INSTALL" "${OPT_CUDA_VERSION:-latest}"
        fi
    else
        _summary_row "CUDA Toolkit" "SKIP" "disabled"
    fi

    # cuDNN row
    if [ "$OPT_CUDNN" = true ]; then
        if [ -n "$cur_cudnn_ver" ]; then
            _summary_row "cuDNN" "OK" "v$cur_cudnn_ver"
        else
            _summary_row "cuDNN" "INSTALL" "9.x"
        fi
    else
        _summary_row "cuDNN" "SKIP" "disabled"
    fi

    # NCCL row
    if [ "$OPT_NCCL" = true ]; then
        if [ "${GPU_COUNT:-1}" -le 1 ] && [ "$GPU_TIER" != "datacenter" ]; then
            _summary_row "NCCL" "SKIP" "single GPU"
        elif [ -n "$cur_nccl_ver" ]; then
            _summary_row "NCCL" "OK" "v$cur_nccl_ver"
        else
            _summary_row "NCCL" "INSTALL" "multi-GPU comms"
        fi
    else
        _summary_row "NCCL" "SKIP" "disabled"
    fi

    # Enterprise row
    if [ "$OPT_ENTERPRISE" = true ]; then
        if [ ${#ent_parts[@]} -ge 4 ]; then
            _summary_row "Enterprise Tools" "OK" "all present"
        elif [ ${#ent_parts[@]} -gt 0 ]; then
            local IFS=", "
            _summary_row "Enterprise Tools" "INSTALL" "partial: have ${ent_parts[*]}"
        else
            _summary_row "Enterprise Tools" "INSTALL" "DCGM, FabricMgr, GDS, peermem"
        fi
    else
        _summary_row "Enterprise Tools" "SKIP" "disabled"
    fi

    # Container Toolkit row
    if [ "$OPT_CONTAINER_TOOLKIT" = true ]; then
        if [ "$docker_present" = false ]; then
            _summary_row "Container Toolkit" "SKIP" "no Docker"
        elif [ "$ctk_installed" = true ]; then
            _summary_row "Container Toolkit" "OK" "installed"
        else
            _summary_row "Container Toolkit" "INSTALL" "nvidia-ctk"
        fi
    else
        _summary_row "Container Toolkit" "SKIP" "disabled"
    fi

    # System Tools row
    if [ "$OPT_SYSTEM_TOOLS" = true ]; then
        if [ ${#sys_missing[@]} -eq 0 ]; then
            _summary_row "System Tools" "OK" "all present"
        else
            _summary_row "System Tools" "INSTALL" "${#sys_missing[@]} packages"
        fi
    else
        _summary_row "System Tools" "SKIP" "disabled"
    fi

    # Kernel Tuning row
    if [ "$OPT_KERNEL_TUNING" = true ]; then
        if [ "$sysctl_exists" = true ]; then
            _summary_row "Kernel Tuning" "OK" "config present"
        else
            _summary_row "Kernel Tuning" "INSTALL" "sysctl + limits"
        fi
    else
        _summary_row "Kernel Tuning" "SKIP" "disabled"
    fi

    printf "\n"

    # Final verdict
    if [ "$blocking_issues" -gt 0 ]; then
        printf "  ${_C_RED}${_C_BOLD}RESULT: %d blocking issue(s) found — installation would FAIL${_C_RESET}\n" "$blocking_issues"
        printf "  Resolve the [FAIL] items above before proceeding.\n"
    else
        printf "  ${_C_GREEN}${_C_BOLD}RESULT: All checks passed — installation can proceed${_C_RESET}\n"
    fi
    printf "\n"

    return "$blocking_issues"
}

# Run dry-run diagnostic and exit
if [ "$OPT_DRY_RUN" = true ]; then
    run_dry_run_diagnostic
    exit_code=$?
    if [ "$exit_code" -gt 0 ]; then
        exit 1
    fi
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
