#!/usr/bin/env bash
# Machine Setting - Single-entry bootstrap
# Usage:
#   ./setup.sh                                    # Interactive mode
#   ./setup.sh --python 3.12 --venv global --node --java
#   ./setup.sh --profile gpu-workstation
#   ./setup.sh --no-node --no-java --venv local
#   ./setup.sh --plan                             # Pre-flight check only
#   ./setup.sh --preflight                        # Pre-flight check then install
#   ./setup.sh --resume                           # Resume failed install
#   ./setup.sh --reset                            # Start fresh
#   ./setup.sh --from 3                           # Start from stage 3
#   ./setup.sh --doctor                           # Run health check
#   ./setup.sh --recover                          # Auto-recover broken components
#   ./setup.sh --cloud                             # Cloud/container mode (skip sudo ops)
#   ./setup.sh --uninstall                        # Uninstall
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Validate HOME ---
if [ -z "${HOME:-}" ] || [ ! -d "$HOME" ]; then
    echo "Warning: HOME is not set or invalid ('${HOME:-}')"
    HOME=$(getent passwd "$(whoami)" 2>/dev/null | cut -d: -f6 || echo "/home/$(whoami)")
    export HOME
    echo "  HOME resolved to: $HOME"
fi

# --- Load checkpoint library ---
source "$SCRIPT_DIR/scripts/lib-checkpoint.sh"

# --- Load defaults ---
source "$SCRIPT_DIR/config/default.conf"
[ -f "$SCRIPT_DIR/config/machine.conf" ] && source "$SCRIPT_DIR/config/machine.conf"

# --- Parse CLI flags ---
INTERACTIVE=true
VENV_MODE=""         # global/local/custom
VENV_CUSTOM_PATH=""
PROFILE=""
OPT_NODE=""
OPT_JAVA=""
OPT_RESUME=false
OPT_RESET=false
OPT_FROM=""
OPT_PREFLIGHT=""       # ""=auto in interactive, "plan"=check only, "run"=check then install
OPT_CLOUD=""           # ""=auto-detect, true=force cloud mode

while [[ $# -gt 0 ]]; do
    case "$1" in
        --python)       PYTHON_VERSION="$2"; INTERACTIVE=false; shift 2 ;;
        --venv)
            case "$2" in
                global) VENV_MODE="global" ;;
                local)  VENV_MODE="local" ;;
                *)      VENV_MODE="custom"; VENV_CUSTOM_PATH="$2" ;;
            esac
            INTERACTIVE=false; shift 2 ;;
        --node)         OPT_NODE=true; INTERACTIVE=false; shift ;;
        --no-node)      OPT_NODE=false; INTERACTIVE=false; shift ;;
        --java)         OPT_JAVA=true; INTERACTIVE=false; shift ;;
        --no-java)      OPT_JAVA=false; INTERACTIVE=false; shift ;;
        --profile)      PROFILE="$2"; INTERACTIVE=false; shift 2 ;;
        --cloud)        OPT_CLOUD=true; INTERACTIVE=false; shift ;;
        --dry-run)      shift; exec bash "$SCRIPT_DIR/scripts/dry-run.sh" "$@" ;;
        --plan)         exec bash "$SCRIPT_DIR/scripts/preflight.sh" --check-only ;;
        --preflight)    OPT_PREFLIGHT="run"; shift ;;
        --resume)       OPT_RESUME=true; shift ;;
        --reset)        OPT_RESET=true; shift ;;
        --from)         OPT_FROM="$2"; shift 2 ;;
        --doctor)       exec bash "$SCRIPT_DIR/scripts/doctor.sh" ;;
        --gpu-doctor)   exec bash "$SCRIPT_DIR/scripts/gpu-doctor.sh" ;;
        --gpu-persist-fix) shift; exec sudo bash "$SCRIPT_DIR/scripts/gpu-persist-fix.sh" "$@" ;;
        --recover)      exec bash "$SCRIPT_DIR/scripts/doctor.sh" --recover ;;
        --uninstall)    shift; exec bash "$SCRIPT_DIR/scripts/uninstall.sh" "$@" ;;
        --help|-h)
            echo "Usage: ./setup.sh [options]"
            echo ""
            echo "Setup options:"
            echo "  --python <ver>    Python version (default: $PYTHON_VERSION)"
            echo "  --venv <mode>     global | local | <path>"
            echo "  --node            Install NVM + Node.js"
            echo "  --no-node         Skip Node.js"
            echo "  --java            Install SDKMAN + Java"
            echo "  --no-java         Skip Java"
            echo "  --cloud           Cloud/container mode (skip driver/CUDA/kernel tuning)"
            echo "  --profile <name>  Use profile (gpu-workstation, cloud-server, cpu-server, mac-apple-silicon, laptop, minimal)"
            echo ""
            echo "Diagnostic options:"
            echo "  --dry-run         Full system dry-run diagnostic (all 7 stages)"
            echo "  --plan            Pre-flight check only (show what would happen)"
            echo "  --preflight       Pre-flight check, then install selected items"
            echo ""
            echo "Recovery options:"
            echo "  --resume          Resume from last failed/incomplete stage"
            echo "  --reset           Reset state and start from scratch"
            echo "  --from <N>        Start from stage N (1-7), mark earlier stages as done"
            echo "  --doctor          Run health check"
            echo "  --gpu-doctor      GPU-specific health diagnostics"
            echo "  --gpu-persist-fix Permanent GPU stability fixes (sudo)"
            echo "  --recover         Auto-recover broken components"
            echo "  --uninstall       Uninstall (pass additional flags after --uninstall)"
            echo "  --help            Show this help"
            exit 0 ;;
        *)  echo "Unknown option: $1"; exit 1 ;;
    esac
