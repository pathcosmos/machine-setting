#!/usr/bin/env bash
# cuda-defense-check.sh — CUDA process-level health diagnostics
# PyTorch + Ollama (또는 vLLM/TGI) GPU 공유 환경에서 프로세스 레벨 CUDA 상태 점검
#
# Usage:
#   ./scripts/cuda-defense-check.sh              # Full detailed diagnostics
#   ./scripts/cuda-defense-check.sh --summary    # One-line summary (for doctor.sh)
#   ./scripts/cuda-defense-check.sh --json       # Machine-readable JSON output
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# --- Parse arguments ---
MODE="full"  # full | summary | json
while [[ $# -gt 0 ]]; do
    case "$1" in
        --summary) MODE="summary"; shift ;;
        --json)    MODE="json"; shift ;;
        --help|-h)
            echo "Usage: ./scripts/cuda-defense-check.sh [--summary|--json]"
            echo "  (no args)    Full CUDA process-level diagnostics"
            echo "  --summary    One-line summary for doctor.sh integration"
            echo "  --json       Machine-readable JSON output"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# --- Pre-check: nvidia-smi must exist ---
if ! command -v nvidia-smi &>/dev/null; then
    if [ "$MODE" = "summary" ]; then
        echo "SKIP nvidia-smi not found"
        exit 0
    elif [ "$MODE" = "json" ]; then
        echo '{"status":"skip","reason":"nvidia-smi not found"}'
        exit 0
    fi
    echo "=== CUDA Defense Check ==="
    echo "  nvidia-smi not found — GPU 환경 아님, 검사 생략"
    exit 0
fi

# --- Status tracking ---
ISSUE_COUNT=0
WARN_COUNT=0
ACTIONS=()

# --- Output helpers ---
section_header() { echo ""; echo "--- [$1] $2 ---"; }
item_ok()   { echo "  ✓ $1: $2"; }
item_warn() { echo "  ⚠ $1: $2"; WARN_COUNT=$((WARN_COUNT + 1)); }
item_fail() { echo "  ✗ $1: $2"; ISSUE_COUNT=$((ISSUE_COUNT + 1)); }
add_action() {
    local priority="$1"; shift
    ACTIONS+=("[$priority] $*")
}

# ═══════════════════════════════════════════════════════════════════════════════
# [1/4] CUDA 프로세스 상태
# ═══════════════════════════════════════════════════════════════════════════════
check_cuda_processes() {
    section_header "1/4" "CUDA 프로세스 상태"

    # Active CUDA processes
    local gpu_procs
    gpu_procs=$(nvidia-smi --query-compute-apps=pid,used_memory,name --format=csv,noheader,nounits 2>/dev/null || true)

    if [ -z "$gpu_procs" ]; then
        item_ok "CUDA 프로세스" "활성 프로세스 없음 (GPU idle)"
        return
    fi

    local total=0
    local zombie=0
    local zombie_pids=""

    while IFS=', ' read -r pid mem name; do
        pid=$(echo "$pid" | tr -d ' ')
        [ -z "$pid" ] && continue
        total=$((total + 1))
        if ! kill -0 "$pid" 2>/dev/null; then
            zombie=$((zombie + 1))
            zombie_pids="$zombie_pids $pid"
        fi
    done <<< "$gpu_procs"

    item_ok "CUDA 프로세스" "${total}개 활성"

    if [ "$zombie" -gt 0 ]; then
        item_fail "좀비 프로세스" "${zombie}개 감지 (PID:${zombie_pids}) — GPU 메모리 누수 원인"
        add_action "CRITICAL" "좀비 CUDA 프로세스 정리 필요: kill -9${zombie_pids}"
    else
        item_ok "좀비 프로세스" "없음"
    fi

    # List top consumers
    echo ""
    echo "  프로세스 목록:"
    while IFS=', ' read -r pid mem name; do
        pid=$(echo "$pid" | tr -d ' ')
        mem=$(echo "$mem" | tr -d ' ')
        name=$(echo "$name" | tr -d ' ')
        [ -z "$pid" ] && continue
        local status="running"
        kill -0 "$pid" 2>/dev/null || status="ZOMBIE"
        printf "    PID %-8s  %6s MiB  %-8s  %s\n" "$pid" "$mem" "$status" "$name"
    done <<< "$gpu_procs"
}

