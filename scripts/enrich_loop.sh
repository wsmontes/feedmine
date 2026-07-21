#!/bin/bash
# Auto-resuming enrichment launcher — restarts if killed, exits when all feeds done.
# Kills any existing enrich processes before starting to prevent duplicates.
# Usage: ./scripts/enrich_loop.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SCRIPT="$SCRIPT_DIR/enrich_feed_descriptions.py"

cd "$PROJECT_DIR"

# Kill any existing enrich processes (from previous runs) to prevent duplicates
cleanup_old() {
    # Kill Python enrich processes (skip current grep)
    pkill -f "enrich_feed_descriptions.py" 2>/dev/null
    # Kill old loop wrappers
    pkill -f "enrich_loop.sh" 2>/dev/null
    sleep 2
}

# Run cleanup once at the start
cleanup_old

restarts=0
while true; do
    echo "============================================"
    echo "  FeedMine Enrich Loop — run $((restarts + 1))"
    echo "  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "============================================"

    python3 "$SCRIPT"
    exit_code=$?

    if [ $exit_code -eq 0 ]; then
        echo ""
        echo "✓ Enrichment complete (exit 0)"
        break
    fi

    restarts=$((restarts + 1))
    echo ""
    echo "⚠ Script exited with code $exit_code — auto-restarting in 5s..."
    sleep 5
done
