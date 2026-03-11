#!/usr/bin/env bash
# disk-check-smart-long.sh — 5개 NAS HDD 동시 SMART Extended Self-Test 실행
# 디스크 내부 테스트(수 시간 소요). 진행률은 smartctl -a /dev/sdX 로 확인.
# Usage: sudo ./scripts/disk-check-smart-long.sh
set -uo pipefail

DISKS=(sde sdf sdg sdh sdi)

echo "=== SMART Extended Self-Test 시작 (5개 디스크 병렬) ==="
for d in "${DISKS[@]}"; do
  dev="/dev/$d"
  [ -b "$dev" ] || { echo "Skip: $dev"; continue; }
  echo "  Start long test: $dev"
  sudo smartctl -t long "$dev" 2>&1
done
echo ""
echo "진행 확인: sudo smartctl -a /dev/sde  (Self-test execution status)"
echo "완료 후:   sudo ./scripts/disk-check-smart.sh  로 최종 SMART 수집 권장."
