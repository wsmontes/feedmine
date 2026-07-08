from __future__ import annotations

import json
import time
from urllib.parse import urlencode

import aiohttp

from ..models import Candidate, Country

ITUNES_SEARCH = "https://itunes.apple.com/search"


def podcast_seed_terms(country: Country) -> list[str]:
    terms = [country.name]
    if country.native_name and country.native_name != country.name:
        terms.append(country.native_name)
    terms.extend(country.cities)
    seen: set[str] = set()
    out: list[str] = []
    for t in terms:
        if t and t not in seen:
            seen.add(t)
            out.append(t)
    return out


def itunes_search_url(term: str, iso2: str, limit: int = 50) -> str:
    q = urlencode({"term": term, "country": iso2, "entity": "podcast", "limit": limit})
    return f"{ITUNES_SEARCH}?{q}"


def podcasts_from_itunes_json(payload: dict, iso3: str) -> list[Candidate]:
    out: list[Candidate] = []
    seen: set[str] = set()
    for r in payload.get("results", []):
        if (r.get("country") or "").upper() != iso3.upper():
            continue
        feed = r.get("feedUrl")
        if not feed or feed in seen:
            continue
        seen.add(feed)
        out.append(Candidate(
            url=feed, category="Podcasts",
            title=r.get("collectionName", ""),
            genre=r.get("primaryGenreName", ""),
            national=True, national_reason="itunes country==iso3",
        ))
    return out


def _safe(term: str) -> str:
    return "".join(ch if ch.isalnum() else "_" for ch in term)


async def discover(country: Country, session, cfg) -> list[Candidate]:
    cands: list[Candidate] = []
    seen: set[str] = set()
    for term in podcast_seed_terms(country):
        cache_path = cfg.cache_dir / "itunes" / country.slug / (_safe(term) + ".json")
        if not cfg.fresh and cache_path.exists():
            payload = json.loads(cache_path.read_text(encoding="utf-8"))
        else:
            payload = {"results": []}
            url = itunes_search_url(term, country.iso2, 50)
            try:
                async with session.get(
                    url, timeout=aiohttp.ClientTimeout(total=cfg.timeout)
                ) as resp:
                    if resp.status == 200:
                        payload = await resp.json(content_type=None)
            except (aiohttp.ClientError, TimeoutError):
                payload = {"results": []}
            cache_path.parent.mkdir(parents=True, exist_ok=True)
            cache_path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
            if cfg.delay:
                time.sleep(cfg.delay)
        for c in podcasts_from_itunes_json(payload, country.iso3):
            if c.url not in seen:
                seen.add(c.url)
                cands.append(c)
    return cands
