#!/usr/bin/env bash
# preflight.sh — Pre-flight system check and installation planner
# Detects current state, compares with target profile, proposes actions.
#
# Usage:
#   ./scripts/preflight.sh                    # Interactive (detect + plan + confirm)
#   ./scripts/preflight.sh --quiet            # Non-interactive (detect + write plan)
#   ./scripts/preflight.sh --check-only       # Show status only, no plan file
#   ./scripts/preflight.sh --profile <name>   # Force specific profile
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PKG_DIR="$REPO_DIR/packages"
PLAN_FILE="$REPO_DIR/env/.preflight_plan"

# --- Load config ---
source "$REPO_DIR/config/default.conf"
[ -f "$REPO_DIR/config/machine.conf" ] && source "$REPO_DIR/config/machine.conf"

# --- Load checkpoint library ---
if [ -f "$SCRIPT_DIR/lib-checkpoint.sh" ]; then
    source "$SCRIPT_DIR/lib-checkpoint.sh"
    HAS_CHECKPOINT=true
else
    HAS_CHECKPOINT=false
fi

# --- Parse arguments ---
MODE="interactive"    # interactive | quiet | check-only
FORCE_PROFILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --quiet)      MODE="quiet"; shift ;;
        --check-only) MODE="check-only"; shift ;;
        --profile)    FORCE_PROFILE="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: ./scripts/preflight.sh [options]"
            echo "  --quiet        Non-interactive mode (write plan and exit)"
            echo "  --check-only   Show status only (no plan file)"
            echo "  --profile <n>  Force specific profile"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ============================================================
# Detection Results (parallel arrays)
# ============================================================
COMP_NAMES=()        # Component display name
COMP_KEYS=()         # Internal key (HARDWARE, PYTHON, VENV, NODE, JAVA, SHELL)
COMP_STATUS=()       # current status description
COMP_ACTIONS=()      # proposed action: run|skip|update
COMP_DETAILS=()      # action detail text
COMP_SELECTED=()     # 1=selected, 0=deselected

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
        local gen_date
        gen_date=$(grep "^# Auto-generated" "$profile" | sed 's/.*on //' || echo "unknown")
        COMP_NAMES+=("Hardware Profile")
        COMP_KEYS+=("HARDWARE")
        COMP_STATUS+=("generated ($gen_date)")
        COMP_ACTIONS+=("skip")
        COMP_DETAILS+=("Already exists")
        COMP_SELECTED+=(0)
    else
        COMP_NAMES+=("Hardware Profile")
        COMP_KEYS+=("HARDWARE")
        COMP_STATUS+=("not generated")
        COMP_ACTIONS+=("run")
        COMP_DETAILS+=("Generate ~/.machine_setting_profile")
        COMP_SELECTED+=(1)
    fi
}

check_python() {
    local target_ver="$PYTHON_VERSION"
    local python_bin=""
    local actual_ver=""

    if command -v uv &>/dev/null; then
        python_bin=$(uv python find "$target_ver" 2>/dev/null || true)
        if [ -n "$python_bin" ] && [ -x "$python_bin" ]; then
            actual_ver=$("$python_bin" --version 2>/dev/null | sed 's/Python //')
        fi
    fi

    if [ -z "$actual_ver" ] && command -v "python${target_ver}" &>/dev/null; then
        actual_ver=$("python${target_ver}" --version 2>/dev/null | sed 's/Python //')
    fi

    if [ -n "$actual_ver" ]; then
        local uv_ver=""
        command -v uv &>/dev/null && uv_ver=" + uv $(uv --version 2>/dev/null | head -1 | awk '{print $2}')"
        COMP_NAMES+=("Python $target_ver")
        COMP_KEYS+=("PYTHON")
        COMP_STATUS+=("$actual_ver installed${uv_ver}")
        COMP_ACTIONS+=("skip")
        COMP_DETAILS+=("Already installed")
        COMP_SELECTED+=(0)
    else
        COMP_NAMES+=("Python $target_ver")
        COMP_KEYS+=("PYTHON")
        COMP_STATUS+=("not found")
        COMP_ACTIONS+=("run")
        COMP_DETAILS+=("Install via uv")
        COMP_SELECTED+=(1)
    fi
}

