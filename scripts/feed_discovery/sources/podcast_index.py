# scripts/feed_discovery/sources/podcast_index.py

from __future__ import annotations

import asyncio
import hashlib
import os
import time
from urllib.parse import urlencode

import aiohttp

from ..models import Candidate
from ..opml import normalize_url
from ..profiles._schema import CountryProfile, SourceConfig
from ._base import ProbeResult


class PodcastIndexSource:
    """Podcast Index API — free, open, 4M+ podcasts globally.

    Uses /podcasts/trending with language filters to find the BEST podcasts
    per country (trending/popular), not raw volume. One trending call per
    language the country speaks, plus a category-diverse search query.

    API docs: https://podcastindex-org.github.io/docs-api/
    """

    name = "podcast_index"
    BASE = "https://api.podcastindex.org/api/1.0"

    # Top podcast categories that exist across most countries
    _DISCOVERY_CATEGORIES = [
        "news", "society", "sports", "comedy", "technology",
        "business", "health", "education", "music", "religion",
    ]

    def __init__(self):
        self.api_key = os.getenv("PODCAST_INDEX_KEY", "")
        self.api_secret = os.getenv("PODCAST_INDEX_SECRET", "")
        self.enabled = bool(self.api_key and self.api_secret)
        if not self.enabled:
            import warnings
            warnings.warn(
                "PodcastIndexSource disabled: PODCAST_INDEX_KEY and "
                "PODCAST_INDEX_SECRET env vars not set. "
                "Get free keys at https://api.podcastindex.org/"
            )

    def _auth_headers(self) -> dict[str, str]:
        epoch_time = int(time.time())
        data_to_hash = f"{self.api_key}{self.api_secret}{epoch_time}"
        sha1_hash = hashlib.sha1(data_to_hash.encode()).hexdigest()
        return {
            "User-Agent": "FeedmineDiscovery/1.0",
            "X-Auth-Key": self.api_key,
            "X-Auth-Date": str(epoch_time),
            "Authorization": sha1_hash,
        }

    async def _fetch_trending(
        self, lang: str, max_results: int, session, timeout: int,
    ) -> list[dict]:
        """Fetch trending podcasts for a language."""
        params = {"lang": lang, "max": str(max_results)}
        url = f"{self.BASE}/podcasts/trending?{urlencode(params)}"
        try:
            async with session.get(
                url, headers=self._auth_headers(),
                timeout=aiohttp.ClientTimeout(total=timeout),
            ) as resp:
                if resp.status != 200:
                    return []
                data = await resp.json()
                return data.get("feeds", [])
        except Exception:
            return []

    async def _search_best(
        self, query: str, lang: str, max_results: int, session, timeout: int,
    ) -> list[dict]:
        """Search by term with language filter for a specific query."""
        params = {"q": query, "max": str(max_results)}
        if lang:
            params["lang"] = lang
        url = f"{self.BASE}/search/byterm?{urlencode(params)}"
        try:
            async with session.get(
                url, headers=self._auth_headers(),
                timeout=aiohttp.ClientTimeout(total=timeout),
            ) as resp:
                if resp.status != 200:
                    return []
                data = await resp.json()
                return data.get("feeds", [])
        except Exception:
            return []

    def _feeds_to_candidates(self, feeds: list[dict], reason: str) -> list[Candidate]:
        """Convert API feed dicts to Candidate objects."""
        candidates: list[Candidate] = []
        seen: set[str] = set()
        for feed in feeds:
            feed_url = feed.get("url") or feed.get("originalUrl")
            if not feed_url:
                continue
            feed_url = normalize_url(feed_url)
            if feed_url in seen:
                continue
            seen.add(feed_url)
            cats = feed.get("categories", {})
            genre = next(iter(cats.values()), "") if cats else ""
            candidates.append(Candidate(
                url=feed_url,
                category="Podcasts",
                title=feed.get("title", ""),
                genre=genre,
                national=True,
                national_reason=reason,
            ))
        return candidates

    async def search(
        self, query: str, profile: CountryProfile,
        config: SourceConfig, session,
    ) -> list[Candidate]:
        """Discover the BEST podcasts for a country.

        Strategy:
        1. Trending podcasts for each language the country speaks
        2. One category-diverse search query per language
        All results combined and deduplicated.
        """
        if not self.enabled:
            return []

        languages = profile.languages[:3] if profile.languages else ["en"]
        per_call = max(10, min(config.max_results // len(languages), 50))
        timeout = config.timeout

        country_name = profile.country.replace("-", " ") if profile.country else ""
        all_candidates: list[Candidate] = []
        seen_urls: set[str] = set()

        for lang_index, lang in enumerate(languages):
            # Strategy 1: Trending podcasts in this language
            trending = await self._fetch_trending(lang, per_call, session, timeout)
            for c in self._feeds_to_candidates(trending, f"podcast_index:trending:{lang}"):
                url = normalize_url(c.url)
                if url not in seen_urls:
                    seen_urls.add(url)
                    all_candidates.append(c)

            # Strategy 2: Multiple category-diverse searches in local language
            # Pick 2-3 categories rotated by lang index to maximize diversity
            cat_start = (lang_index * 3) % len(self._DISCOVERY_CATEGORIES)
            cats_to_try = [
                self._DISCOVERY_CATEGORIES[(cat_start + i) % len(self._DISCOVERY_CATEGORIES)]
                for i in range(3)
            ]
            for cat in cats_to_try:
                local_query = f"{country_name} {cat}" if country_name else cat
                best = await self._search_best(local_query, lang, per_call // 3, session, timeout)
                for c in self._feeds_to_candidates(best, f"podcast_index:search:{lang}:{cat}"):
                    url = normalize_url(c.url)
                    if url not in seen_urls:
                        seen_urls.add(url)
                        all_candidates.append(c)

        return all_candidates[:config.max_results]

    async def probe(
        self, profile: CountryProfile,
        config: SourceConfig, session,
    ) -> ProbeResult:
        if not self.enabled:
            return ProbeResult(
                source_name="podcast_index", success=False,
                result_count=0, latency_ms=0,
                error="disabled: missing PODCAST_INDEX_KEY or PODCAST_INDEX_SECRET",
            )
        t0 = time.monotonic()
        query = profile.country.replace("-", " ") if profile.country else "news"
        try:
            results = await self.search(query, profile, config, session)
            elapsed = (time.monotonic() - t0) * 1000
            return ProbeResult(
                source_name="podcast_index",
                success=len(results) > 0,
                result_count=len(results),
                latency_ms=elapsed,
            )
        except Exception as e:
            elapsed = (time.monotonic() - t0) * 1000
            return ProbeResult(
                source_name="podcast_index", success=False,
                result_count=0, latency_ms=elapsed,
                error=str(e)[:200],
            )
