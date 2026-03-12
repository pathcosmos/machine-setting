#!/usr/bin/env bash
# uninstall.sh — Uninstall machine_setting components
# Usage:
#   ./scripts/uninstall.sh                        # Interactive mode
#   ./scripts/uninstall.sh --all                   # Remove everything
#   ./scripts/uninstall.sh --dry-run               # Show what would be removed
#   ./scripts/uninstall.sh --component venv,node   # Remove specific components
#   ./scripts/uninstall.sh --keep-config           # Keep config/state, remove runtimes
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# --- Load checkpoint library ---
source "$SCRIPT_DIR/lib-checkpoint.sh"

# --- Load config ---
source "$REPO_DIR/config/default.conf"
[ -f "$REPO_DIR/config/machine.conf" ] && source "$REPO_DIR/config/machine.conf"
[ -f "$HOME/.machine_setting_profile" ] && source "$HOME/.machine_setting_profile"

# --- Parse arguments ---
MODE="interactive"    # interactive | all | dry-run | component
COMPONENTS=""         # comma-separated list for --component
KEEP_CONFIG=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)          MODE="all"; shift ;;
        --dry-run)      MODE="dry-run"; shift ;;
        --component)    MODE="component"; COMPONENTS="$2"; shift 2 ;;
        --keep-config)  KEEP_CONFIG=true; shift ;;
        --help|-h)
            echo "Usage: ./scripts/uninstall.sh [options]"
            echo ""
            echo "  (no args)              Interactive mode (toggle components)"
            echo "  --all                  Remove everything"
            echo "  --dry-run              Show what would be removed"
            echo "  --component <list>     Remove specific components (comma-separated)"
            echo "  --keep-config          Keep config & state, remove runtimes only"
            echo ""
            echo "Components: nvidia, venv, python, node, java, shell, config"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# --- State ---
STATE_VENV_PATH=$(checkpoint_read_key "VENV_PATH")
VENV_PATH="${STATE_VENV_PATH:-${VENV_DEFAULT_PATH:-$HOME/ai-env}}"
NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
SDKMAN_DIR="${SDKMAN_DIR:-$HOME/.sdkman}"

# Shell RC marker
MARKER="# >>> machine_setting >>>"
MARKER_END="# <<< machine_setting <<<"

# ============================================================
# Component detection & sizing
# ============================================================

# Get directory size in human-readable format (cross-platform)
get_dir_size() {
    local dir="$1"
    if [ -d "$dir" ]; then
        du -sh "$dir" 2>/dev/null | cut -f1 | tr -d ' '
    else
        echo "N/A"
    fi
}

# Component info arrays
declare -a COMP_NAMES=("nvidia" "venv" "python" "node" "java" "shell" "config")
declare -a COMP_LABELS=()
declare -a COMP_FOUND=()     # true/false
declare -a COMP_SELECTED=()  # true/false
declare -a COMP_SIZES=()

