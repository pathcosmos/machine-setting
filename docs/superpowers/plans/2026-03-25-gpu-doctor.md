# GPU Doctor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** GPU 전용 진단 도구(`gpu-doctor.sh`)를 만들어 Xid 에러, PCI 상태, 온도/전력, 드라이버 호환성 등을 점검하고 구체적 조치 방법을 제시한다.

**Architecture:** 단일 bash 스크립트(`scripts/gpu-doctor.sh`)에 6개 진단 섹션 + 요약. `--summary` 모드로 doctor.sh와 통합. setup.sh에 `--gpu-doctor` 플래그 추가.

**Tech Stack:** Bash, nvidia-smi, lspci, dmesg/journalctl

**Spec:** `docs/superpowers/specs/2026-03-25-gpu-doctor-design.md`

---

## File Map

| Action | File | Responsibility |
|--------|------|---------------|
| Create | `scripts/gpu-doctor.sh` | GPU 전용 진단 (6 섹션 + 요약) |
| Modify | `scripts/doctor.sh` | `check_nvidia_driver()` → gpu-doctor.sh --summary 호출로 교체 |
| Modify | `setup.sh` | `--gpu-doctor` 플래그 추가 |

---

## Task 1: gpu-doctor.sh 스켈레톤 + Driver Communication 섹션

**Files:**
- Create: `scripts/gpu-doctor.sh`

- [ ] **Step 1: 스크립트 스켈레톤 작성**

`scripts/gpu-doctor.sh` 생성. 기존 프로젝트 패턴을 따른다:
- `set -uo pipefail`, `SCRIPT_DIR`/`REPO_DIR` 변수
- `--summary` / `--help` 인자 파싱
- NVIDIA GPU 존재 여부 사전 검증 (nvidia-smi 없으면 조기 종료)
- 섹션 카운터 (`ISSUE_COUNT`, `WARN_COUNT`, `ACTIONS` 배열)
- 출력 헬퍼 함수: `section_header()`, `item_ok()`, `item_warn()`, `item_fail()`, `add_action()`

```bash
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

# --- Collect GPU info ---
GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)
DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || true)
BUS_ID=$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader 2>/dev/null | head -1 || true)
GPU_UUID=$(nvidia-smi --query-gpu=uuid --format=csv,noheader 2>/dev/null | head -1 || true)
NVIDIA_SMI_EXIT=0
nvidia-smi &>/dev/null || NVIDIA_SMI_EXIT=$?

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
```

- [ ] **Step 2: Driver Communication 섹션 구현**

nvidia-smi 응답 여부, 드라이버 버전, 커널 모듈 타입(open/proprietary), Bus ID, UUID를 확인한다.

```bash
# ============================================================
# [1/6] Driver Communication
# ============================================================
check_driver_communication() {
    section_header "1/6" "Driver Communication"

    # nvidia-smi responsiveness
    if [ "$NVIDIA_SMI_EXIT" -ne 0 ]; then
        item_fail "nvidia-smi" "exit code $NVIDIA_SMI_EXIT (cannot communicate with GPU)"
        add_action "CRITICAL" "nvidia-smi가 GPU와 통신 불가 (exit $NVIDIA_SMI_EXIT)\n       → 리부트 필요. 리부트 후에도 실패 시: sudo modprobe nvidia"
        return
    fi
    item_ok "nvidia-smi" "exit 0"

    # Driver version
    if [ -n "$DRIVER_VER" ]; then
        # Detect kernel module type
        local mod_type="unknown"
        if lsmod 2>/dev/null | grep -q "^nvidia_drm"; then
            if modinfo nvidia 2>/dev/null | grep -q "open-gpu-kernel-modules"; then
                mod_type="open"
            else
                mod_type="proprietary"
            fi
        fi
        item_ok "Driver" "$DRIVER_VER ($mod_type kernel module)"
    else
        item_fail "Driver" "version unknown"
        add_action "WARNING" "드라이버 버전 확인 불가\n       → 드라이버 재설치: ./setup.sh --from 2"
    fi

    # Bus ID and UUID
    [ -n "$BUS_ID" ] && item_ok "Bus ID" "$BUS_ID"
    [ -n "$GPU_UUID" ] && item_ok "UUID" "$GPU_UUID"
}
```

