from __future__ import annotations

import json
import time
from pathlib import Path


def build_query(terms: list[str]) -> str:
    term = terms[0] if terms else "news"
    return f"{term} RSS feed"


def _extract_url(row: dict) -> str:
    return row.get("href") or row.get("url") or row.get("link") or ""


def _ddg_text(query: str, region: str, max_results: int) -> list[dict]:
    from ddgs import DDGS  # imported lazily so tests don't require the network

    try:
        with DDGS() as ddgs:
            return list(ddgs.text(query, region=region, max_results=max_results))
    except Exception:
        # Invalid region or transient error → retry region-agnostic once.
        with DDGS() as ddgs:
            return list(ddgs.text(query, region="wt-wt", max_results=max_results))


def search(
    query: str,
    region: str,
    max_results: int,
    cache_path: Path,
    delay: float = 2.0,
    fresh: bool = False,
) -> list[str]:
    cache_path = Path(cache_path)
    if not fresh and cache_path.exists():
        return json.loads(cache_path.read_text(encoding="utf-8"))

    rows = _ddg_text(query, region, max_results)
    urls: list[str] = []
    for row in rows:
        u = _extract_url(row)
        if u.startswith(("http://", "https://")):
            urls.append(u)

    cache_path.parent.mkdir(parents=True, exist_ok=True)
    cache_path.write_text(json.dumps(urls, ensure_ascii=False, indent=2), encoding="utf-8")
    if delay:
        time.sleep(delay)  # politeness spacing between live queries
    return urls
