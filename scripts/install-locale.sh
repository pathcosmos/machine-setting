#!/usr/bin/env bash
# install-locale.sh — Generate the UTF-8 locales the shell config switches between.
#
# shell/bashrc.d/20-env.sh picks the locale per terminal:
#   SSH / terminal emulator / tmux  -> LOCALE_REMOTE  (default ko_KR.UTF-8: Korean messages)
#   Linux console (direct tty)      -> LOCALE_CONSOLE (default en_US.UTF-8: the console cannot draw Hangul)
# This script only makes those locales exist. The system default (/etc/default/locale) is left
# alone, so services and logs keep their current language.
#
# Usage:
#   ./scripts/install-locale.sh            # generate missing locales (+ Ubuntu language pack), sudo
#   ./scripts/install-locale.sh --check    # status only, no changes
#   ./scripts/install-locale.sh --dry-run  # show what would be done
#
# Config: INSTALL_LOCALES=true|false, LOCALE_REMOTE, LOCALE_CONSOLE in config/default.conf / machine.conf.
# Called from: setup.sh (after base tools). Idempotent. Linux with locale-gen only.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "$REPO_DIR/config/default.conf"
[ -f "$REPO_DIR/config/machine.conf" ] && source "$REPO_DIR/config/machine.conf"

MODE="install"
case "${1:-}" in
    --check)   MODE="check" ;;
    --dry-run) MODE="dry" ;;
    --help|-h) sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    "") ;;
    *) echo "Unknown option: $1"; exit 1 ;;
esac

REMOTE="${LOCALE_REMOTE:-ko_KR.UTF-8}"
CONSOLE="${LOCALE_CONSOLE:-en_US.UTF-8}"
WANTED=$(printf '%s\n' "$REMOTE" "$CONSOLE" | awk 'NF && !seen[$0]++')

has_locale() {   # ko_KR.UTF-8 is listed by `locale -a` as ko_KR.utf8
    locale -a 2>/dev/null | grep -qiE "^${1%.*}\.utf-?8$"
}
# Ubuntu ships translated messages (apt, coreutils, ...) in language-pack-<lang>
lang_pack() {
    local lang="${1%%_*}"
    [ "$lang" = "en" ] || [ "$lang" = "C" ] && return 1
    command -v apt-cache &>/dev/null && apt-cache show "language-pack-$lang" &>/dev/null && echo "language-pack-$lang"
}
has_localegen() { command -v locale-gen &>/dev/null || [ -x /usr/sbin/locale-gen ]; }
pack_installed() { dpkg -s "$1" 2>/dev/null | grep -q '^Status: install ok installed'; }

MISSING=(); PACKS=()
for l in $WANTED; do
    has_locale "$l" || MISSING+=("$l")
    if p=$(lang_pack "$l"); then pack_installed "$p" || PACKS+=("$p"); fi
done

if [ "$MODE" = "check" ]; then
    if [ ${#MISSING[@]} -eq 0 ] && [ ${#PACKS[@]} -eq 0 ]; then
        echo "  [OK]    Locales ready: remote/SSH = $REMOTE, console = $CONSOLE"; exit 0
    fi
    [ ${#MISSING[@]} -gt 0 ] && echo "  [WARN]  Locales not generated: ${MISSING[*]} — Run: ./scripts/install-locale.sh"
    [ ${#PACKS[@]} -gt 0 ] && echo "  [WARN]  Translation packages missing: ${PACKS[*]} — Run: ./scripts/install-locale.sh"
    exit 1
fi
if [ ${#MISSING[@]} -eq 0 ] && [ ${#PACKS[@]} -eq 0 ]; then
    echo "  Locales already set up: remote/SSH = $REMOTE, console = $CONSOLE"
    exit 0
fi
if [ "$(uname -s)" != "Linux" ]; then
    echo "  [SKIP] Locale generation is Linux-only (macOS ships its locales)"; exit 0
fi
if [ "$MODE" = "dry" ]; then
    [ ${#PACKS[@]} -gt 0 ] && echo "  [DRY]   would install: ${PACKS[*]}"
    [ ${#MISSING[@]} -gt 0 ] && echo "  [DRY]   would generate: ${MISSING[*]}"
    exit 0
fi

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"
RC=0
if command -v apt-get &>/dev/null; then
    PKGS=()
    has_localegen || PKGS+=(locales)
    PKGS+=("${PACKS[@]}")
    if [ ${#PKGS[@]} -gt 0 ]; then
        echo "  Installing: ${PKGS[*]}"
        $SUDO apt-get install -y "${PKGS[@]}" || { $SUDO apt-get update && $SUDO apt-get install -y "${PKGS[@]}"; } || RC=1
    fi
fi
for l in "${MISSING[@]}"; do
    has_locale "$l" && continue          # the language pack may have generated it already
    echo "  Generating locale: $l"
    if has_localegen; then
        # Ubuntu's locale-gen takes the name as an argument; Debian's reads /etc/locale.gen
        if ! $SUDO locale-gen "$l" >/dev/null 2>&1 || ! has_locale "$l"; then
            $SUDO sed -i "s/^# *\(${l%.*}\.UTF-8 UTF-8\)/\1/" /etc/locale.gen 2>/dev/null
            grep -qs "^${l%.*}\.UTF-8 UTF-8" /etc/locale.gen || echo "${l%.*}.UTF-8 UTF-8" | $SUDO tee -a /etc/locale.gen >/dev/null
            $SUDO locale-gen >/dev/null 2>&1
        fi
    elif command -v localedef &>/dev/null; then
        $SUDO localedef -i "${l%.*}" -f UTF-8 "${l%.*}.UTF-8"
    fi
    has_locale "$l" || { echo "  [WARN]  Could not generate $l"; RC=1; }
done
[ $RC -eq 0 ] && echo "  [OK]    Locales ready: remote/SSH = $REMOTE, console = $CONSOLE (open a new shell to apply)"
exit $RC