# ═══════════════════════════════════════════════════════════════════════════════
# [2/4] Ollama 서비스 상태
# ═══════════════════════════════════════════════════════════════════════════════
check_ollama_health() {
    section_header "2/4" "Ollama 서비스 상태"

    # Skip if Ollama not installed
    if ! command -v ollama &>/dev/null; then
        item_ok "Ollama" "미설치 — 검사 생략"
        return
    fi

    local proc_running=false
    local api_ok=false

    if pgrep -f "ollama" &>/dev/null; then
        proc_running=true
    fi

    if curl -sf --max-time 5 http://localhost:11434/ &>/dev/null; then
        api_ok=true
    fi

    if [ "$proc_running" = true ] && [ "$api_ok" = true ]; then
        item_ok "Ollama" "프로세스 실행 중 + API 응답 정상"
    elif [ "$proc_running" = true ] && [ "$api_ok" = false ]; then
        item_fail "Ollama" "프로세스 실행 중이나 API 무응답 — hang 상태 의심"
        add_action "CRITICAL" "Ollama hang 감지 — pkill -9 -f ollama && ollama serve"
    elif [ "$proc_running" = false ] && [ "$api_ok" = false ]; then
        item_warn "Ollama" "프로세스 미실행 (비활성 상태)"
    else
        item_warn "Ollama" "API 응답하나 프로세스 감지 불가 (비정상)"
    fi

    # Check Ollama VRAM usage
    if [ "$proc_running" = true ]; then
        local ollama_pid
        ollama_pid=$(pgrep -f "ollama" | head -1 || true)
        if [ -n "$ollama_pid" ]; then
            local ollama_vram
            ollama_vram=$(nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits 2>/dev/null \
                | grep "^${ollama_pid}" | awk -F', ' '{print $2}' || true)
            if [ -n "$ollama_vram" ]; then
                item_ok "Ollama VRAM" "${ollama_vram} MiB 사용 중"
            fi
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# [3/4] GPU 메모리 압력
# ═══════════════════════════════════════════════════════════════════════════════
check_gpu_memory() {
    section_header "3/4" "GPU 메모리 압력"

    local mem_info
    mem_info=$(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || true)

    if [ -z "$mem_info" ]; then
        item_fail "VRAM" "nvidia-smi 메모리 조회 실패"
        add_action "CRITICAL" "nvidia-smi 통신 불가 — GPU 드라이버 상태 확인 필요"
        return
    fi

    local used total pct
    used=$(echo "$mem_info" | awk -F', ' '{print $1}' | tr -d ' ')
    total=$(echo "$mem_info" | awk -F', ' '{print $2}' | tr -d ' ')

    if [ "$total" -gt 0 ] 2>/dev/null; then
        pct=$((used * 100 / total))
    else
        pct=0
    fi

    if [ "$pct" -ge 95 ]; then
        item_fail "VRAM" "${used}/${total} MiB (${pct}%) — CRITICAL: OOM 위험"
        add_action "CRITICAL" "VRAM ${pct}% 사용 — 불필요한 GPU 프로세스 종료 필요"
    elif [ "$pct" -ge 85 ]; then
        item_warn "VRAM" "${used}/${total} MiB (${pct}%) — 높은 사용률"
        add_action "WARNING" "VRAM ${pct}% — 모델 동시 로딩 시 OOM 가능성"
    else
        item_ok "VRAM" "${used}/${total} MiB (${pct}%)"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# [4/4] CUDA 드라이버 일관성
# ═══════════════════════════════════════════════════════════════════════════════
check_driver_consistency() {
    section_header "4/4" "CUDA 드라이버 일관성"

    # nvidia-smi response time check
    local start_ns end_ns elapsed_ms
    start_ns=$(date +%s%N)
    nvidia-smi --query-gpu=name --format=csv,noheader &>/dev/null
    local smi_exit=$?
    end_ns=$(date +%s%N)
    elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))

    if [ "$smi_exit" -ne 0 ]; then
        item_fail "nvidia-smi 응답" "실패 (exit=$smi_exit) — 드라이버 오염 가능성"
        add_action "CRITICAL" "nvidia-smi 실패 — nvidia-smi --gpu-reset -i 0 또는 리부팅 필요"
        return
    fi

    if [ "$elapsed_ms" -gt 3000 ]; then
        item_warn "nvidia-smi 응답" "${elapsed_ms}ms — 느림 (>3s), 드라이버 부하 의심"
        add_action "WARNING" "nvidia-smi 응답 지연 — GPU 프로세스 상태 확인"
    elif [ "$elapsed_ms" -gt 1000 ]; then
        item_warn "nvidia-smi 응답" "${elapsed_ms}ms — 약간 느림"
    else
        item_ok "nvidia-smi 응답" "${elapsed_ms}ms"
    fi

    # Driver version consistency
    local smi_ver proc_ver
    smi_ver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ' || true)
    proc_ver=""
    if [ -f /proc/driver/nvidia/version ]; then
        proc_ver=$(grep -oP 'Kernel Module\s+\K[0-9]+\.[0-9.]+' /proc/driver/nvidia/version 2>/dev/null || true)
    fi

    if [ -n "$smi_ver" ] && [ -n "$proc_ver" ]; then
        if [ "$smi_ver" = "$proc_ver" ]; then
            item_ok "드라이버 버전" "nvidia-smi=$smi_ver, kernel=$proc_ver (일치)"
        else
            item_fail "드라이버 버전" "불일치! nvidia-smi=$smi_ver, kernel=$proc_ver"
            add_action "CRITICAL" "드라이버 버전 불일치 — 리부팅 또는 드라이버 재설치 필요"
        fi
    elif [ -n "$smi_ver" ]; then
        item_ok "드라이버 버전" "$smi_ver (kernel module 버전 확인 불가)"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# Summary mode
# ═══════════════════════════════════════════════════════════════════════════════
if [ "$MODE" = "summary" ] || [ "$MODE" = "json" ]; then
    SUMMARY_ISSUES=()

    # [1] Zombie processes
    gpu_procs=$(nvidia-smi --query-compute-apps=pid,used_memory,name --format=csv,noheader,nounits 2>/dev/null || true)
    proc_count=0
    zombie_count=0
    if [ -n "$gpu_procs" ]; then
        while IFS=', ' read -r pid _mem _name; do
            pid=$(echo "$pid" | tr -d ' ')
            [ -z "$pid" ] && continue
            proc_count=$((proc_count + 1))
            kill -0 "$pid" 2>/dev/null || zombie_count=$((zombie_count + 1))
        done <<< "$gpu_procs"
    fi
    [ "$zombie_count" -gt 0 ] && SUMMARY_ISSUES+=("zombie:${zombie_count}")

    # [2] Ollama health
    ollama_status="n/a"
    if command -v ollama &>/dev/null; then
        if pgrep -f "ollama" &>/dev/null; then
            if curl -sf --max-time 3 http://localhost:11434/ &>/dev/null; then
                ollama_status="up"
            else
                ollama_status="hung"
                SUMMARY_ISSUES+=("ollama:hung")
            fi
        else
            ollama_status="off"
        fi
    fi

    # [3] VRAM pressure
    mem_info=$(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || true)
    vram_str="?"
    if [ -n "$mem_info" ]; then
        used=$(echo "$mem_info" | awk -F', ' '{print $1}' | tr -d ' ')
        total=$(echo "$mem_info" | awk -F', ' '{print $2}' | tr -d ' ')
        if [ "$total" -gt 0 ] 2>/dev/null; then
            pct=$((used * 100 / total))
            vram_str="${used}M/${total}M(${pct}%)"
            [ "$pct" -ge 95 ] && SUMMARY_ISSUES+=("vram:${pct}%")
            [ "$pct" -ge 85 ] && [ "$pct" -lt 95 ] && SUMMARY_ISSUES+=("vram-high:${pct}%")
        fi
    fi

    # [4] nvidia-smi response time
    start_ns=$(date +%s%N)
    nvidia-smi --query-gpu=name --format=csv,noheader &>/dev/null
    smi_ok=$?
    end_ns=$(date +%s%N)
    resp_ms=$(( (end_ns - start_ns) / 1000000 ))
    [ "$smi_ok" -ne 0 ] && SUMMARY_ISSUES+=("smi:fail")
    [ "$resp_ms" -gt 3000 ] && SUMMARY_ISSUES+=("smi:slow(${resp_ms}ms)")

    if [ "$MODE" = "json" ]; then
        # JSON output
        status="ok"
        if [ ${#SUMMARY_ISSUES[@]} -gt 0 ]; then
            for issue in "${SUMMARY_ISSUES[@]}"; do
                case "$issue" in
                    zombie:*|ollama:hung|smi:fail|vram:*) status="fail" ;;
                    *) [ "$status" != "fail" ] && status="warn" ;;
                esac
            done
            issues_json=$(printf '"%s",' "${SUMMARY_ISSUES[@]}" | sed 's/,$//')
        else
            issues_json=""
        fi
        cat <<EOJSON
{"status":"${status}","cuda_procs":${proc_count},"zombie_procs":${zombie_count},"ollama":"${ollama_status}","vram":"${vram_str}","smi_response_ms":${resp_ms},"issues":[${issues_json}]}
EOJSON
        [ "$status" = "fail" ] && exit 2
        [ "$status" = "warn" ] && exit 1
        exit 0
    fi

    # Summary one-liner
    if [ ${#SUMMARY_ISSUES[@]} -gt 0 ]; then
        detail=$(IFS=', '; echo "${SUMMARY_ISSUES[*]}")
        # Check severity
        has_critical=false
        for issue in "${SUMMARY_ISSUES[@]}"; do
            case "$issue" in
                zombie:*|ollama:hung|smi:fail|vram:[9][5-9]*) has_critical=true ;;
            esac
        done
        if [ "$has_critical" = true ]; then
            echo "FAIL ${proc_count} CUDA procs, ollama:${ollama_status}, ${vram_str} ($detail)"
            exit 2
        else
            echo "WARN ${proc_count} CUDA procs, ollama:${ollama_status}, ${vram_str} ($detail)"
            exit 1
        fi
    fi

    echo "OK ${proc_count} CUDA procs, ollama:${ollama_status}, ${vram_str}"
    exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Full mode
# ═══════════════════════════════════════════════════════════════════════════════
echo "=== CUDA Defense Check ==="
echo "  PyTorch + GPU Service 공존 환경 프로세스 레벨 진단"
echo "  참조: docs/10-cuda-defense-patterns.md"

check_cuda_processes
check_ollama_health
check_gpu_memory
check_driver_consistency

# --- Print summary ---
echo ""
echo "═══════════════════════════════════════════"
if [ "$ISSUE_COUNT" -gt 0 ]; then
    echo "  결과: ✗ CRITICAL ${ISSUE_COUNT}건, ⚠ WARNING ${WARN_COUNT}건"
elif [ "$WARN_COUNT" -gt 0 ]; then
    echo "  결과: ⚠ WARNING ${WARN_COUNT}건"
else
    echo "  결과: ✓ 모든 검사 통과"
fi

if [ ${#ACTIONS[@]} -gt 0 ]; then
    echo ""
    echo "  권장 조치:"
    for action in "${ACTIONS[@]}"; do
        echo "    → $action"
    done
fi
echo "═══════════════════════════════════════════"

[ "$ISSUE_COUNT" -gt 0 ] && exit 2
[ "$WARN_COUNT" -gt 0 ] && exit 1
exit 0
