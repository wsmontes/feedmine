#!/usr/bin/env python3
"""Build a clean, resumable FeedMine source and content corpus.

The DuckDB database is a bounded checkpoint. A run records catalog metadata,
HTTP attempts, and only the current content batch. Completed batches are
written as compressed Parquet parts and removed from DuckDB.

Typical usage:
    source .venv_feeds/bin/activate
    python scripts/fetch_all_feeds_v2.py --reset
    python scripts/fetch_all_feeds_v2.py --limit 100 --reset
    python scripts/fetch_all_feeds_v2.py --retry-failed
    python scripts/fetch_all_feeds_v2.py --export-parquet
"""

from __future__ import annotations

import argparse
import asyncio
import calendar
import hashlib
import html
import json
import re
import shutil
import signal
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

import duckdb
import feedparser
import httpx
from tqdm import tqdm


PROJECT_ROOT = Path(__file__).resolve().parent.parent
FEEDS_DIR = PROJECT_ROOT / "feedmine" / "Resources" / "Feeds"
MANIFEST_PATH = FEEDS_DIR / "opml_manifest.json"
DEFAULT_DB = PROJECT_ROOT / "feeds_corpus.duckdb"
DEFAULT_OUTPUT_PREFIX = PROJECT_ROOT / "feeds_corpus"

SCHEMA_VERSION = 4
MAX_ARTICLES = 30
MAX_CONCURRENT = 50
REQUEST_TIMEOUT = 30.0
MAX_RETRIES = 3
USER_AGENT = "FeedMine/2.0 corpus builder"

TRACKING_QUERY_KEYS = {
    "fbclid", "gclid", "mc_cid", "mc_eid", "ref", "ref_src",
    "utm_campaign", "utm_content", "utm_medium", "utm_source", "utm_term",
}

DATE_TEXT_FIELDS = (
    "published", "updated", "created", "issued", "modified", "date",
    "dc_date", "dcterms_created", "dcterms_modified",
)
DATE_STRUCTURED_FIELDS = (
    "published_parsed", "updated_parsed", "created_parsed", "issued_parsed",
    "modified_parsed", "date_parsed",
)
YMD_DATE_RE = re.compile(
    r"(?<!\d)(?P<year>19\d{2}|20\d{2})[-_/](?P<month>0?[1-9]|1[0-2])[-_/](?P<day>0?[1-9]|[12]\d|3[01])(?!\d)"
)
COMPACT_YMD_DATE_RE = re.compile(
    r"(?<!\d)(?P<year>19\d{2}|20\d{2})(?P<month>0[1-9]|1[0-2])(?P<day>0[1-9]|[12]\d|3[01])(?!\d)"
)
MONTH_NAME_DATE_RE = re.compile(
    r"\b(?P<month>jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|"
    r"jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)"
    r"\.?\s+(?P<day>0?[1-9]|[12]\d|3[01])(?:st|nd|rd|th)?[,]?\s+"
    r"(?P<year>19\d{2}|20\d{2})\b",
    re.I,
)
DAY_MONTH_NAME_DATE_RE = re.compile(
    r"\b(?P<day>0?[1-9]|[12]\d|3[01])(?:st|nd|rd|th)?\s+"
    r"(?P<month>jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|"
    r"jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)"
    r"\.?\s+(?P<year>19\d{2}|20\d{2})\b",
    re.I,
)
MONTHS = {
    "jan": 1, "january": 1,
    "feb": 2, "february": 2,
    "mar": 3, "march": 3,
    "apr": 4, "april": 4,
    "may": 5,
    "jun": 6, "june": 6,
    "jul": 7, "july": 7,
    "aug": 8, "august": 8,
    "sep": 9, "sept": 9, "september": 9,
    "oct": 10, "october": 10,
    "nov": 11, "november": 11,
    "dec": 12, "december": 12,
}


@dataclass(frozen=True)
class MembershipRecord:
    collection: str
    topic: str
    subcategory: str | None
    claimed_language: str | None
    region: str
    claimed_country: str | None
    opml_file: str
    opml_title: str | None
    claimed_media_kind: str | None


@dataclass
class SourceRecord:
    source_id: str
    title: str
    xml_url: str
    canonical_xml_url: str
    memberships: list[MembershipRecord] = field(default_factory=list)


@dataclass
class FetchAttempt:
    attempt_number: int
    requested_at: str
    completed_at: str
    duration_ms: int
    ttfb_ms: int | None
    http_status: int | None
    response_bytes: int | None
    final_url: str | None
    content_type: str | None
    error_message: str | None


@dataclass
class FetchResult:
    source: SourceRecord
    status: str
    articles: list[dict]
    attempts: list[FetchAttempt]
    fetch_duration_ms: int
    feed_meta: dict | None = None
    error_message: str | None = None
    parser_warning: str | None = None


class _PlainTextParser(HTMLParser):
    """Small stateless HTML-to-text parser with no markdown side effects."""

    _BLOCK_TAGS = {
        "address", "article", "aside", "blockquote", "br", "dd", "div", "dl",
        "dt", "figcaption", "figure", "footer", "h1", "h2", "h3", "h4", "h5",
        "h6", "header", "hr", "li", "main", "nav", "ol", "p", "pre", "section",
        "table", "td", "th", "tr", "ul",
    }
    _SKIP_TAGS = {"script", "style", "noscript", "template"}

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self.skip_depth = 0

    def handle_starttag(self, tag: str, attrs) -> None:
        tag = tag.lower()
        if tag in self._SKIP_TAGS:
            self.skip_depth += 1
        elif not self.skip_depth and tag in self._BLOCK_TAGS:
            self.parts.append(" ")

    def handle_startendtag(self, tag: str, attrs) -> None:
        if not self.skip_depth and tag.lower() in self._BLOCK_TAGS:
            self.parts.append(" ")

    def handle_endtag(self, tag: str) -> None:
        tag = tag.lower()
        if tag in self._SKIP_TAGS and self.skip_depth:
            self.skip_depth -= 1
        elif not self.skip_depth and tag in self._BLOCK_TAGS:
            self.parts.append(" ")

    def handle_data(self, data: str) -> None:
        if not self.skip_depth:
            self.parts.append(data)

    def text(self) -> str | None:
        return clean_text("".join(self.parts))


