#!/usr/bin/env bash
# install-base-tools.sh — Small system tools every machine gets, GPU or not (default: btop).
#
# Usage:
#   ./scripts/install-base-tools.sh            # install missing tools from BASE_TOOLS (sudo on Linux)
#   ./scripts/install-base-tools.sh --check    # status only, no changes
#   ./scripts/install-base-tools.sh --dry-run  # show what would be installed
#
# Config: BASE_TOOLS="btop ..." and INSTALL_BASE_TOOLS=true|false in config/default.conf / machine.conf.
# Package names are used as-is with apt-get (Debian/Ubuntu), dnf (Fedora/RHEL) or brew (macOS).
# Called from: setup.sh (right after hardware detection) and install-server.sh. Idempotent.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "$REPO_DIR/config/default.conf"
[ -f "$REPO_DIR/config/machine.conf" ] && source "$REPO_DIR/config/machine.conf"

MODE="install"
case "${1:-}" in
    --check)   MODE="check" ;;
    --dry-run) MODE="dry" ;;
    --help|-h) sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    "") ;;
    *) echo "Unknown option: $1"; exit 1 ;;
esac

TOOLS="${BASE_TOOLS:-btop}"
is_installed() {
    if command -v dpkg &>/dev/null; then dpkg -s "$1" 2>/dev/null | grep -q '^Status: install ok installed'
    elif command -v rpm &>/dev/null; then rpm -q "$1" &>/dev/null
    elif command -v brew &>/dev/null; then brew list --versions "$1" &>/dev/null
    else command -v "$1" &>/dev/null; fi
}

MISSING=()
for t in $TOOLS; do is_installed "$t" || MISSING+=("$t"); done

if [ "$MODE" = "check" ]; then
    if [ ${#MISSING[@]} -eq 0 ]; then echo "  [OK]    Base tools installed: $TOOLS"; exit 0; fi
    echo "  [WARN]  Base tools missing: ${MISSING[*]} — Run: ./scripts/install-base-tools.sh"
    exit 1
fi
if [ ${#MISSING[@]} -eq 0 ]; then
    echo "  Base tools already installed: $TOOLS"
    exit 0
fi
if [ "$MODE" = "dry" ]; then
    echo "  [DRY]   would install: ${MISSING[*]}"
    exit 0
fi

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"
echo "  Installing base tools: ${MISSING[*]}"
if command -v apt-get &>/dev/null; then
    $SUDO apt-get install -y "${MISSING[@]}" || { $SUDO apt-get update && $SUDO apt-get install -y "${MISSING[@]}"; }
elif command -v dnf &>/dev/null; then
    $SUDO dnf install -y "${MISSING[@]}"
elif command -v brew &>/dev/null; then
    brew install "${MISSING[@]}"
else
    echo "  [SKIP] No supported package manager (apt-get, dnf, brew) — install manually: ${MISSING[*]}"
    exit 0
fi
rc=$?
[ $rc -eq 0 ] && echo "  [OK]    Installed: ${MISSING[*]}" || echo "  [WARN]  Could not install: ${MISSING[*]}"
exit $rc
