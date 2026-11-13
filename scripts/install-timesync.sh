#!/usr/bin/env bash
# install-timesync.sh — Keep the clock right: NTP sync on, optional extra time sources, optional timezone.
#
# What it does (each step only when needed):
#   1. Makes sure an NTP client is installed and running (chrony or systemd-timesyncd; installs chrony if none)
#   2. Adds NTP_EXTRA_SERVERS as additional sources, so sync survives when the distro's servers are unreachable
#   3. Sets the system timezone to TIMEZONE (empty = leave the current timezone alone)
#
# Usage:
#   ./scripts/install-timesync.sh            # apply (sudo)
#   ./scripts/install-timesync.sh --check    # status only, no changes (exit 1 when something is off)
#   ./scripts/install-timesync.sh --dry-run  # show what would be done
#
# Config: INSTALL_TIMESYNC=true|false, TIMEZONE, NTP_EXTRA_SERVERS in config/default.conf / machine.conf.
# Called from: setup.sh (after locales). Idempotent. Linux with systemd only.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "$REPO_DIR/config/default.conf"
[ -f "$REPO_DIR/config/machine.conf" ] && source "$REPO_DIR/config/machine.conf"

MODE="install"
case "${1:-}" in
    --check)   MODE="check" ;;
    --dry-run) MODE="dry" ;;
    --help|-h) sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    "") ;;
    *) echo "Unknown option: $1"; exit 1 ;;
esac

WANT_TZ="${TIMEZONE:-}"
EXTRA="${NTP_EXTRA_SERVERS:-}"
CHRONY_SRC="/etc/chrony/sources.d/machine-setting.sources"
[ -d /etc/chrony ] || CHRONY_SRC="/etc/chrony.d/machine-setting.sources"   # RHEL layout
TIMESYNCD_DROPIN="/etc/systemd/timesyncd.conf.d/machine-setting.conf"

if [ "$(uname -s)" != "Linux" ] || ! command -v timedatectl &>/dev/null; then
    echo "  [SKIP] Time sync setup needs Linux with systemd (timedatectl)"; exit 0
fi

tdc() { timedatectl show -p "$1" --value 2>/dev/null; }
unit_active() { systemctl is-active --quiet "$1" 2>/dev/null; }
unit_exists() { systemctl cat "$1" &>/dev/null; }

# Which client is in charge: chrony | timesyncd | other (ntpd/ntpsec/...) | none
client() {
    if unit_active chrony || unit_active chronyd; then echo chrony
    elif unit_active systemd-timesyncd; then echo timesyncd
    elif unit_active ntpsec || unit_active ntpd || unit_active ntp; then echo other
    elif command -v chronyd &>/dev/null; then echo chrony-stopped
    elif unit_exists systemd-timesyncd.service; then echo timesyncd-stopped
    else echo none
    fi
}
chrony_unit() { unit_exists chrony.service && echo chrony || echo chronyd; }

# Desired content of the extra-sources file for the active client
extra_content() {
    case "$1" in
        chrony*)    for s in $EXTRA; do echo "pool $s iburst maxsources 2"; done ;;
        timesyncd*) printf '[Time]\nFallbackNTP=%s\n' "$EXTRA" ;;
    esac
}
extra_file() { case "$1" in chrony*) echo "$CHRONY_SRC" ;; timesyncd*) echo "$TIMESYNCD_DROPIN" ;; esac; }
extra_ok() {   # true when nothing to add, the client is not ours to configure, or the file is current
    [ -z "$EXTRA" ] && return 0
    local f; f=$(extra_file "$1"); [ -z "$f" ] && return 0
    [ -f "$f" ] && [ "$(cat "$f" 2>/dev/null)" = "$(extra_content "$1")" ]
}

# Current offset from NTP time, for display
offset() {
    if command -v chronyc &>/dev/null; then
        chronyc tracking 2>/dev/null | awk -F': *' '/^System time/ {split($2,a," "); printf "%.1f ms %s", a[1]*1000, a[3]}'
    else
        timedatectl timesync-status 2>/dev/null | awk -F': *' '/Offset/ {print $2}'
    fi
}

CLIENT=$(client)
# Kernel flag, or chrony reporting a selected source (the flag drops briefly when sources are reloaded)
is_synced() {
    [ "$(tdc NTPSynchronized)" = "yes" ] && return 0
    command -v chronyc &>/dev/null && chronyc tracking 2>/dev/null | grep -q '^Leap status *: Normal'
}
SYNCED=no; is_synced && SYNCED=yes
CUR_TZ=$(tdc Timezone)