def _decode_entities(value: str) -> str:
    # Two passes also handle strings such as &amp;#8217; without retaining codes.
    for _ in range(2):
        decoded = html.unescape(value)
        if decoded == value:
            break
        value = decoded
    return value


def clean_text(raw: str | None) -> str | None:
    if not raw:
        return None
    return re.sub(r"\s+", " ", _decode_entities(str(raw))).strip() or None


def clean_html(raw: str | None) -> str | None:
    if not raw:
        return None
    parser = _PlainTextParser()
    try:
        parser.feed(_decode_entities(str(raw)))
        parser.close()
        return parser.text()
    except Exception:
        return clean_text(re.sub(r"<[^>]+>", " ", str(raw)))


def canonical_url(raw: str, *, strip_tracking: bool = False) -> str:
    trimmed = raw.strip()
    if not trimmed:
        return ""
    parsed = urlsplit(trimmed)
    scheme = (parsed.scheme or "https").lower()
    hostname = (parsed.hostname or "").lower()
    if not hostname:
        return trimmed
    port = parsed.port
    default_port = (scheme == "http" and port == 80) or (scheme == "https" and port == 443)
    netloc = hostname if not port or default_port else f"{hostname}:{port}"
    query = parsed.query
    if strip_tracking and query:
        pairs = [
            (key, value) for key, value in parse_qsl(query, keep_blank_values=True)
            if key.lower() not in TRACKING_QUERY_KEYS and not key.lower().startswith("utm_")
        ]
        query = urlencode(pairs, doseq=True)
    return urlunsplit((scheme, netloc, parsed.path or "/", query, ""))


def stable_id(namespace: str, value: str) -> str:
    return hashlib.sha256(f"{namespace}:{value}".encode("utf-8")).hexdigest()


def _dedup_summary(content_text: str | None, summary: str | None) -> str | None:
    if not content_text or not summary:
        return summary
    content_key = content_text.casefold().strip()
    summary_key = summary.casefold().strip()
    if summary_key == content_key:
        return None
    if len(summary_key) > 50 and (summary_key in content_key or content_key in summary_key):
        return None
    return summary


def _valid_published(value: datetime) -> bool:
    now = datetime.now(timezone.utc)
    return datetime(1990, 1, 1, tzinfo=timezone.utc) <= value <= now + timedelta(days=7)


def _normalize_datetime(value: datetime) -> datetime:
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


def _datetime_from_structured(value) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromtimestamp(calendar.timegm(value), tz=timezone.utc)
    except (OverflowError, TypeError, ValueError):
        return None


def _datetime_from_text(raw: str) -> datetime | None:
    try:
        return _normalize_datetime(parsedate_to_datetime(raw))
    except (TypeError, ValueError, OverflowError):
        pass
    try:
        return _normalize_datetime(datetime.fromisoformat(raw.replace("Z", "+00:00")))
    except ValueError:
        return None


def _date_from_parts(year: str, month: str | int, day: str) -> datetime | None:
    if isinstance(month, str) and not month.isdigit():
        month_value = MONTHS.get(month.rstrip(".").lower())
        if month_value is None:
            return None
    else:
        month_value = int(month)
    try:
        return datetime(int(year), month_value, int(day), tzinfo=timezone.utc)
    except ValueError:
        return None


def _infer_date_from_text(raw: str | None) -> tuple[datetime | None, str | None]:
    text = clean_text(raw)
    if not text:
        return None, None
    for pattern in (YMD_DATE_RE, COMPACT_YMD_DATE_RE):
        for match in pattern.finditer(text):
            value = _date_from_parts(match["year"], match["month"], match["day"])
            if value and _valid_published(value):
                return value, match.group(0)
    for pattern in (MONTH_NAME_DATE_RE, DAY_MONTH_NAME_DATE_RE):
        for match in pattern.finditer(text):
            value = _date_from_parts(match["year"], match["month"], match["day"])
            if value and _valid_published(value):
                return value, match.group(0)
    return None, None


def normalize_published(entry, *fallback_texts: str | None) -> tuple[str | None, str | None, bool]:
    raw_values = [clean_text(entry.get(field)) for field in DATE_TEXT_FIELDS]
    raw_values = [value for value in raw_values if value]
    first_invalid_raw: str | None = None

    for field in DATE_STRUCTURED_FIELDS:
        value = _datetime_from_structured(entry.get(field))
        if value and _valid_published(value):
            raw = clean_text(entry.get(field.removesuffix("_parsed"))) or field
            return value.isoformat(), raw, True

    for raw in raw_values:
        explicit_years = [int(year) for year in re.findall(r"(?<!\d)(\d{4})(?!\d)", raw)]
        if explicit_years and any(year < 1990 for year in explicit_years):
            first_invalid_raw = first_invalid_raw or raw
            continue
        value = _datetime_from_text(raw)
        if value and _valid_published(value):
            return value.isoformat(), raw, True

    for fallback in fallback_texts:
        value, matched = _infer_date_from_text(fallback)
        if value and matched:
            return value.isoformat(), f"inferred:{matched}", True

    if first_invalid_raw:
        return None, first_invalid_raw, False
    raw = raw_values[0] if raw_values else None
    return None, raw, False