- [ ] **Step 3: 스크립트에 실행 가능 권한 부여**

```bash
chmod +x scripts/gpu-doctor.sh
```

- [ ] **Step 4: 수동 테스트 — Driver Communication 섹션**

```bash
bash scripts/gpu-doctor.sh
```

Expected: `--- [1/6] Driver Communication ---` 섹션이 표시되고, nvidia-smi OK, Driver 버전, Bus ID, UUID가 출력됨.

- [ ] **Step 5: 커밋**

```bash
git add scripts/gpu-doctor.sh
git commit -m "feat: add gpu-doctor.sh skeleton + driver communication check"
```

---

## Task 2: Xid Errors 섹션

**Files:**
- Modify: `scripts/gpu-doctor.sh`

- [ ] **Step 1: dmesg 접근 헬퍼 함수 작성**

dmesg → journalctl → skip 순서로 폴백한다.

```bash
# --- Kernel log access helper ---
# Returns kernel log lines or empty string if inaccessible
# Sets KLOG_SOURCE to "dmesg", "journalctl", or "unavailable"
get_kernel_log() {
    local since="${1:-24 hours ago}"
    KLOG_SOURCE="unavailable"

    # Try dmesg first
    local dmesg_out
    dmesg_out=$(dmesg --time-format iso 2>/dev/null || true)
    if [ -n "$dmesg_out" ]; then
        KLOG_SOURCE="dmesg"
        echo "$dmesg_out"
        return
    fi

    # Fallback: journalctl -k
    local journal_out
    journal_out=$(journalctl -k --since "$since" --no-pager 2>/dev/null || true)
    if [ -n "$journal_out" ]; then
        KLOG_SOURCE="journalctl"
        echo "$journal_out"
        return
    fi
}
```

- [ ] **Step 2: Xid Errors 섹션 구현**

dmesg에서 NVRM Xid 메시지를 파싱하고 심각도별로 분류한다.

```bash
# ============================================================
# [2/6] Xid Errors
# ============================================================
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

    # Parse Xid errors
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

    # Classify by Xid number
    local xid_numbers
    xid_numbers=$(echo "$xid_lines" | grep -oP 'Xid.*?:\s*\K[0-9]+' | sort | uniq -c | sort -rn)

    while read -r count xid; do
        [ -z "$xid" ] && continue
        local severity="INFO"
        local desc=""
        local action=""

        case "$xid" in
            79)
                severity="CRITICAL"; desc="GPU has fallen off the bus"
                action="리부트 필요. 재발 시: BIOS에서 PCIe Gen3 다운그레이드 + PSU 확인 (180W TDP)"
                ;;
            154)
                severity="CRITICAL"; desc="Recovery action: Node Reboot Required"
                action="즉시 리부트. Xid 79와 함께 발생하면 PCI 버스 이탈 확인"
                ;;
            48)
                severity="CRITICAL"; desc="Double Bit ECC Error"
                action="GPU 메모리 손상 가능. 재발 시 RMA 검토"
                ;;
            13)
                severity="WARNING"; desc="Graphics Engine Exception"
                action="드라이버 업그레이드 시도: sudo apt install nvidia-driver-5XX"
                ;;
            31)
                severity="WARNING"; desc="GPU Setup Failure"
                action="드라이버 재설치 또는 GPU 슬롯 재장착"
                ;;
            45)
                severity="WARNING"; desc="Preemptive Cleanup"
                action="일반적으로 무해. 반복 시 드라이버 업그레이드"
                ;;
            8)
                severity="INFO"; desc="Dropped interrupt"
                action="MSI 인터럽트 문제 가능. 보통 무해"
                ;;
            32)
                severity="INFO"; desc="Invalid or legacy Xid"
                action="무시 가능"
                ;;
            *)
                severity="WARNING"; desc="Unknown Xid"
                action="NVIDIA 문서 참조: https://docs.nvidia.com/deploy/xid-errors/"
                ;;
        esac

        echo "  [$severity] Xid $xid — $desc (${count}회)"
        if [ "$severity" = "CRITICAL" ] || [ "$severity" = "WARNING" ]; then
            add_action "$severity" "Xid $xid ($desc)\n       → $action"
        fi
    done <<< "$xid_numbers"
}
```

