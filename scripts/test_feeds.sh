#!/bin/bash
# Test all RSS/Atom feed URLs from OPML files
# Usage: ./scripts/test_feeds.sh [--timeout SECONDS] [--concurrent N]
set -euo pipefail

TIMEOUT=${1:-10}
OPML_DIR="${OPML_DIR:-feedmine/Resources/Feeds}"
RESULT_DIR=$(mktemp -d)
PASS=0; FAIL=0; EMPTY=0; TOTAL=0
trap "rm -rf $RESULT_DIR" EXIT

echo "🔍 Testing feeds with ${TIMEOUT}s timeout..."
echo ""

URLS=$(grep -oh 'xmlUrl="[^"]*"' "$OPML_DIR"/*.opml 2>/dev/null | sed 's/xmlUrl="//;s/"//' | sort -u)
TOTAL=$(echo "$URLS" | wc -l | tr -d ' ')
echo "   $TOTAL unique URLs across $(ls "$OPML_DIR"/*.opml 2>/dev/null | wc -l | tr -d ' ') OPML files."
echo ""

i=0
while IFS= read -r url; do
    ((i++))
    response=$(curl -sS -L -A "FeedmineTester/1.0" \
        --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" \
        -o /dev/null -w "%{http_code} %{size_download}" \
        "$url" 2>/dev/null || echo "000 0")

    read -r code size <<< "$response"

    if [[ "$code" =~ ^2 ]]; then
        if [[ "$size" -gt 100 ]]; then
            echo "  [$i/$TOTAL] ✅ $code ${size}B  $url"
            ((PASS++))
        else
            echo "  [$i/$TOTAL] ⚠️  $code ${size}B  $url (empty)"
            ((EMPTY++))
        fi
    else
        echo "  [$i/$TOTAL] ❌ $code  $url"
        echo "$url" >> "$RESULT_DIR/failed.txt"
        ((FAIL++))
    fi
done <<< "$URLS"

echo ""
echo "─────────────────────────────────────────────"
echo "  ✅ Pass:  $PASS"
echo "  ⚠️ Empty: $EMPTY"
echo "  ❌ Fail:  $FAIL"
echo "  📊 Total: $TOTAL"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
    echo "Failed URLs saved to $RESULT_DIR/failed.txt"
fi