def _claimed_media_kind(opml_file: str, parent_chain: list[str], child: ET.Element) -> str | None:
    explicit = child.get("mediaKind") or child.get("media_kind") or child.get("kind")
    if explicit:
        return clean_text(explicit.lower())
    hint = " ".join([Path(opml_file).stem, *parent_chain]).lower()
    if "youtube" in hint or "video" in hint:
        return "video"
    if "podcast" in hint or "audio" in hint:
        return "audio"
    return None


def load_manifest(path: Path = MANIFEST_PATH) -> dict[str, dict]:
    if not path.exists():
        return {}
    with path.open(encoding="utf-8") as handle:
        data = json.load(handle)
    return {entry["path"]: entry for entry in data.get("files", []) if entry.get("path")}


def _walk_outlines(
    element: ET.Element,
    *,
    collection: str,
    topic: str,
    region: str,
    country: str | None,
    language: str | None,
    opml_file: str,
    opml_title: str | None,
    parent_chain: list[str],
    out: list[tuple[str, str, MembershipRecord]],
) -> None:
    for child in element.findall("outline"):
        text_attr = clean_text(child.get("text"))
        title_attr = clean_text(child.get("title"))
        xml_url = clean_text(child.get("xmlUrl"))
        child_language = clean_text(child.get("language") or child.get("lang")) or language
        label = title_attr or text_attr
        if xml_url:
            membership = MembershipRecord(
                collection=collection,
                topic=topic,
                subcategory=" / ".join(parent_chain) if parent_chain else None,
                claimed_language=child_language,
                region=region,
                claimed_country=country,
                opml_file=opml_file,
                opml_title=opml_title,
                claimed_media_kind=_claimed_media_kind(opml_file, parent_chain, child),
            )
            out.append((title_attr or text_attr or xml_url, xml_url, membership))
        children = child.findall("outline")
        if children:
            next_chain = parent_chain + ([label] if label and not xml_url else [])
            _walk_outlines(
                child,
                collection=collection,
                topic=topic,
                region=region,
                country=country,
                language=child_language,
                opml_file=opml_file,
                opml_title=opml_title,
                parent_chain=next_chain,
                out=out,
            )


def parse_opml(file_path: Path, rel_path: str, manifest_index: dict[str, dict]) -> list[tuple[str, str, MembershipRecord]]:
    root = ET.parse(file_path).getroot()
    head = root.find("head")
    language = clean_text(head.findtext("language")) if head is not None else None
    opml_title = clean_text(head.findtext("title")) if head is not None else None
    parts = Path(rel_path).parts
    collection = parts[0] if parts else "unknown"
    country = parts[1] if collection == "countries" and len(parts) > 1 else None
    topic = Path(rel_path).stem
    region = clean_text(manifest_index.get(rel_path, {}).get("region")) or "global"
    body = root.find("body")
    if body is None:
        return []
    records: list[tuple[str, str, MembershipRecord]] = []
    _walk_outlines(
        body,
        collection=collection,
        topic=topic,
        region=region,
        country=country,
        language=language,
        opml_file=rel_path,
        opml_title=opml_title,
        parent_chain=[],
        out=records,
    )
    return records


def discover_sources(feeds_dir: Path, manifest_index: dict[str, dict]) -> list[SourceRecord]:
    merged: dict[str, SourceRecord] = {}
    membership_keys: dict[str, set[MembershipRecord]] = {}
    files = sorted(feeds_dir.rglob("*.opml"))
    print(f"Found {len(files)} OPML files. Parsing...")
    for file_path in tqdm(files, desc="Parsing OPMLs", unit="file"):
        if file_path.name.endswith(".tmp"):
            continue
        rel_path = str(file_path.relative_to(feeds_dir))
        try:
            records = parse_opml(file_path, rel_path, manifest_index)
        except Exception as exc:
            tqdm.write(f"  [skip] {rel_path}: {exc}")
            continue
        for title, xml_url, membership in records:
            canonical = canonical_url(xml_url)
            if not canonical:
                continue
            source = merged.get(canonical)
            if source is None:
                source = SourceRecord(stable_id("source", canonical), title, xml_url, canonical)
                merged[canonical] = source
                membership_keys[canonical] = set()
            if membership not in membership_keys[canonical]:
                source.memberships.append(membership)
                membership_keys[canonical].add(membership)
    return list(merged.values())


def _entry_content(entry) -> tuple[str | None, str | None]:
    content_raw = ""
    if entry.get("content"):
        content_raw = entry.content[0].get("value", "")
    summary_raw = entry.get("summary") or entry.get("description") or ""
    content_text = clean_html(content_raw)
    summary = clean_html(summary_raw)
    if not content_text and summary:
        return summary, None
    return content_text, _dedup_summary(content_text, summary)


def extract_articles(feed_data, source_id: str, max_articles: int = MAX_ARTICLES) -> list[dict]:
    articles: list[dict] = []
    seen: set[str] = set()
    for position, entry in enumerate(feed_data.entries[:max_articles]):
        title = clean_html(entry.get("title"))
        raw_url = clean_text(entry.get("link"))
        item_url = canonical_url(raw_url or "", strip_tracking=True)
        published_at, published_raw, published_valid = normalize_published(entry, item_url, raw_url, title)
        content_text, summary = _entry_content(entry)
        if not any((title, item_url, content_text, summary)):
            continue
        if item_url:
            item_id = stable_id("item-url", item_url)
        else:
            fallback = "|".join((title or "", published_at or published_raw or "", content_text or summary or ""))
            item_id = stable_id("item-fallback", f"{source_id}|{fallback}")
        if item_id in seen:
            continue
        seen.add(item_id)
        articles.append({
            "item_id": item_id,
            "position": position,
            "title": title,
            "raw_url": raw_url,
            "canonical_url": item_url or None,
            "published_at": published_at,
            "published_raw": published_raw,
            "published_valid": published_valid,
            "summary": summary,
            "content_text": content_text,
        })
    return articles


