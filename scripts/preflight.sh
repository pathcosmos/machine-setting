#!/usr/bin/env bash
# preflight.sh — Pre-flight system check and installation planner
#
# Finds what is already on the machine (however it was installed), compares it with the target
# profile and lets you decide per component: install, update, replace, or keep/skip.
#
# Usage:
#   ./scripts/preflight.sh                       # Interactive (detect + plan + confirm)
#   ./scripts/preflight.sh --quiet               # Non-interactive (detect + write plan)
#   ./scripts/preflight.sh --check-only          # Show status only, no plan file
#   ./scripts/preflight.sh --profile <name>      # Force specific profile
#   ./scripts/preflight.sh --existing <policy>   # What to propose for things that already exist:
#                                                #   keep (default) | update | replace
#   ./scripts/preflight.sh --server / --vllm     # Propose the server extras / vLLM even if the profile does not
#
# Actions written to the plan (env/.preflight_plan, read by setup.sh) as PLAN_<KEY>=<action>:
#   run      install (nothing there yet, or install the managed version next to a foreign one)
#   update   bring an existing managed install to the target / latest version
#   replace  remove what is there and install the managed version
#   skip     keep what is there / do not install
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PKG_DIR="$REPO_DIR/packages"
PLAN_FILE="$REPO_DIR/env/.preflight_plan"

# --- Load config ---
source "$REPO_DIR/config/default.conf"
[ -f "$REPO_DIR/config/machine.conf" ] && source "$REPO_DIR/config/machine.conf"
source "$SCRIPT_DIR/lib-existing.sh"
export PATH="$HOME/.local/bin:$PATH"

# --- Parse arguments ---
MODE="interactive"    # interactive | quiet | check-only
FORCE_PROFILE=""
POLICY="${EXISTING_POLICY:-keep}"
WANT_SERVER=""; WANT_VLLM=""; WANT_NODE=""; WANT_JAVA=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --quiet)      MODE="quiet"; shift ;;
        --check-only) MODE="check-only"; shift ;;
        --profile)    FORCE_PROFILE="$2"; shift 2 ;;
        --existing)   POLICY="$2"; shift 2 ;;
        --server)     WANT_SERVER=true; shift ;;
        --vllm)       WANT_VLLM=true; shift ;;
        --no-vllm)    WANT_VLLM=false; shift ;;
        --node)       WANT_NODE=true; shift ;;
        --no-node)    WANT_NODE=false; shift ;;
        --java)       WANT_JAVA=true; shift ;;
        --no-java)    WANT_JAVA=false; shift ;;
        --python-version) PYTHON_VERSION="$2"; shift 2 ;;
        --help|-h)    sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done
case "$POLICY" in keep|update|replace) ;; *) echo "Unknown --existing policy: $POLICY (keep|update|replace)"; exit 1 ;; esac

# ============================================================
# Components (parallel arrays + per-action descriptions)
# ============================================================
COMP_KEYS=()         # internal key -> PLAN_<KEY>
COMP_NAMES=()        # display name
COMP_STATUS=()       # what was found
COMP_ACTIONS=()      # chosen action: run | update | replace | skip
COMP_OPTIONS=()      # actions allowed for this component (space separated)
COMP_GROUP=()        # core | server
declare -A DESC      # DESC[KEY:action] = what that action does
declare -A EXISTS    # EXISTS[KEY] = 1 when something is already there

# add KEY NAME STATUS DEFAULT "OPTIONS" [GROUP]
add() {
    COMP_KEYS+=("$1"); COMP_NAMES+=("$2"); COMP_STATUS+=("$3"); COMP_ACTIONS+=("$4"); COMP_OPTIONS+=("$5"); COMP_GROUP+=("${6:-core}")
}
# Default action for something that already exists, following the policy.
# by_policy "<options>" [foreign]
#   update  -> update where offered, otherwise keep
#   replace -> replace only FOREIGN installs (the point of that policy); managed ones are updated,
#              never wiped by a blanket policy — pick REPLACE on the item itself for that
by_policy() {
    local opts=" $1 " foreign="${2:-}"
    case "$POLICY" in
        replace) [ -n "$foreign" ] && [[ "$opts" == *" replace "* ]] && { echo replace; return; }
                 [[ "$opts" == *" update "* ]] && { echo update; return; } ;;
        update)  [[ "$opts" == *" update "* ]] && { echo update; return; } ;;
    esac
    echo skip
}