done

# --- Load profile if specified ---
if [ -n "$PROFILE" ]; then
    PROFILE_FILE="$SCRIPT_DIR/profiles/${PROFILE}.conf"
    if [ -f "$PROFILE_FILE" ]; then
        source "$PROFILE_FILE"
    else
        echo "Error: Profile not found: $PROFILE_FILE"
        echo "Available: $(ls "$SCRIPT_DIR/profiles/" | sed 's/.conf//' | tr '\n' ' ')"
        exit 1
    fi
fi

# --- Pre-flight check (interactive or --preflight) ---
PLAN_FILE="$SCRIPT_DIR/env/.preflight_plan"
USE_PLAN=false

if [ "$OPT_PREFLIGHT" = "run" ] || { [ "$INTERACTIVE" = true ] && [ "$OPT_RESUME" = false ] && [ "$OPT_RESET" = false ] && [ -z "$OPT_FROM" ]; }; then
    if bash "$SCRIPT_DIR/scripts/preflight.sh"; then
        if [ -f "$PLAN_FILE" ]; then
            source "$PLAN_FILE"
            USE_PLAN=true
        fi
    else
        echo "  Setup cancelled by pre-flight check."
        exit 0
    fi
fi

# ============================================================
echo ""
echo "╔══════════════════════════════════════╗"
echo "║     Machine Setting Bootstrap        ║"
echo "╚══════════════════════════════════════╝"
echo ""

# --- Initialize checkpoint system ---
checkpoint_init

# --- Handle resume/reset/from flags ---
if [ "$OPT_RESET" = true ]; then
    echo "  Resetting install state..."
    checkpoint_reset
elif [ -n "$OPT_FROM" ]; then
    # Mark stages before OPT_FROM as done
    echo "  Starting from stage $OPT_FROM (marking earlier stages as done)..."
    for n in 1 2 3 4 5 6 7; do
        _name=$(_stage_name "$n")
        if [ "$n" -lt "$OPT_FROM" ]; then
            checkpoint_write_key "STAGE_${n}_${_name}" "done"
        else
            checkpoint_write_key "STAGE_${n}_${_name}" "pending"
        fi
    done
elif [ "$OPT_RESUME" = true ]; then
    echo "  Resuming previous installation..."