check_venv_and_packages() {
    local venv_path="${VENV_DEFAULT_PATH:-$HOME/ai-env}"

    if [ ! -d "$venv_path" ]; then
        # No venv — need full install
        local group_list="${PACKAGE_GROUPS:-core}"
        [ "${GPU_PACKAGES:-}" = true ] && group_list="$group_list + GPU"
        COMP_NAMES+=("AI Environment")
        COMP_KEYS+=("VENV")
        COMP_STATUS+=("not created")
        COMP_ACTIONS+=("run")
        COMP_DETAILS+=("Create $venv_path + install [$group_list]")
        COMP_SELECTED+=(1)
        return
    fi

    if [ ! -x "$venv_path/bin/python" ]; then
        COMP_NAMES+=("AI Environment")
        COMP_KEYS+=("VENV")
        COMP_STATUS+=("broken (missing bin/python)")
        COMP_ACTIONS+=("run")
        COMP_DETAILS+=("Recreate $venv_path")
        COMP_SELECTED+=(1)
        return
    fi

    # Venv exists — check packages
    local installed_count
    installed_count=$("$venv_path/bin/pip" list 2>/dev/null | tail -n +3 | wc -l | tr -d ' ')

    # Compare installed vs required
    local installed_tmp required_tmp
    installed_tmp=$(mktemp)
    required_tmp=$(mktemp)

    # Installed packages (lowercase names)
    "$venv_path/bin/pip" freeze 2>/dev/null | \
        sed 's/==.*//; s/\+.*//' | awk '{print tolower($0)}' | sort -u > "$installed_tmp"

    # Required packages from applicable groups
    local _groups="${PACKAGE_GROUPS:-core}"
    for group in $_groups; do
        local req_file="$PKG_DIR/requirements-${group}.txt"
        [ -f "$req_file" ] || continue
        grep -v '^#' "$req_file" | grep -v '^$' | grep -v '^\-' | \
            sed 's/[>=<!\[].*//; s/[[:space:]]*$//' | awk '{print tolower($0)}' >> "$required_tmp"
    done

    # Add compute-specific requirements
    if [ "$_GPU_BACKEND" = "cuda" ] && [ -f "$PKG_DIR/requirements-gpu.txt" ]; then
        grep -v '^#' "$PKG_DIR/requirements-gpu.txt" | grep -v '^$' | grep -v '^\-' | \
            sed 's/[>=<!\[].*//; s/\+.*//; s/[[:space:]]*$//' | awk '{print tolower($0)}' >> "$required_tmp"
    elif [ "$_GPU_BACKEND" = "mps" ] && [ -f "$PKG_DIR/requirements-mps.txt" ]; then
        grep -v '^#' "$PKG_DIR/requirements-mps.txt" | grep -v '^$' | \
            sed 's/[>=<!\[].*//; s/[[:space:]]*$//' | awk '{print tolower($0)}' >> "$required_tmp"
    elif [ -f "$PKG_DIR/requirements-cpu.txt" ]; then
        grep -v '^#' "$PKG_DIR/requirements-cpu.txt" | grep -v '^$' | \
            sed 's/[>=<!\[].*//; s/[[:space:]]*$//' | awk '{print tolower($0)}' >> "$required_tmp"
    fi
    sort -u "$required_tmp" -o "$required_tmp"

    local missing_pkgs missing_count
    missing_pkgs=$(comm -23 "$required_tmp" "$installed_tmp" || true)
    missing_count=0
    [ -n "$missing_pkgs" ] && missing_count=$(echo "$missing_pkgs" | wc -l | tr -d ' ')

    local required_count
    required_count=$(wc -l < "$required_tmp" | tr -d ' ')

    rm -f "$installed_tmp" "$required_tmp"

    # Determine action
    if [ "$missing_count" -eq 0 ]; then
        COMP_NAMES+=("AI Environment")
        COMP_KEYS+=("VENV")
        COMP_STATUS+=("$venv_path ($installed_count pkgs)")
        COMP_ACTIONS+=("skip")
        COMP_DETAILS+=("All $required_count required packages installed")
        COMP_SELECTED+=(0)
    else
        local top_missing=""
        if [ -n "$missing_pkgs" ]; then
            top_missing=$(echo "$missing_pkgs" | head -3 | tr '\n' ', ' | sed 's/,$//')
            [ "$missing_count" -gt 3 ] && top_missing="$top_missing ..."
        fi
        COMP_NAMES+=("AI Environment")
        COMP_KEYS+=("VENV")
        COMP_STATUS+=("$venv_path ($installed_count pkgs)")
        COMP_ACTIONS+=("update")
        COMP_DETAILS+=("Install $missing_count missing ($top_missing)")
        COMP_SELECTED+=(1)
    fi
}

