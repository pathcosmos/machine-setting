#!/usr/bin/env bash
# disk-badblocks-to-sectors.sh — .badblocks 파일(1024바이트 블록 번호)을 512바이트 섹터 구간으로 변환
# 파티션 설계 시 배드 구간을 피할 때 사용.
# Usage: ./scripts/disk-badblocks-to-sectors.sh <disk.badblocks> [섹터 여유]
# 출력: 한 줄에 "시작섹터 끝섹터" (공백 구분). 여유 기본 1 = 배드 앞뒤 1섹터씩 더 피함.
set -uo pipefail

BADBLOCKS_FILE="${1:?Usage: $0 <disk.badblocks> [sector_margin]}"
MARGIN="${2:-1}"

if [ ! -f "$BADBLOCKS_FILE" ]; then
  echo "No file: $BADBLOCKS_FILE" >&2
  exit 1
fi

# 1024-byte block -> 512-byte sector: 1 block = 2 sectors. Block B -> sectors 2*B, 2*B+1
# Sort and merge consecutive blocks into ranges
awk -v margin="$MARGIN" '
  { b = $1; s_start = b*2 - margin; s_end = b*2 + 1 + margin; print s_start, s_end }
' "$BADBLOCKS_FILE" | sort -n | awk -v margin="$MARGIN" '
  BEGIN { start = ""; end = "" }
  {
    s_start = $1; s_end = $2
    if (s_start < 0) s_start = 0
    if (start == "" || s_start > end + 1) {
      if (start != "") print start, end
      start = s_start; end = s_end
    } else {
      if (s_end > end) end = s_end
    }
  }
  END { if (start != "") print start, end }
'
