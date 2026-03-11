#!/usr/bin/env bash
# disk-check-smart.sh — 5개 NAS HDD(sde,sdf,sdg,sdh,sdi) SMART 상세 수집
# Usage: sudo ./scripts/disk-check-smart.sh [출력디렉토리]
# 요구: smartmontools
set -uo pipefail

DISKS=(sde sdf sdg sdh sdi)
OUT_DIR="${1:-$HOME/disk-check-results}"
SMART_DIR="$OUT_DIR/smart"
mkdir -p "$SMART_DIR"

echo "=== SMART 상세 수집 (출력: $SMART_DIR) ==="
for d in "${DISKS[@]}"; do
  dev="/dev/$d"
  [ -b "$dev" ] || { echo "Skip (no device): $dev"; continue; }
  echo "  $dev ..."
  sudo smartctl -a "$dev" > "$SMART_DIR/${d}.txt" 2>&1
  sudo smartctl -H "$dev" >> "$SMART_DIR/${d}-health.txt" 2>&1
done

echo "=== 요약 (Health + Reallocated/Current_Pending/Offline_Uncorrectable) ==="
for d in "${DISKS[@]}"; do
  f="$SMART_DIR/${d}.txt"
  [ -f "$f" ] || continue
  echo "--- $d ---"
  grep -E "^(SMART overall|Reallocated_Sector|Current_Pending_Sector|Offline_Uncorrectable|Serial|Model)" "$f" 2>/dev/null || true
  echo ""
done

echo "Done. Full reports: $SMART_DIR/*.txt"
