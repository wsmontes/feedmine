#!/usr/bin/env python3
"""Seed empty OPML backlog files with localized Google News candidates.

Topic queries are translated to the target language. Geographic queries are
qualified by country to avoid ambiguous place names. Generated entries carry
explicit metadata and can be replaced safely without touching editorial feeds.

Usage:
  python scripts/populate_empty_opml_candidates.py --refresh-translations
  python scripts/populate_empty_opml_candidates.py
  python scripts/populate_empty_opml_candidates.py --write
"""

from __future__ import annotations

import argparse
import json
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FEEDS_ROOT = ROOT / "feedmine" / "Resources" / "Feeds"
COUNTRIES_PATH = ROOT / "scripts" / "feed_discovery" / "data" / "countries.json"
TRANSLATIONS_PATH = (
    ROOT / "scripts" / "feed_discovery" / "data" / "query_translations.json"
)
FEEDS_PER_FILE = 10
DISCOVERY_SOURCE = "google-news-search-v3"

LANGUAGE_COUNTRIES = {
    "am": "ET", "ar": "EG", "az": "AZ", "bg": "BG", "cs": "CZ",
    "da": "DK", "de": "DE", "el": "GR", "es": "ES", "et": "EE",
    "fa": "IR", "fi": "FI", "fr": "FR", "hr": "HR", "hu": "HU",
    "hy": "AM", "id": "ID", "it": "IT", "km": "KH", "lt": "LT",
    "ms": "MY", "my": "MM", "nl": "NL", "no": "NO", "pl": "PL",
    "pt": "BR", "ro": "RO", "ru": "RU", "si": "LK", "sk": "SK",
    "sl": "SI", "sr": "RS", "sv": "SE", "th": "TH", "tl": "PH",
    "tr": "TR", "uk": "UA", "vi": "VN", "zh": "CN",
}

TOPIC_INTENTS = (
    "", "news", "analysis", "magazine", "blog", "podcast", "research",
    "reviews", "community", "guide",
)
PLACE_INTENTS = (
    "", "local news", "politics", "business", "culture", "education",
    "health", "science technology", "environment", "sports",
)
TRANSLATE_CODES = {"zh": "zh-CN"}
TOPIC_QUERY_ALIASES = {
    "blogs": "blog",
    "culture": "culture",
    "general_english": "news",
    "health": "health",
    "news": "news",
    "podcasts": "podcast",
    "science": "science technology",
    "soccer": "sports",
    "sports": "sports",
    "tech": "science technology",
    "youtube_news": "news",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="update candidate OPML files")
    parser.add_argument(
        "--refresh-translations",
        action="store_true",
        help="fetch and cache missing query translations before generation",
    )
    return parser.parse_args()


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}


def opml_title(root: ET.Element, fallback: str) -> str:
    return (root.findtext("./head/title") or fallback).strip()


def topic_name(root: ET.Element, path: Path) -> str:
    title = opml_title(root, path.stem.replace("_", " ").title())
    return title.split(" — ", 1)[0].strip()


def topic_query_name(path: Path) -> str:
    return path.stem.replace("_", " ").replace("-", " ").title()


def place_name(root: ET.Element, path: Path, country: dict) -> str:
    title = opml_title(root, path.stem.replace("-", " ").title())
    for suffix in (" Feeds (candidates)", " Feeds", " feeds"):
        if title.endswith(suffix):
            title = title[: -len(suffix)]
            break
    if title.strip().lower() in {"feeds", "news", "sources"}:
        return country.get("native_name") or country.get("name") or path.stem
    return title.strip()


def generated_nodes(root: ET.Element) -> list[ET.Element]:
    return root.findall('.//outline[@feedmineCandidate="true"]')


def editorial_nodes(root: ET.Element) -> list[ET.Element]:
    return [
        node for node in root.findall(".//outline[@xmlUrl]")
        if node.attrib.get("feedmineCandidate") != "true"
    ]


def candidate_files(countries: dict[str, dict]) -> list[tuple[str, Path, ET.ElementTree]]:
    files = []
    for kind in ("languages", "countries"):
        parent = FEEDS_ROOT / kind
        for path in sorted(parent.rglob("*.opml")):
            tree = ET.parse(path)
            root = tree.getroot()
            if editorial_nodes(root):
                continue
            if not generated_nodes(root) and root.findall(".//outline[@xmlUrl]"):
                continue
            files.append((kind, path, tree))
    return files


