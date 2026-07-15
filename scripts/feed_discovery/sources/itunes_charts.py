# scripts/feed_discovery/sources/itunes_charts.py

from __future__ import annotations

import json
import re
import time
from urllib.parse import urlencode

import aiohttp

from ..models import Candidate
from ..profiles._schema import CountryProfile, SourceConfig
from ._base import ProbeResult


class ITunesChartsSource:
    """iTunes Top Podcasts Chart by country.

    Uses Apple's RSS feed (itunes.apple.com/{country}/rss/toppodcasts)
    to get the top 100 podcasts per country, then resolves each podcast's
    RSS feed URL via the iTunes Lookup API.

    Free, no authentication required. Covers ~150 countries.
    """

    name = "itunes_charts"
    CHART_URL = "https://itunes.apple.com/{country}/rss/toppodcasts/limit={limit}/explicit=true/json"
    LOOKUP_URL = "https://itunes.apple.com/lookup"

    # ISO2 → iTunes country code (most are the same, some differ)
    _ITUNES_COUNTRY_OVERRIDES: dict[str, str] = {
        "gb": "gb",  # United Kingdom
        "us": "us",
        "jp": "jp",
        "kr": "kr",
        "cn": "cn",
        "tw": "tw",
        "hk": "hk",
        "sg": "sg",
        "ae": "ae",
        "sa": "sa",
    }

    def __init__(self):
        self.enabled = True  # Always enabled — no API key required

    def _country_code(self, profile: CountryProfile) -> str | None:
        """Map Feedmine country slug to iTunes store country code."""
        # Try ISO2 from profile
        slug = (profile.country or "").lower()
        if slug in self._ITUNES_COUNTRY_OVERRIDES:
            return self._ITUNES_COUNTRY_OVERRIDES[slug]

        # Check if we have ISO2 in the profile indirectly
        iso2_map = {
            "algeria": "dz", "angola": "ao", "argentina": "ar",
            "australia": "au", "austria": "at", "belgium": "be",
            "brazil": "br", "bulgaria": "bg", "canada": "ca",
            "chile": "cl", "colombia": "co", "costa-rica": "cr",
            "czech-republic": "cz", "denmark": "dk", "ecuador": "ec",
            "egypt": "eg", "estonia": "ee", "finland": "fi",
            "france": "fr", "germany": "de", "greece": "gr",
            "hungary": "hu", "india": "in", "indonesia": "id",
            "ireland": "ie", "israel": "il", "italy": "it",
            "japan": "jp", "kazakhstan": "kz", "kenya": "ke",
            "latvia": "lv", "lithuania": "lt", "luxembourg": "lu",
            "malaysia": "my", "mexico": "mx", "netherlands": "nl",
            "new-zealand": "nz", "nigeria": "ng", "norway": "no",
            "peru": "pe", "philippines": "ph", "poland": "pl",
            "portugal": "pt", "romania": "ro", "russia": "ru",
            "saudi-arabia": "sa", "singapore": "sg", "slovakia": "sk",
            "south-africa": "za", "south-korea": "kr", "spain": "es",
            "sweden": "se", "switzerland": "ch", "taiwan": "tw",
            "thailand": "th", "turkey": "tr", "uae": "ae",
            "ukraine": "ua", "united-kingdom": "gb", "usa": "us",
            "venezuela": "ve", "vietnam": "vn",
        }
        return iso2_map.get(slug)

    def _extract_podcast_ids(self, data: dict) -> list[str]:
        """Extract podcast IDs from iTunes RSS feed JSON."""
        ids = []
        entries = data.get("feed", {}).get("entry", [])
        if isinstance(entries, dict):
            entries = [entries]

        for entry in entries:
            pod_id = entry.get("id", {})
            if isinstance(pod_id, dict):
                id_label = pod_id.get("label", "")
                # Extract numeric ID: id1498261768
                match = re.search(r"id(\d+)", id_label)
                if match:
                    ids.append(match.group(1))
        return ids

    async def _resolve_feed_urls(
        self, ids: list[str], session: aiohttp.ClientSession, timeout: int
    ) -> dict[str, dict]:
        """Batch-resolve podcast IDs to RSS feed URLs via iTunes Lookup."""
        results: dict[str, dict] = {}
        batch_size = 50

        for i in range(0, len(ids), batch_size):
            batch = ids[i : i + batch_size]
            # Don't use urlencode — iTunes API expects literal commas, not %2C
            url = f"{self.LOOKUP_URL}?id={','.join(batch)}"

            try:
                async with session.get(
                    url, timeout=aiohttp.ClientTimeout(total=timeout)
                ) as resp:
                    if resp.status != 200:
                        continue
                    text = await resp.text()
                    data = json.loads(text)
                    for item in data.get("results", []):
                        feed_url = item.get("feedUrl", "")
                        if feed_url:
                            results[feed_url] = {
                                "title": item.get("collectionName", ""),
                                "artist": item.get("artistName", ""),
                                "genre": item.get("primaryGenreName", ""),
                                "feed_url": feed_url,
                            }
            except Exception:
                continue

        return results

    async def search(
        self,
        query: str,
        profile: CountryProfile,
        config: SourceConfig,
        session: aiohttp.ClientSession,
    ) -> list[Candidate]:
        """Return top podcasts for the profile's country."""
        country_code = self._country_code(profile)
        if not country_code:
            return []

        limit = min(config.max_results, 100)
        chart_url = self.CHART_URL.format(country=country_code, limit=limit)

        # Step 1: Fetch top charts
        try:
            async with session.get(
                chart_url, timeout=aiohttp.ClientTimeout(total=config.timeout)
            ) as resp:
                if resp.status != 200:
                    return []
                text = await resp.text()
                data = json.loads(text)
        except Exception:
            return []

        # Step 2: Extract podcast IDs
        ids = self._extract_podcast_ids(data)
        if not ids:
            return []

        # Step 3: Resolve to RSS feed URLs
        feed_map = await self._resolve_feed_urls(ids, session, config.timeout)

        # Step 4: Build candidates
        candidates: list[Candidate] = []
        country_slug = (profile.country or "").lower()

        for feed_url, info in feed_map.items():
            candidates.append(Candidate(
                url=feed_url,
                category="Podcast",
                title=info["title"],
                genre=info.get("genre", ""),
                national=True,
                national_reason=f"itunes_charts:{country_code}",
            ))

        return candidates[:config.max_results]

    async def probe(
        self,
        profile: CountryProfile,
        config: SourceConfig,
        session: aiohttp.ClientSession,
    ) -> ProbeResult:
        """Probe iTunes charts for a country."""
        country_code = self._country_code(profile)
        if not country_code:
            return ProbeResult(
                source_name="itunes_charts", success=False,
                result_count=0, latency_ms=0,
                error=f"no itunes store for {profile.country}",
            )

        t0 = time.monotonic()
        country_slug = (profile.country or "").lower()
        try:
            results = await self.search("", profile, config, session)
            elapsed = (time.monotonic() - t0) * 1000
            return ProbeResult(
                source_name="itunes_charts",
                success=len(results) > 0,
                result_count=len(results),
                latency_ms=elapsed,
            )
        except Exception as e:
            elapsed = (time.monotonic() - t0) * 1000
            return ProbeResult(
                source_name="itunes_charts", success=False,
                result_count=0, latency_ms=elapsed,
                error=str(e)[:200],
            )