# ============================================================
# Hardware Detection (non-destructive read)
# ============================================================
detect_system() {
    local os_type arch ram_gb cpu_model cpu_cores
    os_type="$(uname -s)"
    arch="$(uname -m)"

    case "$os_type" in
        Linux)
            OS_NAME=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo "Linux")
            ram_gb=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo "?")
            cpu_model=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | sed 's/.*: //' || echo "unknown")
            cpu_cores=$(nproc 2>/dev/null || echo "?")
            ;;
        Darwin)
            OS_NAME="macOS $(sw_vers -productVersion 2>/dev/null || echo '?')"
            local ram_bytes
            ram_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
            ram_gb=$(( ram_bytes / 1073741824 ))
            cpu_model=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Apple Silicon")
            cpu_cores=$(sysctl -n hw.ncpu 2>/dev/null || echo "?")
            ;;
        *)
            OS_NAME="$os_type"
            ram_gb="?"; cpu_model="unknown"; cpu_cores="?"
            ;;
    esac

    # GPU detection
    _HAS_GPU=false
    _GPU_NAME=""
    _GPU_BACKEND="none"
    _CUDA_VERSION=""
    _CUDA_SUFFIX="cpu"

    case "$os_type" in
        Linux)
            local gpu_info=""
            if command -v lspci &>/dev/null; then
                gpu_info=$(lspci 2>/dev/null | grep -i 'vga\|3d\|display' | grep -i nvidia || true)
            fi
            if [ -n "$gpu_info" ]; then
                _HAS_GPU=true
                _GPU_BACKEND="cuda"
                if command -v nvidia-smi &>/dev/null; then
                    _GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "NVIDIA GPU")
                else
                    _GPU_NAME=$(echo "$gpu_info" | head -1 | sed 's/.*: //')
                fi
                # CUDA version (nvcc first, then nvidia-smi)
                if command -v nvcc &>/dev/null; then
                    _CUDA_VERSION=$(nvcc --version 2>/dev/null | sed -n 's/.*release \([0-9]*\.[0-9]*\).*/\1/p' || true)
                elif command -v nvidia-smi &>/dev/null; then
                    _CUDA_VERSION=$(nvidia-smi 2>/dev/null | sed -n 's/.*CUDA Version: \([0-9]*\.[0-9]*\).*/\1/p' || true)
                fi
                [ -n "$_CUDA_VERSION" ] && _CUDA_SUFFIX="cu$(echo "$_CUDA_VERSION" | tr -d '.')"
                # The PyTorch build actually selected (toolkit 13.5 -> cu132) lives in the hardware profile
                _prof_suffix=$(sed -n 's/^CUDA_SUFFIX="\{0,1\}\(cu[0-9]*\)"\{0,1\}$/\1/p' "$HOME/.machine_setting_profile" 2>/dev/null | head -1 || true)
                [ -n "$_prof_suffix" ] && _CUDA_SUFFIX="$_prof_suffix"
            fi
            ;;
        Darwin)
            if [[ "$arch" == "arm64" ]]; then
                _HAS_GPU=true
                _GPU_BACKEND="mps"
                _GPU_NAME=$(system_profiler SPDisplaysDataType 2>/dev/null | grep "Chipset Model" | sed 's/.*: //' | head -1 || echo "Apple Silicon")
                _CUDA_SUFFIX="mps"
            fi
            ;;
    esac

    # Auto-select profile
    if [ -n "$FORCE_PROFILE" ]; then
        _PROFILE="$FORCE_PROFILE"
    elif [ "$_GPU_BACKEND" = "mps" ]; then
        _PROFILE="mac-apple-silicon"
    elif [ "$_GPU_BACKEND" = "cuda" ]; then
        _PROFILE="gpu-workstation"
    elif [ "$ram_gb" != "?" ] && [ "$ram_gb" -ge 32 ] 2>/dev/null; then
        _PROFILE="cpu-server"
    elif [ "$ram_gb" != "?" ] && [ "$ram_gb" -ge 8 ] 2>/dev/null; then
        _PROFILE="laptop"
    else
        _PROFILE="minimal"
    fi

    # Load profile for PACKAGE_GROUPS etc.
    local profile_file="$REPO_DIR/profiles/${_PROFILE}.conf"
    [ -f "$profile_file" ] && source "$profile_file"

    # Disk free
    local avail_gb
    avail_gb=$(df -k "$HOME" 2>/dev/null | awk 'NR==2 {printf "%.0f", $4/1048576}')

    # Display system info
    _SYS_LINE="$OS_NAME / $cpu_model ($cpu_cores cores) / ${ram_gb}GB RAM / ${avail_gb}GB free"
    if [ "$_HAS_GPU" = true ]; then
        if [ "$_GPU_BACKEND" = "cuda" ]; then
            _GPU_LINE="$_GPU_NAME / CUDA $_CUDA_VERSION ($_CUDA_SUFFIX)"
        else
            _GPU_LINE="$_GPU_NAME / MPS (Metal)"
        fi
    else
        _GPU_LINE="None detected (CPU only)"
    fi
}

# ============================================================
# Component Checks
# ============================================================

check_hardware_profile() {
    local profile="$HOME/.machine_setting_profile"
    if [ -f "$profile" ] && grep -q "^HAS_GPU=" "$profile" 2>/dev/null; then
        EXISTS[HARDWARE]=1
        DESC[HARDWARE:update]="Re-detect hardware and rewrite ~/.machine_setting_profile"
        DESC[HARDWARE:skip]="Keep the current profile"
        add HARDWARE "Hardware Profile" "generated" "$(by_policy "update skip")" "update skip"
    else
        DESC[HARDWARE:run]="Generate ~/.machine_setting_profile"
        add HARDWARE "Hardware Profile" "not generated" run "run"
    fi
}

