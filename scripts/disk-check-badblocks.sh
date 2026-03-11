#!/usr/bin/env bash
# disk-check-badblocks.sh — 5개 NAS HDD 병렬 read-only 배드섹터 검사
# 데이터 변경 없음(-n 아님, 읽기만). 결과는 OUT_DIR에 저장.
# Usage: sudo ./scripts/disk-check-badblocks.sh [출력디렉토리]
# 소요: 디스크당 수 시간~수십 시간 (용량·속도에 따라). 병렬로 5개 동시 진행.
set -uo pipefail

DISKS=(sde sdf sdg sdh sdi)
OUT_DIR="${1:-$HOME/disk-check-results}"
BADBLOCKS_DIR="$OUT_DIR/badblocks"
LOG_DIR="$OUT_DIR/logs"
mkdir -p "$BADBLOCKS_DIR" "$LOG_DIR"

# 1024-byte 블록 개수 계산 (badblocks 기본 블록 크기 1024)
block_count() {
  local dev="$1"
  local bytes
  bytes=$(sudo blockdev --getsize64 "$dev" 2>/dev/null)
  [ -n "$bytes" ] || return 1
  echo $(( bytes / 1024 ))
}

echo "=== 병렬 read-only 배드섹터 검사 시작 ==="
echo "출력: 배드블록 목록 → $BADBLOCKS_DIR/<disk>.badblocks"
echo "로그 → $LOG_DIR/<disk>.log"
echo ""

for d in "${DISKS[@]}"; do
  dev="/dev/$d"
  [ -b "$dev" ] || { echo "Skip (no device): $dev"; continue; }
  out="$BADBLOCKS_DIR/${d}.badblocks"
  log="$LOG_DIR/${d}.log"
  cnt=$(block_count "$dev")
  if [ -z "$cnt" ] || [ "$cnt" -le 0 ]; then
    echo "Skip $dev: could not get block count"
    continue
  fi
  if [ -f "$out" ]; then
    echo "Skip $dev: 결과 파일 이미 존재 ($out). 재검사 시 해당 파일 삭제 후 다시 실행."
    continue
  fi
  echo "Start $dev — block count $cnt"
  # read-only: -s (진행), -v (verbose). 블록 수 지정 시 전체 디스크 검사.
  nohup sudo badblocks -sv -o "$out" "$dev" "$cnt" >> "$log" 2>&1 &
done

wait
echo ""
echo "=== 배드섹터 검사 완료 ==="
for d in "${DISKS[@]}"; do
  out="$BADBLOCKS_DIR/${d}.badblocks"
  if [ -f "$out" ]; then
    n=$(wc -l < "$out")
    echo "  /dev/$d: ${n} bad block(s) → $out"
  else
    echo "  /dev/$d: no bad blocks file (check $LOG_DIR/${d}.log)"
  fi
done
echo "결과 디렉토리: $OUT_DIR"