elif [ -f "$CHECKPOINT_STATE" ]; then
    # Check for previous state interactively
    _any_progress=false
    for n in 1 2 3 4 5 6 7; do
        _name=$(_stage_name "$n")
        _state=$(checkpoint_get_state "$n" "$_name")
        if [ "$_state" != "pending" ] && [ -n "$_state" ]; then
            _any_progress=true
            break
        fi
    done
    if [ "$_any_progress" = true ] && [ "$INTERACTIVE" = true ]; then
        checkpoint_show_resume_menu
        case "$RESUME_ACTION" in
            resume) echo "  Resuming..." ;;
            reset)  echo "  Resetting..."; checkpoint_reset ;;
            cancel) echo "  Cancelled."; exit 0 ;;
        esac
    fi
fi

# --- macOS prerequisites check ---
if [ "$(uname -s)" = "Darwin" ]; then
    if ! xcode-select -p &>/dev/null; then
        echo "[Pre] Installing Xcode Command Line Tools..."
        xcode-select --install 2>/dev/null || true
        echo "  Please complete the Xcode CLT installation and re-run setup.sh"
        exit 1
    fi
fi

# ============================================================
# [1/7] Hardware Detection
# ============================================================
if checkpoint_is_done 1 HARDWARE; then
    echo "[1/7] Hardware Detection... already done, skipping"
    [ -f "$HOME/.machine_setting_profile" ] && source "$HOME/.machine_setting_profile"
elif [ "$USE_PLAN" = true ] && [ "${PLAN_HARDWARE:-}" = "skip" ]; then
    echo "[1/7] Hardware Detection... skipped (pre-flight)"
    [ -f "$HOME/.machine_setting_profile" ] && source "$HOME/.machine_setting_profile"
else
    echo "[1/7] Hardware Detection..."
    checkpoint_start_stage 1 HARDWARE
    checkpoint_trap_setup 1 HARDWARE

    bash "$SCRIPT_DIR/scripts/detect-hardware.sh" "$HOME/.machine_setting_profile"
    source "$HOME/.machine_setting_profile"

    checkpoint_trap_clear
    checkpoint_complete_stage 1 HARDWARE
fi
echo ""

# Auto-select profile if not specified
if [ -z "$PROFILE" ]; then
    PROFILE="${SUGGESTED_PROFILE:-}"
    if [ -n "$PROFILE" ]; then
        PROFILE_FILE="$SCRIPT_DIR/profiles/${PROFILE}.conf"
        [ -f "$PROFILE_FILE" ] && source "$PROFILE_FILE"
    fi
fi

# --- Cloud mode resolution ---
# Explicit --cloud flag overrides; otherwise auto-detect from hardware profile
if [ "$OPT_CLOUD" = true ]; then
    CLOUD_MODE=true
elif [ -z "$OPT_CLOUD" ] && [ "${IS_CLOUD:-false}" = true ]; then
    CLOUD_MODE=true
fi

if [ "${CLOUD_MODE:-false}" = true ]; then
    echo "  ☁ Cloud mode active (${CLOUD_REASON:-manual})"
    echo "    → Skipping: driver install, CUDA toolkit, kernel tuning, system packages"
    echo "    → Installing: Python venv, Node.js, Java, shell config (user-space only)"
    echo ""
    # Force-disable all sudo-required stages
    INSTALL_NVIDIA=false
    NVIDIA_SYSTEM_TOOLS=false
    NVIDIA_KERNEL_TUNING=false
fi

# ============================================================
# [2/7] NVIDIA GPU Stack (driver, CUDA, cuDNN, NCCL)
# ============================================================
if checkpoint_is_done 2 NVIDIA; then
    echo "[2/7] NVIDIA GPU Stack... already done, skipping"
elif [ "$USE_PLAN" = true ] && [ "${PLAN_NVIDIA:-}" = "skip" ]; then
    echo "[2/7] NVIDIA GPU Stack... skipped (pre-flight)"
elif [ "${HAS_GPU:-false}" != "true" ] || [ "${GPU_BACKEND:-none}" != "cuda" ]; then
    echo "[2/7] NVIDIA GPU Stack... skipped (no NVIDIA GPU)"
    checkpoint_write_key "STAGE_2_NVIDIA" "skipped"