class FeedFetcher:
    def __init__(self, timeout: float, max_retries: int, max_articles: int):
        self.timeout = timeout
        self.max_retries = max_retries
        self.max_articles = max_articles
        self.client: httpx.AsyncClient

    async def __aenter__(self):
        self.client = httpx.AsyncClient(
            timeout=httpx.Timeout(self.timeout),
            limits=httpx.Limits(max_connections=MAX_CONCURRENT + 10, max_keepalive_connections=MAX_CONCURRENT),
            headers={"User-Agent": USER_AGENT, "Accept": "application/rss+xml, application/atom+xml, application/xml, text/xml, */*"},
            follow_redirects=True,
        )
        return self

    async def __aexit__(self, *args):
        await self.client.aclose()

    async def fetch_one(self, source: SourceRecord) -> FetchResult:
        fetch_started = time.perf_counter()
        attempts: list[FetchAttempt] = []
        last_error: str | None = None
        for attempt_number in range(1, self.max_retries + 1):
            started_at = datetime.now(timezone.utc)
            started = time.perf_counter()
            response: httpx.Response | None = None
            ttfb_ms: int | None = None
            body: bytes | None = None
            try:
                async with self.client.stream("GET", source.xml_url) as response:
                    ttfb_ms = round((time.perf_counter() - started) * 1000)
                    body = await response.aread()
                duration_ms = round((time.perf_counter() - started) * 1000)
                response.raise_for_status()
                attempts.append(FetchAttempt(
                    attempt_number, started_at.isoformat(), datetime.now(timezone.utc).isoformat(),
                    duration_ms, ttfb_ms, response.status_code, len(body), str(response.url),
                    response.headers.get("content-type"), None,
                ))
                feed_data = feedparser.parse(body)
                if feed_data.bozo and not feed_data.entries:
                    raise RuntimeError(f"Parse error: {feed_data.bozo_exception}")
                articles = extract_articles(feed_data, source.source_id, self.max_articles)
                warning = str(feed_data.bozo_exception)[:1000] if feed_data.bozo else None
                feed_meta = {
                    "feed_title": clean_html(feed_data.feed.get("title")),
                    "feed_description": clean_html(feed_data.feed.get("description") or feed_data.feed.get("subtitle")),
                    "feed_reported_language": clean_text(feed_data.feed.get("language")),
                    "site_url": clean_text(feed_data.feed.get("link")),
                    "final_url": str(response.url),
                    "http_status": response.status_code,
                    "content_type": response.headers.get("content-type"),
                    "response_bytes": len(body),
                    "response_time_ms": duration_ms,
                    "ttfb_ms": ttfb_ms,
                }
                return FetchResult(
                    source=source,
                    status="done" if articles else "empty",
                    articles=articles,
                    attempts=attempts,
                    fetch_duration_ms=round((time.perf_counter() - fetch_started) * 1000),
                    feed_meta=feed_meta,
                    parser_warning=warning,
                )
            except Exception as exc:
                last_error = str(exc)[:1000]
                if not attempts or attempts[-1].attempt_number != attempt_number:
                    attempts.append(FetchAttempt(
                        attempt_number, started_at.isoformat(), datetime.now(timezone.utc).isoformat(),
                        round((time.perf_counter() - started) * 1000), ttfb_ms,
                        response.status_code if response else None, len(body) if body is not None else None,
                        str(response.url) if response else None,
                        response.headers.get("content-type") if response else None, last_error,
                    ))
                else:
                    attempts[-1].error_message = last_error
                retryable = not isinstance(exc, httpx.HTTPStatusError) or exc.response.status_code in {408, 425, 429, 500, 502, 503, 504}
                if attempt_number < self.max_retries and retryable:
                    await asyncio.sleep(2 ** (attempt_number - 1))
                    continue
                break
        last_attempt = attempts[-1] if attempts else None
        failure_meta = {
            "final_url": last_attempt.final_url if last_attempt else None,
            "http_status": last_attempt.http_status if last_attempt else None,
            "content_type": last_attempt.content_type if last_attempt else None,
            "response_bytes": last_attempt.response_bytes if last_attempt else None,
            "response_time_ms": last_attempt.duration_ms if last_attempt else None,
            "ttfb_ms": last_attempt.ttfb_ms if last_attempt else None,
        }
        return FetchResult(
            source=source,
            status="failed",
            articles=[],
            attempts=attempts,
            fetch_duration_ms=round((time.perf_counter() - fetch_started) * 1000),
            feed_meta=failure_meta,
            error_message=last_error,
        )


