#!/usr/bin/env python3
"""Discover non-English RSS feeds per topic using DeepSeek (batched).

Batches 10 topics per API call — ~390 calls for 98 topics × 39 languages.
Output: OPML files at Feeds/languages/{lang}/{topic}.opml

Usage:
  export DEEPSEEK_API_KEY=sk-...
  python3 discover_topics.py          # dry-run
  python3 discover_topics.py --write  # create OPML files (with --resume built in)
"""

import os
import sys
import json
import time
import xml.etree.ElementTree as ET
from pathlib import Path
from datetime import datetime, timezone
from urllib.request import Request, urlopen
from urllib.error import URLError

FEEDS_ROOT = Path(__file__).resolve().parent.parent / "feedmine" / "Resources" / "Feeds"
LANGUAGES_DIR = FEEDS_ROOT / "languages"
CACHE_PATH = Path(__file__).resolve().parent.parent / ".superpowers" / "sdd" / "topic_discovery_cache.json"

# Languages with ≥5 OPMLs, excluding English
TARGET_LANGUAGES = [
    "es", "ar", "pt", "de", "vi", "fr", "ro", "nl", "tr", "id",
    "bg", "it", "sr", "sv", "sl", "et", "fa", "uk", "km", "zh",
    "hr", "hu", "pl", "tl", "cs", "ms", "th", "no", "el", "fi",
    "my", "hy", "lt", "az", "si", "sk", "da", "am", "ru",
]

LANGUAGE_NAMES = {
    "es": "Spanish", "ar": "Arabic", "pt": "Portuguese", "de": "German",
    "vi": "Vietnamese", "fr": "French", "ro": "Romanian", "nl": "Dutch",
    "tr": "Turkish", "id": "Indonesian", "bg": "Bulgarian", "it": "Italian",
    "sr": "Serbian", "sv": "Swedish", "sl": "Slovenian", "et": "Estonian",
    "fa": "Persian", "uk": "Ukrainian", "km": "Khmer", "zh": "Chinese",
    "hr": "Croatian", "hu": "Hungarian", "pl": "Polish", "tl": "Filipino",
    "cs": "Czech", "ms": "Malay", "th": "Thai", "no": "Norwegian",
    "el": "Greek", "fi": "Finnish", "my": "Burmese", "hy": "Armenian",
    "lt": "Lithuanian", "az": "Azerbaijani", "si": "Sinhala", "sk": "Slovak",
    "da": "Danish", "am": "Amharic", "ru": "Russian",
}

DEEPSEEK_MODEL = "deepseek-chat"
TOPICS_PER_BATCH = 10
FEEDS_PER_TOPIC = 5
DELAY_BETWEEN_CALLS = 1.5
MAX_RETRIES = 3


def get_global_topics() -> list[Path]:
    return sorted([p for p in FEEDS_ROOT.glob("*.opml")
                   if p.name != "opml_manifest.json"])


def topic_display_name(opml_path: Path) -> str:
    try:
        tree = ET.parse(opml_path)
        head = tree.getroot().find("head")
        if head is not None:
            title_el = head.find("title")
            if title_el is not None and title_el.text:
                return title_el.text.strip().split(" — ")[0].split(" & ")[0]
    except Exception:
        pass
    return opml_path.stem.replace("_", " ").title()


