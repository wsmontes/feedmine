# scripts/feed_discovery/sources/podcast_index.py

from __future__ import annotations

import hashlib
import hmac
import os
import time
from datetime import datetime, timezone
from urllib.parse import urlencode

from ..models import Candidate
from ..opml import normalize_url
from ..profiles._schema import CountryProfile, SourceConfig
from ._base import ProbeResult


class PodcastIndexSource:
    """Podcast Index API — free, open, 4M+ podcasts globally.

    API docs: https://podcastindex-org.github.io/docs-api/
    Auth: X-Auth-Key + X-Auth-Date + Authorization (HMAC-SHA1)
    Rate limit: generous for standard use.

    Env vars:
        PODCAST_INDEX_KEY: API key from api.podcastindex.org
        PODCAST_INDEX_SECRET: API secret from api.podcastindex.org
    """
    name = "podcast_index"
    BASE = "https://api.podcastindex.org/api/1.0"

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
        """Generate X-Auth-Key, X-Auth-Date, Authorization headers."""
        dt = datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S GMT")
        string_to_sign = f"{self.api_key}{self.api_key}{dt}"
        signature = hmac.new(
            self.api_secret.encode(), string_to_sign.encode(), hashlib.sha1
        ).hexdigest()
        return {
            "User-Agent": "FeedmineDiscovery/1.0",
            "X-Auth-Key": self.api_key,
            "X-Auth-Date": dt,
            "Authorization": signature,
        }

    async def search(
        self,
        query: str,
        profile: CountryProfile,
        config: SourceConfig,
        session,
    ) -> list[Candidate]:
        """Search Podcast Index by term.

        Uses /search/byterm with query, language filter from profile,
        and max_results from config.
        """
        if not self.enabled:
            return []

        params = {"q": query, "max": str(config.max_results)}
        # Filter by language if profile specifies one
        if profile.languages:
            params["lang"] = ",".join(profile.languages[:3])

        url = f"{self.BASE}/search/byterm?{urlencode(params)}"
        try:
            async with session.get(
                url,
                headers=self._auth_headers(),
                timeout=aiohttp.ClientTimeout(total=config.timeout),
            ) as resp:
                if resp.status != 200:
                    return []
                data = await resp.json()
        except Exception:
            return []

        candidates: list[Candidate] = []
        seen: set[str] = set()
        for feed in data.get("feeds", []):
            feed_url = feed.get("url") or feed.get("originalUrl")
            if not feed_url or feed_url in seen:
                continue
            seen.add(feed_url)
            # Determine category from itunes categories if available
            cats = feed.get("categories", {})
            genre = ""
            if cats:
                # categories is {cat_id: cat_name}
                genre = next(iter(cats.values()), "")
            candidates.append(Candidate(
                url=feed_url,
                category="Podcasts",
                title=feed.get("title", ""),
                genre=genre,
                national=True,
                national_reason="podcast_index",
            ))

        return candidates

    async def probe(
        self,
        profile: CountryProfile,
        config: SourceConfig,
        session,
    ) -> ProbeResult:
        """Probe Podcast Index with the country name."""
        if not self.enabled:
            return ProbeResult(
                source_name="podcast_index",
                success=False,
                result_count=0,
                latency_ms=0,
                error="disabled: missing PODCAST_INDEX_KEY or PODCAST_INDEX_SECRET",
            )

        t0 = time.monotonic()
        query = profile.country.replace("-", " ")
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
                source_name="podcast_index",
                success=False,
                result_count=0,
                latency_ms=elapsed,
                error=str(e)[:200],
            )


# Import aiohttp at module level for type annotations
import aiohttp  # noqa: E402
