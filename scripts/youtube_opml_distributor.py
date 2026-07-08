#!/usr/bin/env python3
"""
Distribute YouTube channels from wikipedia scraping into country OPMLs.

Maps Wikipedia languages → countries via countries.json, then adds YouTube
RSS feeds into each country's OPML file under a <outline text="YouTube"> section.

Also updates the main youtube.opml with all channels.

Usage:
    python3 scripts/youtube_opml_distributor.py           # dry-run (show what would change)
    python3 scripts/youtube_opml_distributor.py --write   # actually write files
"""

from __future__ import annotations

import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from collections import defaultdict

# ── Paths ────────────────────────────────────────────────────────────────────
PROJECT_ROOT = Path(__file__).resolve().parent.parent
CHANNELS_JSON = PROJECT_ROOT / "scripts/feed_discovery/data/youtube_channels_wikipedia.json"
COUNTRIES_JSON = Path(".claude/worktrees/feed-discovery/scripts/feed_discovery/data/countries.json")
COUNTRIES_OPML_DIR = PROJECT_ROOT / "feedmine/Resources/Feeds/countries"
MAIN_YOUTUBE_OPML = PROJECT_ROOT / "feedmine/Resources/Feeds/youtube.opml"
MAIN_YOUTUBE_NEWS_OPML = PROJECT_ROOT / "feedmine/Resources/Feeds/youtube_news.opml"

# ── Helpers ──────────────────────────────────────────────────────────────────

def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def load_channels() -> list[dict]:
    data = load_json(CHANNELS_JSON)
    return data["channels"]


def load_countries() -> dict:
    """Load countries.json and return {slug: country_data}."""
    return load_json(COUNTRIES_JSON)


def build_lang_to_countries(countries: dict) -> dict[str, list[str]]:
    """Map language code → list of country slugs."""
    mapping: dict[str, list[str]] = defaultdict(list)
    for slug, data in countries.items():
        lang = data.get("lang", "")
        if lang:
            mapping[lang].append(slug)

    # Manual overrides for languages without direct country matches
    overrides: dict[str, list[str]] = {
        "hi": ["india"],          # Hindi → India
        "gl": ["spain"],          # Galician → Spain
        "pnb": ["pakistan"],      # Western Punjabi → Pakistan
    }
    for lang, countries_list in overrides.items():
        for c in countries_list:
            if c not in mapping.get(lang, []):
                mapping[lang].append(c)

    return mapping


def parse_opml(path: Path) -> ET.ElementTree | None:
    """Parse an OPML file, return ElementTree or None if missing/invalid."""
    if not path.exists():
        return None
    try:
        # Register OPML namespace to avoid ns0: prefixes
        ET.register_namespace("", "http://www.w3.org/2000/09/opml")
        return ET.parse(str(path))
    except ET.ParseError as e:
        print(f"  ⚠ Parse error in {path}: {e}", file=sys.stderr)
        return None


def get_existing_urls(body: ET.Element) -> set[str]:
    """Get all existing xmlUrl values from an OPML body."""
    urls = set()
    for outline in body.iter("outline"):
        url = outline.get("xmlUrl", "")
        if url and url != "None":
            urls.add(url)
    return urls


def find_or_create_yt_section(body: ET.Element) -> ET.Element:
    """Find existing YouTube outline or create one. Returns the outline element."""
    for outline in body.findall("outline"):
        if outline.get("text") == "YouTube":
            return outline
    # Create new
    yt_outline = ET.SubElement(body, "outline", {"text": "YouTube"})
    return yt_outline


def add_channels_to_section(section: ET.Element, channels: list[dict], existing_urls: set[str]) -> int:
    """Add channel outlines to a section. Skip duplicates. Returns count added."""
    added = 0
    for ch in channels:
        feed_url = ch.get("feed_url")
        if not feed_url:
            continue
        if feed_url in existing_urls:
            continue
        name = ch.get("channel_name", "Unknown")
        ET.SubElement(section, "outline", {
            "title": name,
            "xmlUrl": feed_url,
            "type": "rss",
        })
        existing_urls.add(feed_url)
        added += 1
    return added


