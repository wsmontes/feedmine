from __future__ import annotations

import json
from pathlib import Path

from .country_meta import COUNTRY_META, display_name

REPO_ROOT = Path(__file__).resolve().parents[3]
COUNTRIES_DIR = REPO_ROOT / "feedmine" / "Resources" / "Feeds" / "countries"
OUT = Path(__file__).parent / "countries.json"


def build() -> dict:
    folders = sorted(p.name for p in COUNTRIES_DIR.iterdir() if p.is_dir())
    result: dict[str, dict] = {}
    missing: list[str] = []
    for slug in folders:
        meta = COUNTRY_META.get(slug)
        if meta is None:
            missing.append(slug)
            continue
        cctld, lang, use_cctld = meta
        result[slug] = {
            "name": display_name(slug),
            "cctld": cctld,
            "use_cctld": use_cctld,
            "lang": lang,
            "ddg_region": f"{cctld}-{lang}",
            "allowlist": [],
        }
    if missing:
        raise SystemExit(f"COUNTRY_META missing entries for: {missing}")
    return result


if __name__ == "__main__":
    OUT.write_text(json.dumps(build(), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {OUT} with {len(build())} countries")