check_nvidia() {
    if [ "$(uname -s)" != "Linux" ] || [ "$_GPU_BACKEND" != "cuda" ]; then
        return 0                                         # nothing to show on machines without an NVIDIA GPU
    fi
    if [ "${INSTALL_NVIDIA:-true}" = false ] || [ "${IS_CLOUD:-false}" = true ]; then
        DESC[NVIDIA_DRIVER:skip]="Disabled (INSTALL_NVIDIA=false or cloud/container mode)"
        add NVIDIA_DRIVER "NVIDIA stack" "disabled in profile" skip "skip"
        return 0
    fi
    ex_nvidia_driver || true; ex_cuda || true

    # --- driver ---
    local target="${NVIDIA_DRIVER_VERSION:-recommended}"
    if [ -z "$EX_DRIVER_VER" ] && [ -z "$EX_DRIVER_SRC" ]; then
        DESC[NVIDIA_DRIVER:run]="Install the $target driver (reboot needed)"
        DESC[NVIDIA_DRIVER:skip]="Do not install a driver"
        add NVIDIA_DRIVER "NVIDIA driver" "not installed" run "run skip"
    else
        EXISTS[NVIDIA_DRIVER]=1
        local st="${EX_DRIVER_VER:-?} (${EX_DRIVER_SRC:-unknown source}"
        [ "$EX_DRIVER_LOADED" = true ] && st="$st, loaded)" || st="$st, NOT loaded)"
        DESC[NVIDIA_DRIVER:skip]="Keep driver ${EX_DRIVER_VER:-as is}"
        if [ "$EX_DRIVER_SRC" = "run-installer" ]; then
            DESC[NVIDIA_DRIVER:replace]="Run nvidia-uninstall, then install the $target driver from apt (reboot needed)"
            add NVIDIA_DRIVER "NVIDIA driver" "$st" "$(by_policy "replace skip" foreign)" "replace skip"
        else
            DESC[NVIDIA_DRIVER:update]="Upgrade the driver packages to the newest in their branch (reboot needed)"
            DESC[NVIDIA_DRIVER:replace]="Purge the driver packages and install the $target driver (reboot needed)"
            add NVIDIA_DRIVER "NVIDIA driver" "$st" "$(by_policy "update replace skip")" "update replace skip"
        fi
    fi

    # --- CUDA toolkit ---
    local want_cuda="${NVIDIA_CUDA_VERSION//-/.}"
    if [ -z "$EX_CUDA_VERS" ]; then
        DESC[NVIDIA_CUDA:run]="Install CUDA Toolkit ${want_cuda:-(latest in the NVIDIA repo)}"
        DESC[NVIDIA_CUDA:skip]="Do not install the CUDA Toolkit"
        add NVIDIA_CUDA "CUDA Toolkit" "not installed" run "run skip"
    else
        EXISTS[NVIDIA_CUDA]=1
        DESC[NVIDIA_CUDA:skip]="Keep CUDA $EX_CUDA_VERS"
        if [ -n "$want_cuda" ] && [[ " $EX_CUDA_VERS " != *" $want_cuda "* ]]; then
            DESC[NVIDIA_CUDA:run]="Install CUDA $want_cuda next to $EX_CUDA_VERS and make it the default"
            add NVIDIA_CUDA "CUDA Toolkit" "$EX_CUDA_VERS (target $want_cuda)" "$( [ "$POLICY" = keep ] && echo skip || echo run )" "run skip"
        else
            DESC[NVIDIA_CUDA:update]="Install the latest CUDA Toolkit from the NVIDIA repo next to $EX_CUDA_VERS"
            add NVIDIA_CUDA "CUDA Toolkit" "$EX_CUDA_VERS" "$(by_policy "update skip")" "update skip"
        fi
    fi

    # --- cuDNN / NCCL ---
    if [ -z "$EX_CUDNN_VER" ]; then
        DESC[NVIDIA_LIBS:run]="Install cuDNN and NCCL"
        DESC[NVIDIA_LIBS:skip]="Do not install cuDNN / NCCL"
        add NVIDIA_LIBS "cuDNN / NCCL" "cuDNN not installed" run "run skip"
    else
        EXISTS[NVIDIA_LIBS]=1
        DESC[NVIDIA_LIBS:update]="Upgrade cuDNN / NCCL packages (installs NCCL if missing)"
        DESC[NVIDIA_LIBS:skip]="Keep cuDNN $EX_CUDNN_VER${EX_NCCL_VER:+ / NCCL $EX_NCCL_VER}"
        local d; d=$(by_policy "update skip")
        add NVIDIA_LIBS "cuDNN / NCCL" "cuDNN $EX_CUDNN_VER / NCCL ${EX_NCCL_VER:-none}" "$d" "update skip"
    fi
}

check_python() {
    local target="$PYTHON_VERSION"
    ex_python "$target" || true
    local others="${EX_PY_OTHERS:+; also: $EX_PY_OTHERS}"
    if [ -z "$EX_UV_VER" ]; then
        DESC[PYTHON:run]="Install uv and Python $target (other Pythons are left untouched)"
        DESC[PYTHON:skip]="Do not install uv / Python (the AI environment cannot be built without them)"
        add PYTHON "Python $target (uv)" "uv not installed${others}" run "run skip"
    elif [ -z "$EX_UV_PY" ]; then
        DESC[PYTHON:run]="Install Python $target with the existing uv $EX_UV_VER"
        DESC[PYTHON:update]="Update uv, then install Python $target"
        DESC[PYTHON:skip]="Do not install Python $target"
        add PYTHON "Python $target (uv)" "uv $EX_UV_VER, no Python $target${others}" run "run update skip"
    else
        EXISTS[PYTHON]=1
        DESC[PYTHON:update]="Update uv ($EX_UV_SRC install) and Python $target to the latest patch release"
        DESC[PYTHON:skip]="Keep uv $EX_UV_VER and Python $EX_UV_PY"
        add PYTHON "Python $target (uv)" "$EX_UV_PY, uv $EX_UV_VER${others}" "$(by_policy "update skip")" "update skip"
    fi
}