check_node() {
    local want_node="${INSTALL_NODE:-true}"
    local nvm_dir="${NVM_DIR:-$HOME/.nvm}"

    if [ "$want_node" = false ]; then
        COMP_NAMES+=("Node.js")
        COMP_KEYS+=("NODE")
        COMP_STATUS+=("not in profile")
        COMP_ACTIONS+=("skip")
        COMP_DETAILS+=("Profile does not include Node.js")
        COMP_SELECTED+=(0)
        return
    fi

    if [ -d "$nvm_dir" ] && [ -s "$nvm_dir/nvm.sh" ]; then
        # Load NVM to check version
        source "$nvm_dir/nvm.sh" 2>/dev/null || true
        if command -v node &>/dev/null; then
            local node_ver
            node_ver=$(node --version 2>/dev/null || echo "unknown")
            COMP_NAMES+=("Node.js")
            COMP_KEYS+=("NODE")
            COMP_STATUS+=("$node_ver (NVM)")
            COMP_ACTIONS+=("skip")
            COMP_DETAILS+=("Already installed")
            COMP_SELECTED+=(0)
        else
            COMP_NAMES+=("Node.js")
            COMP_KEYS+=("NODE")
            COMP_STATUS+=("NVM present, no Node active")
            COMP_ACTIONS+=("run")
            COMP_DETAILS+=("Install Node.js ${NODE_VERSION:-LTS} via NVM")
            COMP_SELECTED+=(1)
        fi
    else
        COMP_NAMES+=("Node.js")
        COMP_KEYS+=("NODE")
        COMP_STATUS+=("not installed")
        COMP_ACTIONS+=("run")
        COMP_DETAILS+=("Install NVM + Node.js ${NODE_VERSION:-LTS}")
        COMP_SELECTED+=(1)
    fi
}

check_java() {
    local want_java="${INSTALL_JAVA:-true}"
    local sdk_dir="${SDKMAN_DIR:-$HOME/.sdkman}"

    if [ "$want_java" = false ]; then
        COMP_NAMES+=("Java ${JAVA_VERSION:-21}")
        COMP_KEYS+=("JAVA")
        COMP_STATUS+=("not in profile")
        COMP_ACTIONS+=("skip")
        COMP_DETAILS+=("Profile does not include Java")
        COMP_SELECTED+=(0)
        return
    fi

    if [ -d "$sdk_dir" ] && [ -s "$sdk_dir/bin/sdkman-init.sh" ]; then
        set +u
        source "$sdk_dir/bin/sdkman-init.sh" 2>/dev/null || true
        set -u
        if command -v java &>/dev/null; then
            local java_ver
            java_ver=$(java -version 2>&1 | head -1 | sed 's/.*"\(.*\)".*/\1/' || echo "unknown")
            COMP_NAMES+=("Java ${JAVA_VERSION:-21}")
            COMP_KEYS+=("JAVA")
            COMP_STATUS+=("$java_ver (SDKMAN)")
            COMP_ACTIONS+=("skip")
            COMP_DETAILS+=("Already installed")
            COMP_SELECTED+=(0)
        else
            COMP_NAMES+=("Java ${JAVA_VERSION:-21}")
            COMP_KEYS+=("JAVA")
            COMP_STATUS+=("SDKMAN present, no Java active")
            COMP_ACTIONS+=("run")
            COMP_DETAILS+=("Install Java ${JAVA_VERSION:-21} via SDKMAN")
            COMP_SELECTED+=(1)
        fi
    else
        COMP_NAMES+=("Java ${JAVA_VERSION:-21}")
        COMP_KEYS+=("JAVA")
        COMP_STATUS+=("not installed")
        COMP_ACTIONS+=("run")
        COMP_DETAILS+=("Install SDKMAN + Java ${JAVA_VERSION:-21}")
        COMP_SELECTED+=(1)
    fi
}