def required_translations(
    files: list[tuple[str, Path, ET.ElementTree]],
    countries: dict[str, dict],
) -> dict[str, set[str]]:
    required: dict[str, set[str]] = defaultdict(set)
    for kind, path, tree in files:
        root = tree.getroot()
        if kind == "languages":
            language = (root.findtext("./head/language") or path.parent.name).strip()
            required[language].add(topic_name(root, path))
            alias = TOPIC_QUERY_ALIASES.get(path.stem)
            if alias:
                required[language].add(alias)
            required[language].update(intent for intent in TOPIC_INTENTS if intent)
            continue

        country_slug = path.relative_to(FEEDS_ROOT).parts[1]
        country = countries.get(country_slug, {})
        language = (root.findtext("./head/language") or country.get("lang") or "en").strip()
        required[language].update(intent for intent in PLACE_INTENTS if intent)
        required[language].add("region")
    return required


def translate_batch(language: str, texts: list[str]) -> list[str]:
    if language == "en":
        return texts
    data = urllib.parse.urlencode({
        "client": "gtx",
        "sl": "en",
        "tl": TRANSLATE_CODES.get(language, language),
        "dt": "t",
        "q": "\n".join(texts),
    }).encode()
    request = urllib.request.Request(
        "https://translate.googleapis.com/translate_a/single",
        data=data,
        headers={"User-Agent": "FeedmineDiscovery/2.0"},
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        payload = json.loads(response.read().decode("utf-8"))
    translated = "".join(part[0] for part in payload[0]).splitlines()
    if len(translated) != len(texts):
        raise RuntimeError(
            f"translation count mismatch for {language}: {len(texts)} != {len(translated)}"
        )
    return [value.strip() for value in translated]


def refresh_translations(required: dict[str, set[str]], cache: dict) -> int:
    translations = cache.setdefault("translations", {})
    fetched = 0
    for language in sorted(required):
        language_cache = translations.setdefault(language, {})
        missing = sorted(text for text in required[language] if text not in language_cache)
        if not missing:
            continue
        values = translate_batch(language, missing)
        language_cache.update(zip(missing, values, strict=True))
        fetched += len(missing)
        print(f"translated {len(missing):3d} query terms for {language}")
    if fetched:
        cache["version"] = 1
        cache["source_language"] = "en"
        TRANSLATIONS_PATH.write_text(
            json.dumps(cache, indent=2, ensure_ascii=False, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    return fetched


def ensure_translations(required: dict[str, set[str]], cache: dict) -> None:
    translations = cache.get("translations", {})
    missing = {
        language: sorted(text for text in texts if text not in translations.get(language, {}))
        for language, texts in required.items()
    }
    missing = {language: texts for language, texts in missing.items() if texts}
    if missing:
        count = sum(len(texts) for texts in missing.values())
        raise RuntimeError(
            f"translation cache is missing {count} terms; run with --refresh-translations"
        )


def localized(cache: dict, language: str, text: str) -> str:
    if not text:
        return ""
    return cache["translations"][language][text]


def localized_topic(cache: dict, language: str, root: ET.Element, path: Path) -> str:
    language_cache = cache["translations"][language]
    canonical = topic_query_name(path)
    if canonical in language_cache:
        return language_cache[canonical]
    alias = TOPIC_QUERY_ALIASES.get(path.stem)
    if alias:
        return language_cache[alias]
    return language_cache[topic_name(root, path)]


def google_news_url(query: str, language: str, country_code: str) -> str:
    params = urllib.parse.urlencode({
        "q": query,
        "hl": language,
        "gl": country_code,
        "ceid": f"{country_code}:{language}",
    })
    return f"https://news.google.com/rss/search?{params}"


def country_by_iso2(countries: dict[str, dict], country_code: str) -> dict:
    code = country_code.lower()
    return next(
        (country for country in countries.values() if country.get("iso2", "").lower() == code),
        {},
    )


def country_constraint(country: dict) -> str:
    cctld = str(country.get("cctld") or "").lower().lstrip(".")
    if cctld and country.get("use_cctld", True):
        return f"site:.{cctld}"
    return str(country.get("native_name") or country.get("name") or "").strip()


def topic_expression(topic: str) -> str:
    is_single_term = bool(topic) and all(character.isalnum() for character in topic)
    return f'"{topic}"' if is_single_term else topic


def candidate_element(title: str, url: str, language: str, scope: str) -> ET.Element:
    return ET.Element("outline", {
        "title": title,
        "text": title,
        "xmlUrl": url,
        "type": "rss",
        "category": "Candidate",
        "feedmineCandidate": "true",
        "discoverySource": DISCOVERY_SOURCE,
        "queryLanguage": language,
        "queryScope": scope,
        "semanticConstraints": "localized-query,country-domain",
    })


def language_candidates(
    root: ET.Element,
    path: Path,
    countries: dict[str, dict],
    translations: dict,
) -> list[ET.Element]:
    language = (root.findtext("./head/language") or path.parent.name).strip()
    country_code = LANGUAGE_COUNTRIES.get(language, "US")
    constraint = country_constraint(country_by_iso2(countries, country_code))
    topic = localized_topic(translations, language, root, path)
    candidates = []
    for intent in TOPIC_INTENTS:
        localized_intent = localized(translations, language, intent)
        query = " ".join(
            part for part in (topic_expression(topic), localized_intent, constraint) if part
        )
        title = f"Candidate: {topic}{f' — {localized_intent}' if localized_intent else ''}"
        candidates.append(candidate_element(
            title,
            google_news_url(query, language, country_code),
            language,
            "topic",
        ))
    return candidates


def country_candidates(
    root: ET.Element,
    path: Path,
    countries: dict[str, dict],
    translations: dict,
) -> list[ET.Element]:
    relative = path.relative_to(FEEDS_ROOT)
    country_slug = relative.parts[1]
    country = countries.get(country_slug, {})
    language = (root.findtext("./head/language") or country.get("lang") or "en").strip()
    country_code = str(country.get("iso2") or "US").upper()
    country_name = country.get("native_name") or country.get("name") or country_slug
    place = place_name(root, path, country)
    region_term = localized(translations, language, "region") if path.stem != country_slug else ""
    scope = " ".join(
        part for part in (place, region_term, country_constraint(country)) if part
    )
    candidates = []
    for intent in PLACE_INTENTS:
        localized_intent = localized(translations, language, intent)
        query = " ".join(part for part in (scope, localized_intent) if part)
        title = f"Candidate: {place}, {country_name}{f' — {localized_intent}' if localized_intent else ''}"
        candidates.append(candidate_element(
            title,
            google_news_url(query, language, country_code),
            language,
            "region-country",
        ))
    return candidates


def remove_generated(root: ET.Element) -> None:
    for parent in root.iter():
        for child in list(parent):
            if child.attrib.get("feedmineCandidate") == "true":
                parent.remove(child)
            elif child.attrib.get("feedmineCandidateGroup") == "true":
                parent.remove(child)


def insert_candidates(root: ET.Element, path: Path, candidates: list[ET.Element]) -> None:
    body = root.find("body")
    if body is None:
        body = ET.SubElement(root, "body")
    if "languages" in path.relative_to(FEEDS_ROOT).parts:
        container = body.find("outline")
        if container is None:
            container = ET.SubElement(body, "outline", {"text": topic_name(root, path)})
    else:
        container = ET.SubElement(body, "outline", {
            "text": "Candidate Feeds",
            "feedmineCandidateGroup": "true",
        })
    container.extend(candidates)


def write_tree(tree: ET.ElementTree, path: Path) -> None:
    ET.indent(tree, space="  ")
    contents = ET.tostring(
        tree.getroot(), encoding="utf-8", xml_declaration=True, short_empty_elements=True,
    )
    path.write_bytes(contents + b"\n")


def main() -> int:
    args = parse_args()
    countries = load_json(COUNTRIES_PATH)
    files = candidate_files(countries)
    required = required_translations(files, countries)
    translations = load_json(TRANSLATIONS_PATH)

    if args.refresh_translations:
        fetched = refresh_translations(required, translations)
        print(f"cached {fetched} new translations in {TRANSLATIONS_PATH}")
    ensure_translations(required, translations)

    candidate_count = 0
    for kind, path, tree in files:
        root = tree.getroot()
        if kind == "languages":
            candidates = language_candidates(root, path, countries, translations)
        else:
            candidates = country_candidates(root, path, countries, translations)
        if len(candidates) != FEEDS_PER_FILE:
            raise RuntimeError(f"expected {FEEDS_PER_FILE} candidates for {path}")
        candidate_count += len(candidates)
        if args.write:
            remove_generated(root)
            insert_candidates(root, path, candidates)
            write_tree(tree, path)

    mode = "updated" if args.write else "would update"
    print(f"{mode} {len(files)} OPML backlog files with {candidate_count} candidates")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
