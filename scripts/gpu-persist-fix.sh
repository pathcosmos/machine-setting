#!/usr/bin/env bash
# gpu-persist-fix.sh — Permanent GPU stability fixes for RTX 5060 Ti + Z390
# Prevents Xid 79 "GPU has fallen off the bus" caused by PCIe power management
#
# Usage: sudo ./scripts/gpu-persist-fix.sh
#        sudo ./scripts/gpu-persist-fix.sh --dry-run   # Preview changes only
#        sudo ./scripts/gpu-persist-fix.sh --revert     # Undo all changes
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

DRY_RUN=false
REVERT=false
CHECK=false
CHANGES_MADE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --revert) REVERT=true; shift ;;
        --check) CHECK=true; shift ;;
        --help|-h)
            echo "Usage: sudo $0 [--dry-run|--revert|--check]"
            echo "  (no args)    Apply permanent GPU stability fixes"
            echo "  --dry-run    Preview changes without applying"
            echo "  --revert     Undo all changes made by this script"
            echo "  --check      Check status of all fixes (no changes, no sudo needed)"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ "$CHECK" = false ] && [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}ERROR: Must run as root (sudo)${NC}"
    exit 1
fi

# Validate dependencies (only for apply/revert modes)
if [ "$CHECK" = false ]; then
    for cmd in update-grub udevadm systemctl; do
        if ! command -v "$cmd" &>/dev/null; then
            echo -e "${RED}ERROR: '$cmd' not found. Install it first.${NC}"
            exit 1
        fi
    done
fi

log_action() { echo -e "${CYAN}[ACTION]${NC} $1"; }
log_ok()     { echo -e "${GREEN}[  OK  ]${NC} $1"; }
log_skip()   { echo -e "${YELLOW}[ SKIP ]${NC} $1"; }
log_dry()    { echo -e "${YELLOW}[ DRY  ]${NC} $1"; }

backup_file() {
    local f="$1"
    if [ -f "$f" ] && [ ! -f "${f}.gpu-persist-fix.bak" ]; then
        cp "$f" "${f}.gpu-persist-fix.bak"
    fi
}

# ============================================================
# 1. GRUB: Disable PCIe ASPM & GPU dynamic power management
# ============================================================
GRUB_FILE="/etc/default/grub"
GRUB_PARAMS="pcie_aspm=off pcie_port_pm=off nvidia.NVreg_DynamicPowerManagement=0x00"

fix_grub() {
    log_action "GRUB: Adding PCIe/NVIDIA kernel parameters"

    if ! [ -f "$GRUB_FILE" ]; then
        echo -e "${RED}ERROR: $GRUB_FILE not found${NC}"; return 1
    fi

    local current
    current=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" | sed 's/^GRUB_CMDLINE_LINUX_DEFAULT="//' | sed 's/"$//')

    local need_update=false
    for param in $GRUB_PARAMS; do
        if ! echo "$current" | grep -q "$param"; then
            need_update=true
            break
        fi
    done

    if [ "$need_update" = false ]; then
        log_skip "GRUB already has all required parameters"
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        log_dry "Would add to GRUB: $GRUB_PARAMS"
        return 0
    fi

    backup_file "$GRUB_FILE"

    # Build new value: existing + new params (deduped)
    local new_val="$current"
    for param in $GRUB_PARAMS; do
        if ! echo "$new_val" | grep -q "$param"; then
            new_val="$new_val $param"
        fi
    done
    new_val=$(echo "$new_val" | sed 's/^ *//')

    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$new_val\"|" "$GRUB_FILE"
    update-grub 2>&1 | tail -3
    log_ok "GRUB updated: $new_val"
    ((CHANGES_MADE++)) || true
}

revert_grub() {
    log_action "GRUB: Reverting kernel parameters"
    if [ -f "${GRUB_FILE}.gpu-persist-fix.bak" ]; then
        cp "${GRUB_FILE}.gpu-persist-fix.bak" "$GRUB_FILE"
        update-grub 2>&1 | tail -3
        rm "${GRUB_FILE}.gpu-persist-fix.bak"
        log_ok "GRUB reverted from backup"
    else
        log_skip "No GRUB backup found"
    fi
}

