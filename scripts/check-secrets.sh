#!/usr/bin/env bash
# Scan files for potential secrets (standalone, can be run anytime)
set -euo pipefail

TARGET="${1:-.}"
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo "=== Secret Scanner ==="
echo "Scanning: $TARGET"
echo ""

PATTERNS=(
    'AKIA[0-9A-Z]{16}'
    'aws_secret_access_key\s*='
    'github_pat_[a-zA-Z0-9_]{22,}'
    'ghp_[a-zA-Z0-9]{36}'
    'sk-[a-zA-Z0-9]{20,}'
    'xox[bpors]-[a-zA-Z0-9-]+'
    'AIza[0-9A-Za-z_-]{35}'
    'PRIVATE KEY-----'
)

FOUND=0

for pattern in "${PATTERNS[@]}"; do
    MATCHES=$(grep -rPn "$pattern" "$TARGET" \
        --include='*.sh' --include='*.conf' --include='*.env' \
        --include='*.py' --include='*.yml' --include='*.yaml' \
        --include='*.json' --include='*.toml' --include='*.txt' \
        --exclude-dir='.git' --exclude='*.example' --exclude='*.md' \
        2>/dev/null || true)

    if [ -n "$MATCHES" ]; then
        echo -e "${RED}[FOUND]${NC} Pattern: $pattern"
        echo "$MATCHES" | head -5
        echo ""
        FOUND=1
    fi
done

if [ "$FOUND" -eq 0 ]; then
    echo -e "${GREEN}No secrets detected.${NC}"
else
    echo -e "${RED}Potential secrets found! Review and move to ~/.bashrc.local${NC}"
    exit 1
fi