detect_components() {
    # 1) nvidia
    local has_nvidia=false
    if command -v nvidia-smi &>/dev/null || dpkg -l 'cuda-toolkit*' 2>/dev/null | grep -q '^ii'; then
        has_nvidia=true
    fi
    COMP_FOUND+=("$has_nvidia")
    COMP_SIZES+=("N/A")
    if [ "$has_nvidia" = true ]; then
        local nv_driver=""
        nv_driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo "unknown")
        COMP_LABELS+=("NVIDIA stack (driver $nv_driver, CUDA, cuDNN, tools)")
    else
        COMP_LABELS+=("NVIDIA stack (not installed)")
    fi

    # 3) venv
    if [ -d "$VENV_PATH" ]; then
        COMP_FOUND+=(true)
        COMP_SIZES+=("$(get_dir_size "$VENV_PATH")")
        COMP_LABELS+=("AI Virtual Environment ($VENV_PATH, ${COMP_SIZES[-1]})")
    else
        COMP_FOUND+=(false)
        COMP_SIZES+=("N/A")
        COMP_LABELS+=("AI Virtual Environment (not installed)")
    fi

    # 2) python (uv-managed)
    local uv_python_dir="$HOME/.local/share/uv/python"
    if [ -d "$uv_python_dir" ]; then
        COMP_FOUND+=(true)
        COMP_SIZES+=("$(get_dir_size "$uv_python_dir")")
        COMP_LABELS+=("Python via uv (${COMP_SIZES[-1]})")
    else
        COMP_FOUND+=(false)
        COMP_SIZES+=("N/A")
        COMP_LABELS+=("Python via uv (not installed)")
    fi

    # 3) node
    if [ -d "$NVM_DIR" ]; then
        COMP_FOUND+=(true)
        COMP_SIZES+=("$(get_dir_size "$NVM_DIR")")
        COMP_LABELS+=("NVM + Node.js (${COMP_SIZES[-1]})")
    else
        COMP_FOUND+=(false)
        COMP_SIZES+=("N/A")
        COMP_LABELS+=("NVM + Node.js (not installed)")
    fi

    # 4) java
    if [ -d "$SDKMAN_DIR" ]; then
        COMP_FOUND+=(true)
        COMP_SIZES+=("$(get_dir_size "$SDKMAN_DIR")")
        COMP_LABELS+=("Java/SDKMAN (${COMP_SIZES[-1]})")
    else
        COMP_FOUND+=(false)
        COMP_SIZES+=("N/A")
        COMP_LABELS+=("Java/SDKMAN (not installed)")
    fi

    # 5) shell
    local has_shell=false
    for rc_file in "$HOME/.bashrc" "$HOME/.zshrc"; do
        [ -f "$rc_file" ] && grep -qF "$MARKER" "$rc_file" 2>/dev/null && has_shell=true
    done
    COMP_FOUND+=("$has_shell")
    COMP_SIZES+=("N/A")
    if [ "$has_shell" = true ]; then
        local shells=""
        [ -f "$HOME/.bashrc" ] && grep -qF "$MARKER" "$HOME/.bashrc" 2>/dev/null && shells+=".bashrc "
        [ -f "$HOME/.zshrc" ] && grep -qF "$MARKER" "$HOME/.zshrc" 2>/dev/null && shells+=".zshrc"
        COMP_LABELS+=("Shell integration ($shells)")
    else
        COMP_LABELS+=("Shell integration (not configured)")
    fi

    # 6) config
    local has_config=false
    [ -d "$CHECKPOINT_DIR" ] || [ -f "$HOME/.machine_setting_profile" ] && has_config=true
    COMP_FOUND+=("$has_config")
    COMP_SIZES+=("N/A")
    COMP_LABELS+=("Config & state files")

    # Default selection: all found components
    for found in "${COMP_FOUND[@]}"; do
        COMP_SELECTED+=("$found")
    done
}

# ============================================================
# Removal functions
# ============================================================

remove_nvidia() {
    echo "  Removing NVIDIA stack..."
    if [ -f "$SCRIPT_DIR/install-nvidia.sh" ]; then
        bash "$SCRIPT_DIR/install-nvidia.sh" --uninstall
    else
        # Manual removal fallback
        sudo apt-get purge -y 'nvidia-*' 'libnvidia-*' 'cuda-*' 'libcuda*' \
            'cudnn*' 'libcudnn*' 'libnccl*' 'datacenter-gpu-manager' \
            nvidia-container-toolkit 2>/dev/null || true
        sudo apt-get autoremove -y 2>/dev/null || true
        sudo rm -f /usr/local/cuda 2>/dev/null || true
        sudo rm -f /etc/sysctl.d/99-machine-setting-gpu.conf 2>/dev/null || true
        sudo rm -f /etc/security/limits.d/99-machine-setting-gpu.conf 2>/dev/null || true
    fi
    echo "  Done. Reboot recommended."
}

