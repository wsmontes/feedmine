#!/usr/bin/env python3
"""
Scrape Wikipedia's "List of most-subscribed YouTube channels" for channels
with Diamond (10M+) and Red Diamond (100M+) Play Buttons.

Table includes: Name, Subscribers (millions), Language, Category, Country.
Resolves channel URLs (/channel/, /user/, /@) to channel IDs and RSS feeds.

Usage:
    python scripts/diamond_playbutton_scraper.py           # dry-run
    python scripts/diamond_playbutton_scraper.py --write   # save JSON
"""

from __future__ import annotations

import json
import re
import sys
import time
from pathlib import Path
from urllib.parse import urljoin

import requests
from bs4 import BeautifulSoup

# ── Paths ────────────────────────────────────────────────────────────────────
PROJECT_ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = PROJECT_ROOT / "scripts/feed_discovery/data"
OUTPUT_PATH = DATA_DIR / "youtube_channels_diamond.json"
WIKI_CHANNELS_PATH = DATA_DIR / "youtube_channels_wikipedia.json"

# ── Wikipedia ────────────────────────────────────────────────────────────────
WIKI_URL = "https://en.wikipedia.org/wiki/List_of_most-subscribed_YouTube_channels"
HEADERS = {
    "User-Agent": "Feedmine/1.0 (Diamond Play Button Scraper; contact@feedmine.app)",
}


def fetch_page() -> BeautifulSoup | None:
    try:
        resp = requests.get(WIKI_URL, timeout=30, headers=HEADERS)
        resp.raise_for_status()
        return BeautifulSoup(resp.text, "html.parser")
    except Exception as e:
        print(f"Failed to fetch: {e}", file=sys.stderr)
        return None


def load_known_channels() -> dict[str, dict]:
    """Load existing channel data for cross-reference. Returns {name_key: data}."""
    if not WIKI_CHANNELS_PATH.exists():
        return {}
    data = json.loads(WIKI_CHANNELS_PATH.read_text(encoding="utf-8"))
    by_name: dict[str, dict] = {}
    by_cid: dict[str, dict] = {}
    for ch in data.get("channels", []):
        name = ch.get("channel_name", "").lower().strip()
        cid = ch.get("channel_id", "")
        if cid:
            by_cid[cid] = ch
        if name:
            by_name[name] = ch
    # Merge dicts (cid-based preferred)
    result = dict(by_name)
    for cid, ch in by_cid.items():
        result[f"cid:{cid}"] = ch
    return result


def resolve_channel_id(youtube_url: str) -> str | None:
    """Extract channel ID from a YouTube URL, or resolve /user/ URLs."""
    # /channel/UC...
    cid = re.search(r'channel/(UC[\w-]{22})', youtube_url)
    if cid:
        return cid.group(1)

    # /@handle or /user/ — need to visit the page to extract channel ID
    try:
        resp = requests.get(youtube_url, timeout=15, headers={
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
        })
        resp.raise_for_status()
        for pattern in [
            r'"channelId"\s*:\s*"(UC[\w-]{22})"',
            r'"externalId"\s*:\s*"(UC[\w-]{22})"',
            r'browse_id\s*=\s*(UC[\w-]{22})',
            r'UC[\w-]{22}',  # Last resort — find any UC ID
        ]:
            match = re.search(pattern, resp.text)
            if match:
                return match.group(1) if '(' not in pattern else match.group(0)
    except Exception as e:
        print(f"    ⚠ Failed to resolve {youtube_url}: {e}", file=sys.stderr)
    return None


