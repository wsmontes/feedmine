# scripts/feed_discovery/sources/youtube_diamond.py

from __future__ import annotations

import json
import time
from pathlib import Path

from ..models import Candidate
from ..profiles._schema import CountryProfile, SourceConfig
from ._base import ProbeResult


class YouTubeDiamondSource:
    """Wikipedia top-100 most-subscribed YouTube channels (Diamond Play Button).

    All 100 channels have 50M+ subscribers. Includes country, language,
    and category metadata. Data scraped from Wikipedia's
    "List of most-subscribed YouTube channels" page.

    Zero API calls — purely local JSON lookup.
    """

    name = "youtube_diamond"
    DATA_PATH = (
        Path(__file__).resolve().parents[1]
        / "data"
        / "youtube_channels_diamond.json"
    )

    def __init__(self):
        self._channels: list[dict] = []
        self.enabled = self.DATA_PATH.exists()
        if self.enabled:
            self._load_data()

    def _load_data(self):
        try:
            data = json.loads(self.DATA_PATH.read_text(encoding="utf-8"))
            self._channels = data.get("channels", [])
        except Exception:
            self._channels = []

    async def search(
        self, query: str, profile: CountryProfile, config: SourceConfig, session,
    ) -> list[Candidate]:
        if not self.enabled:
            return []

        country_slug = (profile.country or "").lower()
        candidates: list[Candidate] = []
        seen: set[str] = set()

        for ch in self._channels:
            feed_url = ch.get("feed_url", "")
            cid = ch.get("channel_id", "")
            if not feed_url or cid in seen:
                continue
            seen.add(cid)

            ch_country = (ch.get("country") or "").lower()
            play_button = ch.get("play_button", "")
            subs = ch.get("subscribers_millions", 0)

            # These are global top channels — include for all countries
            # but boost relevance for matching country
            candidates.append(Candidate(
                url=feed_url,
                category="YouTube",
                title=ch.get("channel_name", ""),
                genre="",
                national=ch_country == country_slug,
                national_reason=f"diamond_{play_button}:{int(subs)}M:{ch_country}",
            ))

        return candidates[:config.max_results]

    async def probe(self, profile, config, session) -> ProbeResult:
        if not self.enabled:
            return ProbeResult(
                source_name="youtube_diamond", success=False,
                result_count=0, latency_ms=0,
                error="disabled: data file not found",
            )
        t0 = time.monotonic()
        try:
            results = await self.search("", profile, config, session)
            elapsed = (time.monotonic() - t0) * 1000
            return ProbeResult(
                source_name="youtube_diamond",
                success=len(results) > 0,
                result_count=len(results),
                latency_ms=elapsed,
            )
        except Exception as e:
            return ProbeResult(
                source_name="youtube_diamond", success=False,
                result_count=0, latency_ms=(time.monotonic() - t0) * 1000,
                error=str(e)[:200],
            )