- [ ] **Step 3: 수동 테스트**

```bash
bash scripts/gpu-doctor.sh
```

Expected: `--- [2/6] Xid Errors ---` 섹션이 표시됨. 리부트 직후이므로 Xid가 있거나 없을 수 있음.

- [ ] **Step 4: 커밋**

```bash
git add scripts/gpu-doctor.sh
git commit -m "feat(gpu-doctor): add Xid error detection with severity classification"
```

---

## Task 3: PCI Bus Status 섹션

**Files:**
- Modify: `scripts/gpu-doctor.sh`

- [ ] **Step 1: PCI Bus Status 섹션 구현**

lspci로 BAR 상태, PCIe link speed/width를 확인한다.

```bash
# ============================================================
# [3/6] PCI Bus Status
# ============================================================
check_pci_status() {
    section_header "3/6" "PCI Bus Status"

    if ! command -v lspci &>/dev/null; then
        item_warn "lspci" "not found (pciutils 패키지 필요)"
        add_action "INFO" "PCI 진단 불가 — sudo apt install pciutils"
        return
    fi

    # Normalize bus ID for lspci (remove leading zeros in domain)
    local pci_slot
    pci_slot=$(echo "$BUS_ID" | sed 's/^0000//' | tr '[:upper:]' '[:lower:]')

    # BAR memory status
    local lspci_out
    lspci_out=$(lspci -v -s "$pci_slot" 2>/dev/null || true)
    if [ -z "$lspci_out" ]; then
        item_warn "PCI device" "not found at $pci_slot"
        return
    fi

    if echo "$lspci_out" | grep -q "\[disabled\]"; then
        item_fail "BAR Memory" "DISABLED"
        add_action "CRITICAL" "PCI BAR memory가 비활성화 상태 — GPU가 버스에서 이탈\n       → 리부트 필요. 재발 시 PCIe 슬롯 재장착"
    else
        item_ok "BAR Memory" "enabled"
    fi

    # PCIe link speed and width
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
```

- [ ] **Step 2: 수동 테스트**

```bash
bash scripts/gpu-doctor.sh
```

Expected: PCI Bus Status 섹션에 BAR Memory, Link Speed, Link Width 출력.

- [ ] **Step 3: 커밋**

```bash
git add scripts/gpu-doctor.sh
git commit -m "feat(gpu-doctor): add PCI bus status check (BAR, link speed/width)"
```

---

## Task 4: Thermal & Power 섹션

**Files:**
- Modify: `scripts/gpu-doctor.sh`

- [ ] **Step 1: Thermal & Power 섹션 구현**

nvidia-smi에서 온도, 전력, throttle 상태, fan speed를 쿼리한다.