check_venv_and_packages() {
    local venv_path="${VENV_DEFAULT_PATH:-$HOME/ai-env}"
    local group_list="${PACKAGE_GROUPS:-core}"
    [ "${GPU_PACKAGES:-}" = true ] && group_list="$group_list + GPU"

    if [ ! -d "$venv_path" ]; then
        DESC[VENV:run]="Create $venv_path and install [$group_list]"
        DESC[VENV:skip]="Do not create the AI environment"
        add VENV "AI Environment" "not created" run "run skip"
        return
    fi
    EXISTS[VENV]=1
    DESC[VENV:replace]="Delete $venv_path and build it again from the requirement files"
    if [ ! -x "$venv_path/bin/python" ]; then
        add VENV "AI Environment" "broken (missing bin/python)" replace "replace skip"
        DESC[VENV:skip]="Leave the broken environment as it is"
        return
    fi
    # Venv exists — check packages
    local installed_count
    # uv-created venvs have no pip of their own: ask uv, fall back to the venv's pip
    _venv_freeze() {
        if command -v uv &>/dev/null; then uv pip freeze --python "$venv_path/bin/python" 2>/dev/null || true
        else "$venv_path/bin/python" -m pip freeze 2>/dev/null || true; fi
    }
    local freeze_out; freeze_out=$(_venv_freeze)
    installed_count=$(printf '%s\n' "$freeze_out" | grep -c . || true)

    # Compare installed vs required
    local installed_tmp required_tmp
    installed_tmp=$(mktemp)
    required_tmp=$(mktemp)

    # Installed packages (lowercase names)
    printf '%s\n' "$freeze_out" | \
        sed 's/==.*//; s/\+.*//' | awk '{print tolower($0)}' | tr '_.' '--' | sort -u > "$installed_tmp"

    # Required packages from applicable groups
    local _groups="${PACKAGE_GROUPS:-core}"
    for group in $_groups; do
        local req_file="$PKG_DIR/requirements-${group}.txt"
        [ -f "$req_file" ] || continue
        grep -v '^#' "$req_file" | grep -v '^$' | grep -v '^\-' | \
            sed 's/[[:space:]]*#.*//; s/[>=<!\[].*//; s/[[:space:]]*$//' | awk '{print tolower($0)}' | tr '_.' '--' >> "$required_tmp"
    done

    # Add compute-specific requirements
    if [ "$_GPU_BACKEND" = "cuda" ] && [ -f "$PKG_DIR/requirements-gpu.txt" ]; then
        grep -v '^#' "$PKG_DIR/requirements-gpu.txt" | grep -v '^$' | grep -v '^\-' | \
            sed 's/[[:space:]]*#.*//; s/[>=<!\[].*//; s/\+.*//; s/[[:space:]]*$//' | awk '{print tolower($0)}' | tr '_.' '--' >> "$required_tmp"
    elif [ "$_GPU_BACKEND" = "mps" ] && [ -f "$PKG_DIR/requirements-mps.txt" ]; then
        grep -v '^#' "$PKG_DIR/requirements-mps.txt" | grep -v '^$' | \
            sed 's/[[:space:]]*#.*//; s/[>=<!\[].*//; s/[[:space:]]*$//' | awk '{print tolower($0)}' | tr '_.' '--' >> "$required_tmp"
    elif [ -f "$PKG_DIR/requirements-cpu.txt" ]; then
        grep -v '^#' "$PKG_DIR/requirements-cpu.txt" | grep -v '^$' | \
            sed 's/[[:space:]]*#.*//; s/[>=<!\[].*//; s/[[:space:]]*$//' | awk '{print tolower($0)}' | tr '_.' '--' >> "$required_tmp"
    fi
    sort -u "$required_tmp" -o "$required_tmp"

    local missing_pkgs missing_count
    missing_pkgs=$(comm -23 "$required_tmp" "$installed_tmp" || true)
    missing_count=0
    [ -n "$missing_pkgs" ] && missing_count=$(echo "$missing_pkgs" | wc -l | tr -d ' ')

    local required_count
    required_count=$(wc -l < "$required_tmp" | tr -d ' ')

    rm -f "$installed_tmp" "$required_tmp"
    DESC[VENV:update]="Sync packages to the pinned versions ($missing_count missing of $required_count)"
    DESC[VENV:skip]="Keep $venv_path as it is"
    local st="$venv_path ($installed_count pkgs"
    if [ "$missing_count" -eq 0 ]; then
        add VENV "AI Environment" "$st)" "$(by_policy "update replace skip")" "update replace skip"
    else
        # missing packages are an incomplete install, not an "existing resource" decision: propose the sync
        local d=update; [ "$POLICY" = replace ] && d=replace
        add VENV "AI Environment" "$st, $missing_count missing)" "$d" "update replace skip"
    fi
}