def main():
    write_mode = "--write" in sys.argv
    dry_run = not write_mode

    if dry_run:
        print("DRY RUN — use --write to save\n", file=sys.stderr)

    # Load known channels for cross-reference
    known_raw = load_known_channels()
    known: dict[str, dict] = {}
    known_ids: set[str] = set()
    for k, ch in known_raw.items():
        known[k] = ch
        cid = ch.get("channel_id", "")
        if cid:
            known_ids.add(cid)
            known[cid] = ch  # index by channel ID too
    print(f"Known channels loaded: {len(known_ids)} IDs", file=sys.stderr)

    soup = fetch_page()
    if not soup:
        sys.exit(1)

    table = soup.find_all("table", class_="wikitable")[0]
    if not table:
        print("No table found!", file=sys.stderr)
        sys.exit(1)

    channels = []
    resolved_count = 0
    from_known_count = 0

    for row in table.find_all("tr")[1:]:
        cells = row.find_all("td")
        if len(cells) < 7:
            continue

        name = cells[0].get_text(strip=True)

        # Extract YouTube channel URL from "Link" column
        link_cell = cells[1]
        yt_url = ""
        for a in link_cell.find_all("a", href=True):
            href = a["href"]
            if "youtube.com" in href:
                yt_url = urljoin(WIKI_URL, href)
                break

        subs_text = cells[2].get_text(strip=True)  # millions
        language = cells[3].get_text(strip=True)
        category = cells[4].get_text(strip=True)
        country = cells[6].get_text(strip=True)

        # Parse subscriber count
        subs_millions = 0
        try:
            subs_millions = float(subs_text.replace(",", "").replace("~", ""))
        except ValueError:
            pass

        # Determine play button level
        if subs_millions >= 100:
            play_button = "red_diamond"  # 100M+
        elif subs_millions >= 50:
            play_button = "red_diamond_legacy"  # 50M+ (old threshold)
        elif subs_millions >= 10:
            play_button = "diamond"  # 10M+
        else:
            play_button = "gold"  # Below diamond threshold — skip

        # Resolve channel ID
        channel_id = ""
        feed_url = ""

        # Strategy 1: Extract from /channel/ URL
        cid = re.search(r'channel/(UC[\w-]{22})', yt_url)
        if cid:
            channel_id = cid.group(1)
            resolved_count += 1

        # Strategy 2: Check known channels JSON by name match
        if not channel_id:
            name_key = name.lower().strip()
            if name_key in known:
                channel_id = known[name_key].get("channel_id", "")
                if channel_id:
                    from_known_count += 1

        # Strategy 3: Resolve /user/ or /@ URL by visiting YouTube
        if not channel_id and yt_url and write_mode:
            channel_id = resolve_channel_id(yt_url) or ""
            if channel_id:
                resolved_count += 1
            time.sleep(0.5)

        if channel_id:
            feed_url = f"https://www.youtube.com/feeds/videos.xml?channel_id={channel_id}"

        channels.append({
            "channel_name": name,
            "channel_id": channel_id,
            "feed_url": feed_url,
            "youtube_url": yt_url,
            "subscribers_millions": subs_millions,
            "play_button": play_button,
            "language": language,
            "category": category,
            "country": country,
        })

    # ── Summary ────────────────────────────────────────────────────────────
    with_cid = sum(1 for c in channels if c["channel_id"])
    with_feed = sum(1 for c in channels if c["feed_url"])
    by_button: dict[str, int] = {}
    for c in channels:
        by_button[c["play_button"]] = by_button.get(c["play_button"], 0) + 1

    print(f"\n{'='*60}", file=sys.stderr)
    print(f"Channels in table: {len(channels)}", file=sys.stderr)
    print(f"Resolved from URL: {resolved_count}", file=sys.stderr)
    print(f"Resolved from known: {from_known_count}", file=sys.stderr)
    print(f"With channel ID: {with_cid}", file=sys.stderr)
    print(f"With feed URL: {with_feed}", file=sys.stderr)
    for btn, count in sorted(by_button.items()):
        print(f"  {btn}: {count} channels", file=sys.stderr)

    # Show top channels
    print(f"\nTop 10:", file=sys.stderr)
    for c in channels[:10]:
        print(f"  {c['channel_name'][:35]:35s} {c['subscribers_millions']:6.0f}M {c['play_button']:20s} {c['country']}", file=sys.stderr)

    output = {
        "metadata": {
            "source": "Wikipedia: List of most-subscribed YouTube channels",
            "total_channels": len(channels),
            "with_channel_id": with_cid,
            "with_feed_url": with_feed,
            "resolved_count": resolved_count,
            "from_known_count": from_known_count,
        },
        "channels": channels,
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