# ============================================================
# 2. udev rule: Force PCIe power control to "on" for NVIDIA GPU
# ============================================================
UDEV_FILE="/etc/udev/rules.d/80-nvidia-pcie-power.rules"

fix_udev() {
    log_action "udev: Setting GPU PCIe power control to 'on'"

    if [ "$DRY_RUN" = true ]; then
        log_dry "Would create/update $UDEV_FILE"
        return 0
    fi

    # Backup existing rules
    if [ -f "$UDEV_FILE" ]; then
        cp "$UDEV_FILE" "${UDEV_FILE}.gpu-persist-fix.bak"
    fi

    cat > "$UDEV_FILE" <<'RULE'
# Prevent GPU PCIe power management from putting the GPU to sleep
# Fixes Xid 79 "GPU has fallen off the bus" on RTX 5060 Ti + Z390
# Trigger on both add and driver bind events
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030000", ATTR{power/control}="on"
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030200", ATTR{power/control}="on"
ACTION=="bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030000", ATTR{power/control}="on"
ACTION=="bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030200", ATTR{power/control}="on"
RULE
    udevadm control --reload-rules
    log_ok "udev rule created: $UDEV_FILE"
    ((CHANGES_MADE++)) || true
}

revert_udev() {
    log_action "udev: Removing GPU PCIe power rule"
    if [ -f "$UDEV_FILE" ]; then
        rm "$UDEV_FILE"
        udevadm control --reload-rules
        log_ok "udev rule removed"
    else
        log_skip "No udev rule to remove"
    fi
}

# ============================================================
# 3. modprobe: Disable DynamicPowerManagement
# ============================================================
MODPROBE_FILE="/etc/modprobe.d/nvidia-gpu-persist.conf"

fix_modprobe() {
    log_action "modprobe: Disabling NVIDIA DynamicPowerManagement"

    if [ -f "$MODPROBE_FILE" ]; then
        log_skip "modprobe conf already exists: $MODPROBE_FILE"
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        log_dry "Would create $MODPROBE_FILE"
        return 0
    fi

    cat > "$MODPROBE_FILE" <<'CONF'
# Disable GPU dynamic power management to prevent Xid 79
# RTX 5060 Ti + Z390 — GPU falls off bus when power-cycled
options nvidia NVreg_DynamicPowerManagement=0x00
options nvidia NVreg_EnableS0ixPowerManagement=0
CONF
    log_ok "modprobe conf created: $MODPROBE_FILE"
    ((CHANGES_MADE++)) || true
}

revert_modprobe() {
    log_action "modprobe: Removing GPU power management override"
    if [ -f "$MODPROBE_FILE" ]; then
        rm "$MODPROBE_FILE"
        log_ok "modprobe conf removed"
    else
        log_skip "No modprobe conf to remove"
    fi
}

# ============================================================
# 4. nvidia-persistenced: Ensure enabled
# ============================================================
fix_persistenced() {
    log_action "nvidia-persistenced: Ensuring service is enabled"

    if systemctl is-enabled nvidia-persistenced &>/dev/null; then
        log_skip "nvidia-persistenced already enabled"
    else
        if [ "$DRY_RUN" = true ]; then
            log_dry "Would enable nvidia-persistenced"
            return 0
        fi
        systemctl enable nvidia-persistenced
        log_ok "nvidia-persistenced enabled"
        ((CHANGES_MADE++)) || true
    fi
}

revert_persistenced() {
    log_skip "nvidia-persistenced: Not reverting (safe to keep enabled)"
}

# ============================================================
# 5. GPU watchdog systemd service
# ============================================================
WATCHDOG_SERVICE="/etc/systemd/system/nvidia-gpu-watchdog.service"
WATCHDOG_TIMER="/etc/systemd/system/nvidia-gpu-watchdog.timer"

