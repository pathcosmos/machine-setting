#!/usr/bin/env bash
# gpu-doctor.sh — GPU-specific health diagnostics
# Usage:
#   ./scripts/gpu-doctor.sh              # Full detailed diagnostics
#   ./scripts/gpu-doctor.sh --summary    # One-line summary (for doctor.sh)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# --- Parse arguments ---
MODE="full"  # full | summary
while [[ $# -gt 0 ]]; do
    case "$1" in
        --summary) MODE="summary"; shift ;;
        --help|-h)
            echo "Usage: ./scripts/gpu-doctor.sh [--summary]"
            echo "  (no args)    Full GPU diagnostics with detailed output"
            echo "  --summary    One-line summary for doctor.sh integration"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# --- Pre-check: nvidia-smi must exist ---
if ! command -v nvidia-smi &>/dev/null; then
    if [ "$MODE" = "summary" ]; then
        echo "FAIL nvidia-smi not found (driver not installed)"
        exit 2
    fi
    echo "=== GPU Doctor ==="
    echo "  nvidia-smi not found. NVIDIA driver is not installed."
    echo "  → Run: ./setup.sh --from 2"
    exit 2
fi

# --- Collect GPU info (nvidia-smi with lspci/sysfs fallback) ---
NVIDIA_SMI_EXIT=0
nvidia-smi &>/dev/null || NVIDIA_SMI_EXIT=$?

GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)
DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || true)
BUS_ID=$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader 2>/dev/null | head -1 || true)
GPU_UUID=$(nvidia-smi --query-gpu=uuid --format=csv,noheader 2>/dev/null | head -1 || true)

# Fallback: when nvidia-smi can't communicate, get info from lspci/sysfs
# nvidia-smi may output error text like "No devices were found" instead of empty
if [ "$NVIDIA_SMI_EXIT" -ne 0 ] || [ -z "$GPU_NAME" ] || echo "$GPU_NAME" | grep -qi "no devices\|error\|failed\|unable"; then
    GPU_NAME="" ; DRIVER_VER="" ; BUS_ID="" ; GPU_UUID=""
    if command -v lspci &>/dev/null; then
        LSPCI_GPU_LINE=$(lspci -D 2>/dev/null | grep -i 'nvidia' | grep -iE 'vga|3d|display' | head -1 || true)
        if [ -n "$LSPCI_GPU_LINE" ]; then
            [ -z "$BUS_ID" ] && BUS_ID=$(echo "$LSPCI_GPU_LINE" | awk '{print $1}')
            [ -z "$GPU_NAME" ] && GPU_NAME=$(echo "$LSPCI_GPU_LINE" | sed 's/^[^ ]* [^:]*: //' | sed 's/ (rev .*)$//')
        fi
    fi
    if [ -z "$DRIVER_VER" ] && [ -f /proc/driver/nvidia/version ]; then
        DRIVER_VER=$(grep -oP 'NVRM version: NVIDIA.*\s+\K[0-9]+\.[0-9.]+' /proc/driver/nvidia/version 2>/dev/null || true)
    fi
fi

# --- Status tracking ---
ISSUE_COUNT=0
WARN_COUNT=0
ACTIONS=()

# --- Output helpers ---
section_header() { echo ""; echo "--- [$1] $2 ---"; }
item_ok()   { echo "  $1: $2 — OK"; }
item_warn() { echo "  $1: $2"; WARN_COUNT=$((WARN_COUNT + 1)); }
item_fail() { echo "  $1: $2"; ISSUE_COUNT=$((ISSUE_COUNT + 1)); }
add_action() {
    local priority="$1"; shift
    ACTIONS+=("[$priority] $*")
}

# --- Kernel log access helper ---
KLOG_SOURCE="unavailable"
get_kernel_log() {
    local since="${1:-24 hours ago}"
    KLOG_SOURCE="unavailable"

    local dmesg_out
    dmesg_out=$(dmesg --time-format iso 2>/dev/null || true)
    if [ -n "$dmesg_out" ]; then
        KLOG_SOURCE="dmesg"
        echo "$dmesg_out"
        return
    fi

    local journal_out
    journal_out=$(journalctl -k --since "$since" --no-pager 2>/dev/null || true)
    if [ -n "$journal_out" ]; then
        KLOG_SOURCE="journalctl"
        echo "$journal_out"
        return
    fi
}

