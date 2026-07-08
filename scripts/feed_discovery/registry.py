from __future__ import annotations

import json
from pathlib import Path

from .models import Country

CATEGORIES: list[str] = [
    "News", "Sports", "Technology", "Science", "Culture", "Movies", "Music",
    "Food", "Gaming", "Travel", "Blogs", "Design", "Environment", "DIY",
    "History", "Architecture", "Programming", "Business", "Podcasts",
    "Photography", "Health", "Education", "Politics", "Humor", "Apple", "YouTube",
]


def load_countries(path: Path) -> dict[str, Country]:
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    out: dict[str, Country] = {}
    for slug, meta in data.items():
        out[slug] = Country(
            slug=slug,
            name=meta["name"],
            cctld=meta["cctld"],
            use_cctld=bool(meta["use_cctld"]),
            lang=meta["lang"],
            ddg_region=meta.get("ddg_region", f'{meta["cctld"]}-{meta["lang"]}'),
            allowlist=list(meta.get("allowlist", [])),
            native_name=meta.get("native_name") or meta["name"],
            cities=list(meta.get("cities", [])),
        )
    return out


def load_keywords(path: Path) -> dict[str, dict[str, list[str]]]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def keywords_for(keywords: dict, category: str, lang: str) -> list[str]:
    packs = keywords.get(category)
    if not packs:
        return []
    return list(packs.get(lang) or packs.get("en") or [])


def load_blocklist(path: Path) -> set[str]:
    out: set[str] = set()
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        line = line.strip().lower()
        if line and not line.startswith("#"):
            out.add(line)
    return out