check_vllm() {
    [ "$_GPU_BACKEND" = "cuda" ] && [ "$(uname -s)" = "Linux" ] || return 0
    local vpath="${VLLM_VENV_PATH:-$HOME/vllm-env}"
    local want="${WANT_VLLM:-${INSTALL_VLLM:-false}}"
    if [ -x "$vpath/bin/python" ]; then
        EXISTS[VLLM]=1
        local ver; ver=$("$vpath/bin/python" -c "import importlib.metadata as m; print(m.version('vllm'))" 2>/dev/null || echo "?")
        DESC[VLLM:update]="Upgrade vLLM to ${VLLM_VERSION:-the latest release}"
        DESC[VLLM:replace]="Delete $vpath and install vLLM again"
        DESC[VLLM:skip]="Keep vLLM $ver"
        add VLLM "vLLM (own venv)" "$ver at $vpath" "$(by_policy "update replace skip")" "update replace skip"
    else
        DESC[VLLM:run]="Install vLLM ${VLLM_VERSION:-(latest)} in its own venv at $vpath"
        DESC[VLLM:skip]="Do not install vLLM"
        add VLLM "vLLM (own venv)" "not installed" "$( [ "$want" = true ] && echo run || echo skip )" "run skip"
    fi
}

check_node() {
    ex_node || true
    local want="${WANT_NODE:-${INSTALL_NODE:-true}}" target="${NODE_VERSION:-LTS}"
    local foreign="${EX_NODE_FOREIGN_VER:+$EX_NODE_FOREIGN_VER from $EX_NODE_FOREIGN_SRC}"
    if [ -n "$EX_NODE_NVM_VER" ]; then
        EXISTS[NODE]=1
        DESC[NODE:update]="Install the newest Node.js $target with NVM and make it the default (old versions stay)"
        DESC[NODE:skip]="Keep Node.js $EX_NODE_NVM_VER"
        add NODE "Node.js" "$EX_NODE_NVM_VER (NVM)${foreign:+; also $foreign}" "$(by_policy "update skip")" "update skip"
    elif [ -n "$foreign" ]; then
        EXISTS[NODE]=1
        DESC[NODE:skip]="Keep using Node.js $foreign"
        DESC[NODE:run]="Install NVM + Node.js $target next to it (the NVM one wins in your shells)"
        local opts="run skip"
        if [ "$EX_NODE_FOREIGN_SRC" = "apt" ]; then
            DESC[NODE:replace]="Remove the apt nodejs/npm packages, then install NVM + Node.js $target"
            opts="run replace skip"
        fi
        local d=skip; [ "$POLICY" = replace ] && [[ "$opts" == *replace* ]] && d=replace
        [ "$POLICY" = update ] && d=run
        [ "$want" = false ] && d=skip
        add NODE "Node.js" "$foreign (not NVM)" "$d" "$opts"
    else
        DESC[NODE:run]="Install NVM + Node.js $target"
        DESC[NODE:skip]="Do not install Node.js"
        add NODE "Node.js" "not installed" "$( [ "$want" = true ] && echo run || echo skip )" "run skip"
    fi
}

check_java() {
    ex_java || true
    local want="${WANT_JAVA:-${INSTALL_JAVA:-true}}" target="${JAVA_VERSION:-25}"
    local foreign="${EX_JAVA_FOREIGN_VER:+$EX_JAVA_FOREIGN_VER from $EX_JAVA_FOREIGN_SRC}"
    if [ -n "$EX_JAVA_SDK_VER" ]; then
        EXISTS[JAVA]=1
        DESC[JAVA:update]="Install the newest Temurin $target with SDKMAN and make it the default (old versions stay)"
        DESC[JAVA:skip]="Keep Java $EX_JAVA_SDK_VER"
        local d; d=$(by_policy "update skip")
        # a different major version than the target is worth pointing out, but still the user's call
        local note=""; [[ "$EX_JAVA_SDK_VER" != "$target".* ]] && note=", target $target"
        add JAVA "Java JDK" "$EX_JAVA_SDK_VER (SDKMAN${note})${foreign:+; also $foreign}" "$d" "update skip"
    elif [ -n "$foreign" ]; then
        EXISTS[JAVA]=1
        DESC[JAVA:skip]="Keep using Java $foreign"
        DESC[JAVA:run]="Install SDKMAN + Temurin $target next to it (the SDKMAN one wins in your shells)"
        local opts="run skip"
        if [ "$EX_JAVA_FOREIGN_SRC" = "apt" ]; then
            DESC[JAVA:replace]="Remove the apt packages ($EX_JAVA_FOREIGN_PKGS), then install SDKMAN + Temurin $target"
            opts="run replace skip"
        fi
        local d=skip; [ "$POLICY" = replace ] && [[ "$opts" == *replace* ]] && d=replace
        [ "$POLICY" = update ] && d=run
        [ "$want" = false ] && d=skip
        add JAVA "Java JDK" "$foreign (not SDKMAN)" "$d" "$opts"
    else
        DESC[JAVA:run]="Install SDKMAN + Temurin $target"
        DESC[JAVA:skip]="Do not install Java"
        add JAVA "Java JDK" "not installed" "$( [ "$want" = true ] && echo run || echo skip )" "run skip"
    fi
}

check_shell() {
    local marker="# >>> machine_setting >>>" configured=""
    for rc_file in "$HOME/.bashrc" "$HOME/.zshrc"; do
        [ -f "$rc_file" ] && grep -qF "$marker" "$rc_file" 2>/dev/null && configured+="$(basename "$rc_file") "
    done
    if [ -n "$configured" ]; then
        EXISTS[SHELL]=1
        DESC[SHELL:update]="Re-apply the shell block (rc file is backed up first)"
        DESC[SHELL:skip]="Keep the current shell integration"
        add SHELL "Shell integration" "configured (${configured% })" "$(by_policy "update skip")" "update skip"
    else
        DESC[SHELL:run]="Add the machine_setting block to .$(basename "${SHELL:-/bin/bash}")rc (aienv, PATH, lazy loaders)"
        DESC[SHELL:skip]="Do not touch shell rc files"
        add SHELL "Shell integration" "not configured" run "run skip"
    fi
}