SCHEMA_SQL = f"""
CREATE TABLE schema_meta (schema_version INTEGER NOT NULL);
INSERT INTO schema_meta VALUES ({SCHEMA_VERSION});

CREATE TABLE sources (
    source_id VARCHAR PRIMARY KEY,
    source_title VARCHAR,
    xml_url VARCHAR NOT NULL,
    canonical_xml_url VARCHAR UNIQUE NOT NULL,
    site_url VARCHAR,
    feed_title VARCHAR,
    feed_description VARCHAR,
    feed_reported_language VARCHAR,
    status VARCHAR NOT NULL DEFAULT 'pending',
    error_message VARCHAR,
    parser_warning VARCHAR,
    articles_fetched INTEGER NOT NULL DEFAULT 0,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    attempted_at TIMESTAMPTZ,
    fetched_at TIMESTAMPTZ,
    fetch_duration_ms BIGINT,
    response_time_ms BIGINT,
    ttfb_ms BIGINT,
    http_status INTEGER,
    response_bytes BIGINT,
    final_url VARCHAR,
    content_type VARCHAR,
    latest_item_at TIMESTAMPTZ,
    oldest_item_at TIMESTAMPTZ
);

CREATE TABLE source_memberships (
    membership_id VARCHAR PRIMARY KEY,
    source_id VARCHAR NOT NULL,
    collection VARCHAR NOT NULL,
    topic VARCHAR NOT NULL,
    subcategory VARCHAR,
    claimed_language VARCHAR,
    region VARCHAR,
    claimed_country VARCHAR,
    opml_file VARCHAR NOT NULL,
    opml_title VARCHAR,
    claimed_media_kind VARCHAR
);

CREATE TABLE items (
    item_id VARCHAR PRIMARY KEY,
    canonical_url VARCHAR,
    raw_url VARCHAR,
    title VARCHAR,
    published_at TIMESTAMPTZ,
    published_raw VARCHAR,
    published_valid BOOLEAN NOT NULL,
    summary VARCHAR,
    content_text VARCHAR,
    first_seen_at TIMESTAMPTZ NOT NULL,
    last_seen_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE source_items (
    source_id VARCHAR NOT NULL,
    item_id VARCHAR NOT NULL,
    position INTEGER NOT NULL,
    observed_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (source_id, item_id)
);

CREATE TABLE fetch_attempts (
    attempt_id VARCHAR PRIMARY KEY,
    run_id VARCHAR NOT NULL,
    source_id VARCHAR NOT NULL,
    attempt_number INTEGER NOT NULL,
    requested_at TIMESTAMPTZ NOT NULL,
    completed_at TIMESTAMPTZ NOT NULL,
    duration_ms BIGINT NOT NULL,
    ttfb_ms BIGINT,
    http_status INTEGER,
    response_bytes BIGINT,
    final_url VARCHAR,
    content_type VARCHAR,
    error_message VARCHAR
);

CREATE TABLE parquet_parts (
    part_number INTEGER PRIMARY KEY,
    parquet_path VARCHAR UNIQUE NOT NULL,
    relation_count BIGINT NOT NULL,
    item_count BIGINT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX idx_sources_status ON sources(status);
CREATE INDEX idx_source_items_source ON source_items(source_id);
CREATE INDEX idx_memberships_source ON source_memberships(source_id);
CREATE INDEX idx_attempts_source ON fetch_attempts(source_id);
"""


def init_db(db_path: Path, reset: bool = False):
    conn = duckdb.connect(str(db_path))
    conn.execute("SET preserve_insertion_order = false")
    conn.execute("SET threads = 2")
    if reset:
        for table in ("parquet_parts", "fetch_attempts", "source_items", "items", "source_memberships", "sources", "schema_meta", "articles"):
            conn.execute(f"DROP TABLE IF EXISTS {table}")
        conn.execute("DROP SEQUENCE IF EXISTS seq_source_id")
    tables = {row[0] for row in conn.execute("SHOW TABLES").fetchall()}
    if not tables:
        conn.execute(SCHEMA_SQL)
    elif "schema_meta" not in tables:
        conn.close()
        raise RuntimeError(f"{db_path} uses the legacy schema. Run again with --reset or choose another --db.")
    else:
        version = conn.execute("SELECT schema_version FROM schema_meta LIMIT 1").fetchone()[0]
        if version != SCHEMA_VERSION:
            conn.close()
            raise RuntimeError(f"Unsupported schema version {version}; expected {SCHEMA_VERSION}. Use --reset.")
    return conn


def register_catalog(conn, sources: list[SourceRecord]) -> None:
    with tempfile.NamedTemporaryFile(mode="w", suffix=".jsonl", encoding="utf-8") as source_file:
        for source in sources:
            source_file.write(json.dumps({
                "source_id": source.source_id,
                "source_title": source.title,
                "xml_url": source.xml_url,
                "canonical_xml_url": source.canonical_xml_url,
            }, ensure_ascii=False) + "\n")
        source_file.flush()
        conn.execute("BEGIN")
        try:
            conn.execute(
                """INSERT INTO sources (source_id, source_title, xml_url, canonical_xml_url)
                   SELECT source_id, source_title, xml_url, canonical_xml_url
                   FROM read_json_auto(?)
                   ON CONFLICT (source_id) DO UPDATE SET
                     source_title = EXCLUDED.source_title,
                     xml_url = EXCLUDED.xml_url,
                     canonical_xml_url = EXCLUDED.canonical_xml_url""",
                [source_file.name],
            )
            conn.execute("COMMIT")
        except Exception:
            conn.execute("ROLLBACK")
            raise

    with tempfile.NamedTemporaryFile(mode="w", suffix=".jsonl", encoding="utf-8") as membership_file:
        for source in sources:
            for membership in source.memberships:
                values = (
                    membership.collection, membership.topic, membership.subcategory,
                    membership.claimed_language, membership.region,
                    membership.claimed_country, membership.opml_file,
                    membership.opml_title, membership.claimed_media_kind,
                )
                identity = "|".join(value or "" for value in values)
                membership_file.write(json.dumps({
                    "membership_id": stable_id("membership", f"{source.source_id}|{identity}"),
                    "source_id": source.source_id,
                    "collection": membership.collection,
                    "topic": membership.topic,
                    "subcategory": membership.subcategory,
                    "claimed_language": membership.claimed_language,
                    "region": membership.region,
                    "claimed_country": membership.claimed_country,
                    "opml_file": membership.opml_file,
                    "opml_title": membership.opml_title,
                    "claimed_media_kind": membership.claimed_media_kind,
                }, ensure_ascii=False) + "\n")
        membership_file.flush()
        conn.execute("BEGIN")
        try:
            conn.execute(
                """INSERT INTO source_memberships
                   SELECT membership_id, source_id, collection, topic, subcategory, claimed_language,
                          region, claimed_country, opml_file, opml_title, claimed_media_kind
                   FROM read_json_auto(?)
                   ON CONFLICT (membership_id) DO NOTHING""",
                [membership_file.name],
            )
            conn.execute("COMMIT")
        except Exception:
            conn.execute("ROLLBACK")
            raise