NEED=()
case "$CLIENT" in
    none)       NEED+=("install chrony (no NTP client present)") ;;
    *-stopped)  NEED+=("enable NTP sync (${CLIENT%-stopped} is installed but not running)") ;;
esac
extra_ok "$CLIENT" || NEED+=("add time sources: $EXTRA")
if [ -n "$WANT_TZ" ] && [ "$CUR_TZ" != "$WANT_TZ" ]; then NEED+=("timezone $CUR_TZ -> $WANT_TZ"); fi

summary() {
    local off; off=$(offset)
    echo "client ${CLIENT}, timezone ${CUR_TZ}${off:+, offset $off}"
}

if [ "$MODE" = "check" ]; then
    RC=0
    for n in "${NEED[@]}"; do echo "  [WARN]  Time: $n — Run: ./scripts/install-timesync.sh"; RC=1; done
    if [ ${#NEED[@]} -eq 0 ] && [ "$SYNCED" != "yes" ]; then
        echo "  [WARN]  Clock is not synchronized yet (client ${CLIENT}) — check network access to NTP (UDP 123): timedatectl status"
        RC=1
    fi
    [ $RC -eq 0 ] && echo "  [OK]    Clock synchronized ($(summary))"
    exit $RC
fi

if [ ${#NEED[@]} -eq 0 ]; then
    if [ "$SYNCED" = "yes" ]; then
        echo "  Time sync already set up ($(summary))"; exit 0
    fi
    echo "  [WARN]  NTP client is running but the clock is not synchronized yet ($(summary))"
    echo "          Check network access to NTP servers (UDP 123), or set NTP_EXTRA_SERVERS in config/machine.conf"
    exit 1
fi

if [ "$MODE" = "dry" ]; then
    for n in "${NEED[@]}"; do echo "  [DRY]   would $n"; done
    exit 0
fi

if [ -n "$WANT_TZ" ] && ! timedatectl list-timezones 2>/dev/null | grep -qx "$WANT_TZ"; then
    echo "  [WARN]  Unknown timezone '$WANT_TZ' (see: timedatectl list-timezones) — timezone left as $CUR_TZ"
    WANT_TZ=""
fi

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"
RC=0

# 1. NTP client
if [ "$CLIENT" = "none" ]; then
    echo "  Installing chrony"
    if command -v apt-get &>/dev/null; then
        $SUDO apt-get install -y chrony || { $SUDO apt-get update && $SUDO apt-get install -y chrony; } || RC=1
    elif command -v dnf &>/dev/null; then
        $SUDO dnf install -y chrony || RC=1
    else
        echo "  [WARN]  No supported package manager — install chrony manually"; RC=1
    fi
    command -v chronyd &>/dev/null && CLIENT="chrony-stopped"
fi
case "$CLIENT" in
    chrony-stopped)    echo "  Enabling chrony"; $SUDO systemctl enable --now "$(chrony_unit)" || RC=1; CLIENT="chrony" ;;
    timesyncd-stopped) echo "  Enabling systemd-timesyncd"; $SUDO timedatectl set-ntp true || RC=1; CLIENT="timesyncd" ;;
esac

# 2. Extra sources
if ! extra_ok "$CLIENT"; then
    f=$(extra_file "$CLIENT")
    echo "  Adding time sources ($EXTRA) -> $f"
    $SUDO mkdir -p "$(dirname "$f")"
    if extra_content "$CLIENT" | $SUDO tee "$f" >/dev/null; then
        case "$CLIENT" in
            chrony)    $SUDO chronyc reload sources >/dev/null 2>&1 || $SUDO systemctl restart "$(chrony_unit)" || RC=1 ;;
            timesyncd) $SUDO systemctl restart systemd-timesyncd || RC=1 ;;
        esac
    else
        RC=1
    fi
fi

# 3. Timezone
if [ -n "$WANT_TZ" ] && [ "$CUR_TZ" != "$WANT_TZ" ]; then
    echo "  Setting timezone: $CUR_TZ -> $WANT_TZ"
    $SUDO timedatectl set-timezone "$WANT_TZ" || RC=1
    CUR_TZ=$(tdc Timezone)
fi

# Give a freshly started client a moment to get its first sample
for _ in 1 2 3 4 5 6 7 8 9 10; do
    is_synced && break
    sleep 2
done
if is_synced; then
    echo "  [OK]    Clock synchronized ($(summary)) — now: $(date '+%Y-%m-%d %H:%M:%S %Z')"
else
    echo "  [WARN]  Not synchronized yet ($(summary)) — it may take a few minutes; check: timedatectl status"
    RC=1
fi
exit $RC