fix_watchdog() {
    log_action "GPU watchdog: Creating systemd timer service"

    if [ -f "$WATCHDOG_SERVICE" ] && [ -f "$WATCHDOG_TIMER" ]; then
        log_skip "GPU watchdog already exists"
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        log_dry "Would create GPU watchdog service + timer"
        return 0
    fi

    cat > "$WATCHDOG_SERVICE" <<'SERVICE'
[Unit]
Description=NVIDIA GPU Health Watchdog
After=nvidia-persistenced.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c '\
    if ! nvidia-smi &>/dev/null; then \
        echo "GPU WATCHDOG: nvidia-smi failed, attempting recovery..." | systemd-cat -p err -t nvidia-watchdog; \
        rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia 2>/dev/null || true; \
        sleep 2; \
        modprobe nvidia; \
        modprobe nvidia_uvm; \
        modprobe nvidia_drm; \
        if nvidia-smi &>/dev/null; then \
            echo "GPU WATCHDOG: Recovery successful" | systemd-cat -p info -t nvidia-watchdog; \
        else \
            echo "GPU WATCHDOG: Recovery FAILED — reboot required" | systemd-cat -p crit -t nvidia-watchdog; \
        fi; \
    fi'
SERVICE

    cat > "$WATCHDOG_TIMER" <<'TIMER'
[Unit]
Description=Run NVIDIA GPU Health Watchdog every 5 minutes

[Timer]
OnBootSec=60
OnUnitActiveSec=300
AccuracySec=30

[Install]
WantedBy=timers.target
TIMER

    systemctl daemon-reload
    systemctl enable --now nvidia-gpu-watchdog.timer
    log_ok "GPU watchdog installed and started (checks every 5 min)"
    ((CHANGES_MADE++)) || true
}

revert_watchdog() {
    log_action "GPU watchdog: Removing service"
    if [ -f "$WATCHDOG_TIMER" ]; then
        systemctl disable --now nvidia-gpu-watchdog.timer 2>/dev/null || true
    fi
    rm -f "$WATCHDOG_SERVICE" "$WATCHDOG_TIMER"
    systemctl daemon-reload
    log_ok "GPU watchdog removed"
}

# ============================================================
# 6. Boot-time PCIe power control enforcement
# ============================================================
PCIE_POWER_SERVICE="/etc/systemd/system/nvidia-pcie-power-fix.service"

fix_pcie_power_service() {
    log_action "PCIe power fix: Creating boot-time enforcement service"

    if [ -f "$PCIE_POWER_SERVICE" ]; then
        log_skip "PCIe power fix service already exists"
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        log_dry "Would create $PCIE_POWER_SERVICE"
        return 0
    fi

    cat > "$PCIE_POWER_SERVICE" <<'SERVICE'
[Unit]
Description=Force NVIDIA GPU PCIe power control to on
After=nvidia-persistenced.service
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'for d in /sys/bus/pci/devices/*/; do if [ -f "$d/vendor" ] && [ "$(cat "$d/vendor")" = "0x10de" ]; then c=$(cat "$d/class"); if [[ "$c" == 0x0300* ]] || [[ "$c" == 0x0302* ]]; then echo on > "$d/power/control" 2>/dev/null && echo "Set power/control=on for $(basename $d)"; fi; fi; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE

    systemctl daemon-reload
    systemctl enable nvidia-pcie-power-fix.service
    log_ok "PCIe power fix service created and enabled"
    ((CHANGES_MADE++)) || true
}

revert_pcie_power_service() {
    log_action "PCIe power fix: Removing service"
    if [ -f "$PCIE_POWER_SERVICE" ]; then
        systemctl disable nvidia-pcie-power-fix.service 2>/dev/null || true
        rm -f "$PCIE_POWER_SERVICE"
        systemctl daemon-reload
        log_ok "PCIe power fix service removed"
    else
        log_skip "No PCIe power fix service to remove"
    fi
}