check_driver_communication() {
    section_header "1/6" "Driver Communication"

    if [ "$NVIDIA_SMI_EXIT" -ne 0 ]; then
        item_fail "nvidia-smi" "exit code $NVIDIA_SMI_EXIT (cannot communicate with GPU)"
        add_action "CRITICAL" "nvidia-smi가 GPU와 통신 불가 (exit $NVIDIA_SMI_EXIT)\n       → 리부트 필요. 리부트 후에도 실패 시: sudo modprobe nvidia"
        return
    fi
    item_ok "nvidia-smi" "exit 0"

    if [ -n "$DRIVER_VER" ]; then
        local mod_type="unknown"
        if lsmod 2>/dev/null | grep "^nvidia[[:space:]]" &>/dev/null; then
            local license
            license=$(modinfo nvidia 2>/dev/null | grep -i "^license:" | sed 's/^license:[[:space:]]*//' || true)
            if [[ "$license" == *"MIT"* ]] || [[ "$license" == *"GPL"* ]]; then
                mod_type="open"
            elif [ -n "$license" ]; then
                mod_type="proprietary"
            fi
        fi
        item_ok "Driver" "$DRIVER_VER ($mod_type kernel module)"
    else
        item_fail "Driver" "version unknown"
        add_action "WARNING" "드라이버 버전 확인 불가\n       → 드라이버 재설치: ./setup.sh --from 2"
    fi

    [ -n "$BUS_ID" ] && item_ok "Bus ID" "$BUS_ID"
    [ -n "$GPU_UUID" ] && item_ok "UUID" "$GPU_UUID"
}

check_xid_errors() {
    section_header "2/6" "Xid Errors (last 24h)"

    local klog
    klog=$(get_kernel_log "24 hours ago")

    if [ "$KLOG_SOURCE" = "unavailable" ]; then
        item_warn "⚠ Kernel log" "접근 불가 — Xid 체크 생략"
        echo "    → sudo sysctl kernel.dmesg_restrict=0  (임시 해제)"
        echo "    → sudo usermod -aG adm \$USER           (영구 해제, 재로그인 필요)"
        add_action "INFO" "Xid 에러 점검 불가 (커널 로그 접근 권한 없음)\n       → sudo usermod -aG adm \$USER 후 재로그인"
        return
    fi

    local xid_lines
    xid_lines=$(echo "$klog" | grep -i "NVRM.*Xid" || true)

    if [ -z "$xid_lines" ]; then
        item_ok "Xid errors" "none found (source: $KLOG_SOURCE)"
        return
    fi

    local xid_count
    xid_count=$(echo "$xid_lines" | wc -l | tr -d ' ')
    echo "  Found: $xid_count error(s) (source: $KLOG_SOURCE)"
    echo ""

    local xid_numbers
    xid_numbers=$(echo "$xid_lines" | grep -oP 'Xid.*?:\s*\K[0-9]+' | sort | uniq -c | sort -rn)

    while read -r count xid; do
        [ -z "$xid" ] && continue
        local severity="INFO"
        local desc=""
        local action=""

        case "$xid" in
            79)  severity="CRITICAL"; desc="GPU has fallen off the bus"
                 action="리부트 필요. 재발 시: BIOS에서 PCIe Gen3 다운그레이드 + PSU 확인 (180W TDP)" ;;
            154) severity="CRITICAL"; desc="Recovery action: Node Reboot Required"
                 action="즉시 리부트. Xid 79와 함께 발생하면 PCI 버스 이탈 확인" ;;
            48)  severity="CRITICAL"; desc="Double Bit ECC Error"
                 action="GPU 메모리 손상 가능. 재발 시 RMA 검토" ;;
            13)  severity="WARNING"; desc="Graphics Engine Exception"
                 action="드라이버 업그레이드 시도: sudo apt install nvidia-driver-5XX" ;;
            31)  severity="WARNING"; desc="GPU Setup Failure"
                 action="드라이버 재설치 또는 GPU 슬롯 재장착" ;;
            45)  severity="WARNING"; desc="Preemptive Cleanup"
                 action="일반적으로 무해. 반복 시 드라이버 업그레이드" ;;
            8)   severity="INFO"; desc="Dropped interrupt"
                 action="MSI 인터럽트 문제 가능. 보통 무해" ;;
            32)  severity="INFO"; desc="Invalid or legacy Xid"
                 action="무시 가능" ;;
            *)   severity="WARNING"; desc="Unknown Xid"
                 action="NVIDIA 문서 참조: https://docs.nvidia.com/deploy/xid-errors/" ;;
        esac

        echo "  [$severity] Xid $xid — $desc (${count}회)"
        if [ "$severity" = "CRITICAL" ] || [ "$severity" = "WARNING" ]; then
            add_action "$severity" "Xid $xid ($desc)\n       → $action"
        fi
    done <<< "$xid_numbers"
}

