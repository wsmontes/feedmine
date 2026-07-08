from __future__ import annotations

import json
import time
from pathlib import Path

from .models import Country
from .registry import keywords_for

# Categories where local/regional outlets dominate — worth anchoring to city
# names as well as the country name. Global-leaning categories skip cities.
LOCAL_CATEGORIES = {"News", "Sports", "Politics", "Business", "Culture", "Blogs"}
MAX_QUERIES_PER_CATEGORY = 6


def build_query(terms: list[str]) -> str:
    term = terms[0] if terms else "news"
    return f"{term} RSS feed"


def build_queries(country: Country, category: str, keywords: dict) -> list[str]:
    """Anchored search queries for one (country, category) from the search
    dictionary. When the country uses its ccTLD, constrain the search with the
    ``site:.<cctld>`` operator (proven to return ~100% national results on DDG),
    combined with local term synonyms + city names. Countries without a used
    ccTLD (e.g. USA) fall back to country/native-name anchoring and rely on the
    allowlist heuristic. The national heuristic still filters either way."""
    terms = keywords_for(keywords, category, country.lang) or ["news"]
    queries: list[str] = []

    if country.use_cctld:
        site = f"site:.{country.cctld}"
        for term in terms[:3]:
            queries.append(f"{term} rss {site}")
        queries.append(f"{country.name} rss {site}")
        if category in LOCAL_CATEGORIES:
            for city in country.cities[:2]:
                queries.append(f"{terms[0]} {city} rss {site}")
    else:
        anchors = [country.name]
        if country.native_name and country.native_name != country.name:
            anchors.append(country.native_name)
        for anchor in anchors:
            queries.append(f"{terms[0]} {anchor} rss")
        for term in terms[1:3]:
            queries.append(f"{term} {country.name} rss")
        if category in LOCAL_CATEGORIES:
            for city in country.cities[:2]:
                queries.append(f"{terms[0]} {city} rss")

    seen: set[str] = set()
    unique: list[str] = []
    for q in queries:
        if q not in seen:
            seen.add(q)
            unique.append(q)
    return unique[:MAX_QUERIES_PER_CATEGORY]


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
