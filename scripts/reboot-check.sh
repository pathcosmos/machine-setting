#!/usr/bin/env bash
# reboot-check.sh — Is a reboot (or re-login) pending, and why?
#
# Looks at the machine's state instead of trusting what installers reported, so it is correct no
# matter which script made the change or how many times setup ran.
#
# Usage:
#   ./scripts/reboot-check.sh           # list reasons; exit 0 = nothing pending, 10 = reboot needed, 11 = only re-login needed
#   ./scripts/reboot-check.sh --quiet   # exit code only
set -uo pipefail

QUIET=false
[ "${1:-}" = "--quiet" ] && QUIET=true
[ "$(uname -s)" = "Linux" ] || exit 0

REBOOT=(); RELOGIN=()

# 1. NVIDIA driver installed but not the one running
if command -v dpkg-query &>/dev/null || [ -x /usr/bin/nvidia-uninstall ]; then
    installed=""
    for pat in 'nvidia-driver-*' 'linux-modules-nvidia-*'; do
        installed=$(dpkg-query -W -f='${Status} ${Version}\n' "$pat" 2>/dev/null | awk '/^install ok installed/ {print $4; exit}' | sed 's/-.*//')
        [ -n "$installed" ] && break
    done
    [ -x /usr/bin/nvidia-uninstall ] && [ -z "$installed" ] && installed="present"
    if [ -n "$installed" ]; then
        loaded=$(sed -n 's/.*Kernel Module[^0-9]*\([0-9][0-9.]*\).*/\1/p' /proc/driver/nvidia/version 2>/dev/null | head -1)
        if [ -z "$loaded" ]; then
            REBOOT+=("NVIDIA driver is installed but not loaded")
        elif command -v nvidia-smi &>/dev/null && ! nvidia-smi &>/dev/null; then
            REBOOT+=("NVIDIA driver and libraries do not match (loaded module $loaded) — nvidia-smi fails")
        fi
        lsmod 2>/dev/null | grep -q '^nouveau ' && REBOOT+=("nouveau is still loaded (blacklisted, unloads at reboot)")
    fi
fi

# 2. Kernel parameters configured in GRUB but not on the running kernel's command line
GRUB_FILE="${REBOOT_CHECK_GRUB_FILE:-/etc/default/grub}"      # overridable for testing
CMDLINE_FILE="${REBOOT_CHECK_CMDLINE_FILE:-/proc/cmdline}"
if [ -r "$GRUB_FILE" ] && [ -r "$CMDLINE_FILE" ]; then
    want=$(sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/\1/p; s/^GRUB_CMDLINE_LINUX="\(.*\)"/\1/p' "$GRUB_FILE" | tr '\n' ' ')
    missing=""
    for p in $want; do
        case "$p" in quiet|splash|"") continue ;; esac
        grep -qw -- "$p" "$CMDLINE_FILE" || missing="$missing $p"
    done
    [ -n "$missing" ] && REBOOT+=("Kernel parameters not active yet:$missing")
fi

# 3. Distribution says so (new kernel, libc, microcode, ...)
if [ -f /var/run/reboot-required ]; then
    pkgs=$(sort -u /var/run/reboot-required.pkgs 2>/dev/null | head -4 | tr '\n' ' ' | sed 's/ $//')
    REBOOT+=("System packages need a reboot${pkgs:+ ($pkgs)}")
fi

# 4. Newer kernel installed than the one running
if command -v dpkg-query &>/dev/null; then
    newest=$(dpkg-query -W -f='${Status} ${Package}\n' 'linux-image-[0-9]*' 2>/dev/null | awk '/^install ok installed/ {print $4}' | sed 's/linux-image-//' | sort -V | tail -1)
    if [ -n "$newest" ] && [ "$newest" != "$(uname -r)" ] && [ "$(printf '%s\n%s\n' "$newest" "$(uname -r)" | sort -V | tail -1)" = "$newest" ]; then
        REBOOT+=("Kernel $newest is installed, $(uname -r) is running")
    fi
fi

# 5. Group membership that the current login session does not have yet
for g in docker; do
    if id -nG "${USER:-$(id -un)}" 2>/dev/null | tr ' ' '\n' | grep -qx "$g" && ! id -nG | tr ' ' '\n' | grep -qx "$g"; then
        RELOGIN+=("'$g' group is not active in this login session")
    fi
done

if [ "$QUIET" = false ]; then
    for r in "${REBOOT[@]}";  do echo "  [REBOOT]  $r"; done
    for r in "${RELOGIN[@]}"; do echo "  [RELOGIN] $r"; done
    [ ${#REBOOT[@]} -eq 0 ] && [ ${#RELOGIN[@]} -eq 0 ] && echo "  [OK]      No reboot or re-login pending"
fi
[ ${#REBOOT[@]} -gt 0 ] && exit 10
[ ${#RELOGIN[@]} -gt 0 ] && exit 11
exit 0
