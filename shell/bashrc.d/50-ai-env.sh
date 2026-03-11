# AI Environment activation + background update check

# Resolve repo directory from this script's location
_MS_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Remove any conflicting alias before defining function
unalias aienv 2>/dev/null || true

# Main activation function
aienv() {
    local VENV_PATH="${1:-$HOME/ai-env}"

    if [ ! -d "$VENV_PATH" ]; then
        echo "Error: No venv at $VENV_PATH"
        echo "Run: $_MS_REPO_DIR/scripts/setup-venv.sh"
        return 1
    fi

    source "$VENV_PATH/bin/activate"

    # Enable TF32 for Ampere+ GPUs (A100, H100, B200, etc.)
    # TF32 provides ~2x throughput for FP32 matmul with minimal precision loss
    export NVIDIA_TF32_OVERRIDE=1

    echo "AI env activated: $VENV_PATH ($(python --version))"

    # Background update check
    _ms_check_updates &
    disown
}

# Deactivation helper
aienv-off() {
    if [ -n "${VIRTUAL_ENV:-}" ]; then
        deactivate
        echo "AI env deactivated"
    else
        echo "No active venv"
    fi
}

# Background update check (runs silently)
_ms_check_updates() {
    local REPO="$_MS_REPO_DIR"
    [ -d "$REPO/.git" ] || return

    local STAMP="$REPO/.last-update-check"
    local INTERVAL=86400  # 24 hours

    # Load custom interval if set
    if [ -f "$REPO/config/default.conf" ]; then
        INTERVAL=$(sed -n 's/^UPDATE_CHECK_INTERVAL=\([0-9]*\).*/\1/p' "$REPO/config/default.conf" 2>/dev/null || echo 86400)
        [ -z "$INTERVAL" ] && INTERVAL=86400
    fi

    # Skip if checked recently
    if [ -f "$STAMP" ]; then
        local LAST=$(cat "$STAMP" 2>/dev/null || echo 0)
        local NOW=$(date +%s)
        [ $((NOW - LAST)) -lt "$INTERVAL" ] && return
    fi

    # Fetch quietly
    git -C "$REPO" fetch origin main --quiet 2>/dev/null || return

    local LOCAL=$(git -C "$REPO" rev-parse HEAD 2>/dev/null)
    local REMOTE=$(git -C "$REPO" rev-parse origin/main 2>/dev/null)

    if [ -n "$LOCAL" ] && [ -n "$REMOTE" ] && [ "$LOCAL" != "$REMOTE" ]; then
        echo -e "\n\033[33m[machine_setting]\033[0m Updates available. Run: make -C $_MS_REPO_DIR update"
    fi

    date +%s > "$STAMP" 2>/dev/null || true
}