def pending_sources(conn, sources: list[SourceRecord], retry_failed: bool) -> list[SourceRecord]:
    states = dict(conn.execute("SELECT source_id, status FROM sources").fetchall())
    eligible = {"pending"}
    if retry_failed:
        eligible.add("failed")
    return [source for source in sources if states.get(source.source_id, "pending") in eligible]


def store_result(conn, result: FetchResult, run_id: str) -> None:
    now = datetime.now(timezone.utc).isoformat()
    meta = result.feed_meta or {}
    published = [article["published_at"] for article in result.articles if article["published_at"]]
    latest = max(published) if published else None
    oldest = min(published) if published else None
    conn.execute("BEGIN")
    try:
        for attempt in result.attempts:
            attempt_id = stable_id("attempt", f"{run_id}|{result.source.source_id}|{attempt.attempt_number}")
            conn.execute(
                "INSERT INTO fetch_attempts VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT DO NOTHING",
                [attempt_id, run_id, result.source.source_id, attempt.attempt_number,
                 attempt.requested_at, attempt.completed_at, attempt.duration_ms, attempt.ttfb_ms,
                 attempt.http_status, attempt.response_bytes, attempt.final_url,
                 attempt.content_type, attempt.error_message],
            )
        conn.execute(
            """UPDATE sources SET
                 site_url=?, feed_title=?, feed_description=?, feed_reported_language=?, status=?, error_message=?, parser_warning=?,
                 articles_fetched=?, attempt_count=?, attempted_at=?, fetched_at=?, fetch_duration_ms=?,
                 response_time_ms=?, ttfb_ms=?, http_status=?, response_bytes=?, final_url=?, content_type=?,
                 latest_item_at=?, oldest_item_at=?
               WHERE source_id=?""",
            [meta.get("site_url"), meta.get("feed_title"), meta.get("feed_description"),
             meta.get("feed_reported_language"), result.status,
             result.error_message, result.parser_warning, len(result.articles), len(result.attempts),
             result.attempts[0].requested_at if result.attempts else now, now,
             result.fetch_duration_ms, meta.get("response_time_ms"), meta.get("ttfb_ms"),
             meta.get("http_status"), meta.get("response_bytes"), meta.get("final_url"),
             meta.get("content_type"), latest, oldest, result.source.source_id],
        )
        if result.status in {"done", "empty"}:
            conn.execute("DELETE FROM source_items WHERE source_id = ?", [result.source.source_id])
        if result.articles:
            item_placeholders = ",".join(["(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"] * len(result.articles))
            item_parameters = []
            for article in result.articles:
                item_parameters.extend([
                    article["item_id"], article["canonical_url"], article["raw_url"], article["title"],
                    article["published_at"], article["published_raw"], article["published_valid"],
                    article["summary"], article["content_text"], now, now,
                ])
            conn.execute(
                f"""INSERT INTO items VALUES {item_placeholders}
                   ON CONFLICT (item_id) DO UPDATE SET
                     canonical_url=COALESCE(EXCLUDED.canonical_url, items.canonical_url),
                     raw_url=COALESCE(EXCLUDED.raw_url, items.raw_url),
                     title=CASE WHEN length(COALESCE(EXCLUDED.title, '')) > length(COALESCE(items.title, ''))
                                THEN EXCLUDED.title ELSE items.title END,
                     published_at=COALESCE(EXCLUDED.published_at, items.published_at),
                     published_raw=COALESCE(EXCLUDED.published_raw, items.published_raw),
                     published_valid=items.published_valid OR EXCLUDED.published_valid,
                     summary=CASE WHEN length(COALESCE(EXCLUDED.summary, '')) > length(COALESCE(items.summary, ''))
                                  THEN EXCLUDED.summary ELSE items.summary END,
                     content_text=CASE WHEN length(COALESCE(EXCLUDED.content_text, '')) > length(COALESCE(items.content_text, ''))
                                       THEN EXCLUDED.content_text ELSE items.content_text END,
                     last_seen_at=EXCLUDED.last_seen_at""",
                item_parameters,
            )
            relation_placeholders = ",".join(["(?, ?, ?, ?)"] * len(result.articles))
            relation_parameters = []
            for article in result.articles:
                relation_parameters.extend([
                    result.source.source_id, article["item_id"], article["position"], now,
                ])
            conn.execute(
                f"""INSERT INTO source_items VALUES {relation_placeholders}
                    ON CONFLICT (source_id, item_id) DO UPDATE SET
                      position=EXCLUDED.position, observed_at=EXCLUDED.observed_at""",
                relation_parameters,
            )
        conn.execute("COMMIT")
    except Exception:
        conn.execute("ROLLBACK")
        raise


