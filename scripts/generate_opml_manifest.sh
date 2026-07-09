#!/bin/bash
# Generate a JSON manifest of all OPML files for faster app loading.
# Run from project root: scripts/generate_opml_manifest.sh
# Output: feedmine/Resources/Feeds/opml_manifest.json

FEEDS_DIR="feedmine/Resources/Feeds"
OUTPUT="$FEEDS_DIR/opml_manifest.json"

echo "{" > "$OUTPUT"
echo '  "generated_at": "'"$(date -u +"%Y-%m-%dT%H:%M:%SZ")"'",' >> "$OUTPUT"
echo '  "files": [' >> "$OUTPUT"

first=true
find "$FEEDS_DIR" -name "*.opml" | sort | while read -r f; do
    rel="${f#$FEEDS_DIR/}"
    count=$(grep -c 'xmlUrl' "$f" 2>/dev/null || echo 0)
    region="global"
    if [[ "$rel" == countries/* ]]; then
        region=$(echo "$rel" | cut -d'/' -f2- | sed 's/\.opml$//')
    fi
    [ "$first" = true ] || echo ',' >> "$OUTPUT"
    first=false
    echo -n "    {\"path\": \"$rel\", \"region\": \"$region\", \"sources\": $count}" >> "$OUTPUT"
done

echo '' >> "$OUTPUT"
echo '  ]' >> "$OUTPUT"
echo '}' >> "$OUTPUT"

echo "Generated $OUTPUT"