check_base_tools() {
    [ "${INSTALL_BASE_TOOLS:-true}" = true ] && [ "${IS_CLOUD:-false}" != true ] || return 0
    local out
    if out=$(bash "$SCRIPT_DIR/install-base-tools.sh" --check 2>/dev/null); then
        DESC[BASE_TOOLS:skip]="Already installed"
        add BASE_TOOLS "Base tools" "installed (${BASE_TOOLS:-btop})" skip "skip"
    else
        DESC[BASE_TOOLS:run]="Install ${BASE_TOOLS:-btop} (sudo)"
        DESC[BASE_TOOLS:skip]="Do not install"
        add BASE_TOOLS "Base tools" "$(echo "$out" | sed 's/.*missing: //; s/ —.*//') missing" run "run skip"
    fi
}

check_locales() {
    [ "${INSTALL_LOCALES:-true}" = true ] && [ "$(uname -s)" = "Linux" ] && [ "${IS_CLOUD:-false}" != true ] || return 0
    if bash "$SCRIPT_DIR/install-locale.sh" --check &>/dev/null; then
        DESC[LOCALES:skip]="Already generated"
        add LOCALES "Locales" "${LOCALE_REMOTE:-ko_KR.UTF-8} / ${LOCALE_CONSOLE:-en_US.UTF-8}" skip "skip"
    else
        DESC[LOCALES:run]="Generate ${LOCALE_REMOTE:-ko_KR.UTF-8} and ${LOCALE_CONSOLE:-en_US.UTF-8} (sudo)"
        DESC[LOCALES:skip]="Do not generate locales"
        add LOCALES "Locales" "not generated" run "run skip"
    fi
}

