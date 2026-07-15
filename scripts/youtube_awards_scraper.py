#!/usr/bin/env python3
"""
Discover NEW YouTube channels from Streamy/Shorty/Webby Awards winners.

Extracts creator names from Wikipedia awards tables, then resolves
UNMATCHED names to YouTube channel IDs using the YouTube Data API v3.
Channels already in youtube_channels_wikipedia.json are skipped —
the goal is to discover award-winning channels we don't already have.

Usage:
    python3 scripts/youtube_awards_scraper.py           # dry-run
    python3 scripts/youtube_awards_scraper.py --write   # resolve & save
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
from collections import defaultdict
from pathlib import Path
from urllib.parse import urlencode

import requests
from bs4 import BeautifulSoup

# ── Paths ────────────────────────────────────────────────────────────────────
PROJECT_ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = PROJECT_ROOT / "scripts/feed_discovery/data"
OUTPUT_PATH = DATA_DIR / "youtube_channels_awards.json"
WIKI_CHANNELS_PATH = DATA_DIR / "youtube_channels_wikipedia.json"

# ── Awards pages ─────────────────────────────────────────────────────────────
STREAMY_YEARS = range(1, 14)   # 1st–13th Streamy Awards
SHORTY_YEARS = range(1, 14)    # 1st–13th Shorty Awards
WEBBY_URL = "https://en.wikipedia.org/wiki/List_of_Webby_Award_winners"

# ── YouTube API ──────────────────────────────────────────────────────────────
YT_API_KEY = os.getenv("YOUTUBE_API_KEY", "")
YT_SEARCH_URL = "https://www.googleapis.com/youtube/v3/search"
YT_CHANNELS_URL = "https://www.googleapis.com/youtube/v3/channels"


def fetch_page(url: str) -> BeautifulSoup | None:
    try:
        resp = requests.get(url, timeout=30, headers={
            "User-Agent": "Feedmine/1.0 (Awards Scraper; contact@feedmine.app)",
        })
        resp.raise_for_status()
        return BeautifulSoup(resp.text, "html.parser")
    except Exception as e:
        print(f"  ⚠ {e}", file=sys.stderr)
        return None


def load_known_channel_ids() -> set[str]:
    """Load channel IDs we already have, so we skip them."""
    if not WIKI_CHANNELS_PATH.exists():
        return set()
    data = json.loads(WIKI_CHANNELS_PATH.read_text(encoding="utf-8"))
    return {ch.get("channel_id", "") for ch in data.get("channels", [])
            if ch.get("channel_id")}


def load_known_names() -> dict[str, dict]:
    """Index known channels by normalized name for dedup."""
    if not WIKI_CHANNELS_PATH.exists():
        return {}
    data = json.loads(WIKI_CHANNELS_PATH.read_text(encoding="utf-8"))
    name_map: dict[str, dict] = {}
    for ch in data.get("channels", []):
        name = normalize_name(ch.get("channel_name", ""))
        if name:
            name_map[name] = ch
    return name_map


def normalize_name(name: str) -> str:
    return re.sub(r'\s+', '', name.lower().strip())


# ── Name extraction from Wikipedia tables ───────────────────────────────────

_STOP_WORDS = {
    "show of the year", "creator of the year", "streamer of the year",
    "international", "short form", "winner", "winners", "nominee", "nominees",
    "category", "categories", "overall awards", "brand of the year",
    "agency of the year", "branded series", "branded video",
    "influencer campaign", "social impact campaign", "artist(s)", "song(s)",
    "reference", "references", "notes", "see also", "external links",
    "best in", "youtube star", "youtuber of the year", "best in show",
    "video", "music", "sports", "news", "entertainment",
    "people's voice", "webby winner", "webby award",
    # Category labels that aren't creator names
    "overall", "performance", "food", "comedy", "beauty", "dance",
    "kids and family", "animated", "first person", "collaboration",
    "cinematography", "editing", "visual and special effects",
    "writing", "health and wellness", "lifestyle", "fashion",
    "technology", "science", "education", "sports", "gaming",
    "music video", "breakout creator", "best celebrity",
    "best in music", "best in food", "best in science",
    "best in weird", "best in apps", "best in green",
    "web series", "indie series", "scripted series",
    "unscripted series", "documentary", "ensemble cast",
    "cover song", "breakthrough artist", "brand engagement",
    "costume design", "directing", "podcast", "tube",
    "acting", "acting in a comedy", "acting in a drama",
    "live", "vr", "360", "snapchat", "twitter", "instagram",
    "facebook", "tiktok", "twitch", "vimeo",
}

# Category-like patterns — single words or short all-caps phrases
_CATEGORY_PATTERNS = [
    re.compile(r'^[A-Z]{2,}$'),           # ALL CAPS short (OVERALL, VR)
    re.compile(r'^[A-Z][a-z]+$'),          # Single capitalized word (Food, Comedy)
    re.compile(r'^best in\b', re.I),       # "Best in X"
    re.compile(r'^best\b', re.I),          # "Best X"
]


def extract_names(soup: BeautifulSoup) -> list[tuple[str, str]]:
    """Extract (name, category) from wikitable cells."""
    results: list[tuple[str, str]] = []
    seen: set[str] = set()

    for table in soup.find_all("table", class_="wikitable"):
        rows = table.find_all("tr")
        if len(rows) < 3:
            continue

        current_category = ""
        for row in rows:
            cells = row.find_all(["td", "th"])
            for cell in cells:
                text = cell.get_text(strip=True)
                if not text or len(text) < 2 or len(text) > 80:
                    continue
                if text.lower() in _STOP_WORDS:
                    # Might be a category header
                    if len(text) < 40:
                        current_category = text
                    continue

                tokens = _split_concatenated(text)
                for token in tokens:
                    token = token.strip()
                    if token and token not in seen and _looks_like_name(token):
                        seen.add(token)
                        results.append((token, current_category))
    return results


def _split_concatenated(text: str) -> list[str]:
    """Split concatenated names like 'MrBeastAirrackAlix Earle'."""
    if '\n' in text:
        return [t.strip() for t in text.split('\n') if t.strip()]
    # lowercase→UPPERCASE boundary = new name
    parts = re.split(r'(?<=[a-z])(?=[A-Z])', text)
    result = []
    current = ""
    for part in parts:
        if not part:
            continue
        if current and part[0].islower():
            current += part
        elif current:
            result.append(current.strip())
            current = part
        else:
            current = part
    if current:
        result.append(current.strip())
    return [r for r in result if len(r) >= 3 and not r.startswith('(')]


def _looks_like_name(text: str) -> bool:
    if len(text) < 3 or len(text) > 60:
        return False
    if text[0].islower() and text[:3] not in ("iOS", "mac", "the"):
        return False
    if re.search(r'^https?://', text):
        return False
    if re.match(r'^[0-9\s,.]+$', text):
        return False
    if re.search(r'(award|ceremony|nomination|category|winner)', text, re.I):
        return False
    # Song titles
    if text.startswith('"') or text.endswith('"'):
        return False
    if re.search(r'"[^"]*"', text):
        return False
    # Hashtags, Twitter handles
    if text.startswith('#') or text.startswith('@'):
        return False
    # Parenthetical citations
    if re.search(r'\[\d+\]|\[better|citation needed', text):
        return False
    # ALL CAPS (possibly with spaces) like "SOCIAL VIDEO", "VIRTUAL REALITY"
    if re.match(r'^[A-Z\s]{3,}$', text) and text == text.upper():
        return False
    # Starts with "Best" — category label
    if re.match(r'^Best\s', text):
        return False
    # Common noise words that slip through as fragments
    if text.lower() in {"the", "you", "life", "die", "pie", "fed", "source",
                         "justine", "about", "they", "what", "your", "this",
                         "that", "with", "from", "have", "been", "were"}:
        return False
    # Stops words check
    if text.lower() in _STOP_WORDS:
        return False
    return True


# ── YouTube API resolution ──────────────────────────────────────────────────

def resolve_name_to_channel(name: str) -> dict | None:
    """Use YouTube Data API to find a channel by creator name.

    Returns dict with channel_id, channel_name, feed_url or None.
    """
    if not YT_API_KEY:
        return None

    # Step 1: Search for the channel
    params = {
        "part": "snippet",
        "type": "channel",
        "q": name,
        "maxResults": 1,
        "key": YT_API_KEY,
    }
    try:
        resp = requests.get(
            f"{YT_SEARCH_URL}?{urlencode(params)}",
            timeout=10,
        )
        if resp.status_code != 200:
            return None
        data = resp.json()
        items = data.get("items", [])
        if not items:
            return None
        cid = items[0]["snippet"]["channelId"]
        ctitle = items[0]["snippet"]["title"]
    except Exception:
        return None

    # Step 2: Get channel details (brandingSettings for country)
    params2 = {
        "part": "snippet,brandingSettings",
        "id": cid,
        "key": YT_API_KEY,
    }
    try:
        resp2 = requests.get(
            f"{YT_CHANNELS_URL}?{urlencode(params2)}",
            timeout=10,
        )
        if resp2.status_code != 200:
            return None
        data2 = resp2.json()
        items2 = data2.get("items", [])
        if not items2:
            return None
        channel = items2[0]
        ctitle = channel.get("snippet", {}).get("title", ctitle)
        branding = channel.get("brandingSettings", {}).get("channel", {})
        country = branding.get("country", "")
        return {
            "channel_id": cid,
            "channel_name": ctitle,
            "channel_url": f"https://www.youtube.com/channel/{cid}",
            "feed_url": f"https://www.youtube.com/feeds/videos.xml?channel_id={cid}",
            "country": country,
        }
    except Exception:
        return None


def _ordinal(n: int) -> str:
    if 10 <= n % 100 <= 20:
        suffix = "th"
    else:
        suffix = {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th")
    return f"{n}{suffix}"


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    write_mode = "--write" in sys.argv

    if not write_mode:
        print("DRY RUN — use --write to resolve & save\n", file=sys.stderr)

    if not YT_API_KEY:
        print("⚠ YOUTUBE_API_KEY not set. Cannot resolve new channels.", file=sys.stderr)
        print("  Set the env var and re-run with --write.", file=sys.stderr)
        if not write_mode:
            # Dry-run: still show what names we'd attempt to resolve
            pass
        else:
            sys.exit(1)

    # Load existing data
    known_ids = load_known_channel_ids()
    known_names = load_known_names()
    print(f"Known channels: {len(known_ids)} IDs, {len(known_names)} names indexed\n", file=sys.stderr)

    # Collect all award names
    all_names: dict[str, list[tuple[int, str]]] = defaultdict(list)
    # name → [(year, award, category)]

    # Streamy Awards
    print("=" * 60, file=sys.stderr)
    print("Streamy Awards — extracting names", file=sys.stderr)
    for year in STREAMY_YEARS:
        ordinal = _ordinal(year)
        url = f"https://en.wikipedia.org/wiki/{ordinal}_Streamy_Awards"
        soup = fetch_page(url)
        if soup is None:
            continue
        names = extract_names(soup)
        for name, cat in names:
            all_names[name].append((year, "streamy", cat))
        print(f"  {ordinal}: {len(names)} names", file=sys.stderr)

    # Shorty Awards
    print("\nShorty Awards — extracting names", file=sys.stderr)
    for year in SHORTY_YEARS:
        ordinal = _ordinal(year)
        url = f"https://en.wikipedia.org/wiki/{ordinal}_Shorty_Awards"
        soup = fetch_page(url)
        if soup is None:
            continue
        names = extract_names(soup)
        for name, cat in names:
            all_names[name].append((year, "shorty", cat))
        print(f"  {ordinal}: {len(names)} names", file=sys.stderr)

    print(f"\nUnique names extracted: {len(all_names)}", file=sys.stderr)

    # Separate already-known from new
    already_known = 0
    new_names: dict[str, list] = {}
    for name, awards in all_names.items():
        norm = normalize_name(name)
        if norm in known_names:
            already_known += 1
        else:
            new_names[name] = awards

    print(f"Already in Wikipedia JSON: {already_known}", file=sys.stderr)
    print(f"NEW names to resolve: {len(new_names)}", file=sys.stderr)

    if not write_mode:
        print("\nNew names (sample, would attempt to resolve):", file=sys.stderr)
        # Show names sorted by frequency (multi-year = more likely real creator)
        sorted_names = sorted(new_names.items(), key=lambda x: -len(x[1]))
        for i, (name, awards) in enumerate(sorted_names[:30]):
            award_str = ", ".join(f"{a}({y})" for y, a, _ in awards[:3])
            print(f"  {name[:50]:50s} [{len(awards)}x: {award_str}]", file=sys.stderr)
        if len(new_names) > 30:
            print(f"  ... and {len(new_names) - 30} more", file=sys.stderr)
        print("\nDRY RUN complete. Use --write to resolve via YouTube API.", file=sys.stderr)
        return

    # ── Resolve new names via YouTube API ────────────────────────────────
    # Prioritize names with more award appearances (multi-year = more likely real)
    # Default 50 names = ~5,050 quota units (fits within 10K daily limit)
    max_resolve = int(os.getenv("AWARDS_MAX_RESOLVE", "50"))
    sorted_names = sorted(new_names.items(), key=lambda x: -len(x[1]))
    to_resolve = sorted_names[:max_resolve]

    print(f"\nResolving top {len(to_resolve)}/{len(new_names)} names via YouTube API...", file=sys.stderr)
    print("(search.list=100 quota + channels.list=1 quota per name)\n", file=sys.stderr)

    resolved: list[dict] = []
    failed = 0
    quota_used = 0

    for i, (name, awards) in enumerate(to_resolve):
        if i > 0 and i % 10 == 0:
            print(f"  {i}/{len(to_resolve)} (resolved {len(resolved)}, failed {failed}, quota ~{quota_used})", file=sys.stderr)
            time.sleep(1)  # Rate limit burst of 10

        result = resolve_name_to_channel(name)
        quota_used += 101  # search(100) + channels(1)

        if result:
            cid = result["channel_id"]
            if cid in known_ids:
                failed += 1
                continue

            awards_data = awards  # list of (year, award, category)
            result["awards"] = [
                {"year": y, "award": a, "category": c} for y, a, c in awards_data
            ]
            result["primary_award"] = awards_data[0][1]
            result["year"] = awards_data[0][0]
            resolved.append(result)
            print(f"  ✓ {name[:40]:40s} → {result['channel_name'][:40]} ({cid})", file=sys.stderr)
        else:
            failed += 1

        time.sleep(0.3)  # Rate limit

    print(f"\nResolved: {len(resolved)} new channels", file=sys.stderr)
    print(f"Failed: {failed}", file=sys.stderr)
    print(f"Estimated quota used: {quota_used}", file=sys.stderr)

    # ── Save ─────────────────────────────────────────────────────────────
    with_feed = sum(1 for c in resolved if c.get("feed_url"))
    by_award: dict[str, int] = defaultdict(int)
    for ch in resolved:
        by_award[ch.get("primary_award", "unknown")] += 1

    output = {
        "metadata": {
            "source": "Wikipedia awards + YouTube Data API v3 resolution",
            "total_channels": len(resolved),
            "channels_with_feed_url": with_feed,
            "award_counts": dict(by_award),
            "estimated_quota_used": quota_used,
        },
        "channels": resolved,
    }

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_text(
        json.dumps(output, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    print(f"\n✓ Written {len(resolved)} new channels to {OUTPUT_PATH}", file=sys.stderr)


if __name__ == "__main__":
    main()
