#!/usr/bin/env bash
# Install SDKMAN + Java LTS
set -euo pipefail

JAVA_VERSION="${1:-21}"

echo "=== Java Setup ==="

export SDKMAN_DIR="${SDKMAN_DIR:-$HOME/.sdkman}"

# Install SDKMAN if not present
if [ ! -d "$SDKMAN_DIR" ]; then
    echo "Installing SDKMAN..."
    curl -s "https://get.sdkman.io?rcupdate=false" | bash
    echo "  SDKMAN installed"
fi

# Load SDKMAN (disable strict mode — SDKMAN scripts use unbound variables)
set +u
[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ] && source "$SDKMAN_DIR/bin/sdkman-init.sh"
set -u

if ! command -v sdk &>/dev/null; then
    echo "Error: SDKMAN failed to load"
    exit 1
fi

# Install Java (use Temurin distribution)
# SDKMAN internals require relaxed variable checking
set +u
echo "Installing Java ${JAVA_VERSION} (Eclipse Temurin)..."
JAVA_CANDIDATE=$(sdk list java 2>/dev/null | grep -oE "${JAVA_VERSION}\.[0-9.]+-tem" | head -1 || true)

if [ -n "$JAVA_CANDIDATE" ]; then
    sdk install java "$JAVA_CANDIDATE" || true
    echo "  Java $JAVA_CANDIDATE installed"
else
    # Fallback: install any matching version
    sdk install java "${JAVA_VERSION}-tem" 2>/dev/null || \
    sdk install java "${JAVA_VERSION}-open" 2>/dev/null || \
    echo "  Warning: Could not find Java ${JAVA_VERSION}. Run 'sdk list java' to see available versions."
fi
set -u

# Verify
if command -v java &>/dev/null; then
    echo "  $(java -version 2>&1 | head -1)"
fi
