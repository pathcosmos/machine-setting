#!/usr/bin/env bash
# Detect hardware capabilities: GPU, CUDA/MPS, RAM, CPU, OS
# Cross-platform: Linux (x86_64) + macOS (Apple Silicon arm64)
# Outputs to ~/.machine_setting_profile (sourced by other scripts)
set -euo pipefail

PROFILE="${1:-$HOME/.machine_setting_profile}"
OS_TYPE="$(uname -s)"    # Darwin or Linux

echo "=== Hardware Detection ==="

# --- GPU Detection ---
HAS_GPU=false
GPU_NAME=""
GPU_COUNT=0
GPU_BACKEND=""           # cuda | mps | none
CUDA_VERSION=""
CUDA_SUFFIX="cpu"

case "$OS_TYPE" in
    Linux)
        # Try lspci first (may not work in containers)
        if command -v lspci &>/dev/null; then
            GPU_INFO=$(lspci 2>/dev/null | grep -i 'vga\|3d\|display' | grep -i nvidia || true)
            if [ -n "$GPU_INFO" ]; then
                HAS_GPU=true
                GPU_BACKEND="cuda"
                GPU_COUNT=$(echo "$GPU_INFO" | wc -l)
                if command -v nvidia-smi &>/dev/null; then
                    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "Unknown NVIDIA GPU")
                else
                    GPU_NAME=$(echo "$GPU_INFO" | head -1 | sed 's/.*: //')
                fi
            fi
        fi
        # Fallback: nvidia-smi (containers often expose GPU without lspci)
        if [ "$HAS_GPU" = false ] && command -v nvidia-smi &>/dev/null; then
            GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)
            if [ -n "$GPU_NAME" ]; then
                HAS_GPU=true
                GPU_BACKEND="cuda"
                GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l)
            fi
        fi
        ;;
    Darwin)
        # Apple Silicon has GPU via Metal Performance Shaders (MPS)
        CHIP_INFO=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || true)
        if [[ "$(uname -m)" == "arm64" ]]; then
            HAS_GPU=true
            GPU_BACKEND="mps"
            GPU_COUNT=1
            # Extract chip name from system_profiler
            GPU_NAME=$(system_profiler SPDisplaysDataType 2>/dev/null | grep "Chipset Model" | sed 's/.*: //' | head -1 || echo "Apple Silicon GPU")
            CUDA_SUFFIX="mps"
        fi
        ;;
esac

# --- CUDA Detection (Linux only) ---
if [ "$GPU_BACKEND" = "cuda" ]; then
    if command -v nvcc &>/dev/null; then
        CUDA_VERSION=$(nvcc --version 2>/dev/null | sed -n 's/.*release \([0-9]*\.[0-9]*\).*/\1/p' || true)
    elif [ -f /usr/local/cuda/version.txt ]; then
        CUDA_VERSION=$(sed -n 's/.*\([0-9]\{1,\}\.[0-9]\{1,\}\).*/\1/p' /usr/local/cuda/version.txt | head -1)
    elif command -v nvidia-smi &>/dev/null; then
        CUDA_VERSION=$(nvidia-smi 2>/dev/null | sed -n 's/.*CUDA Version: \([0-9]*\.[0-9]*\).*/\1/p' || true)
    fi

    if [ -n "$CUDA_VERSION" ]; then
        CUDA_SUFFIX="cu$(echo "$CUDA_VERSION" | tr -d '.')"

        # Fallback: if detected suffix not in gpu-index-urls.conf, use nearest lower version
        SCRIPT_DIR_HW="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        REPO_DIR_HW="$(dirname "$SCRIPT_DIR_HW")"
        GPU_URLS_CONF="$REPO_DIR_HW/config/gpu-index-urls.conf"
        if [ -f "$GPU_URLS_CONF" ] && ! grep -q "^${CUDA_SUFFIX}=" "$GPU_URLS_CONF"; then
            ORIGINAL_SUFFIX="$CUDA_SUFFIX"
            for fallback in $(grep -oP '^cu\d+' "$GPU_URLS_CONF" | sort -rV); do
                if [[ "$fallback" < "$CUDA_SUFFIX" ]] || [[ "$fallback" == "$CUDA_SUFFIX" ]]; then
                    CUDA_SUFFIX="$fallback"
                    break
                fi
            done
            if [ "$ORIGINAL_SUFFIX" != "$CUDA_SUFFIX" ]; then
                echo "  Note: ${ORIGINAL_SUFFIX} not in index, falling back to ${CUDA_SUFFIX}"
            fi
        fi
    fi
fi

# --- System Info (cross-platform) ---
ARCH=$(uname -m)

case "$OS_TYPE" in
    Linux)
        OS_NAME=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo "Linux")
        OS_ID=$(. /etc/os-release 2>/dev/null && echo "$ID" || echo "linux")
        RAM_GB=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo "unknown")
        CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | sed 's/.*: //' || echo "unknown")
        CPU_CORES=$(nproc 2>/dev/null || echo "unknown")
        ;;
    Darwin)
        OS_NAME="macOS $(sw_vers -productVersion 2>/dev/null || echo 'unknown')"
        OS_ID="macos"
        # macOS: hw.memsize is in bytes
        RAM_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
        RAM_GB=$(( RAM_BYTES / 1073741824 ))
        CPU_MODEL=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Apple Silicon")
        CPU_CORES=$(sysctl -n hw.ncpu 2>/dev/null || echo "unknown")
        ;;
    *)
        OS_NAME="$OS_TYPE"
        OS_ID="unknown"
        RAM_GB="unknown"
        CPU_MODEL="unknown"
        CPU_CORES="unknown"
        ;;
