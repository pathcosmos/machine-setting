#!/usr/bin/env bash
# lib-existing.sh — Find what is ALREADY on the machine, however it was installed.
#
# Sourced by preflight.sh. Each ex_* function sets EX_<NAME>_* variables and never changes anything.
# "managed" = installed the way this project does it (uv, NVM, SDKMAN, NVIDIA apt repo, docker-ce);
# "foreign" = came from somewhere else (distro package, snap, vendor installer, pyenv, conda, ...).

_ex_dpkg_ver() { dpkg-query -W -f='${Status} ${Version}\n' "$1" 2>/dev/null | awk '/^install ok installed/ {print $4; exit}'; }
_ex_dpkg_glob() {   # names of installed packages matching a glob
    dpkg-query -W -f='${Status} ${Package}\n' "$1" 2>/dev/null | awk '/^install ok installed/ {print $4}'
}

# ---- NVIDIA driver -------------------------------------------------------------------
# EX_DRIVER_VER, EX_DRIVER_SRC (apt|ppa|run-installer|""), EX_DRIVER_LOADED (true|false), EX_DRIVER_PKG
ex_nvidia_driver() {
    EX_DRIVER_VER=""; EX_DRIVER_SRC=""; EX_DRIVER_LOADED=false; EX_DRIVER_PKG=""
    if command -v nvidia-smi &>/dev/null; then
        EX_DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || true)
        [ -n "$EX_DRIVER_VER" ] && EX_DRIVER_LOADED=true
    fi
    if [ -x /usr/bin/nvidia-uninstall ]; then
        EX_DRIVER_SRC="run-installer"
        [ -z "$EX_DRIVER_VER" ] && EX_DRIVER_VER=$(sed -n 's/.*Kernel Module[^0-9]*\([0-9.]*\).*/\1/p' /proc/driver/nvidia/version 2>/dev/null | head -1)
    elif command -v dpkg-query &>/dev/null; then
        EX_DRIVER_PKG=$(_ex_dpkg_glob 'nvidia-driver-*' | head -1)
        [ -z "$EX_DRIVER_PKG" ] && EX_DRIVER_PKG=$(_ex_dpkg_glob 'linux-modules-nvidia-*' | head -1)
        if [ -n "$EX_DRIVER_PKG" ]; then
            EX_DRIVER_SRC="apt"
            grep -rqs 'graphics-drivers' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null && EX_DRIVER_SRC="ppa"
            [ -z "$EX_DRIVER_VER" ] && EX_DRIVER_VER=$(_ex_dpkg_ver "$EX_DRIVER_PKG" | sed 's/-.*//')
        fi
    fi
}

# ---- CUDA toolkit / cuDNN / NCCL -----------------------------------------------------
# EX_CUDA_VERS (space separated, e.g. "12.4 13.5"), EX_CUDA_ACTIVE, EX_CUDNN_VER, EX_NCCL_VER
ex_cuda() {
    EX_CUDA_VERS=""; EX_CUDA_ACTIVE=""; EX_CUDNN_VER=""; EX_NCCL_VER=""
    local d
    for d in /usr/local/cuda-*; do
        [ -L "$d" ] && continue                          # cuda-13 -> cuda-13.5 style links
        [ -x "$d/bin/nvcc" ] && EX_CUDA_VERS="$EX_CUDA_VERS ${d##*/cuda-}"
    done
    EX_CUDA_VERS="${EX_CUDA_VERS# }"
    local nvcc; nvcc=$(command -v nvcc 2>/dev/null || true)
    [ -z "$nvcc" ] && [ -x /usr/local/cuda/bin/nvcc ] && nvcc=/usr/local/cuda/bin/nvcc
    [ -n "$nvcc" ] && EX_CUDA_ACTIVE=$("$nvcc" --version 2>/dev/null | sed -n 's/.*release \([0-9]*\.[0-9]*\).*/\1/p')
    [ -z "$EX_CUDA_VERS" ] && EX_CUDA_VERS="$EX_CUDA_ACTIVE"
    if command -v dpkg-query &>/dev/null; then
        local p
        p=$(_ex_dpkg_glob 'cudnn9-cuda-*' | head -1); [ -z "$p" ] && p=$(_ex_dpkg_glob 'libcudnn*' | grep -v dev | head -1)
        [ -n "$p" ] && EX_CUDNN_VER=$(_ex_dpkg_ver "$p" | sed 's/-.*//')
        p=$(_ex_dpkg_glob 'libnccl2' | head -1)
        [ -n "$p" ] && EX_NCCL_VER=$(_ex_dpkg_ver "$p" | sed 's/-.*//; s/+.*//')
    fi
}