def call_deepseek_batch(topics: list[tuple[str, str]], lang_name: str, lang: str) -> dict[str, list[dict]] | None:
    """Ask DeepSeek for feeds for multiple topics at once.

    Args:
        topics: list of (slug, display_name) tuples
        lang_name: e.g. "Romanian"
        lang: e.g. "ro"

    Returns:
        dict mapping topic_slug → list of {title, url, description}
    """
    api_key = os.environ.get("DEEPSEEK_API_KEY")
    if not api_key:
        return None

    # Build the prompt with all topics
    topic_list = "\n".join(f"- {name}" for _, name in topics)
    topic_slugs = [s for s, _ in topics]
    slugs_str = ", ".join(topic_slugs)

    system_prompt = (
        "You are a feed discovery assistant. Given a list of topics, find "
        "quality RSS/Atom feed URLs in the specified language for each topic. "
        "Respond with ONLY a JSON object where keys are the topic slugs and "
        "values are arrays of up to 5 feed objects. "
        'Format: {"slug1": [{"title": "...", "url": "...", "description": "..."}], ...} '
        "If a topic has no good feeds in this language, return an empty array. "
        "No markdown, no explanation — just the JSON object."
    )

    user_prompt = (
        f"Find RSS/Atom feeds in {lang_name} ({lang}) for these topics:\n\n"
        f"{topic_list}\n\n"
        f"Return a JSON object with these exact keys: {slugs_str}\n"
        f"For each topic, provide up to 5 high-quality, active RSS/Atom feed URLs "
        f"in {lang_name}. Prefer blogs, news sites, magazines, or podcasts. "
        f"Return an empty array for topics with no good feeds in {lang_name}."
    )

    for attempt in range(MAX_RETRIES):
        try:
            req = Request(
                "https://api.deepseek.com/v1/chat/completions",
                data=json.dumps({
                    "model": DEEPSEEK_MODEL,
                    "messages": [
                        {"role": "system", "content": system_prompt},
                        {"role": "user", "content": user_prompt},
                    ],
                    "temperature": 0.7,
                    "max_tokens": 4096,
                    "response_format": {"type": "json_object"},
                }).encode(),
                headers={
                    "Content-Type": "application/json",
                    "Authorization": f"Bearer {api_key}",
                },
            )
            resp = urlopen(req, timeout=60)
            body = json.loads(resp.read().decode())
            content = body["choices"][0]["message"]["content"]
            data = json.loads(content)

            # Normalize: ensure all topic slugs are present
            result = {}
            for slug in topic_slugs:
                feeds = data.get(slug, [])
                if not isinstance(feeds, list):
                    feeds = []
                valid = []
                for f in feeds:
                    if isinstance(f, dict) and "url" in f and "title" in f:
                        valid.append({
                            "title": str(f["title"]).strip(),
                            "url": str(f["url"]).strip(),
                            "description": str(f.get("description", "")).strip(),
                        })
                result[slug] = valid[:FEEDS_PER_TOPIC]
            return result

        except json.JSONDecodeError as e:
            if attempt < MAX_RETRIES - 1:
                time.sleep(2)
            else:
                print(f"\n  JSON parse error: {e}", file=sys.stderr)
        except Exception as e:
            if attempt < MAX_RETRIES - 1:
                time.sleep(DELAY_BETWEEN_CALLS * (attempt + 1))
            else:
                print(f"\n  API error: {e}", file=sys.stderr)

    return None


def create_opml(topic_name: str, topic_slug: str, lang: str, lang_name: str, feeds: list[dict]):
    lang_dir = LANGUAGES_DIR / lang
    lang_dir.mkdir(parents=True, exist_ok=True)

    xml_parts = ['<?xml version="1.0" encoding="UTF-8"?>']
    xml_parts.append('<opml version="1.0">')
    xml_parts.append('  <head>')
    xml_parts.append(f'    <title>{escape_xml(topic_name)} — {escape_xml(lang_name)}</title>')
    xml_parts.append(f'    <language>{lang}</language>')
    xml_parts.append(f'    <dateCreated>{datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}</dateCreated>')
    xml_parts.append('  </head>')
    xml_parts.append('  <body>')
    xml_parts.append(f'    <outline text="{escape_xml(topic_name)} ({escape_xml(lang_name)})">')
    for feed in feeds:
        xml_parts.append(
            f'      <outline title="{escape_xml(feed["title"])}" '
            f'xmlUrl="{escape_xml(feed["url"])}" type="rss"/>'
        )
    xml_parts.append('    </outline>')
    xml_parts.append('  </body>')
    xml_parts.append('</opml>')

    opml_path = lang_dir / f"{topic_slug}.opml"
    opml_path.write_text("\n".join(xml_parts) + "\n", encoding="utf-8")


def escape_xml(s: str) -> str:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def load_cache() -> dict:
    if CACHE_PATH.exists():
        return json.loads(CACHE_PATH.read_text())
    return {}


