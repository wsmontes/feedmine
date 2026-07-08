from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import aiohttp

from . import discover, search, verify
from .heuristic import host_of, is_national
from .models import Candidate, Country
from .opml import normalize_url


@dataclass
class Config:
    max_results: int = 12
    timeout: int = 15
    delay: float = 2.0
    fresh: bool = False
    concurrency: int = 50
    cache_dir: Path = Path("scripts/feed_discovery/cache")


def candidates_to_opml_map(candidates: list[Candidate]) -> dict[str, list[tuple[str, str]]]:
    out: dict[str, list[tuple[str, str]]] = {}
    seen: set[str] = set()
    for c in candidates:
        if not (c.is_new and c.national and c.is_live):
            continue
        key = normalize_url(c.url)
        if key in seen:
            continue
        seen.add(key)
        title = c.title or host_of(c.url)
        out.setdefault(c.category, []).append((title, c.url))
    return out


async def process_country(
    country: Country,
    categories: list[str],
    keywords: dict,
    blocklist: set[str],
    existing_urls: set[str],
    session: aiohttp.ClientSession,
    cfg: Config,
) -> list[Candidate]:
    candidates: list[Candidate] = []
    seen_feed_urls: set[str] = set()

    for category in categories:
        queries = search.build_queries(country, category, keywords)
        page_urls: list[str] = []
        seen_pages: set[str] = set()
        for qi, query in enumerate(queries):
            cache_path = cfg.cache_dir / "search" / country.slug / category / f"{qi}.json"
            for url in search.search(
                query, country.ddg_region, cfg.max_results, cache_path, cfg.delay, cfg.fresh
            ):
                if url not in seen_pages:
                    seen_pages.add(url)
                    page_urls.append(url)

        # Discover feed URLs from each result page.
        feed_urls: list[str] = []
        for page in page_urls:
            found = await discover.discover_feeds(session, page, cfg.timeout)
            feed_urls.extend(found)

        for feed_url in feed_urls:
            norm = normalize_url(feed_url)
            if norm in seen_feed_urls:
                continue
            seen_feed_urls.add(norm)

            national, reason = is_national(feed_url, country, blocklist)
            cand = Candidate(url=feed_url, category=category,
                             national=national, national_reason=reason)
            if not national:
                candidates.append(cand)
                continue

            cand.is_new = norm not in existing_urls
            if not cand.is_new:
                candidates.append(cand)
                continue

            is_live, status, title = await verify.verify_feed(session, feed_url, cfg.timeout)
            cand.is_live, cand.status_code, cand.title = is_live, status, title
            candidates.append(cand)

    return candidates
