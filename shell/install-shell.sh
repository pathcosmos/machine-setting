#!/usr/bin/env bash
# Install bashrc.d sourcing into user's .bashrc
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
BASHRC="$HOME/.bashrc"

# The sourcing block to add
MARKER="# >>> machine_setting >>>"
MARKER_END="# <<< machine_setting <<<"

BLOCK="$MARKER
# Auto-source shell modules from machine_setting
for f in $HOME/machine_setting/shell/bashrc.d/[0-9]*.sh; do
    [ -r \"\$f\" ] && source \"\$f\"
done
# Source machine-local secrets (never committed)
[ -r \"\$HOME/.bashrc.local\" ] && source \"\$HOME/.bashrc.local\"
$MARKER_END"

# Check if already installed
if grep -qF "$MARKER" "$BASHRC" 2>/dev/null; then
    echo "  Shell integration already installed in $BASHRC"
    # Update the block in case it changed
    # Remove old block and re-add
    TEMP=$(mktemp)
    awk "/$MARKER/{skip=1} /$MARKER_END/{skip=0; next} !skip" "$BASHRC" > "$TEMP"
    echo "" >> "$TEMP"
    echo "$BLOCK" >> "$TEMP"
    mv "$TEMP" "$BASHRC"
    echo "  Updated shell integration block"
else
    echo "" >> "$BASHRC"
    echo "$BLOCK" >> "$BASHRC"
    echo "  Shell integration installed in $BASHRC"
fi

# Create ~/.bashrc.local template if it doesn't exist
if [ ! -f "$HOME/.bashrc.local" ]; then
    cp "$SCRIPT_DIR/bashrc.d/90-local.sh.example" "$HOME/.bashrc.local"
    echo "  Created ~/.bashrc.local template (add your secrets here)"
fi

echo "  Done. Modules will load on next shell session."