esac

# --- NGC Container Detection ---
IS_NGC_CONTAINER=false
if [ "$GPU_BACKEND" = "cuda" ]; then
    # NGC containers have NV custom torch in system site-packages
    if python3 -c "import torch; assert 'nv' in torch.__version__ or '+cu' in torch.__version__" 2>/dev/null; then
        IS_NGC_CONTAINER=true
    # Also check common NGC markers
    elif [ -f /etc/nvidia/entrypoint.d ] || [ -d /opt/nvidia ] || grep -q "NGC" /etc/os-release 2>/dev/null; then
        IS_NGC_CONTAINER=true
    fi
fi

# --- Cloud / Container Environment Detection ---
IS_CLOUD=false
CLOUD_REASON=""
HAS_SUDO=true

# Check sudo availability
if ! command -v sudo &>/dev/null; then
    HAS_SUDO=false
elif ! sudo -n true 2>/dev/null; then
    # sudo exists but requires password or is denied
    HAS_SUDO=false
fi

# Detect container environments
if [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then
    IS_CLOUD=true
    CLOUD_REASON="container detected"
elif grep -qsE '(docker|containerd|lxc|kubepods)' /proc/1/cgroup 2>/dev/null; then
    IS_CLOUD=true
    CLOUD_REASON="cgroup container detected"
elif [ -n "${KUBERNETES_SERVICE_HOST:-}" ]; then
    IS_CLOUD=true
    CLOUD_REASON="Kubernetes pod"
fi

# Detect cloud VM metadata (common cloud providers)
if [ "$IS_CLOUD" = false ]; then
    if [ -f /sys/class/dmi/id/board_vendor ] 2>/dev/null; then
        VENDOR=$(cat /sys/class/dmi/id/board_vendor 2>/dev/null || true)
        case "$VENDOR" in
            *Amazon*|*Google*|*Microsoft*|*DigitalOcean*|*Vultr*|*Oracle*)
                IS_CLOUD=true
                CLOUD_REASON="cloud VM ($VENDOR)"
                ;;
        esac
    fi
fi

# No sudo + not already detected = treat as cloud-like restricted environment
if [ "$HAS_SUDO" = false ] && [ "$IS_CLOUD" = false ]; then
    IS_CLOUD=true
    CLOUD_REASON="no sudo access"
fi

# --- Profile Suggestion ---
if [ "$GPU_BACKEND" = "mps" ]; then
    SUGGESTED_PROFILE="mac-apple-silicon"
elif [ "$IS_NGC_CONTAINER" = true ]; then
    SUGGESTED_PROFILE="ngc-container"
elif [ "$IS_CLOUD" = true ]; then
    SUGGESTED_PROFILE="cloud-server"
elif [ "$GPU_BACKEND" = "cuda" ]; then
    SUGGESTED_PROFILE="gpu-workstation"
elif [ "$OS_ID" = "macos" ]; then
    SUGGESTED_PROFILE="laptop"
elif [ "$RAM_GB" != "unknown" ] && [ "$RAM_GB" -ge 32 ] 2>/dev/null; then
    SUGGESTED_PROFILE="cpu-server"
elif [ "$RAM_GB" != "unknown" ] && [ "$RAM_GB" -ge 8 ] 2>/dev/null; then
    SUGGESTED_PROFILE="laptop"
else
    SUGGESTED_PROFILE="minimal"
fi

# --- Output ---
echo "  OS: ${OS_NAME} (${ARCH})"
echo "  CPU: ${CPU_MODEL} (${CPU_CORES} cores)"
echo "  RAM: ${RAM_GB}GB"
echo "  GPU: ${HAS_GPU} (${GPU_COUNT}x ${GPU_NAME:-none})"
echo "  Backend: ${GPU_BACKEND:-none}"
[ "$GPU_BACKEND" = "cuda" ] && echo "  CUDA: ${CUDA_VERSION:-none} (${CUDA_SUFFIX})"
[ "$GPU_BACKEND" = "mps" ] && echo "  MPS: available (Metal Performance Shaders)"
[ "$IS_NGC_CONTAINER" = true ] && echo "  NGC: detected (NV custom builds available)"
[ "$IS_CLOUD" = true ] && echo "  Cloud: yes (${CLOUD_REASON})"
[ "$HAS_SUDO" = false ] && echo "  Sudo: not available (user-space install only)"
echo "  Profile: ${SUGGESTED_PROFILE}"

# --- Write profile ---
cat > "$PROFILE" << EOF
# Auto-generated by detect-hardware.sh on $(date -I)
# Do NOT commit this file
OS_TYPE="${OS_TYPE}"
OS_NAME="${OS_NAME}"
OS_ID="${OS_ID}"
ARCH="${ARCH}"
RAM_GB=${RAM_GB}
CPU_MODEL="${CPU_MODEL}"
CPU_CORES=${CPU_CORES}
HAS_GPU=${HAS_GPU}
GPU_NAME="${GPU_NAME}"
GPU_COUNT=${GPU_COUNT}
GPU_BACKEND="${GPU_BACKEND}"
CUDA_VERSION="${CUDA_VERSION}"
CUDA_SUFFIX="${CUDA_SUFFIX}"
IS_NGC_CONTAINER=${IS_NGC_CONTAINER}
IS_CLOUD=${IS_CLOUD}
CLOUD_REASON="${CLOUD_REASON}"
HAS_SUDO=${HAS_SUDO}
SUGGESTED_PROFILE="${SUGGESTED_PROFILE}"
EOF

echo ""
echo "Profile saved to: $PROFILE"
