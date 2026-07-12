from __future__ import annotations

import asyncio
import time
from pathlib import Path
from urllib.parse import urlparse

from .. import discover, search, verify
from ..heuristic import is_local
from ..models import Candidate
from ..opml import normalize_url
from ..pipeline import Config
from ..profiles._schema import CountryProfile, SourceConfig
from ._base import ProbeResult


class DDGTextSource:
    """DDG web search for text/news feeds as a SourceProtocol implementation.

    Wraps the existing search.py → discover.py → verify.py pipeline
    into the pluggable source interface. Does NOT modify the original
    modules.
    """
    name = "ddg_text"

    def __init__(self, cache_dir: Path | None = None):
        self._cache_dir = cache_dir or Path("scripts/feed_discovery/cache")

    async def search(
        self,
        query: str,
        profile: CountryProfile,
        config: SourceConfig,
        session,
    ) -> list[Candidate]:
        """Search DDG for text feeds, discover RSS, verify liveness."""
        candidates: list[Candidate] = []
        seen_urls: set[str] = set()

        # 1. DDG search for page URLs
        cache_path = self._cache_dir / "ddg_text" / profile.country / (
            "".join(ch if ch.isalnum() else "_" for ch in query) + ".json"
        )
        page_urls = search.search(
            query, profile._ddg_region(), config.max_results,
            cache_path, delay=2.0, fresh=False,
        )
        if not page_urls:
            return []

        # 2. Discover feeds from each unique domain root
        roots = list(dict.fromkeys(self._root_of(u) for u in page_urls))
        sem = asyncio.Semaphore(10)

        async def _discover_one(root: str) -> tuple[str, list[str]]:
            async with sem:
                feeds = await discover.discover_feeds(session, root, config.timeout)
                return root, feeds

        discovered = await asyncio.gather(*(_discover_one(r) for r in roots[:10]))
        root_feeds = dict(discovered)

        # 3. Collect unique feed URLs
        feed_urls: list[str] = []
        for root in roots[:10]:
            for feed in root_feeds.get(root, []):
                norm = normalize_url(feed)
                if norm not in seen_urls:
                    seen_urls.add(norm)
                    feed_urls.append(feed)

        # 4. Classify & verify liveness
        to_verify: list[tuple[str, str]] = []
        for feed_url in feed_urls[:config.max_results]:
            # Use the query as the subregion name for is_local check
            is_loc, reason = is_local(feed_url, query, feed_title="")
            if not is_loc:
                continue
            to_verify.append((feed_url, reason))

        sem_v = asyncio.Semaphore(10)

        async def _verify_one(url: str, reason: str) -> Candidate | None:
            async with sem_v:
                try:
                    is_live, status, title = await verify.verify_feed(
                        session, url, config.timeout,
                    )
                except Exception:
                    return None
                if not is_live:
                    return None
                if discover.is_comment_feed_title(title):
                    return None
                return Candidate(
                    url=url, category="News", title=title, genre="",
                    national=True, national_reason=reason,
                    is_live=True, status_code=status,
                )

        results = await asyncio.gather(*(_verify_one(u, r) for u, r in to_verify))
        for c in results:
            if c is not None:
                candidates.append(c)

        return candidates

    async def probe(
        self,
        profile: CountryProfile,
        config: SourceConfig,
        session,
    ) -> ProbeResult:
        """Probe DDG with the country name as query."""
        t0 = time.monotonic()
        query = profile.country.replace("-", " ")
        try:
            results = await self.search(query, profile, config, session)
            elapsed = (time.monotonic() - t0) * 1000
            return ProbeResult(
                source_name="ddg_text",
                success=len(results) > 0,
                result_count=len(results),
                latency_ms=elapsed,
            )
        except Exception as e:
            elapsed = (time.monotonic() - t0) * 1000
            return ProbeResult(
                source_name="ddg_text",
                success=False,
                result_count=0,
                latency_ms=elapsed,
                error=str(e)[:200],
            )

    @staticmethod
    def _root_of(url: str) -> str:
        parsed = urlparse(url)
        return f"{parsed.scheme}://{parsed.netloc}"


def _ddg_region_for_profile(profile: CountryProfile) -> str:
    """Derive a DDG region string from a CountryProfile."""
    lang = profile.languages[0] if profile.languages else "en"
    country = profile.country
    return f"{country}-{lang}"


# Monkey-patch _ddg_region as a convenience accessor
CountryProfile._ddg_region = lambda self: _ddg_region_for_profile(self)
