#!/usr/bin/env bash
# Install Python via uv (installs uv first if needed)
set -euo pipefail

PYTHON_VERSION="${1:-3.12}"

echo "=== Python Setup ==="

# Install uv if not present
if ! command -v uv &>/dev/null; then
    echo "Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    # Source uv into current session
    export PATH="$HOME/.local/bin:$PATH"
    echo "  uv $(uv --version) installed"
else
    echo "  uv $(uv --version) already installed"
fi

# Install Python version
echo "Installing Python ${PYTHON_VERSION}..."
uv python install "$PYTHON_VERSION"

# Verify
PYTHON_BIN=$(uv python find "$PYTHON_VERSION" 2>/dev/null || true)
if [ -n "$PYTHON_BIN" ]; then
    echo "  Python $("$PYTHON_BIN" --version) ready at $PYTHON_BIN"
else
    echo "  Warning: Could not locate Python $PYTHON_VERSION binary"
fi
