from __future__ import annotations

import asyncio
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse

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


def _root_of(url: str) -> str:
    parsed = urlparse(url)
    return f"{parsed.scheme}://{parsed.netloc}"


async def _bounded_gather(limit: int, coros: list):
    """Run coroutines concurrently, capped at *limit* in flight."""
    sem = asyncio.Semaphore(max(1, limit))

    async def _run(coro):
        async with sem:
            return await coro

    return await asyncio.gather(*(_run(c) for c in coros))


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
    root_feeds: dict[str, list[str]] = {}  # domain root -> discovered feed URLs

    for category in categories:
        # --- Search (sequential: DDG politeness delay per query) ---
        page_urls: list[str] = []
        seen_pages: set[str] = set()
        for qi, query in enumerate(search.build_queries(country, category, keywords)):
            cache_path = cfg.cache_dir / "search" / country.slug / category / f"{qi}.json"
            for url in search.search(
                query, country.ddg_region, cfg.max_results, cache_path, cfg.delay, cfg.fresh
            ):
                if url not in seen_pages:
                    seen_pages.add(url)
                    page_urls.append(url)

        # --- Discover feeds per unique domain root, concurrently ---
        roots = list(dict.fromkeys(_root_of(u) for u in page_urls))
        pending = [r for r in roots if r not in root_feeds]
        discovered = await _bounded_gather(
            cfg.concurrency,
            [discover.discover_feeds(session, r, cfg.timeout) for r in pending],
        )
        for root, feeds in zip(pending, discovered):
            root_feeds[root] = feeds

        # --- Collect this category's feeds (dedup, skip globally seen) ---
        feed_urls: list[str] = []
        seen_local: set[str] = set()
        for root in roots:
            for feed in root_feeds.get(root, []):
                norm = normalize_url(feed)
                if norm in seen_local or norm in seen_feed_urls:
                    continue
                seen_local.add(norm)
                feed_urls.append(feed)

        # --- Classify; queue national + new feeds for verification ---
        to_verify: list[Candidate] = []
        for feed_url in feed_urls:
            norm = normalize_url(feed_url)
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
            to_verify.append(cand)

        # --- Verify liveness concurrently ---
        verdicts = await _bounded_gather(
            cfg.concurrency,
            [verify.verify_feed(session, c.url, cfg.timeout) for c in to_verify],
        )
        for cand, (is_live, status, title) in zip(to_verify, verdicts):
            cand.is_live, cand.status_code, cand.title = is_live, status, title
            candidates.append(cand)

    return candidates