def save_cache(cache: dict):
    CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
    CACHE_PATH.write_text(json.dumps(cache, indent=2, ensure_ascii=False))


def main():
    write_mode = "--write" in sys.argv
    api_key = os.environ.get("DEEPSEEK_API_KEY")

    if write_mode and not api_key:
        print("ERROR: DEEPSEEK_API_KEY required for --write mode")
        sys.exit(1)

    topics = get_global_topics()
    cache = load_cache()

    # Build topic info
    topic_info = [(p.stem, topic_display_name(p)) for p in topics]

    total_feeds = 0
    total_created = 0
    total_cached = 0
    failed_langs = 0

    print(f"Topics: {len(topics)} | Languages: {len(TARGET_LANGUAGES)}")
    print(f"Batching: {TOPICS_PER_BATCH} topics/call → ~{(len(topics) + TOPICS_PER_BATCH - 1) // TOPICS_PER_BATCH} calls/language")
    print(f"Mode: {'WRITE' if write_mode else 'DRY-RUN'}\n")

    for lang in TARGET_LANGUAGES:
        lang_name = LANGUAGE_NAMES.get(lang, lang)

        # Check cache for this language — skip if all topics cached
        pending_topics = []
        for slug, name in topic_info:
            key = f"{lang}/{slug}"
            if key not in cache:
                pending_topics.append((slug, name))

        if not pending_topics:
            # All cached — create OPMLs from cache
            for slug, name in topic_info:
                key = f"{lang}/{slug}"
                feeds = cache.get(key, [])
                if feeds and write_mode:
                    create_opml(name, slug, lang, lang_name, feeds)
                    total_created += 1
                total_cached += 1
            print(f"  {lang_name} ({lang}): all {len(topic_info)} cached ✓")
            continue

        print(f"  {lang_name} ({lang}): {len(pending_topics)} topics to query...")

        # Batch pending topics
        for batch_start in range(0, len(pending_topics), TOPICS_PER_BATCH):
            batch = pending_topics[batch_start:batch_start + TOPICS_PER_BATCH]

            if not api_key:
                for slug, name in batch:
                    print(f"    [dry-run] {slug}")
                continue

            batch_num = batch_start // TOPICS_PER_BATCH + 1
            total_batches = (len(pending_topics) + TOPICS_PER_BATCH - 1) // TOPICS_PER_BATCH
            batch_label = f"{lang}/{batch_num}/{total_batches}"
            print(f"    batch {batch_label}: {len(batch)} topics...", end=" ", flush=True)

            result = call_deepseek_batch(batch, lang_name, lang)
            if result is None:
                print("FAILED")
                failed_langs += 1
                break

            batch_feeds = 0
            for slug, name in batch:
                feeds = result.get(slug, [])
                key = f"{lang}/{slug}"
                cache[key] = feeds
                batch_feeds += len(feeds)

                if write_mode and feeds:
                    create_opml(name, slug, lang, lang_name, feeds)
                    total_created += 1

            save_cache(cache)

            # Show sample of what was found
            samples = []
            for slug, name in batch[:3]:
                feeds = result.get(slug, [])
                if feeds:
                    samples.append(f"{slug}:{len(feeds)}")
            print(f"✓ {batch_feeds} feeds [{', '.join(samples)}]")

            total_feeds += batch_feeds
            time.sleep(DELAY_BETWEEN_CALLS)

    # Also create OPMLs for cached topics (non-pending)
    if write_mode:
        for lang in TARGET_LANGUAGES:
            for slug, name in topic_info:
                key = f"{lang}/{slug}"
                dest = LANGUAGES_DIR / lang / f"{slug}.opml"
                if not dest.exists() and key in cache:
                    feeds = cache.get(key, [])
                    if feeds:
                        create_opml(name, slug, lang, LANGUAGE_NAMES.get(lang, lang), feeds)
                        total_created += 1

    print(f"\n{'='*60}")
    print(f"Total feeds discovered: {total_feeds}")
    print(f"OPMLs created: {total_created}")
    print(f"From cache: {total_cached}")
    if not write_mode:
        print("\n  DRY-RUN. Run with --write to create OPML files.")

    save_cache(cache)


if __name__ == "__main__":
    main()