elif [ "$(uname -s)" != "Linux" ]; then
    echo "[2/7] NVIDIA GPU Stack... skipped (Linux-only)"
    checkpoint_write_key "STAGE_2_NVIDIA" "skipped"
elif [ "${INSTALL_NVIDIA:-true}" = false ]; then
    echo "[2/7] NVIDIA GPU Stack... skipped (disabled in profile)"
    checkpoint_write_key "STAGE_2_NVIDIA" "skipped"
else
    echo "[2/7] NVIDIA GPU Stack"

    NVIDIA_ARGS=""
    [ "${NVIDIA_ENTERPRISE:-false}" = true ] && NVIDIA_ARGS="$NVIDIA_ARGS --enterprise"
    [ "${NVIDIA_NO_DRIVER:-false}" = true ] && NVIDIA_ARGS="$NVIDIA_ARGS --no-driver"
    [ -n "${NVIDIA_DRIVER_VERSION:-}" ] && NVIDIA_ARGS="$NVIDIA_ARGS --driver-version $NVIDIA_DRIVER_VERSION"
    [ -n "${NVIDIA_CUDA_VERSION:-}" ] && NVIDIA_ARGS="$NVIDIA_ARGS --cuda-version $NVIDIA_CUDA_VERSION"
    [ "${NVIDIA_OPEN_KERNEL:-auto}" != "auto" ] && {
        [ "$NVIDIA_OPEN_KERNEL" = true ] && NVIDIA_ARGS="$NVIDIA_ARGS --open-kernel"
        [ "$NVIDIA_OPEN_KERNEL" = false ] && NVIDIA_ARGS="$NVIDIA_ARGS --proprietary"
    }
    [ "${NVIDIA_CONTAINER_TOOLKIT:-true}" = false ] && NVIDIA_ARGS="$NVIDIA_ARGS --no-container-toolkit"
    [ "${NVIDIA_SYSTEM_TOOLS:-true}" = false ] && NVIDIA_ARGS="$NVIDIA_ARGS --no-system-tools"
    [ "${NVIDIA_KERNEL_TUNING:-true}" = false ] && NVIDIA_ARGS="$NVIDIA_ARGS --no-kernel-tuning"

    checkpoint_start_stage 2 NVIDIA
    checkpoint_trap_setup 2 NVIDIA

    echo "  → Installing NVIDIA stack (driver, CUDA, cuDNN, tools)..."
    bash "$SCRIPT_DIR/scripts/install-nvidia.sh" $NVIDIA_ARGS

    checkpoint_trap_clear
    checkpoint_complete_stage 2 NVIDIA
fi
echo ""

# ============================================================
# [3/7] Python Setup
# ============================================================
if checkpoint_is_done 3 PYTHON; then
    echo "[3/7] Python Setup... already done, skipping"
elif [ "$USE_PLAN" = true ] && [ "${PLAN_PYTHON:-}" = "skip" ]; then
    echo "[3/7] Python Setup... skipped (pre-flight)"
else
    echo "[3/7] Python Setup"
    if [ "$INTERACTIVE" = true ]; then
        read -rp "  Python version [$PYTHON_VERSION]: " INPUT
        [ -n "$INPUT" ] && PYTHON_VERSION="$INPUT"
    fi

    checkpoint_start_stage 3 PYTHON
    checkpoint_save_metadata "" "$PYTHON_VERSION"
    checkpoint_trap_setup 3 PYTHON

    echo "  → Installing Python $PYTHON_VERSION via uv..."
    bash "$SCRIPT_DIR/scripts/install-python.sh" "$PYTHON_VERSION"

    checkpoint_trap_clear
    checkpoint_complete_stage 3 PYTHON
fi
echo ""

# ============================================================
# [4/7] AI Environment
# ============================================================
if checkpoint_is_done 4 VENV; then
    echo "[4/7] AI Environment... already done, skipping"
elif [ "$USE_PLAN" = true ] && [ "${PLAN_VENV:-}" = "skip" ]; then
    echo "[4/7] AI Environment... skipped (pre-flight)"