check_pci_status() {
    section_header "3/6" "PCI Bus Status"

    if ! command -v lspci &>/dev/null; then
        item_warn "lspci" "not found (pciutils 패키지 필요)"
        add_action "INFO" "PCI 진단 불가 — sudo apt install pciutils"
        return
    fi

    # If BUS_ID is empty (nvidia-smi failed), discover from lspci
    if [ -z "$BUS_ID" ]; then
        BUS_ID=$(lspci -D 2>/dev/null | grep -i 'nvidia' | grep -iE 'vga|3d|display' | head -1 | awk '{print $1}' || true)
    fi

    if [ -z "$BUS_ID" ]; then
        item_fail "PCI device" "NVIDIA GPU not found via lspci"
        add_action "CRITICAL" "GPU가 PCI 버스에서 완전히 사라짐 — 물리적 점검 필요"
        return
    fi

    local pci_slot
    pci_slot=$(echo "$BUS_ID" | sed 's/^0000//' | tr '[:upper:]' '[:lower:]')

    local lspci_out
    lspci_out=$(lspci -v -s "$pci_slot" 2>/dev/null || true)
    if [ -z "$lspci_out" ]; then
        item_warn "PCI device" "not found at $pci_slot"
        return
    fi

    if echo "$lspci_out" | grep -E "^[[:space:]]+Memory at" | grep -q "\[disabled\]"; then
        item_fail "BAR Memory" "DISABLED"
        add_action "CRITICAL" "PCI BAR memory가 비활성화 상태 — GPU가 버스에서 이탈\n       → 리부트 필요. 재발 시 PCIe 슬롯 재장착"
    else
        item_ok "BAR Memory" "enabled"
    fi

    local lspci_vv
    lspci_vv=$(lspci -vv -s "$pci_slot" 2>/dev/null || true)

    local link_speed_cur link_speed_max link_width_cur link_width_max
    link_speed_cur=$(echo "$lspci_vv" | grep -oP 'LnkSta:.*Speed \K[0-9.]+ GT/s' | head -1 || true)
    link_speed_max=$(echo "$lspci_vv" | grep -oP 'LnkCap:.*Speed \K[0-9.]+ GT/s' | head -1 || true)
    link_width_cur=$(echo "$lspci_vv" | grep -oP 'LnkSta:.*Width x\K[0-9]+' | head -1 || true)
    link_width_max=$(echo "$lspci_vv" | grep -oP 'LnkCap:.*Width x\K[0-9]+' | head -1 || true)

    if [ -n "$link_speed_cur" ] && [ -n "$link_speed_max" ]; then
        if [ "$link_speed_cur" = "$link_speed_max" ]; then
            item_ok "Link Speed" "${link_speed_cur} (max: ${link_speed_max})"
        else
            item_warn "⚠ Link Speed" "${link_speed_cur} (max: ${link_speed_max}) — DOWNGRADED"
            add_action "WARNING" "PCIe 속도 다운그레이드: ${link_speed_cur} / ${link_speed_max}\n       → GPU 슬롯 재장착, 다른 슬롯 시도\n       → BIOS에서 PCIe Gen 설정 확인"
        fi
    fi

    if [ -n "$link_width_cur" ] && [ -n "$link_width_max" ]; then
        if [ "$link_width_cur" = "$link_width_max" ]; then
            item_ok "Link Width" "x${link_width_cur} (max: x${link_width_max})"
        else
            item_warn "⚠ Link Width" "x${link_width_cur} (max: x${link_width_max}) — DOWNGRADED"
            add_action "WARNING" "PCIe 폭 다운그레이드: x${link_width_cur} / x${link_width_max}\n       → 물리적 접촉 불량 가능. GPU 재장착"
        fi
    fi
}

