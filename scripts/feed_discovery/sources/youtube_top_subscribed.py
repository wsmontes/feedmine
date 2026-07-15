# scripts/feed_discovery/sources/youtube_top_subscribed.py

from __future__ import annotations

import json
import time
from collections import defaultdict
from pathlib import Path

from ..models import Candidate
from ..profiles._schema import CountryProfile, SourceConfig
from ._base import ProbeResult


class YouTubeTopSubscribedSource:
    """Wikipedia "List of most-subscribed YouTube channels" across 24 languages.

    Reads pre-scraped data from youtube_channels_wikipedia.json and maps
    Wikipedia language editions to target countries via country profiles.

    Data is generated offline by scripts/youtube_wikipedia_scraper.py.
    No runtime API calls needed — purely static data lookup.

    This source is always enabled as long as the data file exists.
    """

    name = "youtube_top_subscribed"
    DATA_PATH = (
        Path(__file__).resolve().parents[1]
        / "data"
        / "youtube_channels_wikipedia.json"
    )
    COUNTRIES_PATH = (
        Path(__file__).resolve().parents[1] / "data" / "countries.json"
    )

    def __init__(self):
        self._channels: list[dict] = []
        self._by_lang: dict[str, list[dict]] = defaultdict(list)
        self._lang_to_countries: dict[str, list[str]] = {}
        self.enabled = self.DATA_PATH.exists()
        if self.enabled:
            self._load_data()
            self._build_lang_mapping()

    def _load_data(self):
        """Load channel data from the Wikipedia-scraped JSON."""
        try:
            data = json.loads(self.DATA_PATH.read_text(encoding="utf-8"))
            self._channels = data.get("channels", [])
        except Exception:
            self._channels = []

        self._by_lang = defaultdict(list)
        for ch in self._channels:
            if not ch.get("feed_url"):
                continue
            for lang in ch.get("wiki_langs", []):
                self._by_lang[lang].append(ch)

    def _build_lang_mapping(self):
        """Build language code → country slug mapping from countries.json."""
        if not self.COUNTRIES_PATH.exists():
            return
        try:
            countries = json.loads(self.COUNTRIES_PATH.read_text(encoding="utf-8"))
        except Exception:
            return

        for slug, data in countries.items():
            lang = data.get("lang", "")
            if lang:
                if lang not in self._lang_to_countries:
                    self._lang_to_countries[lang] = []
                self._lang_to_countries[lang].append(slug)

        # Manual overrides for languages without direct country matches
        overrides: dict[str, list[str]] = {
            "hi": ["india"],
            "gl": ["spain"],
            "pnb": ["pakistan"],
        }
        for lang, countries_list in overrides.items():
            for c in countries_list:
                if c not in self._lang_to_countries.get(lang, []):
                    if lang not in self._lang_to_countries:
                        self._lang_to_countries[lang] = []
                    self._lang_to_countries[lang].append(c)

    def _country_to_langs(self, country_slug: str) -> list[str]:
        """Find which Wikipedia languages are relevant for a country."""
        langs = []
        for lang, slugs in self._lang_to_countries.items():
            if country_slug in slugs:
                langs.append(lang)
        return langs

    async def search(
        self,
        query: str,
        profile: CountryProfile,
        config: SourceConfig,
        session,
    ) -> list[Candidate]:
        """Return top subscribed YouTube channels relevant to this country.

        The query parameter is ignored — channels are matched by the
        country's languages from the profile.

        Uses two matching strategies:
        1. Direct language match: profile.languages → Wikipedia language editions
        2. Country match: profile.country → lang-to-country mapping
        """
        if not self.enabled:
            return []

        candidates: list[Candidate] = []
        seen_ids: set[str] = set()

        # Collect relevant languages
        relevant_langs: set[str] = set()

        # Strategy 1: profile languages
        for lang in profile.languages:
            relevant_langs.add(lang)

        # Strategy 2: country → language mapping
        country_slug = (profile.country or "").lower()
        if country_slug and country_slug != "*":
            for lang in self._country_to_langs(country_slug):
                relevant_langs.add(lang)

        # Collect channels for relevant languages
        for lang in relevant_langs:
            lang_channels = self._by_lang.get(lang, [])
            for ch in lang_channels:
                feed_url = ch.get("feed_url", "")
                channel_id = ch.get("channel_id", "")
                channel_name = ch.get("channel_name", "")

                # Dedup by channel_id (preferred) or feed_url
                dedup_key = channel_id or feed_url
                if not dedup_key or dedup_key in seen_ids:
                    continue
                seen_ids.add(dedup_key)

                candidates.append(Candidate(
                    url=feed_url,
                    category="YouTube",
                    title=channel_name,
                    genre="",
                    national=True,
                    national_reason=f"wikipedia_top_subscribed:{lang}",
                ))

        # Limit to max_results
        return candidates[:config.max_results]

    async def probe(
        self,
        profile: CountryProfile,
        config: SourceConfig,
        session,
    ) -> ProbeResult:
        """Check if this source has data for the profile's country/languages."""
        if not self.enabled:
            return ProbeResult(
                source_name="youtube_top_subscribed",
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
                source_name="youtube_top_subscribed",
                success=len(results) > 0,
                result_count=len(results),
                latency_ms=elapsed,
            )
        except Exception as e:
            elapsed = (time.monotonic() - t0) * 1000
            return ProbeResult(
                source_name="youtube_top_subscribed",
                success=False,
                result_count=0,
                latency_ms=elapsed,
                error=str(e)[:200],
            )
