#!/usr/bin/env python3
"""
Scrape Wikipedia "List of newspapers in [Country]" pages for newspaper URLs.
Discovers RSS/Atom feeds via autodiscovery from newspaper homepages.

Usage:
    python scripts/newspapers_scraper.py           # dry-run
    python scripts/newspapers_scraper.py --write   # discover RSS & save JSON
"""

from __future__ import annotations

import asyncio
import json
import re
import sys
import time
from pathlib import Path
from urllib.parse import urljoin, urlparse

import aiohttp
import requests
from bs4 import BeautifulSoup

# ── Paths ────────────────────────────────────────────────────────────────────
PROJECT_ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = PROJECT_ROOT / "scripts/feed_discovery/data"
OUTPUT_PATH = DATA_DIR / "newspapers_by_country.json"
COUNTRIES_PATH = DATA_DIR / "countries.json"

HEADERS = {
    "User-Agent": "Feedmine/1.0 (Newspaper Scraper; contact@feedmine.app)",
}
WIKI_BASE = "https://en.wikipedia.org/wiki/"
PAGE_PATTERNS = [
    "List_of_newspapers_in_{}",
    "List_of_newspapers_{}",
    "Newspapers_of_{}",
    "Media_of_{}",
    "Mass_media_in_{}",
]

# ── RSS Discovery ────────────────────────────────────────────────────────────

RSS_PATTERNS = [
    "/feed/", "/rss/", "/feeds/", "/rss.xml", "/feed.xml",
    "/atom.xml", "/index.xml", "?format=feed", "?feed=rss2",
    "/noticias/feed/", "/ultimas/feed/", "/news/rss/",
]


async def discover_feed(session: aiohttp.ClientSession, homepage: str) -> str | None:
    """Try to find RSS/Atom feed from a newspaper homepage."""
    try:
        async with session.get(
            homepage.strip(),
            timeout=aiohttp.ClientTimeout(total=10),
            headers={"User-Agent": HEADERS["User-Agent"]},
        ) as resp:
            if resp.status != 200:
                return None
            html = await resp.text()
    except Exception:
        return None

    # Strategy 1: <link rel="alternate" type="application/rss+xml">
    for pattern in [
        r'<link[^>]*type\s*=\s*["\']application/(?:rss|atom)\+xml["\'][^>]*href\s*=\s*["\']([^"\']+)["\']',
        r'<link[^>]*href\s*=\s*["\']([^"\']+)["\'][^>]*type\s*=\s*["\']application/(?:rss|atom)\+xml["\']',
    ]:
        match = re.search(pattern, html, re.IGNORECASE)
        if match:
            return urljoin(homepage, match.group(1))

    # Strategy 2: Common RSS path patterns
    base = homepage.rstrip("/")
    for path in RSS_PATTERNS:
        try_url = urljoin(base, path)
        try:
            async with session.head(
                try_url,
                timeout=aiohttp.ClientTimeout(total=5),
                headers={"User-Agent": HEADERS["User-Agent"]},
            ) as resp:
                if resp.status == 200:
                    content_type = resp.headers.get("Content-Type", "")
                    if "xml" in content_type or "rss" in content_type or "atom" in content_type:
                        return try_url
        except Exception:
            continue

    return None


def scrape_wikipedia_page(country_name: str) -> list[dict]:
    """Scrape a Wikipedia 'List of newspapers in X' page for newspaper URLs."""
    newspapers = []

    # Try multiple URL patterns
    wiki_title = country_name.replace(" ", "_")
    for pattern in PAGE_PATTERNS:
        url = WIKI_BASE + pattern.format(wiki_title)
        try:
            resp = requests.get(url, timeout=15, headers=HEADERS)
            if resp.status_code == 200:
                break
        except Exception:
            continue
    else:
        return newspapers

    soup = BeautifulSoup(resp.text, "html.parser")

    # Find all wikitables
    for table in soup.find_all("table", class_="wikitable"):
        rows = table.find_all("tr")
        if len(rows) < 3:
            continue

        for row in rows[1:]:
            cells = row.find_all("td")
            if len(cells) < 1:
                continue

            name = cells[0].get_text(strip=True)

            # Find external links in this row (usually in the website/url column)
            for a in row.find_all("a", href=True):
                href = a["href"].strip()
                if href.startswith("http") and "wikipedia" not in href:
                    parsed = urlparse(href)
                    domain = parsed.netloc.lower()
                    if domain and domain not in ("web.archive.org", "www.wikidata.org"):
                        newspapers.append({
                            "name": name,
                            "url": href,
                            "domain": domain,
                        })
                        break  # One URL per newspaper

    return newspapers


async def main_async():
    write_mode = "--write" in sys.argv

    if not write_mode:
        print("DRY RUN — use --write to discover RSS feeds & save\n")

    # Load country names
    countries = json.loads(COUNTRIES_PATH.read_text(encoding="utf-8")) if COUNTRIES_PATH.exists() else {}

    all_data: dict[str, list[dict]] = {}
    total_newspapers = 0
    total_feeds = 0
    all_by_name: list[str] = []

    connector = aiohttp.TCPConnector(limit=20)
    async with aiohttp.ClientSession(connector=connector) as session:
        for slug, info in sorted(countries.items()):
            country_name = info["name"]
            native = info.get("native_name", "")

            # Try both English and native name
            newspapers = scrape_wikipedia_page(country_name)
            if not newspapers and native and native != country_name:
                newspapers = scrape_wikipedia_page(native)

            if not newspapers:
                continue

            # Discover RSS feeds
            feeds_found = 0
            for np in newspapers:
                if write_mode:
                    feed_url = await discover_feed(session, np["url"])
                    if feed_url:
                        np["feed_url"] = feed_url
                        feeds_found += 1
                time.sleep(0.05)  # Tiny delay between requests

            all_data[slug] = newspapers
            total_newspapers += len(newspapers)
            total_feeds += feeds_found

            with_feed = sum(1 for n in newspapers if n.get("feed_url"))
            top3 = ", ".join(n["name"][:25] for n in newspapers[:3])
            mode = "✓" if write_mode else ""
            print(f"  {slug} ({country_name}): {len(newspapers)} newspapers, {with_feed} feeds {mode} — {top3}")

    # ── Save ────────────────────────────────────────────────────────────────
    output = {
        "metadata": {
            "source": "Wikipedia: List of newspapers by country",
            "countries_scraped": len(all_data),
            "total_newspapers": total_newspapers,
            "total_rss_feeds": total_feeds,
        },
        "by_country": all_data,
    }

    if write_mode:
        OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
        OUTPUT_PATH.write_text(json.dumps(output, indent=2, ensure_ascii=False), encoding="utf-8")
        print(f"\n✓ Written to {OUTPUT_PATH}")
        print(f"  {len(all_data)} countries, {total_newspapers} newspapers, {total_feeds} RSS feeds")
    else:
        print(f"\nDRY RUN complete. {len(all_data)} countries, {total_newspapers} newspapers")
        print("Use --write to discover RSS feeds and save.")


def main():
    asyncio.run(main_async())


if __name__ == "__main__":
    main()