```bash
# ============================================================
# [4/6] Thermal & Power
# ============================================================
check_thermal_power() {
    section_header "4/6" "Thermal & Power"

    if [ "$NVIDIA_SMI_EXIT" -ne 0 ]; then
        item_fail "Status" "nvidia-smi 통신 불가 — 측정 불가"
        return
    fi

    # Query all thermal/power metrics in one call
    local gpu_query
    gpu_query=$(nvidia-smi --query-gpu=temperature.gpu,power.draw,power.limit,power.max_limit,fan.speed,clocks_event_reasons.active --format=csv,noheader,nounits 2>/dev/null | head -1 || true)

    if [ -n "$gpu_query" ]; then
        IFS=',' read -r temp power_draw power_limit power_max fan_speed throttle_raw <<< "$gpu_query"
        # Trim whitespace
        temp=$(echo "$temp" | tr -d ' ')
        power_draw=$(echo "$power_draw" | tr -d ' ')
        power_limit=$(echo "$power_limit" | tr -d ' ')
        power_max=$(echo "$power_max" | tr -d ' ')
        fan_speed=$(echo "$fan_speed" | tr -d ' ')

        # Temperature check
        if [ -n "$temp" ] && [ "$temp" != "[N/A]" ]; then
            local temp_status="OK"
            if [ "$temp" -ge 90 ] 2>/dev/null; then
                temp_status="CRITICAL"
                item_fail "Temperature" "${temp}°C — 과열!"
                add_action "CRITICAL" "GPU 온도 ${temp}°C (위험)\n       → 케이스 에어플로우 확인, 서멀 페이스트 교체 검토\n       → fan curve 설정 확인"
            elif [ "$temp" -ge 80 ] 2>/dev/null; then
                temp_status="WARNING"
                item_warn "⚠ Temperature" "${temp}°C — 높음"
                add_action "WARNING" "GPU 온도 ${temp}°C (높음)\n       → 케이스 에어플로우 및 쿨링 확인"
            else
                item_ok "Temperature" "${temp}°C"
            fi
        fi

        # Power check
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

        # Fan speed
        if [ -n "$fan_speed" ] && [ "$fan_speed" != "[N/A]" ]; then
            item_ok "Fan" "${fan_speed}%"
        fi

        # Throttle check
        local throttle_reasons
        throttle_reasons=$(nvidia-smi --query-gpu=clocks_event_reasons.hw_thermal_slowdown,clocks_event_reasons.hw_power_brake_slowdown,clocks_event_reasons.sw_thermal_slowdown,clocks_event_reasons.sw_power_cap --format=csv,noheader 2>/dev/null | head -1 || true)
        if echo "$throttle_reasons" | grep -qi "active"; then
            item_warn "⚠ Throttle" "감지됨 — $throttle_reasons"
            add_action "WARNING" "GPU throttling 감지\n       → 온도/전력 원인 확인. 지속 시 워크로드 경감 또는 쿨링 보강"
        else
            item_ok "Throttle" "none"
        fi
    else
        item_warn "Thermal/Power" "쿼리 실패"
    fi
}
```

- [ ] **Step 2: 수동 테스트**

```bash
bash scripts/gpu-doctor.sh
```

Expected: Thermal & Power 섹션에 온도, 전력, Fan, Throttle 출력.

- [ ] **Step 3: 커밋**

```bash
git add scripts/gpu-doctor.sh
git commit -m "feat(gpu-doctor): add thermal and power diagnostics"
```

---

## Task 5: Driver Compatibility 섹션

**Files:**
- Modify: `scripts/gpu-doctor.sh`

- [ ] **Step 1: Driver Compatibility 섹션 구현**

GPU 아키텍처를 감지하고 드라이버 최소 요구 버전과 비교한다. DKMS, tainted kernel도 확인.

```bash
# ============================================================
# [5/6] Driver Compatibility
# ============================================================
check_driver_compat() {
    section_header "5/6" "Driver Compatibility"

    # Detect GPU architecture from PCI device ID or GPU name
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
            *)
                arch="Unknown" ;;
        esac
    fi

    item_ok "Architecture" "$arch (minimum driver: $min_driver)"

    # Driver version check
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

    # Kernel version
    local kernel_ver
    kernel_ver=$(uname -r)
    item_ok "Kernel" "$kernel_ver"

    # DKMS status
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

    # Tainted kernel check
    if [ -f /proc/sys/kernel/tainted ]; then
        local tainted
        tainted=$(cat /proc/sys/kernel/tainted)
        if [ "$tainted" -ne 0 ] 2>/dev/null; then
            # Check if it's just unsigned module (bit 12 or bit 13)
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
```

- [ ] **Step 2: 수동 테스트**

```bash
bash scripts/gpu-doctor.sh
```

Expected: Driver Compatibility 섹션에 아키텍처, 드라이버 버전 호환성, DKMS, tainted 출력.

- [ ] **Step 3: 커밋**

```bash
git add scripts/gpu-doctor.sh
git commit -m "feat(gpu-doctor): add driver compatibility check (arch mapping, DKMS, tainted)"
```

---

## Task 6: ECC Status 섹션

**Files:**
- Modify: `scripts/gpu-doctor.sh`

- [ ] **Step 1: ECC Status 섹션 구현**

Consumer GPU는 ECC 미지원이므로 skip. 지원 시 에러 카운트, retired pages를 확인한다.