def parts_directory(output_prefix: Path) -> Path:
    return Path(f"{output_prefix}_merged_parts")


def reset_outputs(output_prefix: Path) -> None:
    shutil.rmtree(parts_directory(output_prefix), ignore_errors=True)
    for suffix in (
        "_sources.parquet", "_source_memberships.parquet",
        "_fetch_attempts.parquet", "_parts.parquet", "_merged.parquet",
        "_items.parquet", "_source_items.parquet",
    ):
        Path(f"{output_prefix}{suffix}").unlink(missing_ok=True)


def flush_parquet_batch(conn, output_prefix: Path) -> Path | None:
    relation_count = conn.execute("SELECT COUNT(*) FROM source_items").fetchone()[0]
    if relation_count == 0:
        # Failed and empty feeds contain no large text payload to unload.
        return None
    item_count = conn.execute("SELECT COUNT(*) FROM items").fetchone()[0]
    next_part = conn.execute("SELECT COALESCE(MAX(part_number), 0) + 1 FROM parquet_parts").fetchone()[0]
    directory = parts_directory(output_prefix)
    directory.mkdir(parents=True, exist_ok=True)
    final_path = directory / f"part-{next_part:06d}.parquet"
    temporary_path = directory / f"part-{next_part:06d}.tmp.parquet"
    temporary_path.unlink(missing_ok=True)
    conn.execute(
        f"""COPY (SELECT
            s.source_id, s.source_title, s.xml_url, s.canonical_xml_url, s.site_url,
            s.feed_title, s.feed_description, s.feed_reported_language, s.status,
            s.articles_fetched, s.fetched_at, s.fetch_duration_ms, s.response_time_ms,
            s.ttfb_ms, s.http_status, s.response_bytes, s.latest_item_at, s.oldest_item_at,
            si.position, si.observed_at,
            i.item_id, i.canonical_url AS item_url, i.raw_url AS item_raw_url,
            i.title, i.published_at, i.published_raw, i.published_valid,
            i.summary, i.content_text
          FROM source_items si
          JOIN sources s ON s.source_id = si.source_id
          JOIN items i ON i.item_id = si.item_id)
          TO '{_sql_path(temporary_path)}'
          (FORMAT PARQUET, COMPRESSION ZSTD, COMPRESSION_LEVEL 3)"""
    )
    temporary_path.replace(final_path)
    conn.execute("BEGIN")
    try:
        conn.execute(
            "INSERT INTO parquet_parts VALUES (?, ?, ?, ?, ?)",
            [next_part, str(final_path.resolve()), relation_count, item_count,
             datetime.now(timezone.utc).isoformat()],
        )
        conn.execute("DELETE FROM source_items")
        conn.execute("DELETE FROM items")
        conn.execute("COMMIT")
        conn.execute("CHECKPOINT")
    except Exception:
        conn.execute("ROLLBACK")
        raise
    return final_path


def _sql_path(path: Path) -> str:
    return str(path.resolve()).replace("'", "''")


def export_parquets(conn, output_prefix: Path) -> dict[str, Path]:
    outputs = {
        "sources": Path(f"{output_prefix}_sources.parquet"),
        "memberships": Path(f"{output_prefix}_source_memberships.parquet"),
        "attempts": Path(f"{output_prefix}_fetch_attempts.parquet"),
        "parts": Path(f"{output_prefix}_parts.parquet"),
    }
    table_queries = {
        "sources": "SELECT * FROM sources",
        "memberships": "SELECT * FROM source_memberships",
        "attempts": "SELECT * FROM fetch_attempts",
        "parts": "SELECT * FROM parquet_parts ORDER BY part_number",
    }
    output_prefix.parent.mkdir(parents=True, exist_ok=True)
    for name, path in outputs.items():
        path.unlink(missing_ok=True)
        conn.execute(
            f"COPY ({table_queries[name]}) TO '{_sql_path(path)}' "
            "(FORMAT PARQUET, COMPRESSION ZSTD, COMPRESSION_LEVEL 3)"
        )
    return outputs


def print_stats(conn, db_path: Path) -> None:
    status_rows = conn.execute("SELECT status, COUNT(*) FROM sources GROUP BY status ORDER BY status").fetchall()
    statuses = ", ".join(f"{status}={count}" for status, count in status_rows)
    buffered_items = conn.execute("SELECT COUNT(*) FROM items").fetchone()[0]
    buffered_relations = conn.execute("SELECT COUNT(*) FROM source_items").fetchone()[0]
    persisted = conn.execute(
        "SELECT COUNT(*), COALESCE(SUM(relation_count), 0) FROM parquet_parts"
    ).fetchone()
    memberships = conn.execute("SELECT COUNT(*) FROM source_memberships").fetchone()[0]
    attempts = conn.execute("SELECT COUNT(*) FROM fetch_attempts").fetchone()[0]
    latency = conn.execute("SELECT median(response_time_ms), quantile_cont(response_time_ms, 0.95) FROM sources WHERE response_time_ms IS NOT NULL").fetchone()
    db_mb = db_path.stat().st_size / 1024 / 1024 if db_path.exists() else 0
    print(f"DB: {db_mb:.1f} MB | Sources: {statuses}")
    print(
        f"Parquet parts: {persisted[0]}, {persisted[1]} persisted relations | "
        f"Buffer: {buffered_items} items, {buffered_relations} relations"
    )
    print(f"Memberships: {memberships} | Attempts: {attempts}")
    if latency[0] is not None:
        print(f"Response time: median={latency[0]:.0f} ms, p95={latency[1]:.0f} ms")