def indent_xml(elem: ET.Element, level: int = 0):
    """Pretty-print XML with proper indentation."""
    indent = "\n" + "  " * level
    if len(elem):
        if not elem.text or not elem.text.strip():
            elem.text = indent + "  "
        if not elem.tail or not elem.tail.strip():
            elem.tail = indent
        for child in elem:
            indent_xml(child, level + 1)
        if not child.tail or not child.tail.strip():
            child.tail = indent
    else:
        if level and (not elem.tail or not elem.tail.strip()):
            elem.tail = indent


def write_opml(tree: ET.ElementTree, path: Path):
    """Write OPML with proper XML declaration and formatting."""
    root = tree.getroot()
    indent_xml(root)

    # Build XML string manually for proper formatting
    xml_str = ET.tostring(root, encoding="unicode", xml_declaration=False)

    # Add XML declaration and newline before body close
    lines = ['<?xml version="1.0" encoding="UTF-8"?>', '<opml version="1.0">']
    # Find head and body
    head = root.find("head")
    body = root.find("body")
    if head is not None:
        head_str = ET.tostring(head, encoding="unicode")
        lines.append(f"  {head_str}")
    if body is not None:
        body_str = ET.tostring(body, encoding="unicode")
        lines.append(f"  {body_str}")
    lines.append("</opml>")

    path.write_text("\n".join(lines), encoding="utf-8")