```bash
# ============================================================
# [6/6] ECC Status
# ============================================================
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

    # Error counts
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

    # Retired pages
    local retired
    retired=$(nvidia-smi --query-gpu=retired_pages.pending --format=csv,noheader 2>/dev/null | head -1 || true)
    if [ -n "$retired" ] && [ "$retired" != "[N/A]" ] && [ "$retired" != "No" ]; then
        item_warn "⚠ Retired Pages" "pending: $retired"
        add_action "WARNING" "GPU 메모리 페이지 퇴역 대기 중 — 리부트 후 적용됨"
    fi
}
```

- [ ] **Step 2: 수동 테스트**

```bash
bash scripts/gpu-doctor.sh
```

Expected: ECC Status 섹션 — consumer GPU(RTX 5060 Ti)이므로 "Skipped" 출력.

- [ ] **Step 3: 커밋**

```bash
git add scripts/gpu-doctor.sh
git commit -m "feat(gpu-doctor): add ECC status check"
```

---

## Task 7: Summary, --summary 모드, main 실행 로직

**Files:**
- Modify: `scripts/gpu-doctor.sh`

- [ ] **Step 1: Summary 섹션 + main 로직 구현**

모든 섹션 결과를 종합하여 상태 요약 + 액션 리스트를 출력한다. `--summary` 모드는 한 줄만 출력.

```bash
# ============================================================
# Summary & Actions
# ============================================================
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
        # Print CRITICAL first, then WARNING, then INFO
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
    # Quick checks — collect issues silently
    SUMMARY_ISSUES=()

    if [ "$NVIDIA_SMI_EXIT" -ne 0 ]; then
        echo "FAIL GPU unreachable (nvidia-smi exit $NVIDIA_SMI_EXIT — reboot required)"
        exit 2
    fi

    # Check for Xid errors
    klog=$(get_kernel_log "24 hours ago" 2>/dev/null || true)
    if [ -n "$klog" ]; then
        xid_count=$(echo "$klog" | grep -c "NVRM.*Xid" 2>/dev/null || echo "0")
        if [ "$xid_count" -gt 0 ]; then
            SUMMARY_ISSUES+=("Xid errors: $xid_count")
        fi
    fi

    # Check temperature
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
```

- [ ] **Step 2: 전체 테스트 (full 모드)**

```bash
bash scripts/gpu-doctor.sh
```

Expected: 6개 섹션 모두 출력 + Summary 섹션에 상태 요약과 액션 리스트.

- [ ] **Step 3: summary 모드 테스트**

```bash
bash scripts/gpu-doctor.sh --summary
```

Expected: `OK NVIDIA GeForce RTX 5060 Ti (590.48.01, 32°C, no errors)` 형태의 한 줄 출력.

- [ ] **Step 4: 커밋**

```bash
git add scripts/gpu-doctor.sh
git commit -m "feat(gpu-doctor): add summary section and --summary mode"
```

---

## Task 8: doctor.sh 통합

**Files:**
- Modify: `scripts/doctor.sh` (lines 438-465: `check_nvidia_driver()` 함수)

- [ ] **Step 1: check_nvidia_driver() 수정**

기존 `check_nvidia_driver()` 함수를 gpu-doctor.sh --summary 호출로 교체한다.

기존 코드 (`scripts/doctor.sh:438-465`):
```bash
check_nvidia_driver() {
    # Skip on non-Linux or non-GPU systems
    if [ "$(uname -s)" != "Linux" ] || [ "${HAS_GPU:-false}" != "true" ] || [ "${GPU_BACKEND:-none}" != "cuda" ]; then
        status_skip "NVIDIA driver (not applicable)"
        return
    fi

    local stage_state
    stage_state=$(checkpoint_get_state 2 NVIDIA)
    if [ "$stage_state" = "skipped" ]; then
        status_skip "NVIDIA driver (stage skipped)"
        return
    fi

    if command -v nvidia-smi &>/dev/null; then
        local driver_ver
        driver_ver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || true)
        if [ -n "$driver_ver" ]; then
            local gpu_info
            gpu_info=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)
            status_ok "NVIDIA driver ($driver_ver, $gpu_info)"
        else
            status_fail "NVIDIA driver (nvidia-smi present but cannot communicate with driver)" "nvidia"
        fi
    else
        status_fail "NVIDIA driver (nvidia-smi not found)" "nvidia"
    fi
}
```