else
    echo "[4/7] AI Environment"

    if [ -z "$VENV_MODE" ]; then
        if [ "$INTERACTIVE" = true ]; then
            echo "  Install location:"
            echo "    1) Global (~/ai-env)  [default]"
            echo "    2) Project local (./.venv)"
            echo "    3) Custom path"
            read -rp "  Choice [1]: " CHOICE
            case "${CHOICE:-1}" in
                1) VENV_MODE="global" ;;
                2) VENV_MODE="local" ;;
                3) read -rp "  Path: " VENV_CUSTOM_PATH; VENV_MODE="custom" ;;
                *) VENV_MODE="global" ;;
            esac
        else
            VENV_MODE="global"
        fi
    fi

    case "$VENV_MODE" in
        global) VENV_ARGS="--global"; RESOLVED_VENV_PATH="$HOME/ai-env" ;;
        local)  VENV_ARGS="--local"; RESOLVED_VENV_PATH="./.venv" ;;
        custom) VENV_ARGS="--path $VENV_CUSTOM_PATH"; RESOLVED_VENV_PATH="$VENV_CUSTOM_PATH" ;;
    esac

    # --- Disk space check ---
    REQUIRED_GB=15
    VENV_CHECK_DIR="$(dirname "$RESOLVED_VENV_PATH")"
    [ -d "$VENV_CHECK_DIR" ] || VENV_CHECK_DIR="$HOME"
    AVAILABLE_GB=$(df -BG "$VENV_CHECK_DIR" 2>/dev/null | awk 'NR==2{print $4}' | tr -d 'G' || echo 0)
    if [ "$AVAILABLE_GB" -lt "$REQUIRED_GB" ] 2>/dev/null; then
        echo "  Warning: Only ${AVAILABLE_GB}GB available at $VENV_CHECK_DIR (${REQUIRED_GB}GB recommended)"
        echo "  Consider using --venv <path> with a larger partition"
        if [ "$INTERACTIVE" = true ]; then
            read -rp "  Continue anyway? [y/N]: " CONT
            [[ "${CONT:-N}" =~ ^[Yy]$ ]] || exit 1
        fi
    fi

    checkpoint_start_stage 4 VENV
    checkpoint_save_metadata "$RESOLVED_VENV_PATH" "$PYTHON_VERSION"
    checkpoint_trap_setup 4 VENV

    GPU_LABEL="CPU mode"
    [ "${GPU_BACKEND:-none}" = "cuda" ] && GPU_LABEL="GPU mode (CUDA)"
    [ "${GPU_BACKEND:-none}" = "mps" ] && GPU_LABEL="GPU mode (MPS/Apple Silicon)"

    echo "  → Creating venv ($GPU_LABEL)..."
    VENV_EXTRA_ARGS=""
    if [ "${NV_LINK:-false}" = true ]; then
        VENV_EXTRA_ARGS="--nv-link"
        echo "  → NV custom build symlink mode enabled"
    fi
    bash "$SCRIPT_DIR/scripts/setup-venv.sh" $VENV_ARGS --python "$PYTHON_VERSION" $VENV_EXTRA_ARGS

    checkpoint_trap_clear
    checkpoint_complete_stage 4 VENV
fi
echo ""

# ============================================================
# [5/7] Node.js (optional)
# ============================================================
if checkpoint_is_done 5 NODE; then
    echo "[5/7] Node.js... already done, skipping"
elif [ "$USE_PLAN" = true ] && [ "${PLAN_NODE:-}" = "skip" ]; then
    echo "[5/7] Node.js... skipped (pre-flight)"