def write_opml_simple(tree: ET.ElementTree, path: Path):
    """Write OPML with simple formatting using minidom."""
    from xml.dom import minidom
    root = tree.getroot()
    rough = ET.tostring(root, encoding="unicode")
    reparsed = minidom.parseString(rough)
    xml_str = reparsed.toprettyxml(indent="  ", encoding="UTF-8").decode("utf-8")
    # Fix the XML declaration (minidom adds <?xml version="1.0" ?>)
    xml_str = xml_str.replace('<?xml version="1.0" ?>', '<?xml version="1.0" encoding="UTF-8"?>')
    path.write_text(xml_str, encoding="utf-8")


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    write_mode = "--write" in sys.argv
    dry_run = not write_mode

    if dry_run:
        print("DRY RUN — use --write to actually modify files\n", file=sys.stderr)

    # Load data
    channels = load_channels()
    countries_data = load_countries()
    lang_to_countries = build_lang_to_countries(countries_data)

    # Only use channels that have feed_urls
    ready = [ch for ch in channels if ch.get("feed_url")]
    print(f"Channels with feed_url: {len(ready)}/{len(channels)}", file=sys.stderr)

    # Group channels by wiki_lang
    by_lang: dict[str, list[dict]] = defaultdict(list)
    for ch in ready:
        for lang in ch.get("wiki_langs", []):
            by_lang[lang].append(ch)

    # ── Update country OPMLs ──────────────────────────────────────────────
    country_stats: dict[str, dict] = {}

    for lang, lang_channels in sorted(by_lang.items()):
        target_countries = lang_to_countries.get(lang, [])
        if not target_countries:
            print(f"  [{lang}] No matching countries, skipping {len(lang_channels)} channels", file=sys.stderr)
            continue

        for country_slug in target_countries:
            opml_path = COUNTRIES_OPML_DIR / country_slug / f"{country_slug}.opml"
            if country_slug not in country_stats:
                country_stats[country_slug] = {"added": 0, "skipped": 0, "path": opml_path}

            if not opml_path.exists():
                print(f"  [{country_slug}] OPML not found: {opml_path}", file=sys.stderr)
                continue

            tree = parse_opml(opml_path)
            if tree is None:
                continue

            root = tree.getroot()
            body = root.find("body")
            if body is None:
                print(f"  [{country_slug}] No <body> in OPML", file=sys.stderr)
                continue

            existing_urls = get_existing_urls(body)
            yt_section = find_or_create_yt_section(body)
            added = add_channels_to_section(yt_section, lang_channels, existing_urls)

            if added > 0:
                if write_mode:
                    write_opml_simple(tree, opml_path)
                country_stats[country_slug]["added"] += added
            else:
                country_stats[country_slug]["skipped"] += 1

    # Print country summary
    print(f"\n{'='*60}", file=sys.stderr)
    print("Country OPML updates:", file=sys.stderr)
    total_added = 0
    for slug in sorted(country_stats.keys()):
        s = country_stats[slug]
        if s["added"] > 0:
            print(f"  {slug}: +{s['added']} channels {'[DRY RUN]' if dry_run else '✓'}", file=sys.stderr)
            total_added += s["added"]
    print(f"  Total additions: {total_added} (across {sum(1 for s in country_stats.values() if s['added']>0)} countries)", file=sys.stderr)

    # ── Update main youtube.opml ───────────────────────────────────────────
    print(f"\n{'='*60}", file=sys.stderr)
    print("Main youtube.opml update:", file=sys.stderr)

    yt_tree = parse_opml(MAIN_YOUTUBE_OPML)
    if yt_tree is not None:
        yt_body = yt_tree.getroot().find("body")
        yt_existing = get_existing_urls(yt_body) if yt_body is not None else set()

        # Collect ALL unique channels (deduped by feed_url)
        seen_feeds: set[str] = set()
        all_unique: list[dict] = []
        for ch in ready:
            feed = ch.get("feed_url", "")
            if feed and feed not in seen_feeds:
                seen_feeds.add(feed)
                all_unique.append(ch)

        # Create a "Wikipedia Most Subscribed" section
        wiki_section = None
        for outline in yt_body.findall("outline"):
            if outline.get("text") == "Wikipedia Most Subscribed":
                wiki_section = outline
                break

        if wiki_section is None:
            wiki_section = ET.SubElement(yt_body, "outline", {"text": "Wikipedia Most Subscribed"})

        yt_added = add_channels_to_section(wiki_section, all_unique, yt_existing)
        print(f"  youtube.opml: +{yt_added} new channels {'[DRY RUN]' if dry_run else '✓'}", file=sys.stderr)

        if yt_added > 0 and write_mode:
            write_opml_simple(yt_tree, MAIN_YOUTUBE_OPML)
    else:
        print(f"  ⚠ Could not parse {MAIN_YOUTUBE_OPML}", file=sys.stderr)

    # ── Update youtube_news.opml ───────────────────────────────────────────
    yt_news_tree = parse_opml(MAIN_YOUTUBE_NEWS_OPML)
    if yt_news_tree is not None:
        ytn_body = yt_news_tree.getroot().find("body")
        ytn_existing = get_existing_urls(ytn_body) if ytn_body is not None else set()

        # Find channels that appear to be news-related (heuristic-based)
        news_keywords = ["news", "notícias", "noticias", "journal", "tv", "channel",
                         "times", "today", "news24", "news18", "aaj tak", "abp",
                         "ndtv", "bbc", "cnn", "wion", "republic", "times now",
                         "india today", "zeenews"]
        news_channels = []
        for ch in ready:
            name_lower = ch["channel_name"].lower()
            if any(kw in name_lower for kw in news_keywords):
                news_channels.append(ch)

        if news_channels:
            news_section = find_or_create_yt_section(ytn_body)
            n_added = add_channels_to_section(news_section, news_channels, ytn_existing)
            print(f"  youtube_news.opml: +{n_added} news channels {'[DRY RUN]' if dry_run else '✓'}", file=sys.stderr)
            if n_added > 0 and write_mode:
                write_opml_simple(yt_news_tree, MAIN_YOUTUBE_NEWS_OPML)

    print(f"\n{'='*60}", file=sys.stderr)
    if dry_run:
        print("DRY RUN complete. Use --write to apply changes.", file=sys.stderr)
    else:
        print("Done! OPML files updated.", file=sys.stderr)


if __name__ == "__main__":
    main()
