#!/usr/bin/env python3
"""
Populate OPMLs using ONLY static ranking sources (no API keys needed).

Sources used:
  - youtube_top_subscribed  (795 Wikipedia channels)
  - youtube_awards          (45 award-winning channels)
  - youtube_kaggle          (3,964 top channels by country)
  - youtube_socialblade     (5,050 top-50 per country, 101 countries)

Usage:
    python scripts/populate_ranking_opmls.py           # dry-run
    python scripts/populate_ranking_opmls.py --write   # actually update OPMLs
"""

from __future__ import annotations

import asyncio
import json
import sys
import time
from pathlib import Path

# Ensure project root is on the Python path
_project_root = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_project_root))

import aiohttp

PROJECT_ROOT = _project_root
OPML_BASE = PROJECT_ROOT / "feedmine" / "Resources" / "Feeds" / "countries"
ENRICHED_PATH = PROJECT_ROOT / "scripts/feed_discovery/data" / "countries_enriched.json"

# Load enriched country data
if not ENRICHED_PATH.exists():
    print("Run enrich first: python -m scripts.feed_discovery.subregion.enrich_countries")
    sys.exit(1)

enriched = json.loads(ENRICHED_PATH.read_text(encoding="utf-8"))

# Subregion OPML writer
from scripts.feed_discovery.subregion.opml_writer import write_subregion_opml, read_existing_feeds


def remove_feeds_from_opml(opml_path: Path, urls_to_remove: set[str]) -> int:
    """Remove feeds with matching URLs from an OPML file. Returns count removed."""
    if not opml_path.exists() or not urls_to_remove:
        return 0

    import xml.etree.ElementTree as ET
    from scripts.feed_discovery.opml import normalize_url

    try:
        tree = ET.parse(str(opml_path))
    except ET.ParseError:
        return 0

    root = tree.getroot()
    body = root.find("body")
    if body is None:
        return 0

    removed = 0
    # Collect all (parent, child) pairs to remove
    to_remove: list[tuple] = []
    for parent in body.iter("outline"):
        for child in list(parent):
            xml_url = child.get("xmlUrl", "")
            if xml_url and normalize_url(xml_url) in urls_to_remove:
                to_remove.append((parent, child))

    for parent, child in to_remove:
        parent.remove(child)
        removed += 1

    if removed > 0:
        from scripts.feed_discovery.subregion.opml_writer import _indent_xml
        _indent_xml(root)
        raw = ET.tostring(root, encoding="unicode")
        opml_path.write_text(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            + raw.split("?>", 1)[-1].lstrip(),
            encoding="utf-8",
        )
    return removed


async def run_country(slug: str, data: dict, session: aiohttp.ClientSession):
    """Run ranking sources for one country and write to OPMLs."""
    from scripts.feed_discovery.profiles._schema import CountryProfile, SourceConfig
    from scripts.feed_discovery.models import Candidate, SubRegion
    from scripts.feed_discovery.sources.youtube_top_subscribed import YouTubeTopSubscribedSource
    from scripts.feed_discovery.sources.youtube_awards import YouTubeAwardsSource
    from scripts.feed_discovery.sources.youtube_kaggle import YouTubeKaggleSource
    from scripts.feed_discovery.sources.youtube_socialblade import YouTubeSocialBladeSource
    from scripts.feed_discovery.sources.youtube_diamond import YouTubeDiamondSource
    from scripts.feed_discovery.sources.itunes_charts import ITunesChartsSource
    from scripts.feed_discovery.sources.podcast_index import PodcastIndexSource
    from scripts.feed_discovery.sources.google_news import GoogleNewsSource

    sources = [
        GoogleNewsSource(),
        PodcastIndexSource(),
        ITunesChartsSource(),
        YouTubeTopSubscribedSource(),
        YouTubeAwardsSource(),
        YouTubeKaggleSource(),
        YouTubeSocialBladeSource(),
        YouTubeDiamondSource(),
    ]

    subregions = data.get("subregions", [])
    if not subregions:
        return {"country": slug, "added": 0}

    country_name = data["name"]
    native_name = data.get("native_name", country_name)
    profile = CountryProfile(country=slug, languages=data.get("languages", []))

    total_added = 0

    # Collect all unique candidates from ranking sources (shared across sub-regions)
    all_candidates: list[Candidate] = []
    seen: set[str] = set()

    for source in sources:
        if not source.enabled:
            continue
        config = SourceConfig(priority=99, timeout=15, max_results=50)

        try:
            # Build query from country name — sources like podcast_index need it
            q = f"{country_name} podcast"
            candidates = await source.search(q, profile, config, session)
        except Exception:
            continue

        for c in candidates:
            from scripts.feed_discovery.opml import normalize_url
            norm = normalize_url(c.url)
            if norm in seen:
                continue
            seen.add(norm)
            all_candidates.append(c)

    # Write to national OPML first (e.g., brazil/brazil.opml)
    national_opml = OPML_BASE / slug / f"{slug}.opml"
    if all_candidates:
        try:
            existing_national = read_existing_feeds(national_opml) if national_opml.exists() else set()
            new_national = [c for c in all_candidates if normalize_url(c.url) not in existing_national]
            if new_national:
                written = write_subregion_opml(national_opml, new_national)
                total_added += written
        except Exception:
            pass

    # Reload national URLs after writing (so sub-regions know what's already national)
    national_urls = read_existing_feeds(national_opml) if national_opml.exists() else set()

    # Cleanup: remove from sub-regions any feeds already in the national OPML
    # Rule: if it's in national AND sub-region, national wins — remove from sub-region
    cleanup_total = 0
    for sd in subregions:
        opml_path = Path(sd["opml_path"])
        removed = remove_feeds_from_opml(opml_path, national_urls)
        cleanup_total += removed

    # Write new candidates to each sub-region — skip channels already in national
    for sd in subregions:
        opml_path = Path(sd["opml_path"])
        existing = read_existing_feeds(opml_path) if opml_path.exists() else set()

        sub_candidates = [
            c for c in all_candidates
            if normalize_url(c.url) not in existing
            and normalize_url(c.url) not in national_urls
        ]
        if sub_candidates:
            written = write_subregion_opml(opml_path, sub_candidates)
            total_added += written

    total_added += cleanup_total

    return {"country": slug, "added": total_added}


async def main():
    write_mode = "--write" in sys.argv

    if not write_mode:
        print("DRY RUN — use --write to update OPMLs\n")

    sorted_countries = sorted(
        enriched.keys(),
        key=lambda s: enriched[s].get("population", 0),
        reverse=True,
    )

    connector = aiohttp.TCPConnector(limit=25)
    async with aiohttp.ClientSession(connector=connector) as session:
        for slug in sorted_countries:
            data = enriched[slug]
            subregions = data.get("subregions", [])
            if not subregions:
                continue

            t0 = time.monotonic()
            result = await run_country(slug, data, session)
            elapsed = time.monotonic() - t0

            if result["added"] > 0:
                print(f"  {slug} ({data['name']}): +{result['added']} feeds "
                      f"[{'DRY RUN' if not write_mode else '✓'}] in {elapsed:.0f}s")
            else:
                print(f"  {slug} ({data['name']}): no new feeds [{elapsed:.0f}s]")

    print("\nDone!" if write_mode else "\nDRY RUN complete. Use --write to apply.")


if __name__ == "__main__":
    asyncio.run(main())