# ---- uv + Python ---------------------------------------------------------------------
# EX_UV_VER, EX_UV_SRC (standalone|brew|pip|snap|other), EX_UV_PY (uv-managed version for the target),
# EX_PY_OTHERS (human list of other Pythons: "system 3.14.0, pyenv, conda")
ex_python() {   # $1 = target version, e.g. 3.12
    EX_UV_VER=""; EX_UV_SRC=""; EX_UV_PY=""; EX_PY_OTHERS=""
    local uv; uv=$(command -v uv 2>/dev/null || true)
    [ -z "$uv" ] && [ -x "$HOME/.local/bin/uv" ] && uv="$HOME/.local/bin/uv"
    if [ -n "$uv" ]; then
        EX_UV_VER=$("$uv" --version 2>/dev/null | awk '{print $2}')
        case "$(readlink -f "$uv")" in
            "$HOME"/.local/bin/*|"$HOME"/.cargo/bin/*) EX_UV_SRC="standalone" ;;
            */Cellar/*|/opt/homebrew/*|/home/linuxbrew/*) EX_UV_SRC="brew" ;;
            /snap/*) EX_UV_SRC="snap" ;;
            */site-packages/*|*/pipx/*) EX_UV_SRC="pip" ;;
            *) EX_UV_SRC="other" ;;
        esac
        local bin; bin=$("$uv" python find --managed-python "$1" 2>/dev/null || true)
        [ -n "$bin" ] && [ -x "$bin" ] && EX_UV_PY=$("$bin" --version 2>/dev/null | awk '{print $2}')
    fi
    local others=()
    if [ -x /usr/bin/python3 ]; then others+=("system $(/usr/bin/python3 --version 2>&1 | awk '{print $2}')"); fi
    { [ -d "$HOME/.pyenv" ] || command -v pyenv &>/dev/null; } && others+=("pyenv")
    local c
    for c in "$HOME/miniconda3" "$HOME/anaconda3" "$HOME/miniforge3" "$HOME/mambaforge" /opt/conda; do
        [ -x "$c/bin/conda" ] && { others+=("conda ($c)"); break; }
    done
    [ ${#others[@]} -gt 0 ] && EX_PY_OTHERS=$(IFS=,; echo "${others[*]}" | sed 's/,/, /g')
    return 0
}

# ---- Node.js -------------------------------------------------------------------------
# EX_NODE_NVM_VER (default NVM node), EX_NODE_NVM_ALL, EX_NODE_FOREIGN_VER, EX_NODE_FOREIGN_SRC (apt|snap|fnm|volta|brew|other)
ex_node() {
    EX_NODE_NVM_VER=""; EX_NODE_NVM_ALL=""; EX_NODE_FOREIGN_VER=""; EX_NODE_FOREIGN_SRC=""
    local nvm_dir="${NVM_DIR:-$HOME/.nvm}"
    if [ -d "$nvm_dir/versions/node" ]; then
        EX_NODE_NVM_ALL=$(ls "$nvm_dir/versions/node" 2>/dev/null | sort -V | tr '\n' ' ' | sed 's/ $//')
        local def=""
        [ -f "$nvm_dir/alias/default" ] && def=$(cat "$nvm_dir/alias/default")
        EX_NODE_NVM_VER=$(ls "$nvm_dir/versions/node" 2>/dev/null | sort -V | grep -E "^v?${def#v}" | tail -1)
        [ -z "$EX_NODE_NVM_VER" ] && EX_NODE_NVM_VER=$(ls "$nvm_dir/versions/node" 2>/dev/null | sort -V | tail -1)
    fi
    local p
    for p in /usr/bin/node /usr/local/bin/node /snap/bin/node /opt/homebrew/bin/node "$HOME/.volta/bin/node" "$HOME/.local/share/fnm/aliases/default/bin/node"; do
        [ -x "$p" ] || continue
        EX_NODE_FOREIGN_VER=$("$p" --version 2>/dev/null)
        case "$p" in
            /snap/*) EX_NODE_FOREIGN_SRC="snap" ;;
            */.volta/*) EX_NODE_FOREIGN_SRC="volta" ;;
            */fnm/*) EX_NODE_FOREIGN_SRC="fnm" ;;
            /opt/homebrew/*) EX_NODE_FOREIGN_SRC="brew" ;;
            /usr/bin/node) [ -n "$(_ex_dpkg_ver nodejs)" ] && EX_NODE_FOREIGN_SRC="apt" || EX_NODE_FOREIGN_SRC="other" ;;
            *) EX_NODE_FOREIGN_SRC="other" ;;
        esac
        break
    done
    return 0
}

# ---- Java ----------------------------------------------------------------------------
# EX_JAVA_SDK_VER (SDKMAN current), EX_JAVA_FOREIGN_VER, EX_JAVA_FOREIGN_SRC (apt|other), EX_JAVA_FOREIGN_PKGS
ex_java() {
    EX_JAVA_SDK_VER=""; EX_JAVA_FOREIGN_VER=""; EX_JAVA_FOREIGN_SRC=""; EX_JAVA_FOREIGN_PKGS=""
    local sdk="${SDKMAN_DIR:-$HOME/.sdkman}/candidates/java/current"
    if [ -x "$sdk/bin/java" ]; then
        EX_JAVA_SDK_VER=$(basename "$(readlink -f "$sdk")")
    fi
    if command -v dpkg-query &>/dev/null; then
        EX_JAVA_FOREIGN_PKGS=$( { _ex_dpkg_glob 'openjdk-*-jdk*'; _ex_dpkg_glob 'openjdk-*-jre*'; _ex_dpkg_glob 'default-jdk*'; _ex_dpkg_glob 'default-jre*'; } | sort -u | tr '\n' ' ' | sed 's/ $//')
    fi
    local p=""
    [ -x /usr/bin/java ] && p=/usr/bin/java
    [ -z "$p" ] && [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ] && [[ "$JAVA_HOME" != *".sdkman"* ]] && p="$JAVA_HOME/bin/java"
    if [ -n "$p" ]; then
        EX_JAVA_FOREIGN_VER=$("$p" -version 2>&1 | sed -n '1s/.*"\(.*\)".*/\1/p')
        [ -n "$EX_JAVA_FOREIGN_PKGS" ] && EX_JAVA_FOREIGN_SRC="apt" || EX_JAVA_FOREIGN_SRC="other"
    fi
    return 0
}

