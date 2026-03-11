#!/usr/bin/env bash
# disk-check-progress.sh — 대용량 디스크(sde 14TB, sdf 8TB 등) 배드섹터 검사 진행률 확인
# badblocks -s 는 퍼센트 또는 블록 번호를 로그에 남김. 로그 끝에서 진행률을 파싱해 표시.
# Usage: ./scripts/disk-check-progress.sh [출력디렉토리]
#        watch -n 60 ./scripts/disk-check-progress.sh  # 1분마다 갱신
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${1:-$HOME/disk-check-results}"
LOG_DIR="$OUT_DIR/logs"
DISKS=(sde sdf sdg sdh sdi)

# 디스크별 총 블록 수(1024바이트) 캐시
get_total_blocks() {
  local dev="$1"
  local bytes
  bytes=$(sudo blockdev --getsize64 "$dev" 2>/dev/null)
  [ -n "$bytes" ] || return 1
  echo $(( bytes / 1024 ))
}

# 로그에서 마지막 진행률 추출: 퍼센트(12.34%) 또는 블록 번호(마지막 큰 숫자)
get_progress_from_log() {
  local log="$1"
  local total="$2"
  [ -f "$log" ] || return 1
  # badblocks -s: 일부 버전은 "XX.XX%" 형태, 일부는 블록 번호만 출력
  local last_pct
  last_pct=$(grep -oE '[0-9]+\.?[0-9]*%' "$log" 2>/dev/null | tail -1)
  if [ -n "$last_pct" ]; then
    echo "${last_pct%.*}%"
    return
  fi
  # 블록 번호로 추정: 로그 마지막 부분에서 가장 큰 숫자 (현재 검사 중인 블록)
  local last_block
  last_block=$(grep -oE '[0-9]{8,}' "$log" 2>/dev/null | tail -1)
  if [ -n "$last_block" ] && [ "$total" -gt 0 ]; then
    local pct=$(( last_block * 100 / total ))
    echo "${pct}%"
    return
  fi
  echo "?"
}

# 사람이 읽기 좋은 용량
human_size() {
  local bytes="$1"
  if [ "$bytes" -ge 1099511627776 ]; then
    echo "$(( bytes / 1099511627776 ))TB"
  elif [ "$bytes" -ge 1073741824 ]; then
    echo "$(( bytes / 1073741824 ))GB"
  else
    echo "$(( bytes / 1048576 ))MB"
  fi
}

echo "디스크 배드섹터 검사 진행률 (로그: $LOG_DIR)"
echo "시간: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

for d in "${DISKS[@]}"; do
  dev="/dev/$d"
  log="$LOG_DIR/${d}.log"
  [ -b "$dev" ] || continue
  total_blocks=$(get_total_blocks "$dev")
  [ -n "$total_blocks" ] || total_blocks=0
  total_bytes=$(( total_blocks * 1024 ))
  size_h=$(human_size "$total_bytes")
  progress=$(get_progress_from_log "$log" "$total_blocks")
  # 로그 파일 마지막 수정 시각
  if [ -f "$log" ]; then
    last_modified=$(stat -c '%y' "$log" 2>/dev/null | cut -d'.' -f1)
    running=""
    pgrep -f "badblocks.*$dev" >/dev/null 2>&1 && running="(실행 중)"
  else
    last_modified="로그 없음"
    running=""
  fi
  printf "  %s  %6s   총블록: %d  진행: %6s  %s  %s\n" "$dev" "$size_h" "$total_blocks" "$progress" "$last_modified" "$running"
done

echo ""
echo "계속 보려면: watch -n 60 $SCRIPT_DIR/disk-check-progress.sh"
