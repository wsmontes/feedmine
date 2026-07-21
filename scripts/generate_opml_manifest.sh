#!/usr/bin/env bash
# Generate a JSON manifest of all OPML files for faster app loading.
# Run from project root: scripts/generate_opml_manifest.sh
# Output: feedmine/Resources/Feeds/opml_manifest.json

set -euo pipefail

python3 - <<'PY'
from __future__ import annotations

import json
import re
from datetime import datetime, timezone
from pathlib import Path

feeds_dir = Path("feedmine/Resources/Feeds")
output = feeds_dir / "opml_manifest.json"

files = []
for path in sorted(feeds_dir.rglob("*.opml")):
    rel = path.relative_to(feeds_dir).as_posix()
    sources = 0
    with path.open(encoding="utf-8", errors="ignore") as handle:
        sources = sum(1 for line in handle if "xmlUrl" in line)
    region = "global"
    parts = rel.removesuffix(".opml").split("/")
    if parts and re.sub(r"^\d+[ _-]+", "", parts[0]).lower() == "countries":
        region_parts = parts[1:-1]
        region = "/".join(region_parts or parts[-1:])
    files.append({"path": rel, "region": region, "sources": sources})

manifest = {
    "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "files": files,
}
output.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
print(f"Generated {output}")
PY