# ============================================================
# Check functions (for --check mode)
# ============================================================
check_grub_status() {
    if [ ! -f "$GRUB_FILE" ]; then
        echo -e "${YELLOW}GRUB:SKIP${NC} — $GRUB_FILE not found (cloud/container?)"
        return 1
    fi
    local grub_line
    grub_line=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" 2>/dev/null || true)
    local missing=""
    for param in $GRUB_PARAMS; do
        if ! echo "$grub_line" | grep -q "$param"; then
            missing="${missing:+$missing, }$param"
        fi
    done
    if [ -z "$missing" ]; then
        echo -e "${GREEN}GRUB:OK${NC} — all kernel parameters present"
        return 0
    else
        echo -e "${RED}GRUB:FAIL${NC} — missing: $missing"
        return 1
    fi
}

check_udev_status() {
    if [ ! -f "$UDEV_FILE" ]; then
        echo -e "${RED}UDEV:FAIL${NC} — rule file not found"
        return 1
    fi
    local add_count bind_count
    add_count=$(grep -c 'ACTION=="add"' "$UDEV_FILE" 2>/dev/null || echo 0)
    bind_count=$(grep -c 'ACTION=="bind"' "$UDEV_FILE" 2>/dev/null || echo 0)
    if [ "$add_count" -ge 2 ] && [ "$bind_count" -ge 2 ]; then
        echo -e "${GREEN}UDEV:OK${NC} — add($add_count) + bind($bind_count) rules"
        return 0
    elif [ "$add_count" -ge 2 ]; then
        echo -e "${YELLOW}UDEV:WARN${NC} — missing bind rules (only add rules present)"
        return 1
    else
        echo -e "${RED}UDEV:FAIL${NC} — incomplete rules (add=$add_count, bind=$bind_count)"
        return 1
    fi
}

check_modprobe_status() {
    if [ -f "$MODPROBE_FILE" ]; then
        echo -e "${GREEN}MODPROBE:OK${NC} — config exists"
        return 0
    else
        echo -e "${RED}MODPROBE:FAIL${NC} — config not found"
        return 1
    fi
}

check_persistenced_status() {
    if systemctl is-enabled nvidia-persistenced &>/dev/null; then
        local active=""
        if systemctl is-active nvidia-persistenced &>/dev/null; then
            active=" + active"
        fi
        echo -e "${GREEN}PERSISTENCED:OK${NC} — enabled${active}"
        return 0
    else
        echo -e "${RED}PERSISTENCED:FAIL${NC} — not enabled"
        return 1
    fi
}

check_watchdog_status() {
    if [ ! -f "$WATCHDOG_SERVICE" ] || [ ! -f "$WATCHDOG_TIMER" ]; then
        echo -e "${RED}WATCHDOG:FAIL${NC} — service/timer not installed"
        return 1
    fi
    if systemctl is-active nvidia-gpu-watchdog.timer &>/dev/null; then
        echo -e "${GREEN}WATCHDOG:OK${NC} — timer active"
        return 0
    else
        echo -e "${YELLOW}WATCHDOG:WARN${NC} — installed but timer not active"
        return 1
    fi
}