async def run_fetch(
    conn,
    sources: list[SourceRecord],
    *,
    concurrency: int,
    timeout: float,
    retries: int,
    max_articles: int,
    flush_every: int,
    output_prefix: Path,
) -> tuple[int, int]:
    run_id = stable_id("run", datetime.now(timezone.utc).isoformat())
    work_queue: asyncio.Queue[SourceRecord] = asyncio.Queue()
    result_queue: asyncio.Queue[FetchResult] = asyncio.Queue()
    for source in sources:
        work_queue.put_nowait(source)
    shutdown = False

    def on_sigint(signum, frame):
        nonlocal shutdown
        shutdown = True
        tqdm.write("\n[ctrl+c] Finishing current writes before stopping...")

    original_handler = signal.signal(signal.SIGINT, on_sigint)
    completed = 0
    failed = 0
    workers: list[asyncio.Task] = []
    try:
        async with FeedFetcher(timeout, retries, max_articles) as fetcher:
            async def worker() -> None:
                while True:
                    source = await work_queue.get()
                    try:
                        result = await fetcher.fetch_one(source)
                    except Exception as exc:
                        result = FetchResult(source, "failed", [], [], 0, error_message=str(exc)[:1000])
                    await result_queue.put(result)
                    work_queue.task_done()

            workers = [asyncio.create_task(worker()) for _ in range(min(concurrency, len(sources)))]
            with tqdm(total=len(sources), desc="Fetching feeds", unit="feed") as progress:
                while completed < len(sources):
                    result = await result_queue.get()
                    store_result(conn, result, run_id)
                    completed += 1
                    failed += result.status == "failed"
                    progress.update(1)
                    if completed % flush_every == 0:
                        part = flush_parquet_batch(conn, output_prefix)
                        if part:
                            tqdm.write(f"[parquet] Persisted {part.name}; content buffer cleared")
                    if completed % 50 == 0:
                        progress.set_postfix(failed=failed, status=result.status)
                        conn.execute("CHECKPOINT")
                    if shutdown:
                        break
    finally:
        signal.signal(signal.SIGINT, original_handler)
        for worker in workers:
            worker.cancel()
        if workers:
            await asyncio.gather(*workers, return_exceptions=True)
        conn.execute("CHECKPOINT")
    return completed, failed


def main() -> None:
    parser = argparse.ArgumentParser(description="FeedMine Corpus Builder v4")
    parser.add_argument("--reset", action="store_true", help="Rebuild the database and outputs from scratch")
    parser.add_argument("--limit", type=int, default=0, help="Fetch only the first N pending sources")
    parser.add_argument("--concurrency", type=int, default=MAX_CONCURRENT)
    parser.add_argument("--timeout", type=float, default=REQUEST_TIMEOUT, help="Per-request timeout in seconds")
    parser.add_argument("--retries", type=int, default=MAX_RETRIES)
    parser.add_argument("--max-articles", type=int, default=MAX_ARTICLES)
    parser.add_argument("--flush-every", type=int, default=500,
                        help="Persist and clear content after this many processed feeds")
    parser.add_argument("--retry-failed", action="store_true", help="Retry sources currently marked failed")
    parser.add_argument("--export-parquet", action="store_true", help="Export normalized Parquets and exit")
    parser.add_argument("--stats", action="store_true", help="Print database statistics and exit")
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--output-prefix", type=Path, default=DEFAULT_OUTPUT_PREFIX)
    parser.add_argument("--feeds-dir", type=Path, default=FEEDS_DIR)
    args = parser.parse_args()

    if any(value <= 0 for value in (
        args.concurrency, args.timeout, args.retries, args.max_articles, args.flush_every,
    )):
        parser.error("concurrency, timeout, retries, max-articles, and flush-every must all be positive")

    db_path = args.db.resolve()
    output_prefix = args.output_prefix.resolve()
    if args.reset:
        reset_outputs(output_prefix)
    try:
        conn = init_db(db_path, reset=args.reset)
    except RuntimeError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc

    try:
        if args.stats:
            print_stats(conn, db_path)
            return
        if args.export_parquet:
            flush_parquet_batch(conn, output_prefix)
            outputs = export_parquets(conn, output_prefix)
            for name, path in outputs.items():
                print(f"{name}: {path}")
            return

        print("=" * 60)
        print("FeedMine Corpus Builder v4")
        print("=" * 60)
        print(f"Feeds dir:   {args.feeds_dir.resolve()}")
        print(f"Database:    {db_path}")
        print(f"Concurrency: {args.concurrency}")
        manifest_path = args.feeds_dir / "opml_manifest.json"
        sources = discover_sources(args.feeds_dir, load_manifest(manifest_path))
        print(f"Catalog discovered: {len(sources)} unique sources, {sum(len(s.memberships) for s in sources)} memberships")
        register_catalog(conn, sources)
        pending = pending_sources(conn, sources, args.retry_failed)
        if args.limit:
            pending = pending[:args.limit]
        print(f"Pending: {len(pending)}")
        if pending:
            completed, failed = asyncio.run(run_fetch(
                conn, pending, concurrency=args.concurrency, timeout=args.timeout,
                retries=args.retries, max_articles=args.max_articles,
                flush_every=args.flush_every, output_prefix=output_prefix,
            ))
            print(f"Processed: {completed}, failed: {failed}")
        else:
            print("Nothing to fetch.")
        final_part = flush_parquet_batch(conn, output_prefix)
        if final_part:
            print(f"Persisted final content part: {final_part.name}")
        print_stats(conn, db_path)
        outputs = export_parquets(conn, output_prefix)
        print("Parquet exports:")
        for name, path in outputs.items():
            print(f"  {name}: {path}")
        print(f"  content: {parts_directory(output_prefix)}/*.parquet")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