check_shell() {
    local marker="# >>> machine_setting >>>"
    local configured_shells=""

    for rc_file in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [ -f "$rc_file" ] && grep -qF "$marker" "$rc_file" 2>/dev/null; then
            configured_shells+="$(basename "$rc_file") "
        fi
    done

    if [ -n "$configured_shells" ]; then
        COMP_NAMES+=("Shell Integration")
        COMP_KEYS+=("SHELL")
        COMP_STATUS+=("configured ($configured_shells)")
        COMP_ACTIONS+=("skip")
        COMP_DETAILS+=("Already in $configured_shells")
        COMP_SELECTED+=(0)
    else
        local target_shell
        target_shell=$(basename "${SHELL:-/bin/bash}")
        COMP_NAMES+=("Shell Integration")
        COMP_KEYS+=("SHELL")
        COMP_STATUS+=("not configured")
        COMP_ACTIONS+=("run")
        COMP_DETAILS+=("Add to .${target_shell}rc (aienv, PATH, lazy loaders)")
        COMP_SELECTED+=(1)
    fi
}

# ============================================================
# Display
# ============================================================

display_plan() {
    echo ""
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║            Pre-flight System Check                  ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo ""
    echo "  System:  $_SYS_LINE"
    echo "  GPU:     $_GPU_LINE"
    echo "  Profile: $_PROFILE"
    echo ""

    # Table header
    printf "  %-3s %-20s %-30s %s\n" "#" "Component" "Current Status" "Proposed Action"
    printf "  %s\n" "─────────────────────────────────────────────────────────────────────────────"

    local i
    for i in "${!COMP_NAMES[@]}"; do
        local num=$((i + 1))
        local marker=" "
        local action_label=""
        local color_start="" color_end=""

        case "${COMP_ACTIONS[$i]}" in
            run)
                action_label="→ INSTALL"
                color_start="\033[33m"    # yellow
                color_end="\033[0m"
                ;;
            update)
                action_label="→ UPDATE"
                color_start="\033[36m"    # cyan
                color_end="\033[0m"
                ;;
            skip)
                action_label="  (ok)"
                color_start="\033[32m"    # green
                color_end="\033[0m"
                ;;
        esac

        if [ "${COMP_SELECTED[$i]}" -eq 1 ]; then
            marker="*"
        fi

        printf "  ${color_start}%s %-2d %-20s %-30s %s${color_end}\n" \
            "$marker" "$num" "${COMP_NAMES[$i]}" "${COMP_STATUS[$i]}" "$action_label"
        # Detail on second line if action is not skip
        if [ "${COMP_ACTIONS[$i]}" != "skip" ]; then
            printf "  ${color_start}     %-20s %s${color_end}\n" "" "${COMP_DETAILS[$i]}"
        fi
    done

    # Summary
    local selected_count=0
    local action_items=()
    for i in "${!COMP_SELECTED[@]}"; do
        if [ "${COMP_SELECTED[$i]}" -eq 1 ]; then
            selected_count=$((selected_count + 1))
            action_items+=("[$((i + 1))] ${COMP_NAMES[$i]}")
        fi
    done

    echo ""
    if [ "$selected_count" -eq 0 ]; then
        echo "  Everything is up to date. No actions needed."
    else
        echo "  Proposed actions ($selected_count):"
        for item in "${action_items[@]}"; do
            echo "    $item"
        done
    fi
    echo ""
}

# ============================================================
# Interactive Customization
# ============================================================