check_pcie_power_status() {
    local fail_list="" ok_count=0
    for d in /sys/bus/pci/devices/*/; do
        if [ -f "$d/vendor" ] && [ "$(cat "$d/vendor" 2>/dev/null)" = "0x10de" ]; then
            local c
            c=$(cat "$d/class" 2>/dev/null || true)
            if [[ "$c" == 0x0300* ]] || [[ "$c" == 0x0302* ]]; then
                local dev_id pwr
                dev_id=$(basename "$d")
                pwr=$(cat "$d/power/control" 2>/dev/null || echo "unknown")
                if [ "$pwr" = "on" ]; then
                    ((ok_count++))
                elif [ "$pwr" = "unknown" ]; then
                    : # sysfs not readable — skip this device
                else
                    fail_list="${fail_list:+$fail_list, }${dev_id}=${pwr}"
                fi
            fi
        fi
    done

    if [ -n "$fail_list" ]; then
        echo -e "${RED}PCIE_POWER:FAIL${NC} — $fail_list"
        return 1
    elif [ "$ok_count" -gt 0 ]; then
        echo -e "${GREEN}PCIE_POWER:OK${NC} — ${ok_count} GPU(s) power/control=on"
        return 0
    else
        echo -e "${YELLOW}PCIE_POWER:SKIP${NC} — no NVIDIA GPU found in sysfs"
        return 0
    fi
}

# ============================================================
# Main
# ============================================================
if [ "$CHECK" = true ]; then
    echo ""
    echo "=========================================="
    echo "  GPU Persist Fix — STATUS CHECK"
    echo "=========================================="
    echo ""
    FAIL_COUNT=0
    check_grub_status       || ((FAIL_COUNT++)) || true
    check_udev_status       || ((FAIL_COUNT++)) || true
    check_modprobe_status   || ((FAIL_COUNT++)) || true
    check_persistenced_status || ((FAIL_COUNT++)) || true
    check_watchdog_status   || ((FAIL_COUNT++)) || true
    check_pcie_power_status || ((FAIL_COUNT++)) || true
    echo ""
    if [ "$FAIL_COUNT" -eq 0 ]; then
        echo -e "${GREEN}All 6 fixes in place. No issues found.${NC}"
    else
        echo -e "${YELLOW}${FAIL_COUNT}/6 issue(s) found. Run: sudo ./scripts/gpu-persist-fix.sh${NC}"
    fi
    echo ""
    exit "$FAIL_COUNT"
fi

echo ""
echo "=========================================="
if [ "$REVERT" = true ]; then
    echo "  GPU Persist Fix — REVERT MODE"
elif [ "$DRY_RUN" = true ]; then
    echo "  GPU Persist Fix — DRY RUN"
else
    echo "  GPU Persist Fix — APPLYING"
fi
echo "=========================================="
echo ""

if [ "$REVERT" = true ]; then
    revert_grub
    revert_udev
    revert_modprobe
    revert_persistenced
    revert_watchdog
    revert_pcie_power_service
    echo ""
    echo -e "${GREEN}All changes reverted. Reboot to take full effect.${NC}"
else
    fix_grub
    fix_udev
    fix_modprobe
    fix_persistenced
    fix_watchdog
    fix_pcie_power_service

    # Apply immediate fixes (no reboot needed for these)
    if [ "$DRY_RUN" = false ]; then
        echo -e "${CYAN}[ACTION]${NC} Applying PCIe power/control=on immediately..."
        local immediate_count=0
        for d in /sys/bus/pci/devices/*/; do
            if [ -f "$d/vendor" ] && [ "$(cat "$d/vendor" 2>/dev/null)" = "0x10de" ]; then
                local c
                c=$(cat "$d/class" 2>/dev/null || true)
                if [[ "$c" == 0x0300* ]] || [[ "$c" == 0x0302* ]]; then
                    if echo on > "$d/power/control" 2>/dev/null; then
                        ((immediate_count++))
                    fi
                fi
            fi
        done
        # Reload udev rules and trigger for NVIDIA devices
        udevadm trigger --subsystem-match=pci --attr-match=vendor=0x10de 2>/dev/null || true
        echo -e "${GREEN}[  OK  ]${NC} ${immediate_count} GPU(s) PCIe power/control set to 'on'"
    fi

    echo ""
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}DRY RUN complete. No changes were made.${NC}"
    elif [ "$CHANGES_MADE" -gt 0 ]; then
        echo -e "${GREEN}$CHANGES_MADE fix(es) applied. PCIe power fixed immediately; full effect after reboot.${NC}"
        echo -e "${CYAN}Run: sudo reboot${NC}"
    else
        echo -e "${GREEN}All fixes already in place. No changes needed.${NC}"
    fi
fi
echo ""