check_thermal_power() {
    section_header "4/6" "Thermal & Power"

    if [ "$NVIDIA_SMI_EXIT" -ne 0 ]; then
        item_fail "Status" "nvidia-smi 통신 불가 — 측정 불가"
        return
    fi

    local gpu_query
    gpu_query=$(nvidia-smi --query-gpu=temperature.gpu,power.draw,power.limit,power.max_limit,fan.speed,clocks_event_reasons.active --format=csv,noheader,nounits 2>/dev/null | head -1 || true)

    if [ -n "$gpu_query" ]; then
        IFS=',' read -r temp power_draw power_limit power_max fan_speed throttle_raw <<< "$gpu_query"
        temp=$(echo "$temp" | tr -d ' ')
        power_draw=$(echo "$power_draw" | tr -d ' ')
        power_limit=$(echo "$power_limit" | tr -d ' ')
        power_max=$(echo "$power_max" | tr -d ' ')
        fan_speed=$(echo "$fan_speed" | tr -d ' ')

        if [ -n "$temp" ] && [ "$temp" != "[N/A]" ]; then
            if [ "$temp" -ge 90 ] 2>/dev/null; then
                item_fail "Temperature" "${temp}°C — 과열!"
                add_action "CRITICAL" "GPU 온도 ${temp}°C (위험)\n       → 케이스 에어플로우 확인, 서멀 페이스트 교체 검토\n       → fan curve 설정 확인"
            elif [ "$temp" -ge 80 ] 2>/dev/null; then
                item_warn "⚠ Temperature" "${temp}°C — 높음"
                add_action "WARNING" "GPU 온도 ${temp}°C (높음)\n       → 케이스 에어플로우 및 쿨링 확인"
            else
                item_ok "Temperature" "${temp}°C"
            fi
        fi

        if [ -n "$power_draw" ] && [ "$power_draw" != "[N/A]" ] && [ -n "$power_limit" ] && [ "$power_limit" != "[N/A]" ]; then
            local power_pct
            power_pct=$(awk "BEGIN {printf \"%.0f\", ($power_draw / $power_limit) * 100}" 2>/dev/null || echo "0")
            if [ "$power_pct" -ge 95 ] 2>/dev/null; then
                item_warn "⚠ Power" "${power_draw}W / ${power_limit}W limit (${power_pct}%) — 한도 근접"
                add_action "WARNING" "전력 사용 ${power_draw}W / ${power_limit}W (${power_pct}%)\n       → PSU 용량 확인. RTX 5060 Ti: 최소 550W PSU 권장"
            else
                item_ok "Power" "${power_draw}W / ${power_limit}W limit (${power_pct}%)"
            fi
        fi

        if [ -n "$fan_speed" ] && [ "$fan_speed" != "[N/A]" ]; then
            item_ok "Fan" "${fan_speed}%"
        fi

        local throttle_reasons
        throttle_reasons=$(nvidia-smi --query-gpu=clocks_event_reasons.hw_thermal_slowdown,clocks_event_reasons.hw_power_brake_slowdown,clocks_event_reasons.sw_thermal_slowdown,clocks_event_reasons.sw_power_cap --format=csv,noheader 2>/dev/null | head -1 || true)
        if echo "$throttle_reasons" | grep -qi "active" && ! echo "$throttle_reasons" | grep -qiP "^(Not Active[, ]*)+$"; then
            item_warn "⚠ Throttle" "감지됨 — $throttle_reasons"
            add_action "WARNING" "GPU throttling 감지\n       → 온도/전력 원인 확인. 지속 시 워크로드 경감 또는 쿨링 보강"
        else
            item_ok "Throttle" "none"
        fi
    else
        item_warn "Thermal/Power" "쿼리 실패"
    fi
}