else
    echo "[5/7] Node.js (optional)"
    if [ "$USE_PLAN" = true ] && [ "${PLAN_NODE:-}" = "run" ]; then
        OPT_NODE=true
    fi
    if [ -z "$OPT_NODE" ]; then
        if [ "$INTERACTIVE" = true ]; then
            DEFAULT="Y"
            [ "$INSTALL_NODE" = false ] && DEFAULT="n"
            read -rp "  Install NVM + Node.js LTS? [${DEFAULT}]: " INPUT
            case "${INPUT:-$DEFAULT}" in
                [Yy]*) OPT_NODE=true ;;
                *)     OPT_NODE=false ;;
            esac
        else
            OPT_NODE="$INSTALL_NODE"
        fi
    fi

    if [ "$OPT_NODE" = true ]; then
        checkpoint_start_stage 5 NODE
        checkpoint_trap_setup 5 NODE

        echo "  → Installing NVM + Node.js..."
        bash "$SCRIPT_DIR/scripts/install-node.sh" "$NODE_VERSION"

        checkpoint_trap_clear
        checkpoint_complete_stage 5 NODE
    else
        echo "  → Skipped"
        checkpoint_write_key "STAGE_5_NODE" "skipped"
    fi
fi
echo ""

# ============================================================
# [6/7] Java (optional)
# ============================================================
if checkpoint_is_done 6 JAVA; then
    echo "[6/7] Java... already done, skipping"
elif [ "$USE_PLAN" = true ] && [ "${PLAN_JAVA:-}" = "skip" ]; then
    echo "[6/7] Java... skipped (pre-flight)"
else
    echo "[6/7] Java (optional)"
    if [ "$USE_PLAN" = true ] && [ "${PLAN_JAVA:-}" = "run" ]; then
        OPT_JAVA=true
    fi
    if [ -z "$OPT_JAVA" ]; then
        if [ "$INTERACTIVE" = true ]; then
            DEFAULT="Y"
            [ "$INSTALL_JAVA" = false ] && DEFAULT="n"
            read -rp "  Install SDKMAN + Java LTS? [${DEFAULT}]: " INPUT
            case "${INPUT:-$DEFAULT}" in
                [Yy]*) OPT_JAVA=true ;;
                *)     OPT_JAVA=false ;;
            esac
        else
            OPT_JAVA="$INSTALL_JAVA"
        fi
    fi

    if [ "$OPT_JAVA" = true ]; then
        checkpoint_start_stage 6 JAVA
        checkpoint_trap_setup 6 JAVA

        echo "  → Installing SDKMAN + Java ${JAVA_VERSION}..."
        bash "$SCRIPT_DIR/scripts/install-java.sh" "$JAVA_VERSION"

        checkpoint_trap_clear
        checkpoint_complete_stage 6 JAVA
    else
        echo "  → Skipped"
        checkpoint_write_key "STAGE_6_JAVA" "skipped"
    fi
fi
echo ""

# ============================================================
# [7/7] Shell Integration
# ============================================================
if checkpoint_is_done 7 SHELL; then
    echo "[7/7] Shell Integration... already done, skipping"
elif [ "$USE_PLAN" = true ] && [ "${PLAN_SHELL:-}" = "skip" ]; then
    echo "[7/7] Shell Integration... skipped (pre-flight)"
else
    echo "[7/7] Shell Integration"

    # Backup RC files before modification
    backup_shell_rc "$HOME/.bashrc"
    backup_shell_rc "$HOME/.zshrc"

    checkpoint_start_stage 7 SHELL
    checkpoint_trap_setup 7 SHELL

    echo "  → Configuring shell modules (bash + zsh)..."
    bash "$SCRIPT_DIR/shell/install-shell.sh"

    # Configure git hooks
    git -C "$SCRIPT_DIR" config core.hooksPath .githooks 2>/dev/null || true

    checkpoint_trap_clear
    checkpoint_complete_stage 7 SHELL
fi

# Clean up plan file
[ -f "$PLAN_FILE" ] && rm -f "$PLAN_FILE"

echo ""
echo "╔══════════════════════════════════════╗"
echo "║          Setup Complete!             ║"
echo "╚══════════════════════════════════════╝"
echo ""
CURRENT_SHELL="$(basename "${SHELL:-/bin/bash}")"
case "$CURRENT_SHELL" in
    zsh)  echo "  Run 'source ~/.zshrc' or open a new terminal." ;;
    bash) echo "  Run 'source ~/.bashrc' or open a new terminal." ;;
    *)    echo "  Open a new terminal to load shell modules." ;;
esac
echo "  Then use 'aienv' to activate the AI environment."
echo ""