customize_loop() {
    while true; do
        local selected_count=0
        for i in "${!COMP_SELECTED[@]}"; do
            [ "${COMP_SELECTED[$i]}" -eq 1 ] && selected_count=$((selected_count + 1))
        done

        if [ "$selected_count" -eq 0 ]; then
            echo "  No actions selected."
            read -rp "  (q)uit / (t)oggle items: " choice
        else
            read -rp "  (Y)es, proceed / (t)oggle items / (a)ll / (n)one / (q)uit: " choice
        fi

        case "${choice:-Y}" in
            [Yy]|[Yy]es)
                if [ "$selected_count" -eq 0 ]; then
                    echo "  Nothing to do."
                    return 1
                fi
                return 0
                ;;
            [Tt]|toggle)
                echo ""
                echo "  Current selection (* = selected):"
                for i in "${!COMP_NAMES[@]}"; do
                    local sel=" "
                    [ "${COMP_SELECTED[$i]}" -eq 1 ] && sel="*"
                    local action_tag=""
                    case "${COMP_ACTIONS[$i]}" in
                        run)    action_tag="INSTALL" ;;
                        update) action_tag="UPDATE" ;;
                        skip)   action_tag="ok" ;;
                    esac
                    printf "    %s %d) %-20s [%s]\n" "$sel" "$((i + 1))" "${COMP_NAMES[$i]}" "$action_tag"
                done
                echo ""
                read -rp "  Enter numbers to toggle (e.g., 1,3,5): " toggle_input

                IFS=',' read -ra nums <<< "$toggle_input"
                for num_str in "${nums[@]}"; do
                    num_str=$(echo "$num_str" | tr -d ' ')
                    if [[ "$num_str" =~ ^[0-9]+$ ]]; then
                        local idx=$((num_str - 1))
                        if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#COMP_SELECTED[@]}" ]; then
                            if [ "${COMP_SELECTED[$idx]}" -eq 1 ]; then
                                COMP_SELECTED[$idx]=0
                            else
                                COMP_SELECTED[$idx]=1
                            fi
                        fi
                    fi
                done
                echo ""
                # Re-display summary
                echo "  Updated selection:"
                for i in "${!COMP_NAMES[@]}"; do
                    if [ "${COMP_SELECTED[$i]}" -eq 1 ]; then
                        echo "    [*] $((i + 1)) ${COMP_NAMES[$i]}: ${COMP_DETAILS[$i]}"
                    fi
                done
                echo ""
                ;;
            [Aa]|all)
                for i in "${!COMP_SELECTED[@]}"; do
                    COMP_SELECTED[$i]=1
                done
                echo "  All items selected."
                echo ""
                ;;
            [Nn]|none)
                for i in "${!COMP_SELECTED[@]}"; do
                    COMP_SELECTED[$i]=0
                done
                echo "  All items deselected."
                echo ""
                ;;
            [Qq]|quit)
                return 1
                ;;
            *)
                echo "  Invalid choice."
                ;;
        esac
    done
}

# ============================================================
# Write Plan File
# ============================================================

write_plan() {
    mkdir -p "$(dirname "$PLAN_FILE")"
    cat > "$PLAN_FILE" << PLANEOF
# Auto-generated by preflight.sh on $(date -Iseconds)
# Consumed by setup.sh — do not edit manually
PREFLIGHT_RAN=true
PREFLIGHT_PROFILE=$_PROFILE
PREFLIGHT_GPU_BACKEND=$_GPU_BACKEND
PREFLIGHT_CUDA_SUFFIX=$_CUDA_SUFFIX
PLANEOF

    # Write per-component actions
    for i in "${!COMP_KEYS[@]}"; do
        local action="skip"
        [ "${COMP_SELECTED[$i]}" -eq 1 ] && action="${COMP_ACTIONS[$i]}"
        echo "PLAN_${COMP_KEYS[$i]}=$action" >> "$PLAN_FILE"
    done

    echo "" >> "$PLAN_FILE"
    echo "# Component details" >> "$PLAN_FILE"
    for i in "${!COMP_KEYS[@]}"; do
        echo "PLAN_${COMP_KEYS[$i]}_DETAIL=\"${COMP_DETAILS[$i]}\"" >> "$PLAN_FILE"
    done
}

# ============================================================
# Main
# ============================================================

# 1. Detect system info
detect_system

# 2. Check each component
check_hardware_profile
check_python
check_venv_and_packages
check_node
check_java
check_shell

# 3. Display plan
display_plan

# 4. Handle modes
case "$MODE" in
    check-only)
        exit 0
        ;;
    quiet)
        write_plan
        echo "  Plan written to: $PLAN_FILE"
        exit 0
        ;;
    interactive)
        # Count items needing action
        need_action=0
        for i in "${!COMP_SELECTED[@]}"; do
            [ "${COMP_SELECTED[$i]}" -eq 1 ] && need_action=$((need_action + 1))
        done

        if [ "$need_action" -eq 0 ]; then
            echo "  Nothing to do. System is fully configured."
            read -rp "  Force re-check? (t)oggle items / (q)uit [q]: " force_choice
            case "${force_choice:-q}" in
                [Tt]|toggle)
                    if customize_loop; then
                        write_plan
                        echo "  Plan saved. Run './setup.sh --preflight' to execute."
                    fi
                    ;;
                *) exit 0 ;;
            esac
        else
            if customize_loop; then
                write_plan
                echo "  Plan saved."
                exit 0
            else
                echo "  Cancelled."
                rm -f "$PLAN_FILE"
                exit 1
            fi
        fi
        ;;
esac