check_driver_compat() {
    section_header "5/6" "Driver Compatibility"

    local arch="Unknown"
    local min_driver="0"

    if [ -n "$GPU_NAME" ]; then
        case "$GPU_NAME" in
            *50[5-9]0*|*5090*|*B100*|*B200*|*Blackwell*)
                arch="Blackwell"; min_driver="560" ;;
            *40[5-9]0*|*4090*|*L4*|*L40*|*Ada*|*RTX?6000?Ada*)
                arch="Ada Lovelace"; min_driver="525" ;;
            *H100*|*H200*|*H800*|*Hopper*)
                arch="Hopper"; min_driver="525" ;;
            *30[5-9]0*|*3090*|*A100*|*A6000*|*A40*|*Ampere*)
                arch="Ampere"; min_driver="470" ;;
            *20[5-9]0*|*2080*|*T4*|*Turing*)
                arch="Turing"; min_driver="418" ;;
            *)  arch="Unknown" ;;
        esac
    fi

    item_ok "Architecture" "$arch (minimum driver: $min_driver)"

    if [ -n "$DRIVER_VER" ] && [ "$min_driver" != "0" ]; then
        local driver_major
        driver_major=$(echo "$DRIVER_VER" | cut -d. -f1)
        if [ "$driver_major" -ge "$min_driver" ] 2>/dev/null; then
            item_ok "Driver" "$DRIVER_VER (>= $min_driver)"
        else
            item_fail "Driver" "$DRIVER_VER (< $min_driver 필요!)"
            add_action "CRITICAL" "드라이버 $DRIVER_VER이 $arch GPU에 너무 낮음 (최소 $min_driver)\n       → sudo apt install nvidia-driver-${min_driver}"
        fi
    fi

    local kernel_ver
    kernel_ver=$(uname -r)
    item_ok "Kernel" "$kernel_ver"

    if command -v dkms &>/dev/null; then
        local dkms_status
        dkms_status=$(dkms status 2>/dev/null | grep -i nvidia | grep "$kernel_ver" || true)
        if [ -n "$dkms_status" ]; then
            item_ok "DKMS" "nvidia module built for $kernel_ver"
        else
            local any_dkms
            any_dkms=$(dkms status 2>/dev/null | grep -i nvidia || true)
            if [ -n "$any_dkms" ]; then
                item_warn "⚠ DKMS" "nvidia module NOT built for current kernel $kernel_ver"
                echo "    현재 DKMS: $any_dkms"
                add_action "WARNING" "현재 커널($kernel_ver)용 NVIDIA DKMS 모듈 없음\n       → sudo dkms autoinstall"
            fi
        fi
    fi

    if [ -f /proc/sys/kernel/tainted ]; then
        local tainted
        tainted=$(cat /proc/sys/kernel/tainted)
        if [ "$tainted" -ne 0 ] 2>/dev/null; then
            if dmesg 2>/dev/null | grep -q "module verification failed.*nvidia"; then
                item_warn "ℹ Tainted" "unsigned nvidia module (non-critical)"
                echo "    → open kernel module은 기본적으로 서명 없음"
                echo "    → Secure Boot 비활성화 상태면 무시 가능"
            else
                item_ok "Tainted" "value=$tainted (nvidia unrelated)"
            fi
        else
            item_ok "Tainted" "clean"
        fi
    fi
}

