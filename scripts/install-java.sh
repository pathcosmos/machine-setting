#!/usr/bin/env bash
# Install SDKMAN + Java LTS
set -euo pipefail

JAVA_VERSION="${1:-25}"

echo "=== Java Setup ==="

export SDKMAN_DIR="${SDKMAN_DIR:-$HOME/.sdkman}"

# JAVA_REPLACE_SYSTEM=true (pre-flight "replace"): remove distro JDK/JRE packages so only the SDKMAN one remains
if [ "${JAVA_REPLACE_SYSTEM:-false}" = true ] && command -v apt-get &>/dev/null; then
    OLD_JAVA_PKGS=$(dpkg-query -W -f='${Status} ${Package}\n' 'openjdk-*-jdk*' 'openjdk-*-jre*' 'default-jdk*' 'default-jre*' 2>/dev/null \
        | awk '/^install ok installed/ {print $4}' | tr '\n' ' ' || true)
    if [ -n "$OLD_JAVA_PKGS" ]; then
        echo "Removing apt Java packages: $OLD_JAVA_PKGS"
        # shellcheck disable=SC2086
        sudo apt-get purge -y $OLD_JAVA_PKGS
        sudo apt-get autoremove -y 2>/dev/null || true
    fi
fi

# SDKMAN's installer aborts without zip/unzip/curl (not present on a fresh Ubuntu install)
MISSING_TOOLS=""
for tool in zip unzip curl; do
    command -v "$tool" &>/dev/null || MISSING_TOOLS="$MISSING_TOOLS $tool"
done
if [ -n "$MISSING_TOOLS" ]; then
    echo "Installing SDKMAN prerequisites:$MISSING_TOOLS"
    if command -v apt-get &>/dev/null && command -v sudo &>/dev/null; then
        # shellcheck disable=SC2086
        sudo apt-get install -y $MISSING_TOOLS
    else
        echo "Error: missing$MISSING_TOOLS — install them and re-run"
        exit 1
    fi
fi

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
JAVA_CANDIDATE=$(sdk list java 2>/dev/null | grep -oE "${JAVA_VERSION}\.[0-9.+]+-tem" | head -1 || true)

if [ -n "$JAVA_CANDIDATE" ]; then
    sdk install java "$JAVA_CANDIDATE" || true
    # `sdk install` only offers to switch; make the requested one the default explicitly
    sdk default java "$JAVA_CANDIDATE" >/dev/null 2>&1 || true
    echo "  Java $JAVA_CANDIDATE installed (default)"
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
