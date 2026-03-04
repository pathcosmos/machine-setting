# AI Environment activation + background update check

# Main activation function
aienv() {
    local VENV_PATH="${1:-$HOME/ai-env}"

    if [ ! -d "$VENV_PATH" ]; then
        echo "Error: No venv at $VENV_PATH"
        echo "Run: ~/machine_setting/scripts/setup-venv.sh"
        return 1
    fi

    source "$VENV_PATH/bin/activate"
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
    local REPO="$HOME/machine_setting"
    [ -d "$REPO/.git" ] || return

    local STAMP="$REPO/.last-update-check"
    local INTERVAL=86400  # 24 hours

    # Load custom interval if set
    [ -f "$REPO/config/default.conf" ] && \
        INTERVAL=$(grep -oP 'UPDATE_CHECK_INTERVAL=\K[0-9]+' "$REPO/config/default.conf" 2>/dev/null || echo 86400)

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
        echo -e "\n\033[33m[machine_setting]\033[0m Updates available. Run: make -C ~/machine_setting update"
    fi

    date +%s > "$STAMP" 2>/dev/null || true
}