remove_venv() {
    if [ -d "$VENV_PATH" ]; then
        echo "  Removing virtual environment ($VENV_PATH)..."
        rm -rf "$VENV_PATH"
        echo "  Done."
    fi
}

remove_python() {
    local uv_python_dir="$HOME/.local/share/uv/python"
    if [ -d "$uv_python_dir" ]; then
        echo "  Removing uv-managed Python versions..."
        rm -rf "$uv_python_dir"
        echo "  Done."
    fi
}

remove_node() {
    if [ -d "$NVM_DIR" ]; then
        echo "  Removing NVM + Node.js ($NVM_DIR)..."
        rm -rf "$NVM_DIR"
        echo "  Done."
    fi
}

remove_java() {
    if [ -d "$SDKMAN_DIR" ]; then
        echo "  Removing SDKMAN + Java ($SDKMAN_DIR)..."
        rm -rf "$SDKMAN_DIR"
        echo "  Done."
    fi
}

remove_shell() {
    echo "  Removing shell integration..."
    for rc_file in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [ -f "$rc_file" ] && grep -qF "$MARKER" "$rc_file" 2>/dev/null; then
            # Backup before modification
            backup_shell_rc "$rc_file"
            # Remove marker block using awk
            local tmp
            tmp=$(mktemp)
            awk "/$MARKER/{skip=1} /$MARKER_END/{skip=0; next} !skip" "$rc_file" > "$tmp"
            mv "$tmp" "$rc_file"
            echo "    Removed block from $(basename "$rc_file")"
        fi
    done
    # NEVER delete .bashrc.local or .zshrc.local
    echo "  Note: ~/.bashrc.local and ~/.zshrc.local preserved (user secrets)."
    echo "  Done."
}

remove_config() {
    echo "  Removing config & state files..."
    [ -d "$CHECKPOINT_DIR" ] && rm -rf "$CHECKPOINT_DIR" && echo "    Removed $CHECKPOINT_DIR"
    [ -f "$HOME/.machine_setting_profile" ] && rm -f "$HOME/.machine_setting_profile" && echo "    Removed ~/.machine_setting_profile"
    echo "  Done."
}

# Execute removal for a component by index
remove_component() {
    local idx="$1"
    case "${COMP_NAMES[$idx]}" in
        nvidia) remove_nvidia ;;
        venv)   remove_venv ;;
        python) remove_python ;;
        node)   remove_node ;;
        java)   remove_java ;;
        shell)  remove_shell ;;
        config) remove_config ;;
    esac
}

# ============================================================
# Display
# ============================================================

show_component_list() {
    echo ""
    echo "Components found:"
    for i in "${!COMP_NAMES[@]}"; do
        local marker=" "
        [ "${COMP_SELECTED[$i]}" = true ] && marker="✓"
        local num=$((i + 1))
        if [ "${COMP_FOUND[$i]}" = true ]; then
            printf "  [%d] %s %s\n" "$num" "$marker" "${COMP_LABELS[$i]}"
        else
            printf "  [%d]   %s\n" "$num" "${COMP_LABELS[$i]}"
        fi
    done
}

# ============================================================
# Main
# ============================================================

echo "=== Machine Setting Uninstall ==="

detect_components

