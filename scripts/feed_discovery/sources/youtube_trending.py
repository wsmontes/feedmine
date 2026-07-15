# scripts/feed_discovery/sources/youtube_trending.py

from __future__ import annotations

import os
import time
from urllib.parse import urlencode

import aiohttp

from ..models import Candidate
from ..profiles._schema import CountryProfile, SourceConfig
from ._base import ProbeResult


class YouTubeTrendingSource:
    """YouTube Data API v3 — mostPopular chart per country.

    Uses videos.list with chart=mostPopular to discover channels
    trending in a specific country. Far cheaper than search.list:
    1 quota unit vs 100.

    Each call returns up to 50 trending videos. The source extracts
    unique channel IDs from the video results and converts them to
    RSS feed URLs (no follow-up channels.list call needed — the
    snippet already includes channelId and channelTitle).

    Env vars:
        YOUTUBE_API_KEY: API key from console.cloud.google.com
    """
    name = "youtube_trending"
    BASE = "https://www.googleapis.com/youtube/v3"

    def __init__(self):
        self.api_key = os.getenv("YOUTUBE_API_KEY", "")
        self.enabled = bool(self.api_key)
        if not self.enabled:
            import warnings
            warnings.warn(
                "YouTubeTrendingSource disabled: YOUTUBE_API_KEY env var not set. "
                "Get a free key at https://console.cloud.google.com/apis/credentials"
            )

    def _channel_rss_url(self, channel_id: str) -> str:
        return f"https://www.youtube.com/feeds/videos.xml?channel_id={channel_id}"

    async def search(
        self,
        query: str,
        profile: CountryProfile,
        config: SourceConfig,
        session: aiohttp.ClientSession,
    ) -> list[Candidate]:
        """Discover channels from YouTube's mostPopular chart for a country.

        The query parameter is ignored — this source derives its discovery
        from the regionCode in config.params and the country profile.

        Returns one Candidate per unique channel found in trending videos.
        """
        if not self.enabled:
            return []

        region_code = config.params.get("regionCode", "")
        if not region_code:
            # Fall back to profile country ISO2 if no regionCode in config
            region_code = getattr(profile, "country", "").upper()[:2]

        if not region_code:
            return []

        candidates: list[Candidate] = []
        seen_channel_ids: set[str] = set()

        params = {
            "part": "snippet",
            "chart": "mostPopular",
            "regionCode": region_code,
            "maxResults": str(min(config.max_results, 50)),
            "key": self.api_key,
        }

        url = f"{self.BASE}/videos?{urlencode(params)}"

        try:
            async with session.get(
                url,
                timeout=aiohttp.ClientTimeout(total=config.timeout),
            ) as resp:
                if resp.status != 200:
                    return []
                data = await resp.json()
                for item in data.get("items", []):
                    snippet = item.get("snippet", {})
                    cid = snippet.get("channelId", "")
                    title = snippet.get("channelTitle", "")
                    if cid and cid not in seen_channel_ids:
                        seen_channel_ids.add(cid)
                        rss_url = self._channel_rss_url(cid)
                        candidates.append(Candidate(
                            url=rss_url,
                            category="YouTube",
                            title=title,
                            genre="",
                            national=True,
                            national_reason=f"youtube_trending:{region_code}",
                        ))
        except Exception:
            return []

        return candidates

    async def probe(
        self,
        profile: CountryProfile,
        config: SourceConfig,
        session: aiohttp.ClientSession,
    ) -> ProbeResult:
        """Probe YouTube trending endpoint for this country."""
        if not self.enabled:
            return ProbeResult(
                source_name="youtube_trending",
                success=False,
                result_count=0,
                latency_ms=0,
                error="disabled: missing YOUTUBE_API_KEY",
            )

        t0 = time.monotonic()
        try:
            results = await self.search("", profile, config, session)
            elapsed = (time.monotonic() - t0) * 1000
            return ProbeResult(
                source_name="youtube_trending",
                success=len(results) > 0,
                result_count=len(results),
                latency_ms=elapsed,
            )
        except Exception as e:
            elapsed = (time.monotonic() - t0) * 1000
            return ProbeResult(
                source_name="youtube_trending",
                success=False,
                result_count=0,
                latency_ms=elapsed,
                error=str(e)[:200],
            )
