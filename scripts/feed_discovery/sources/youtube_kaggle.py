# scripts/feed_discovery/sources/youtube_kaggle.py

from __future__ import annotations

import csv
import json
import time
from collections import defaultdict
from pathlib import Path

from ..models import Candidate
from ..profiles._schema import CountryProfile, SourceConfig
from ._base import ProbeResult


class YouTubeKaggleSource:
    """Kaggle "Top YouTube Channels: Global & Country-Wise (2026)" dataset.

    Reads pre-downloaded CSV data with ranked YouTube channels per country.
    Data from: https://www.kaggle.com/datasets/yusufmurtaza01/youtube-top-channels-2026

    Fields: Country Rank, Global Rank, Channel ID, Channel Name,
            Subscribers, Total Views, Total Videos, Country (ISO2)

    Covers 30 countries with top 100 channels each, plus global top 4K.
    All channels have verified Channel IDs — no API calls needed.
    """

    name = "youtube_kaggle"
    DATA_DIR = Path(__file__).resolve().parents[1] / "data" / "youtube_kaggle"

    # ISO2 → Feedmine country slug (built from countries.json at init)
    _ISO2_TO_SLUG: dict[str, str] = {}

    def __init__(self):
        self._by_iso2: dict[str, list[dict]] = defaultdict(list)
        self._global: list[dict] = []
        self.enabled = self.DATA_DIR.exists()
        if self.enabled:
            self._load_country_mapping()
            self._load_data()

    def _load_country_mapping(self):
        """Build ISO2 → country slug from Feedmine's countries.json."""
        countries_path = self.DATA_DIR.parent / "countries.json"
        if not countries_path.exists():
            return
        try:
            countries = json.loads(countries_path.read_text(encoding="utf-8"))
        except Exception:
            return
        for slug, data in countries.items():
            iso2 = data.get("iso2", "").upper()
            if iso2:
                self._ISO2_TO_SLUG[iso2] = slug

    def _load_data(self):
        """Load the country-wise top 100 CSV and global top 4K CSV."""
        # Primary: country-wise top 100
        country_csv = self.DATA_DIR / "top100_channels_by_country.csv"
        if country_csv.exists():
            with open(country_csv, encoding="utf-8", newline="") as f:
                reader = csv.DictReader(f)
                for row in reader:
                    iso2 = (row.get("Country Code") or "").strip().upper()
                    cid = (row.get("Channel ID") or "").strip()
                    if not cid or not cid.startswith("UC"):
                        continue
                    ch = {
                        "channel_id": cid,
                        "channel_name": (row.get("Channel Name") or "").strip(),
                        "feed_url": f"https://www.youtube.com/feeds/videos.xml?channel_id={cid}",
                        "country_rank": int(row.get("Country Rank", 0) or 0),
                        "global_rank": int(row.get("Global Rank", 0) or 0),
                        "subscribers": int_or_0(row.get("Subscribers", "")),
                        "total_views": int_or_0(row.get("Total Views", "")),
                        "country_iso2": iso2,
                    }
                    self._by_iso2[iso2].append(ch)

        # Fallback: global top 4K for countries not in top 100
        global_csv = self.DATA_DIR / "global_top4k.csv"
        if global_csv.exists():
            with open(global_csv, encoding="utf-8", newline="") as f:
                reader = csv.DictReader(f)
                for row in reader:
                    cid = (row.get("Channel ID") or "").strip()
                    if not cid or not cid.startswith("UC"):
                        continue
                    country = (row.get("Country") or "").strip().upper()
                    ch = {
                        "channel_id": cid,
                        "channel_name": (row.get("Channel Name") or "").strip(),
                        "feed_url": f"https://www.youtube.com/feeds/videos.xml?channel_id={cid}",
                        "country_rank": 0,
                        "global_rank": int(row.get("Global Rank", 0) or 0),
                        "subscribers": int_or_0(row.get("Subscribers", "")),
                        "total_views": int_or_0(row.get("Total Views", "")),
                        "country_iso2": country,
                    }
                    self._global.append(ch)

    async def search(
        self,
        query: str,
        profile: CountryProfile,
        config: SourceConfig,
        session,
    ) -> list[Candidate]:
        """Return ranked YouTube channels for the profile's country."""
        if not self.enabled:
            return []

        country_slug = (profile.country or "").lower()
        candidates: list[Candidate] = []
        seen: set[str] = set()

        # Determine ISO2 from country profile
        iso2 = ""
        for code, slug in self._ISO2_TO_SLUG.items():
            if slug == country_slug:
                iso2 = code
                break

        channels = []

        # Strategy 1: Country-specific top 100
        if iso2 and iso2 in self._by_iso2:
            channels = sorted(self._by_iso2[iso2],
                              key=lambda c: c["country_rank"])
        elif iso2:
            # Strategy 2: Global top 4K filtered by country
            channels = [ch for ch in self._global
                        if ch["country_iso2"] == iso2]
            channels.sort(key=lambda c: c["global_rank"])

        if not channels:
            # Strategy 3: Top global channels for this country's languages
            # (broad coverage — any country gets top global English channels)
            channels = sorted(self._global,
                              key=lambda c: c["global_rank"])[:100]

        for ch in channels:
            cid = ch["channel_id"]
            if cid in seen:
                continue
            seen.add(cid)

            rank_info = f"kaggle:g{ch['global_rank']}"
            if ch["country_rank"]:
                rank_info += f"/c{ch['country_rank']}"

            candidates.append(Candidate(
                url=ch["feed_url"],
                category="YouTube",
                title=ch["channel_name"],
                genre="",
                national=True,
                national_reason=rank_info,
            ))

        return candidates[:config.max_results]

    async def probe(
        self,
        profile: CountryProfile,
        config: SourceConfig,
        session,
    ) -> ProbeResult:
        """Check if this source has data for the profile's country."""
        if not self.enabled:
            return ProbeResult(
                source_name="youtube_kaggle",
                success=False,
                result_count=0,
                latency_ms=0,
                error="disabled: data dir not found",
            )

        t0 = time.monotonic()
        try:
            results = await self.search("", profile, config, session)
            elapsed = (time.monotonic() - t0) * 1000
            return ProbeResult(
                source_name="youtube_kaggle",
                success=len(results) > 0,
                result_count=len(results),
                latency_ms=elapsed,
            )
        except Exception as e:
            elapsed = (time.monotonic() - t0) * 1000
            return ProbeResult(
                source_name="youtube_kaggle",
                success=False,
                result_count=0,
                latency_ms=elapsed,
                error=str(e)[:200],
            )


def int_or_0(val: str) -> int:
    """Parse int, return 0 on failure."""
    try:
        return int(float(val))
    except (ValueError, TypeError):
        return 0