교체 후:
```bash
check_nvidia_driver() {
    # Skip on non-Linux or non-GPU systems
    if [ "$(uname -s)" != "Linux" ] || [ "${HAS_GPU:-false}" != "true" ] || [ "${GPU_BACKEND:-none}" != "cuda" ]; then
        status_skip "NVIDIA driver (not applicable)"
        return
    fi

    local stage_state
    stage_state=$(checkpoint_get_state 2 NVIDIA)
    if [ "$stage_state" = "skipped" ]; then
        status_skip "NVIDIA driver (stage skipped)"
        return
    fi

    # Use gpu-doctor.sh --summary for comprehensive check
    if [ -x "$SCRIPT_DIR/gpu-doctor.sh" ]; then
        local gpu_summary gpu_exit
        gpu_summary=$("$SCRIPT_DIR/gpu-doctor.sh" --summary 2>/dev/null) || gpu_exit=$?
        gpu_exit=${gpu_exit:-0}

        case "$gpu_exit" in
            0) status_ok "GPU health ($gpu_summary)" ;;
            1) status_warn "GPU health ($gpu_summary → run './scripts/gpu-doctor.sh')" ;;
            *) status_fail "GPU health ($gpu_summary)" "nvidia" ;;
        esac
    else
        # Fallback: basic nvidia-smi check
        if command -v nvidia-smi &>/dev/null; then
            local driver_ver
            driver_ver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || true)
            if [ -n "$driver_ver" ]; then
                local gpu_info
                gpu_info=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)
                status_ok "NVIDIA driver ($driver_ver, $gpu_info)"
            else
                status_fail "NVIDIA driver (nvidia-smi present but cannot communicate with driver)" "nvidia"
            fi
        else
            status_fail "NVIDIA driver (nvidia-smi not found)" "nvidia"
        fi
    fi
}
```

- [ ] **Step 2: doctor.sh 테스트**

```bash
bash setup.sh --doctor
```

Expected: "GPU health" 항목이 기존 "NVIDIA driver" 대신 표시. gpu-doctor.sh --summary 결과 반영.

- [ ] **Step 3: 커밋**

```bash
git add scripts/doctor.sh
git commit -m "feat(doctor): integrate gpu-doctor.sh --summary for GPU health check"
```

---

## Task 9: setup.sh 통합

**Files:**
- Modify: `setup.sh` (lines 49-103: CLI flag 파싱 영역)

- [ ] **Step 1: --gpu-doctor 플래그 추가**

`setup.sh`의 case문에 `--gpu-doctor` 추가 (line 71의 `--doctor` 바로 아래):

```bash
        --gpu-doctor)   exec bash "$SCRIPT_DIR/scripts/gpu-doctor.sh" ;;
```

help 텍스트에도 추가 (Diagnostic options 섹션):

```bash
            echo "  --gpu-doctor      GPU-specific health diagnostics"
```

- [ ] **Step 2: 테스트**

```bash
bash setup.sh --gpu-doctor
```

Expected: gpu-doctor.sh 전체 출력.

```bash
bash setup.sh --help
```

Expected: `--gpu-doctor` 옵션이 help에 표시.

- [ ] **Step 3: 커밋**

```bash
git add setup.sh
git commit -m "feat(setup): add --gpu-doctor flag for GPU diagnostics"
```

---

## Task 10: 최종 통합 테스트

**Files:** 없음 (테스트만)

- [ ] **Step 1: gpu-doctor.sh 전체 실행**

```bash
bash scripts/gpu-doctor.sh
```

Expected: 6개 섹션 모두 정상 출력, Summary에 상태 요약.

- [ ] **Step 2: gpu-doctor.sh --summary 실행**

```bash
bash scripts/gpu-doctor.sh --summary
```

Expected: 한 줄 요약 출력, exit code 0.

- [ ] **Step 3: doctor.sh 통합 확인**

```bash
bash setup.sh --doctor
```

Expected: "GPU health" 항목이 gpu-doctor.sh 결과를 반영하여 표시.

- [ ] **Step 4: setup.sh --gpu-doctor 확인**

```bash
bash setup.sh --gpu-doctor
```

Expected: gpu-doctor.sh 전체 실행과 동일한 출력.

- [ ] **Step 5: 최종 커밋 (필요 시)**

남은 수정 사항이 있다면 커밋.