case "$MODE" in
    dry-run)
        echo ""
        echo "Dry run — the following would be removed:"
        for i in "${!COMP_NAMES[@]}"; do
            if [ "${COMP_FOUND[$i]}" = true ]; then
                echo "  - ${COMP_LABELS[$i]}"
            fi
        done
        echo ""
        echo "Note: ~/machine_setting repository itself would NOT be removed."
        exit 0
        ;;

    all)
        if [ "$KEEP_CONFIG" = true ]; then
            COMP_SELECTED[6]=false  # Don't remove config
        fi

        echo ""
        echo "WARNING: This will remove ALL machine_setting components."
        echo ""
        for i in "${!COMP_NAMES[@]}"; do
            if [ "${COMP_SELECTED[$i]}" = true ] && [ "${COMP_FOUND[$i]}" = true ]; then
                echo "  - ${COMP_LABELS[$i]}"
            fi
        done
        echo ""
        read -rp "Type 'UNINSTALL' to confirm: " confirm
        if [ "$confirm" != "UNINSTALL" ]; then
            echo "Cancelled."
            exit 0
        fi
        echo ""
        for i in "${!COMP_NAMES[@]}"; do
            if [ "${COMP_SELECTED[$i]}" = true ] && [ "${COMP_FOUND[$i]}" = true ]; then
                remove_component "$i"
            fi
        done
        ;;

    component)
        # Parse comma-separated list
        IFS=',' read -ra TARGETS <<< "$COMPONENTS"
        for target in "${TARGETS[@]}"; do
            target=$(echo "$target" | tr -d ' ')
            found_idx=-1
            for i in "${!COMP_NAMES[@]}"; do
                if [ "${COMP_NAMES[$i]}" = "$target" ]; then
                    found_idx=$i
                    break
                fi
            done
            if [ "$found_idx" -ge 0 ] && [ "${COMP_FOUND[$found_idx]}" = true ]; then
                remove_component "$found_idx"
            elif [ "$found_idx" -ge 0 ]; then
                echo "  Component '$target' is not installed, skipping."
            else
                echo "  Unknown component: $target"
                echo "  Available: ${COMP_NAMES[*]}"
            fi
        done
        ;;

    interactive)
        if [ "$KEEP_CONFIG" = true ]; then
            COMP_SELECTED[5]=false
        fi

        show_component_list
        echo ""
        echo "Toggle numbers to select/deselect, 'a' for all, Enter to proceed:"
        while true; do
            read -rp "> " input
            case "$input" in
                "")
                    break
                    ;;
                a|A)
                    for i in "${!COMP_NAMES[@]}"; do
                        [ "${COMP_FOUND[$i]}" = true ] && COMP_SELECTED[$i]=true
                    done
                    show_component_list
                    echo ""
                    echo "Toggle numbers, 'a' for all, Enter to proceed:"
                    ;;
                [1-7])
                    idx=$((input - 1))
                    if [ "${COMP_FOUND[$idx]}" = true ]; then
                        if [ "${COMP_SELECTED[$idx]}" = true ]; then
                            COMP_SELECTED[$idx]=false
                        else
                            COMP_SELECTED[$idx]=true
                        fi
                    fi
                    show_component_list
                    echo ""
                    echo "Toggle numbers, 'a' for all, Enter to proceed:"
                    ;;
                *)
                    echo "  Invalid input. Enter 1-7, 'a', or Enter to proceed."
                    ;;
            esac
        done

        # Count selected
        selected_count=0
        for i in "${!COMP_NAMES[@]}"; do
            [ "${COMP_SELECTED[$i]}" = true ] && [ "${COMP_FOUND[$i]}" = true ] && ((selected_count++)) || true
        done

        if [ "$selected_count" -eq 0 ]; then
            echo "Nothing selected. Cancelled."
            exit 0
        fi

        echo ""
        echo "Will remove:"
        for i in "${!COMP_NAMES[@]}"; do
            if [ "${COMP_SELECTED[$i]}" = true ] && [ "${COMP_FOUND[$i]}" = true ]; then
                echo "  - ${COMP_LABELS[$i]}"
            fi
        done
        echo ""
        read -rp "Proceed? [y/N]: " confirm
        case "$confirm" in
            [Yy]*)
                echo ""
                for i in "${!COMP_NAMES[@]}"; do
                    if [ "${COMP_SELECTED[$i]}" = true ] && [ "${COMP_FOUND[$i]}" = true ]; then
                        remove_component "$i"
                    fi
                done
                ;;
            *)
                echo "Cancelled."
                exit 0
                ;;
        esac
        ;;
esac

echo ""
echo "Uninstall complete."
echo "Note: ~/machine_setting repository was NOT removed."
echo "  To fully remove, run: rm -rf ~/machine_setting"
