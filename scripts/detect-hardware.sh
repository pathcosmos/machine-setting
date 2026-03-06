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

# --- Profile Suggestion ---
if [ "$GPU_BACKEND" = "mps" ]; then
    SUGGESTED_PROFILE="mac-apple-silicon"
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
SUGGESTED_PROFILE="${SUGGESTED_PROFILE}"
EOF

echo ""
echo "Profile saved to: $PROFILE"
