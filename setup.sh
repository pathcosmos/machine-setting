#!/usr/bin/env bash
# Machine Setting - Single-entry bootstrap
# Usage:
#   ./setup.sh                                    # Interactive mode
#   ./setup.sh --python 3.12 --venv global --node --java
#   ./setup.sh --profile gpu-workstation
#   ./setup.sh --no-node --no-java --venv local
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
        --help|-h)
            echo "Usage: ./setup.sh [options]"
            echo ""
            echo "Options:"
            echo "  --python <ver>    Python version (default: $PYTHON_VERSION)"
            echo "  --venv <mode>     global | local | <path>"
            echo "  --node            Install NVM + Node.js"
            echo "  --no-node         Skip Node.js"
            echo "  --java            Install SDKMAN + Java"
            echo "  --no-java         Skip Java"
            echo "  --profile <name>  Use profile (gpu-workstation, cpu-server, mac-apple-silicon, laptop, minimal)"
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

# ============================================================
echo ""
echo "╔══════════════════════════════════════╗"
echo "║     Machine Setting Bootstrap        ║"
echo "╚══════════════════════════════════════╝"
echo ""

# --- macOS prerequisites check ---
if [ "$(uname -s)" = "Darwin" ]; then
    # Ensure Xcode Command Line Tools are installed
    if ! xcode-select -p &>/dev/null; then
        echo "[Pre] Installing Xcode Command Line Tools..."
        xcode-select --install 2>/dev/null || true
        echo "  Please complete the Xcode CLT installation and re-run setup.sh"
        exit 1
    fi
fi

# ============================================================
# [1/6] Hardware Detection
# ============================================================
echo "[1/6] Hardware Detection..."
bash "$SCRIPT_DIR/scripts/detect-hardware.sh" "$HOME/.machine_setting_profile"
source "$HOME/.machine_setting_profile"
echo ""

# Auto-select profile if not specified
if [ -z "$PROFILE" ]; then
    PROFILE="$SUGGESTED_PROFILE"
    PROFILE_FILE="$SCRIPT_DIR/profiles/${PROFILE}.conf"
    [ -f "$PROFILE_FILE" ] && source "$PROFILE_FILE"
fi

# ============================================================
# [2/6] Python Setup
# ============================================================
echo "[2/6] Python Setup"
if [ "$INTERACTIVE" = true ]; then
    read -rp "  Python version [$PYTHON_VERSION]: " INPUT
    [ -n "$INPUT" ] && PYTHON_VERSION="$INPUT"
fi
echo "  → Installing Python $PYTHON_VERSION via uv..."
bash "$SCRIPT_DIR/scripts/install-python.sh" "$PYTHON_VERSION"
echo ""

# ============================================================
# [3/6] AI Environment
# ============================================================
echo "[3/6] AI Environment"

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
    global) VENV_ARGS="--global" ;;
    local)  VENV_ARGS="--local" ;;
    custom) VENV_ARGS="--path $VENV_CUSTOM_PATH" ;;
esac

GPU_LABEL="CPU mode"
[ "${GPU_BACKEND:-none}" = "cuda" ] && GPU_LABEL="GPU mode (CUDA)"
[ "${GPU_BACKEND:-none}" = "mps" ] && GPU_LABEL="GPU mode (MPS/Apple Silicon)"

echo "  → Creating venv ($GPU_LABEL)..."
bash "$SCRIPT_DIR/scripts/setup-venv.sh" $VENV_ARGS --python "$PYTHON_VERSION"
echo ""

# ============================================================
# [4/6] Node.js (optional)
# ============================================================
echo "[4/6] Node.js (optional)"
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
    echo "  → Installing NVM + Node.js..."
    bash "$SCRIPT_DIR/scripts/install-node.sh" "$NODE_VERSION"
else
    echo "  → Skipped"
fi
echo ""

# ============================================================
# [5/6] Java (optional)
# ============================================================
echo "[5/6] Java (optional)"
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
    echo "  → Installing SDKMAN + Java ${JAVA_VERSION}..."
    bash "$SCRIPT_DIR/scripts/install-java.sh" "$JAVA_VERSION"
else
    echo "  → Skipped"
fi
echo ""

# ============================================================
# [6/6] Shell Integration
# ============================================================
echo "[6/6] Shell Integration"
echo "  → Configuring shell modules (bash + zsh)..."
bash "$SCRIPT_DIR/shell/install-shell.sh"

# Configure git hooks
git -C "$SCRIPT_DIR" config core.hooksPath .githooks 2>/dev/null || true

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
