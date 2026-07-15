# scripts/feed_discovery/sources/youtube_awards.py

from __future__ import annotations

import json
import time
from pathlib import Path

from ..models import Candidate
from ..profiles._schema import CountryProfile, SourceConfig
from ._base import ProbeResult


class YouTubeAwardsSource:
    """Award-winning YouTube channels from Streamy, Shorty, and Webby Awards.

    Reads pre-scraped data from youtube_channels_awards.json.
    Data is generated offline by scripts/youtube_awards_scraper.py.

    Award-winning channels are typically high-production-value and have
    strong local/regional followings. This source discovers channels that
    search-based and trending-based sources may miss.

    This source is always enabled as long as the data file exists.
    """

    name = "youtube_awards"
    DATA_PATH = (
        Path(__file__).resolve().parents[1]
        / "data"
        / "youtube_channels_awards.json"
    )

    def __init__(self):
        self._channels: list[dict] = []
        self.enabled = self.DATA_PATH.exists()
        if self.enabled:
            self._load_data()

    def _load_data(self):
        """Load award-winning channel data from the scraped JSON."""
        try:
            data = json.loads(self.DATA_PATH.read_text(encoding="utf-8"))
            self._channels = data.get("channels", [])
        except Exception:
            self._channels = []

    async def search(
        self,
        query: str,
        profile: CountryProfile,
        config: SourceConfig,
        session,
    ) -> list[Candidate]:
        """Return award-winning YouTube channels relevant to this country.

        The query parameter is ignored — channels are filtered by the
        country profile's country slug and languages.

        Channels without a country tag are still included (many award
        winners create content with global appeal).
        """
        if not self.enabled:
            return []

        candidates: list[Candidate] = []
        seen_ids: set[str] = set()
        country_slug = (profile.country or "").lower()
        profile_langs = set(profile.languages)

        for ch in self._channels:
            feed_url = ch.get("feed_url", "")
            channel_id = ch.get("channel_id", "")
            channel_name = ch.get("channel_name", "")
            # Collect relevant countries and languages from channel data
            ch_countries = ch.get("countries", [])
            ch_langs = ch.get("languages", [])

            # Dedup
            dedup_key = channel_id or feed_url
            if not dedup_key or dedup_key in seen_ids:
                continue

            # Filter: include if country matches OR language overlaps
            # If no country/language tags on the channel, include it
            matches_country = (
                not ch_countries
                or country_slug in (c.lower() for c in ch_countries)
            )
            matches_lang = (
                not ch_langs
                or bool(profile_langs & set(ch_langs))
            )

            if not matches_country and not matches_lang:
                continue

            seen_ids.add(dedup_key)

            source = ch.get("primary_award") or ch.get("award", "award")
            candidates.append(Candidate(
                url=feed_url,
                category="YouTube",
                title=channel_name,
                genre="",
                national=True,
                national_reason=f"youtube_awards:{source}",
            ))

        return candidates[:config.max_results]

    async def probe(
        self,
        profile: CountryProfile,
        config: SourceConfig,
        session,
    ) -> ProbeResult:
        """Check if this source has award data for the profile's country."""
        if not self.enabled:
            return ProbeResult(
                source_name="youtube_awards",
                success=False,
                result_count=0,
                latency_ms=0,
                error="disabled: data file not found",
            )

        t0 = time.monotonic()
        try:
            results = await self.search("", profile, config, session)
            elapsed = (time.monotonic() - t0) * 1000
            return ProbeResult(
                source_name="youtube_awards",
                success=len(results) > 0,
                result_count=len(results),
                latency_ms=elapsed,
            )
        except Exception as e:
            elapsed = (time.monotonic() - t0) * 1000
            return ProbeResult(
                source_name="youtube_awards",
                success=False,
                result_count=0,
                latency_ms=elapsed,
                error=str(e)[:200],
            )