# ---- Docker --------------------------------------------------------------------------
# EX_DOCKER_VER, EX_DOCKER_SRC (docker-ce|docker.io|snap|podman|other), EX_DOCKER_COMPOSE (true|false)
ex_docker() {
    EX_DOCKER_VER=""; EX_DOCKER_SRC=""; EX_DOCKER_COMPOSE=false
    command -v docker &>/dev/null || return 0
    EX_DOCKER_VER=$(docker --version 2>/dev/null | sed 's/.*version //; s/,.*//')
    if [ -n "$(_ex_dpkg_ver docker-ce)" ]; then EX_DOCKER_SRC="docker-ce"
    elif [ -n "$(_ex_dpkg_ver docker.io)" ]; then EX_DOCKER_SRC="docker.io"
    elif [ -n "$(_ex_dpkg_ver podman-docker)" ]; then EX_DOCKER_SRC="podman"
    elif [[ "$(readlink -f "$(command -v docker)")" == /snap/* ]]; then EX_DOCKER_SRC="snap"
    else EX_DOCKER_SRC="other"; fi
    docker compose version &>/dev/null && EX_DOCKER_COMPOSE=true
    return 0
}

# ---- Who is listening on a TCP port (for the monitoring stack) ------------------------
ex_port_in_use() {   # $1 = port; prints the process name (or "in use") and returns 0 when taken
    local out
    out=$(ss -Hltnp "sport = :$1" 2>/dev/null | head -1)
    [ -z "$out" ] && return 1
    echo "$out" | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | grep . || echo "in use"
}
