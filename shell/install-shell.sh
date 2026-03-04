#!/usr/bin/env bash
# Install shell module sourcing into user's shell rc file
# Supports: bash (.bashrc) and zsh (.zshrc)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# --- Detect shell(s) to configure ---
SHELLS_TO_CONFIGURE=()

# Always configure the current shell
CURRENT_SHELL="$(basename "${SHELL:-/bin/bash}")"

# On macOS, zsh is the default; on Linux, bash is typical
# Configure both if both rc files exist or if the shell is active
case "$CURRENT_SHELL" in
    zsh)
        SHELLS_TO_CONFIGURE+=(zsh)
        # Also configure bash if .bashrc exists (user might switch)
        [ -f "$HOME/.bashrc" ] && SHELLS_TO_CONFIGURE+=(bash)
        ;;
    bash)
        SHELLS_TO_CONFIGURE+=(bash)
        # Also configure zsh if .zshrc exists
        [ -f "$HOME/.zshrc" ] && SHELLS_TO_CONFIGURE+=(zsh)
        ;;
    *)
        # Fallback: try both
        SHELLS_TO_CONFIGURE+=(bash)
        command -v zsh &>/dev/null && SHELLS_TO_CONFIGURE+=(zsh)
        ;;
esac

# --- Markers ---
MARKER="# >>> machine_setting >>>"
MARKER_END="# <<< machine_setting <<<"

# --- Install function ---
install_shell_block() {
    local SHELL_NAME="$1"
    local RC_FILE="$2"
    local LOCAL_FILE="$3"

    # Build the sourcing block
    local BLOCK="$MARKER
# Auto-source shell modules from machine_setting
for f in $HOME/machine_setting/shell/bashrc.d/[0-9]*.sh; do
    [ -r \"\$f\" ] && source \"\$f\"
done
# Source machine-local secrets (never committed)
[ -r \"$LOCAL_FILE\" ] && source \"$LOCAL_FILE\"
$MARKER_END"

    # Ensure rc file exists
    touch "$RC_FILE"

    if grep -qF "$MARKER" "$RC_FILE" 2>/dev/null; then
        # Update existing block
        TEMP=$(mktemp)
        awk "/$MARKER/{skip=1} /$MARKER_END/{skip=0; next} !skip" "$RC_FILE" > "$TEMP"
        echo "" >> "$TEMP"
        echo "$BLOCK" >> "$TEMP"
        mv "$TEMP" "$RC_FILE"
        echo "  [$SHELL_NAME] Updated integration in $RC_FILE"
    else
        echo "" >> "$RC_FILE"
        echo "$BLOCK" >> "$RC_FILE"
        echo "  [$SHELL_NAME] Installed integration in $RC_FILE"
    fi
}

# --- Install for each detected shell ---
for shell in "${SHELLS_TO_CONFIGURE[@]}"; do
    case "$shell" in
        bash)
            install_shell_block "bash" "$HOME/.bashrc" "\$HOME/.bashrc.local"
            ;;
        zsh)
            install_shell_block "zsh" "$HOME/.zshrc" "\$HOME/.zshrc.local"
            ;;
    esac
done

# --- Create local secrets template ---
# For bash
if [[ " ${SHELLS_TO_CONFIGURE[*]} " == *" bash "* ]] && [ ! -f "$HOME/.bashrc.local" ]; then
    cp "$SCRIPT_DIR/bashrc.d/90-local.sh.example" "$HOME/.bashrc.local"
    echo "  Created ~/.bashrc.local template (add your secrets here)"
fi

# For zsh (symlink to bashrc.local if it exists, or create separate)
if [[ " ${SHELLS_TO_CONFIGURE[*]} " == *" zsh "* ]] && [ ! -f "$HOME/.zshrc.local" ]; then
    if [ -f "$HOME/.bashrc.local" ]; then
        ln -sf "$HOME/.bashrc.local" "$HOME/.zshrc.local"
        echo "  Linked ~/.zshrc.local -> ~/.bashrc.local (shared secrets)"
    else
        cp "$SCRIPT_DIR/bashrc.d/90-local.sh.example" "$HOME/.zshrc.local"
        echo "  Created ~/.zshrc.local template (add your secrets here)"
    fi
fi

echo "  Done. Modules will load on next shell session."