# ---- Server extras (Linux hosts only). Proposed when the profile asks for them or with --server. ----
check_server() {
    [ "$(uname -s)" = "Linux" ] && [ "${IS_CLOUD:-false}" != true ] && command -v apt-get &>/dev/null || return 0
    local want="${WANT_SERVER:-${INSTALL_SERVER:-false}}"
    local new; new=$( [ "$want" = true ] && echo run || echo skip )
    on() { [ "$want" = true ] && [ "${1:-true}" = true ]; }

    # Docker
    ex_docker || true
    if [ -z "$EX_DOCKER_VER" ]; then
        DESC[DOCKER:run]="Install Docker Engine + Compose from Docker's repo${_NV_TOOLKIT_NOTE}"
        DESC[DOCKER:skip]="Do not install Docker (the monitoring stack needs it)"
        add DOCKER "Docker" "not installed" "$(on "${SERVER_DOCKER:-true}" && echo run || echo skip)" "run skip" server
    else
        EXISTS[DOCKER]=1
        DESC[DOCKER:skip]="Keep Docker $EX_DOCKER_VER ($EX_DOCKER_SRC)"
        if [ "$EX_DOCKER_SRC" = "docker-ce" ]; then
            DESC[DOCKER:update]="Upgrade Docker Engine + Compose packages; re-check GPU container support"
            add DOCKER "Docker" "$EX_DOCKER_VER (docker-ce)" "$( [ "$want" = true ] && by_policy "update skip" || echo skip )" "update skip" server
        else
            DESC[DOCKER:replace]="Remove the $EX_DOCKER_SRC Docker and install Docker Engine from Docker's repo (existing containers/images are not migrated)"
            DESC[DOCKER:update]="Keep the $EX_DOCKER_SRC Docker, only add GPU container support / docker group"
            local d=skip; [ "$want" = true ] && { d=update; [ "$POLICY" = replace ] && d=replace; [ "$POLICY" = keep ] && d=skip; }
            add DOCKER "Docker" "$EX_DOCKER_VER ($EX_DOCKER_SRC, not docker-ce)" "$d" "update replace skip" server
        fi
    fi

    # Monitoring
    local bind; bind=$(grep -s '^MONITORING_BIND=' "$REPO_DIR/monitoring/.env" | cut -d= -f2 || true); bind="${bind:-127.0.0.1}"
    [ "$bind" = "0.0.0.0" ] && bind="127.0.0.1"
    local p3000 p9090
    p3000=$(ex_port_in_use 3000 || true); p9090=$(ex_port_in_use 9090 || true)
    if [ -f "$REPO_DIR/monitoring/.env" ] && curl -fs -m 2 "http://$bind:9090/-/healthy" >/dev/null 2>&1; then
        EXISTS[MONITORING]=1
        DESC[MONITORING:update]="Re-deploy the stack (pulls the image versions pinned in monitoring/docker-compose.yml; data is kept)"
        DESC[MONITORING:skip]="Keep the running stack"
        add MONITORING "Monitoring stack" "running (Prometheus + Grafana)" "$( [ "$want" = true ] && by_policy "update skip" || echo skip )" "update skip" server
    elif [ -n "$p3000$p9090" ]; then
        EXISTS[MONITORING]=1
        DESC[MONITORING:skip]="Leave it: port ${p3000:+3000 }${p9090:+9090 }is used by something that is not this stack"
        DESC[MONITORING:run]="Deploy anyway (will fail to bind unless that service is stopped first)"
        add MONITORING "Monitoring stack" "port ${p3000:+3000 }${p9090:+9090 }already in use" skip "run skip" server
    else
        DESC[MONITORING:run]="Deploy Prometheus + Grafana + node-exporter${_DCGM_NOTE} with Docker Compose"
        DESC[MONITORING:skip]="Do not deploy monitoring"
        add MONITORING "Monitoring stack" "not running" "$(on "${SERVER_MONITORING:-true}" && echo run || echo skip)" "run skip" server
    fi

    # Update policy
    if [ -f /etc/apt/apt.conf.d/52machine-setting-unattended ]; then
        EXISTS[UPDATE_POLICY]=1
        DESC[UPDATE_POLICY:update]="Rewrite the policy file from the current config"
        DESC[UPDATE_POLICY:skip]="Keep the current policy file"
        add UPDATE_POLICY "Update policy" "configured" "$( [ "$want" = true ] && by_policy "update skip" || echo skip )" "update skip" server
    else
        DESC[UPDATE_POLICY:run]="No automatic reboot; hold kernel + NVIDIA packages out of unattended upgrades"
        DESC[UPDATE_POLICY:skip]="Leave Ubuntu's default automatic updates"
        add UPDATE_POLICY "Update policy" "Ubuntu default" "$(on "${SERVER_UPDATE_POLICY:-true}" && echo run || echo skip)" "run skip" server
    fi

    # Disk health
    if command -v smartctl &>/dev/null && { systemctl is-active --quiet smartmontools 2>/dev/null || systemctl is-active --quiet smartd 2>/dev/null; }; then
        DESC[DISK_HEALTH:skip]="smartd already running"
        add DISK_HEALTH "Disk health (smartd)" "active" skip "skip" server
    else
        DESC[DISK_HEALTH:run]="Install smartmontools and enable smartd"
        DESC[DISK_HEALTH:skip]="No SMART monitoring"
        add DISK_HEALTH "Disk health (smartd)" "not active" "$(on "${SERVER_DISK_HEALTH:-true}" && echo run || echo skip)" "run skip" server
    fi

    # Sleep
    if [ "$(systemctl is-enabled suspend.target 2>/dev/null || true)" = "masked" ]; then
        DESC[SLEEP:skip]="Sleep targets already masked"
        add SLEEP "No-sleep" "masked" skip "skip" server
    else
        DESC[SLEEP:run]="Mask sleep / suspend / hibernate targets"
        DESC[SLEEP:skip]="Leave power management as it is"
        add SLEEP "No-sleep" "sleep allowed" "$(on "${SERVER_DISABLE_SLEEP:-true}" && echo run || echo skip)" "run skip" server
    fi

    # GPU persistence
    if [ "$_GPU_BACKEND" = "cuda" ]; then
        if grep -qs 'pcie_aspm=off' /etc/default/grub && grep -qs 'NVreg_DynamicPowerManagement' /etc/default/grub; then
            EXISTS[GPU_PERSIST]=1
            DESC[GPU_PERSIST:update]="Re-run gpu-persist-fix.sh (only changes what drifted)"
            DESC[GPU_PERSIST:skip]="Keep the current GPU stability settings"
            add GPU_PERSIST "GPU stability" "applied" "$( [ "$want" = true ] && by_policy "update skip" || echo skip )" "update skip" server
        else
            DESC[GPU_PERSIST:run]="Kernel parameters (GRUB), modprobe, udev and watchdog for GPU stability (reboot needed; existing GRUB options are kept)"
            DESC[GPU_PERSIST:skip]="Do not change kernel parameters"
            add GPU_PERSIST "GPU stability" "not applied" "$(on "${SERVER_GPU_PERSIST:-true}" && echo run || echo skip)" "run skip" server
        fi
    fi
}

# ============================================================
# Display
# ============================================================
label() {
    case "$1" in
        run) echo "INSTALL" ;; update) echo "UPDATE" ;; replace) echo "REPLACE" ;; skip) echo "keep/skip" ;;
    esac
}
color() {
    case "$1" in
        run) printf '\033[33m' ;; update) printf '\033[36m' ;; replace) printf '\033[31m' ;; *) printf '\033[32m' ;;
    esac
}

display_plan() {
    echo ""
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║            Pre-flight System Check                  ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo ""
    echo "  System:  $_SYS_LINE"
    echo "  GPU:     $_GPU_LINE"
    echo "  Profile: $_PROFILE      Existing installs: $POLICY (--existing keep|update|replace)"
    echo ""
    printf "  %-3s %-22s %-46s %s\n" "#" "Component" "Found on this machine" "Action"
    printf "  %s\n" "──────────────────────────────────────────────────────────────────────────────────────────"
    local i last_group=""
    for i in "${!COMP_KEYS[@]}"; do
        if [ "${COMP_GROUP[$i]}" != "$last_group" ] && [ "${COMP_GROUP[$i]}" = "server" ]; then
            printf "  %s\n" "── server extras ──"
        fi
        last_group="${COMP_GROUP[$i]}"
        local a="${COMP_ACTIONS[$i]}" k="${COMP_KEYS[$i]}"
        printf "  $(color "$a")%-3d %-22s %-46s %s\033[0m\n" "$((i + 1))" "${COMP_NAMES[$i]}" "${COMP_STATUS[$i]:0:46}" "$(label "$a")"
        [ "$a" != "skip" ] && printf "  $(color "$a")    → %s\033[0m\n" "${DESC[$k:$a]:-}"
    done
    echo ""
    local n=0 r=0
    for i in "${!COMP_ACTIONS[@]}"; do
        [ "${COMP_ACTIONS[$i]}" != "skip" ] && n=$((n + 1))
        [ "${COMP_ACTIONS[$i]}" = "replace" ] && r=$((r + 1))
    done
    if [ "$n" -eq 0 ]; then
        echo "  Nothing to do: everything requested is already in place."
    else
        local rnote=""; [ "$r" -gt 0 ] && rnote=", $r of them REPLACE something that exists"
        echo "  $n action(s) planned${rnote}."
    fi
    echo ""
}