check_ecc_status() {
    section_header "6/6" "ECC Status"

    if [ "$NVIDIA_SMI_EXIT" -ne 0 ]; then
        item_fail "Status" "nvidia-smi 통신 불가"
        return
    fi

    local ecc_mode
    ecc_mode=$(nvidia-smi --query-gpu=ecc.mode.current --format=csv,noheader 2>/dev/null | head -1 || true)

    if [ -z "$ecc_mode" ] || [ "$ecc_mode" = "[N/A]" ] || [ "$ecc_mode" = "N/A" ]; then
        echo "  Skipped (consumer GPU — ECC not supported)"
        return
    fi

    item_ok "ECC Mode" "$ecc_mode"

    local sbe dbe
    sbe=$(nvidia-smi --query-gpu=ecc.errors.corrected.aggregate.total --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "0")
    dbe=$(nvidia-smi --query-gpu=ecc.errors.uncorrected.aggregate.total --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "0")

    if [ "$dbe" != "0" ] && [ "$dbe" != "[N/A]" ]; then
        item_fail "Double-bit errors" "$dbe (uncorrectable)"
        add_action "CRITICAL" "ECC Double-bit 에러 $dbe개 감지 — GPU 메모리 손상\n       → RMA 검토 권장"
    elif [ "$sbe" != "0" ] && [ "$sbe" != "[N/A]" ]; then
        item_warn "⚠ Single-bit errors" "$sbe (corrected, 모니터링 필요)"
        add_action "WARNING" "ECC Single-bit 에러 $sbe개 — 메모리 열화 가능성\n       → 지속 증가 시 GPU 교체 검토"
    else
        item_ok "ECC Errors" "none (SBE: $sbe, DBE: $dbe)"
    fi

    local retired
    retired=$(nvidia-smi --query-gpu=retired_pages.pending --format=csv,noheader 2>/dev/null | head -1 || true)
    if [ -n "$retired" ] && [ "$retired" != "[N/A]" ] && [ "$retired" != "No" ]; then
        item_warn "⚠ Retired Pages" "pending: $retired"
        add_action "WARNING" "GPU 메모리 페이지 퇴역 대기 중 — 리부트 후 적용됨"
    fi
}

print_summary() {
    echo ""
    echo "=== Summary ==="

    local status="OK"
    local exit_code=0
    if [ "$ISSUE_COUNT" -gt 0 ]; then
        status="CRITICAL"
        exit_code=2
    elif [ "$WARN_COUNT" -gt 0 ]; then
        status="WARNING"
        exit_code=1
    fi

    local total=$((ISSUE_COUNT + WARN_COUNT))
    if [ "$total" -gt 0 ]; then
        echo "  Status: $status ($total issue(s): $ISSUE_COUNT critical, $WARN_COUNT warnings)"
    else
        echo "  Status: OK — no issues found"
    fi

    if [ ${#ACTIONS[@]} -gt 0 ]; then
        echo ""
        echo "  Actions (by priority):"
        local n=1
        for priority in CRITICAL WARNING INFO; do
            for action in "${ACTIONS[@]}"; do
                if [[ "$action" == "[$priority]"* ]]; then
                    printf "    %d. %b\n" "$n" "$action"
                    n=$((n + 1))
                fi
            done
        done
    fi

    return $exit_code
}

# ============================================================
# Main
# ============================================================

# Summary mode for doctor.sh integration
if [ "$MODE" = "summary" ]; then
    SUMMARY_ISSUES=()

    if [ "$NVIDIA_SMI_EXIT" -ne 0 ]; then
        echo "FAIL ${GPU_NAME:-unknown GPU} unreachable (nvidia-smi exit $NVIDIA_SMI_EXIT — reboot required)"
        exit 2
    fi

    klog=$(get_kernel_log "24 hours ago" 2>/dev/null || true)
    if [ -n "$klog" ]; then
        xid_count=$(echo "$klog" | grep -c "NVRM.*Xid" || true)
        xid_count=${xid_count:-0}
        if [ "$xid_count" -gt 0 ]; then
            SUMMARY_ISSUES+=("Xid errors: $xid_count")
        fi
    fi

    temp=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 || true)

    if [ ${#SUMMARY_ISSUES[@]} -gt 0 ]; then
        detail=$(IFS=', '; echo "${SUMMARY_ISSUES[*]}")
        echo "WARN $GPU_NAME ($detail — run gpu-doctor.sh)"
        exit 1
    fi

    echo "OK $GPU_NAME ($DRIVER_VER, ${temp:-?}°C, no errors)"
    exit 0
fi

# Full mode
echo "=== GPU Doctor ==="
echo "  GPU: $GPU_NAME"
echo "  Driver: $DRIVER_VER"

check_driver_communication
check_xid_errors
check_pci_status
check_thermal_power
check_driver_compat
check_ecc_status
print_summary
