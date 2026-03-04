#!/usr/bin/env bash
# Sync machine_setting with remote
# Usage: sync.sh push|pull|status
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

cd "$REPO_DIR"

# Ensure we're in a git repo with remote
if ! git rev-parse --git-dir &>/dev/null; then
    echo "Error: Not a git repository"
    exit 1
fi

ACTION="${1:-status}"

case "$ACTION" in
    push)
        echo "=== Sync Push ==="

        # 1. Export current packages if venv is active
        if [ -n "${VIRTUAL_ENV:-}" ]; then
            echo "  Exporting packages from active venv..."
            bash "$SCRIPT_DIR/export-packages.sh"
            echo ""
        fi

        # 2. Stage changes
        echo "  Staging changes..."
        git add -A

        # 3. Check if there's anything to commit
        if git diff --cached --quiet; then
            echo "  No changes to commit."
            exit 0
        fi

        # 4. Show what will be committed
        echo "  Changes:"
        git diff --cached --stat

        # 5. Commit
        TIMESTAMP=$(date '+%Y-%m-%d %H:%M')
        HOSTNAME=$(hostname -s 2>/dev/null || echo "unknown")
        git commit -m "update: sync from $HOSTNAME at $TIMESTAMP"
        echo ""

        # 6. Pull + rebase first
        if git remote get-url origin &>/dev/null; then
            echo "  Pulling latest changes..."
            git pull --rebase origin main 2>/dev/null || git pull --rebase origin master 2>/dev/null || true

            # 7. Push
            echo "  Pushing..."
            git push origin HEAD
            echo ""
            echo "  Sync complete."
        else
            echo "  No remote configured. Committed locally only."
        fi
        ;;

    pull)
        echo "=== Sync Pull ==="

        if ! git remote get-url origin &>/dev/null; then
            echo "  No remote configured."
            exit 1
        fi

        # Record current package file hashes
        BEFORE=""
        for f in packages/requirements-*.txt; do
            [ -f "$f" ] && BEFORE="$BEFORE$(md5sum "$f" 2>/dev/null)"
        done

        # Pull
        echo "  Pulling latest changes..."
        git pull --rebase origin main 2>/dev/null || git pull --rebase origin master 2>/dev/null || {
            echo "  Error: Pull failed. Check for conflicts."
            exit 1
        }

        # Check if packages changed
        AFTER=""
        for f in packages/requirements-*.txt; do
            [ -f "$f" ] && AFTER="$AFTER$(md5sum "$f" 2>/dev/null)"
        done

        if [ "$BEFORE" != "$AFTER" ]; then
            echo ""
            echo "  Package files changed!"
            echo "  To update your venv, run:"
            echo "    bash ~/machine_setting/scripts/setup-venv.sh"
        fi

        echo ""
        echo "  Pull complete."
        ;;

    status)
        echo "=== Sync Status ==="

        # Local status
        echo "  Local changes:"
        if git diff --quiet && git diff --cached --quiet; then
            echo "    Clean (no local changes)"
        else
            git diff --stat
            git diff --cached --stat
        fi

        # Remote comparison
        if git remote get-url origin &>/dev/null; then
            git fetch origin --quiet 2>/dev/null || true
            LOCAL=$(git rev-parse HEAD 2>/dev/null || echo "none")
            REMOTE=$(git rev-parse origin/main 2>/dev/null || git rev-parse origin/master 2>/dev/null || echo "none")

            echo ""
            if [ "$LOCAL" = "$REMOTE" ]; then
                echo "  Remote: Up to date"
            elif [ "$REMOTE" = "none" ]; then
                echo "  Remote: Not configured or no remote branch"
            else
                AHEAD=$(git rev-list "$REMOTE..HEAD" --count 2>/dev/null || echo "?")
                BEHIND=$(git rev-list "HEAD..$REMOTE" --count 2>/dev/null || echo "?")
                echo "  Remote: ${AHEAD} ahead, ${BEHIND} behind"
            fi
        else
            echo ""
            echo "  Remote: Not configured"
        fi

        # Last sync info
        echo ""
        echo "  Last commit: $(git log -1 --format='%h %s (%ar)' 2>/dev/null || echo 'none')"
        ;;

    *)
        echo "Usage: sync.sh [push|pull|status]"
        exit 1
        ;;
esac