# ============================================================
# Interactive customization: pick the action per component
# ============================================================
choose_action() {   # $1 = index
    local i="$1" k="${COMP_KEYS[$1]}" opts=(${COMP_OPTIONS[$1]}) n=1 o
    if [ ${#opts[@]} -le 1 ]; then
        echo "  ${COMP_NAMES[$i]}: nothing to choose (${DESC[$k:${opts[0]}]:-${opts[0]}})"
        return
    fi
    echo ""
    echo "  ${COMP_NAMES[$i]} — found: ${COMP_STATUS[$i]}"
    for o in "${opts[@]}"; do
        printf "    %d) %-9s %s%s\n" "$n" "$(label "$o")" "${DESC[$k:$o]:-}" "$( [ "$o" = "${COMP_ACTIONS[$i]}" ] && echo "   [current]" )"
        n=$((n + 1))
    done
    local pick
    read -rp "  Choice [keep current]: " pick
    if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le ${#opts[@]} ]; then
        COMP_ACTIONS[$i]="${opts[$((pick - 1))]}"
    fi
}

customize_loop() {
    while true; do
        local choice
        read -rp "  (Y)es, proceed / <number> change an item / (k)eep all existing / (u)pdate all existing / (n)othing / (q)uit: " choice
        case "${choice:-Y}" in
            [Yy]|[Yy]es) return 0 ;;
            [Qq]|quit)   return 1 ;;
            [Nn])        for i in "${!COMP_ACTIONS[@]}"; do COMP_ACTIONS[$i]=skip; done; display_plan ;;
            [Kk]|[Uu])
                local newpol=keep; [[ "$choice" =~ ^[Uu]$ ]] && newpol=update
                for i in "${!COMP_KEYS[@]}"; do
                    [ -n "${EXISTS[${COMP_KEYS[$i]}]:-}" ] || continue
                    if [ "$newpol" = update ] && [[ " ${COMP_OPTIONS[$i]} " == *" update "* ]]; then COMP_ACTIONS[$i]=update
                    else COMP_ACTIONS[$i]=skip; fi
                done
                display_plan ;;
            *)
                local ok=false num
                for num in ${choice//,/ }; do
                    if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le ${#COMP_KEYS[@]} ]; then
                        choose_action "$((num - 1))"; ok=true
                    fi
                done
                [ "$ok" = true ] && display_plan || echo "  Enter Y, q, or an item number."
                ;;
        esac
    done
}

# ============================================================
# Write Plan File
# ============================================================
write_plan() {
    mkdir -p "$(dirname "$PLAN_FILE")"
    {
        echo "# Auto-generated by preflight.sh on $(date -Iseconds)"
        echo "# Consumed by setup.sh — do not edit manually"
        echo "PREFLIGHT_RAN=true"
        echo "PREFLIGHT_PROFILE=$_PROFILE"
        echo "PREFLIGHT_GPU_BACKEND=$_GPU_BACKEND"
        echo "PREFLIGHT_CUDA_SUFFIX=$_CUDA_SUFFIX"
        echo "PREFLIGHT_EXISTING_POLICY=$POLICY"
        local i nv=skip
        for i in "${!COMP_KEYS[@]}"; do
            echo "PLAN_${COMP_KEYS[$i]}=${COMP_ACTIONS[$i]}"
            [[ "${COMP_KEYS[$i]}" == NVIDIA_* ]] && [ "${COMP_ACTIONS[$i]}" != skip ] && nv=run
        done
        echo "PLAN_NVIDIA=$nv"      # stage-level switch: run when any NVIDIA part has work to do
    } > "$PLAN_FILE"
}

# ============================================================
# Main
# ============================================================
detect_system
_NV_TOOLKIT_NOTE=""; _DCGM_NOTE=""
[ "$_GPU_BACKEND" = "cuda" ] && { _NV_TOOLKIT_NOTE=" + NVIDIA Container Toolkit"; _DCGM_NOTE=" + GPU metrics (DCGM)"; }

check_hardware_profile
check_base_tools
check_locales
check_nvidia
check_python
check_venv_and_packages
check_vllm
check_node
check_java
check_shell
check_server

display_plan

case "$MODE" in
    check-only) exit 0 ;;
    quiet)
        write_plan
        echo "  Plan written to: $PLAN_FILE"
        exit 0 ;;
    interactive)
        if customize_loop; then
            write_plan
            echo "  Plan saved."
            exit 0
        fi
        echo "  Cancelled."
        rm -f "$PLAN_FILE"
        exit 1 ;;
esac
