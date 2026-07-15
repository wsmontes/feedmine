#!/usr/bin/env python3
"""
Scrape Social Blade's public YouTube top-50-by-country pages for channel data.

Produces a JSON file consumed by the YouTubeSocialBladeSource.
Channel IDs are extracted directly from the table rows — no API calls needed.

Usage:
    python scripts/socialblade_scraper.py           # dry-run
    python scripts/socialblade_scraper.py --write   # save JSON
"""

from __future__ import annotations

import json
import re
import sys
import time
from collections import defaultdict
from pathlib import Path

import requests
from bs4 import BeautifulSoup

# ── Paths ────────────────────────────────────────────────────────────────────
PROJECT_ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = PROJECT_ROOT / "scripts/feed_discovery/data"
OUTPUT_PATH = DATA_DIR / "youtube_channels_socialblade.json"
COUNTRIES_PATH = DATA_DIR / "countries.json"

# ── Social Blade ─────────────────────────────────────────────────────────────
SB_BASE = "https://socialblade.com/youtube/top/country"
HEADERS = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                  "AppleWebKit/537.36 (KHTML, like Gecko) "
                  "Chrome/120.0.0.0 Safari/537.36",
}

# Feedmine country slug → Social Blade ISO2 code
# (most are the same ISO2; overrides for differences)
SLUG_TO_ISO2: dict[str, str] = {}


def load_country_iso2_map() -> dict[str, str]:
    """Build {slug: iso2} from Feedmine's countries.json."""
    if not COUNTRIES_PATH.exists():
        return {}
    countries = json.loads(COUNTRIES_PATH.read_text(encoding="utf-8"))
    return {
        slug: data.get("iso2", "").upper()
        for slug, data in countries.items()
        if data.get("iso2")
    }


def scrape_country(iso2: str) -> list[dict]:
    """Scrape top 50 YouTube channels for a country from Social Blade."""
    url = f"{SB_BASE}/{iso2.lower()}"
    try:
        resp = requests.get(url, timeout=30, headers=HEADERS)
        resp.raise_for_status()
    except Exception as e:
        print(f"  ⚠ {iso2}: {e}", file=sys.stderr)
        return []

    soup = BeautifulSoup(resp.text, "html.parser")
    table = soup.find("table")
    if not table:
        print(f"  ⚠ {iso2}: no table found", file=sys.stderr)
        return []

    channels = []
    for row in table.find_all("tr")[1:]:  # skip header
        cells = row.find_all("td")
        if len(cells) < 4:
            continue

        name_cell = cells[1] if len(cells) > 1 else None
        name = name_cell.get_text(strip=True) if name_cell else ""

        # Extract handle from link
        handle = ""
        if name_cell:
            link = name_cell.find("a", href=True)
            if link:
                handle = link["href"].split("/")[-1]

        # Extract channel ID from row HTML
        row_html = str(row)
        cid_match = re.search(r'UC[\w-]{22}', row_html)
        channel_id = cid_match.group(0) if cid_match else ""

        if not channel_id:
            continue

        channels.append({
            "channel_id": channel_id,
            "channel_name": name,
            "handle": handle,
            "feed_url": f"https://www.youtube.com/feeds/videos.xml?channel_id={channel_id}",
            "subscribers_text": cells[2].get_text(strip=True) if len(cells) > 2 else "",
            "views_text": cells[3].get_text(strip=True) if len(cells) > 3 else "",
        })

    return channels


def main():
    write_mode = "--write" in sys.argv
    dry_run = not write_mode

    slug_to_iso2 = load_country_iso2_map()
    print(f"Feedmine countries: {len(slug_to_iso2)}", file=sys.stderr)

    if dry_run:
        print("DRY RUN — use --write to save\n", file=sys.stderr)

    all_by_country: dict[str, list[dict]] = {}
    total_channels = 0

    # Only scrape countries that have ISO2 codes
    countries_to_scrape = sorted(slug_to_iso2.items())

    print("Scraping Social Blade top 50 per country...\n", file=sys.stderr)

    for i, (slug, iso2) in enumerate(countries_to_scrape):
        if i > 0 and i % 10 == 0:
            time.sleep(1)  # Rate limit

        channels = scrape_country(iso2)
        if channels:
            all_by_country[slug] = channels
            total_channels += len(channels)
            top3 = ", ".join(c["channel_name"][:30] for c in channels[:3])
            print(f"  {slug} ({iso2}): {len(channels)} channels — {top3}", file=sys.stderr)
        else:
            print(f"  {slug} ({iso2}): 0 channels", file=sys.stderr)

        time.sleep(0.3)  # Rate limit

    # ── Summary ────────────────────────────────────────────────────────────
    print(f"\n{'='*60}", file=sys.stderr)
    print(f"Countries scraped: {len(all_by_country)}", file=sys.stderr)
    print(f"Total channels: {total_channels}", file=sys.stderr)

    # Build output with both per-country and flat list
    flat_channels: dict[str, dict] = {}  # channel_id → channel_data
    for slug, channels in all_by_country.items():
        for ch in channels:
            cid = ch["channel_id"]
            if cid not in flat_channels:
                flat_channels[cid] = {
                    "channel_id": cid,
                    "channel_name": ch["channel_name"],
                    "handle": ch["handle"],
                    "feed_url": ch["feed_url"],
                    "countries": [slug],
                }
            else:
                if slug not in flat_channels[cid]["countries"]:
                    flat_channels[cid]["countries"].append(slug)

    unique_channels = list(flat_channels.values())

    output = {
        "metadata": {
            "source": "Social Blade public top-50 by country",
            "countries_scraped": len(all_by_country),
            "total_channel_entries": total_channels,
            "unique_channels": len(unique_channels),
        },
        "by_country": all_by_country,
        "channels": unique_channels,
    }

    if write_mode:
        OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
        OUTPUT_PATH.write_text(
            json.dumps(output, indent=2, ensure_ascii=False),
            encoding="utf-8",
        )
        print(f"\n✓ Written to {OUTPUT_PATH}", file=sys.stderr)
    else:
        print("\nDRY RUN complete. Use --write to save.", file=sys.stderr)


if __name__ == "__main__":
    main()
