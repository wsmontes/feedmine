#!/usr/bin/env python3
"""Download articles from every RSS/Atom feed in the OPML collection.

Walks 4,534 OPML files (~52K sources), fetches up to 30 articles per feed,
and stores everything in DuckDB (resumable).  Exports to Parquet on request.

Usage:
    source .venv_feeds/bin/activate
    python scripts/fetch_all_feeds.py                     # run (resumes)
    python scripts/fetch_all_feeds.py --reset              # fresh start
    python scripts/fetch_all_feeds.py --limit 500          # test subset
    python scripts/fetch_all_feeds.py --export-parquet     # export to parquet
"""

from __future__ import annotations

import argparse
import asyncio
import json
import re
import signal
import sys
import unicodedata
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

import duckdb
import feedparser
import html2text
import httpx
from tqdm import tqdm

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

FEEDS_DIR = Path(__file__).resolve().parent.parent / "feedmine" / "Resources" / "Feeds"
MANIFEST_PATH = FEEDS_DIR / "opml_manifest.json"
DB_PATH = Path(__file__).resolve().parent.parent / "feeds_corpus.duckdb"
DEFAULT_EXPORT = Path(__file__).resolve().parent.parent / "feeds_corpus.parquet"

MAX_ARTICLES_PER_FEED = 30
MAX_CONCURRENT = 50
REQUEST_TIMEOUT = 30.0
MAX_RETRIES = 3
USER_AGENT = "FeedMine/1.0 (feed corpus builder; +https://github.com/feedmine)"

# HTML stripper for cleaning article content
_html_stripper = html2text.HTML2Text()
_html_stripper.ignore_links = True
_html_stripper.ignore_images = True
_html_stripper.ignore_emphasis = True
_html_stripper.body_width = 0
_html_stripper.ignore_tables = True


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def clean_html(raw: str | None) -> str | None:
    """Convert HTML to plain text, or return None for empty/invalid input."""
    if not raw:
        return None
    text = _html_stripper.handle(raw).strip()
    return text or None


def clean_text(raw: str | None) -> str | None:
    """Collapse whitespace and strip.  Returns None for empty."""
    if not raw:
        return None
    text = re.sub(r"\s+", " ", raw).strip()
    return text or None


def canonical_url(raw: str) -> str:
    """Normalise a URL: lowercase scheme+host, remove fragments."""
    trimmed = raw.strip()
    p = urlsplit(trimmed)
    scheme = (p.scheme or "https").lower()
    hostname = (p.hostname or "").lower()
    netloc = hostname
    if p.port:
        netloc = f"{hostname}:{p.port}"
    return urlunsplit((scheme, netloc, p.path or "/", p.query, ""))


def slugify(raw: str) -> str:
    """Generate a safe, stable identifier fragment from a string."""
    folded = unicodedata.normalize("NFKD", raw).encode("ascii", "ignore").decode("ascii")
    collapsed = re.sub(r"[^a-z0-9]+", "-", folded.lower()).strip("-")
    return collapsed or "untitled"


# ---------------------------------------------------------------------------
# Data classes
# ---------------------------------------------------------------------------


@dataclass
class SourceRecord:
    """A single feed source parsed from an OPML file."""

    title: str
    xml_url: str
    category: str  # top-level folder (e.g. "Tech_Science")
    subcategory: str | None  # parent outline text (e.g. "Tech")
    language: str | None  # from OPML <head><language>
    region: str  # "global" or "country/region"
    country: str | None  # derived from path when under countries/
    opml_file: str  # relative path from Feeds/


@dataclass
class ArticleRecord:
    """A single article extracted from a feed."""

    title: str | None
    url: str | None
    published: str | None
    summary: str | None
    content_text: str | None  # plain text, HTML stripped


# ---------------------------------------------------------------------------
# Phase 1 – Parse OPMLs
# ---------------------------------------------------------------------------


def load_manifest() -> dict[str, dict]:
    """Load opml_manifest.json and index by relative path."""
    with open(MANIFEST_PATH) as fh:
        data = json.load(fh)
    index: dict[str, dict] = {}
    for entry in data.get("files", []):
        path = entry.get("path", "")
        if path:
            index[path] = entry
    return index


def parse_opml(file_path: Path, rel_path: str, manifest_index: dict[str, dict]) -> list[SourceRecord]:
    """Parse one OPML file and return all SourceRecords found."""
    tree = ET.parse(file_path)
    root = tree.getroot()

    # --- OPML head metadata ---
    head = root.find("head")
    language = None
    opml_title = None
    if head is not None:
        lang_el = head.find("language")
        if lang_el is not None and lang_el.text:
            language = lang_el.text.strip()
        title_el = head.find("title")
        if title_el is not None and title_el.text:
            opml_title = title_el.text.strip()

    # --- Category & region ---
    parts = Path(rel_path).parts
    if parts and parts[0] == "countries":
        # e.g. countries/brazil/brazil.opml
        category = "countries"
        country = parts[1] if len(parts) > 1 else None
    else:
        category = parts[0] if parts else "unknown"
        country = None

    # --- Look up manifest entry ---
    manifest_entry = manifest_index.get(rel_path, {})
    region = manifest_entry.get("region", "global")

    # --- Walk outlines recursively ---
    body = root.find("body")
    if body is None:
        return []

    sources: list[SourceRecord] = []
    _walk_outlines(body, category, region, country, language or None, rel_path, [], sources)
    return sources


def _walk_outlines(
    element: ET.Element,
    category: str,
    region: str,
    country: str | None,
    language: str | None,
    opml_file: str,
    parent_chain: list[str],
    out: list[SourceRecord],
) -> None:
    """Recursively walk <outline> elements, accumulating SourceRecords."""
    for child in element.findall("outline"):
        text_attr = child.get("text", "").strip()
        xml_url = child.get("xmlUrl", "").strip()
        title_attr = child.get("title", "").strip()

        # Does this outline have actual feed children?
        has_feed_children = any(
            gc.get("xmlUrl", "").strip() for gc in child.findall("outline")
        )

        if xml_url:
            # This is a feed source
            subcategory = " / ".join(parent_chain) if parent_chain else None
            out.append(
                SourceRecord(
                    title=title_attr or text_attr or xml_url,
                    xml_url=xml_url,
                    category=category,
                    subcategory=subcategory,
                    language=language,
                    region=region,
                    country=country,
                    opml_file=opml_file,
                )
            )
        elif text_attr and has_feed_children:
            # This is a subcategory container — descend
            _walk_outlines(
                child, category, region, country, language, opml_file,
                parent_chain + [text_attr], out,
            )
        elif has_feed_children:
            # Container without text — still descend
            _walk_outlines(
                child, category, region, country, language, opml_file,
                parent_chain, out,
            )
        elif text_attr:
            # Leaf node without xmlUrl — skip (placeholder)
            pass


def discover_sources(
    feeds_dir: Path,
    manifest_index: dict[str, dict],
) -> list[SourceRecord]:
    """Walk the Feeds directory and parse every OPML file."""
    all_sources: list[SourceRecord] = []
    opml_files = sorted(feeds_dir.rglob("*.opml"))

    print(f"Found {len(opml_files)} OPML files. Parsing...")
    for fp in tqdm(opml_files, desc="Parsing OPMLs", unit="file"):
        # Skip .tmp files
        if fp.name.endswith(".tmp"):
            continue
        try:
            rel = str(fp.relative_to(feeds_dir))
        except ValueError:
            continue
        try:
            sources = parse_opml(fp, rel, manifest_index)
            all_sources.extend(sources)
        except ET.ParseError as exc:
            tqdm.write(f"  [skip] XML parse error in {rel}: {exc}")
        except Exception as exc:
            tqdm.write(f"  [skip] Unexpected error in {rel}: {exc}")

    return all_sources


# ---------------------------------------------------------------------------
# Phase 2 – Fetch feeds (async)
# ---------------------------------------------------------------------------


def extract_articles(feed_data: feedparser.FeedParserDict) -> list[ArticleRecord]:
    """Extract up to MAX_ARTICLES_PER_FEED articles from a parsed feed."""
    articles: list[ArticleRecord] = []
    for entry in feed_data.entries[:MAX_ARTICLES_PER_FEED]:
        # Get the best content available
        content = None
        if entry.get("content"):
            content = entry.content[0].get("value", "")
        elif entry.get("content"):
            content = str(entry.content)

        summary = entry.get("summary", "") or entry.get("description", "")
        summary_clean = clean_html(summary)

        # If we have a summary and no full content, summary becomes content
        if not content and summary_clean:
            content = summary_clean
            summary_clean = None
        elif content:
            content = clean_html(content)

        articles.append(
            ArticleRecord(
                title=clean_text(entry.get("title", "")),
                url=entry.get("link", ""),
                published=entry.get("published", "") or entry.get("updated", ""),
                summary=summary_clean,
                content_text=content,
            )
        )
    return articles


class FeedFetcher:
    """Async feed fetcher with bounded concurrency and retries."""

    def __init__(
        self,
        concurrency: int = MAX_CONCURRENT,
        timeout: float = REQUEST_TIMEOUT,
        max_retries: int = MAX_RETRIES,
    ):
        self.concurrency = concurrency
        self.timeout = timeout
        self.max_retries = max_retries
        self.semaphore = asyncio.Semaphore(concurrency)
        self.client: httpx.AsyncClient | None = None
        self._request_count = 0
        self._error_count = 0

    async def __aenter__(self):
        limits = httpx.Limits(
            max_connections=self.concurrency + 10,
            max_keepalive_connections=self.concurrency // 2,
        )
        self.client = httpx.AsyncClient(
            timeout=self.timeout,
            limits=limits,
            headers={"User-Agent": USER_AGENT},
            follow_redirects=True,
        )
        return self

    async def __aexit__(self, *args):
        if self.client:
            await self.client.aclose()

    async def fetch_one(
        self, source: SourceRecord
    ) -> tuple[SourceRecord, list[ArticleRecord], str | None, dict | None]:
        """Fetch one feed. Returns (source, articles, error, feed_meta)."""
        async with self.semaphore:
            url = source.xml_url
            last_error = None

            for attempt in range(1, self.max_retries + 1):
                try:
                    resp = await self.client.get(url)
                    resp.raise_for_status()
                    content = resp.text

                    feed_data = feedparser.parse(content)

                    if feed_data.bozo and not feed_data.entries:
                        # feedparser error with no entries at all
                        bozo_msg = str(feed_data.bozo_exception)
                        raise RuntimeError(f"Feed parse error: {bozo_msg}")

                    articles = extract_articles(feed_data)

                    # Feed-level metadata
                    feed_meta = {
                        "feed_title": clean_text(
                            feed_data.feed.get("title", "")
                        ),
                        "feed_description": clean_html(
                            feed_data.feed.get("description", "")
                            or feed_data.feed.get("subtitle", "")
                        ),
                        "site_url": feed_data.feed.get("link", ""),
                    }

                    self._request_count += 1
                    return (source, articles, None, feed_meta)

                except httpx.TimeoutException:
                    last_error = f"Timeout after {self.timeout}s"
                    if attempt < self.max_retries:
                        await asyncio.sleep(2 ** (attempt - 1))
                except httpx.HTTPStatusError as exc:
                    last_error = f"HTTP {exc.response.status_code}"
                    if exc.response.status_code in (429, 500, 502, 503, 504):
                        if attempt < self.max_retries:
                            await asyncio.sleep(2 ** (attempt - 1))
                    else:
                        break  # don't retry 4xx (except 429)
                except Exception as exc:
                    last_error = str(exc)[:500]
                    if attempt < self.max_retries:
                        await asyncio.sleep(2 ** (attempt - 1))

            self._error_count += 1
            return (source, [], last_error, None)


# ---------------------------------------------------------------------------
# Phase 3 – DuckDB storage
# ---------------------------------------------------------------------------

CREATE_TABLES_SQL = """
CREATE SEQUENCE IF NOT EXISTS seq_source_id START 1;
CREATE SEQUENCE IF NOT EXISTS seq_article_id START 1;

CREATE TABLE IF NOT EXISTS sources (
    source_id      INTEGER PRIMARY KEY DEFAULT nextval('seq_source_id'),
    source_title   VARCHAR,
    xml_url        VARCHAR UNIQUE NOT NULL,
    site_url       VARCHAR,
    feed_title     VARCHAR,
    feed_description VARCHAR,
    category       VARCHAR,
    subcategory    VARCHAR,
    language       VARCHAR,
    region         VARCHAR,
    country        VARCHAR,
    opml_file      VARCHAR,
    status         VARCHAR DEFAULT 'pending',
    error_message  VARCHAR,
    articles_fetched INTEGER DEFAULT 0,
    fetched_at     VARCHAR
);

CREATE TABLE IF NOT EXISTS articles (
    article_id     INTEGER PRIMARY KEY DEFAULT nextval('seq_article_id'),
    source_id      INTEGER NOT NULL REFERENCES sources(source_id),
    title          VARCHAR,
    url            VARCHAR,
    published      VARCHAR,
    summary        VARCHAR,
    content_text   VARCHAR
);

CREATE INDEX IF NOT EXISTS idx_articles_source ON articles(source_id);
CREATE INDEX IF NOT EXISTS idx_sources_status ON sources(status);
CREATE INDEX IF NOT EXISTS idx_sources_xml_url ON sources(xml_url);
"""


def init_db(db_path: str, reset: bool = False) -> duckdb.DuckDBPyConnection:
    """Open DuckDB, create tables, return connection."""
    # Create parent dir if needed
    Path(db_path).parent.mkdir(parents=True, exist_ok=True)

    conn = duckdb.connect(db_path)
    if reset:
        conn.execute("DROP TABLE IF EXISTS articles")
        conn.execute("DROP TABLE IF EXISTS sources")
        conn.execute("DROP SEQUENCE IF EXISTS seq_source_id")
        conn.execute("DROP SEQUENCE IF EXISTS seq_article_id")
    conn.execute(CREATE_TABLES_SQL)
    return conn


def load_done_urls(conn: duckdb.DuckDBPyConnection) -> set[str]:
    """Return set of xml_urls already fetched successfully."""
    rows = conn.execute(
        "SELECT xml_url FROM sources WHERE status = 'done'"
    ).fetchall()
    return {r[0] for r in rows}


def _escape_sql_str(val: str | None) -> str:
    """Escape a string for safe use in a SQL VALUES clause."""
    if val is None:
        return "NULL"
    escaped = val.replace("'", "''")
    return f"'{escaped}'"


def insert_sources_batch(conn: duckdb.DuckDBPyConnection, sources: list[SourceRecord], chunk_size: int = 2000) -> None:
    """Insert new sources in chunks using fast bulk VALUES (skip duplicates on xml_url)."""
    for i in range(0, len(sources), chunk_size):
        chunk = sources[i : i + chunk_size]
        value_tuples = []
        for s in chunk:
            vals = ", ".join([
                _escape_sql_str(s.title),
                _escape_sql_str(s.xml_url),
                _escape_sql_str(s.category),
                _escape_sql_str(s.subcategory),
                _escape_sql_str(s.language),
                _escape_sql_str(s.region),
                _escape_sql_str(s.country),
                _escape_sql_str(s.opml_file),
                "'pending'",
            ])
            value_tuples.append(f"({vals})")
        sql = (
            "INSERT OR IGNORE INTO sources"
            " (source_title, xml_url, category, subcategory, language,"
            "  region, country, opml_file, status)"
            " VALUES " + ", ".join(value_tuples)
        )
        conn.execute(sql)


def mark_source_done(
    conn: duckdb.DuckDBPyConnection,
    source: SourceRecord,
    articles: list[ArticleRecord],
    feed_meta: dict | None,
) -> None:
    """Mark a source as done and insert its articles in a transaction."""
    now = datetime.now(timezone.utc).isoformat()
    site_url = (feed_meta or {}).get("site_url", "")
    feed_title = (feed_meta or {}).get("feed_title", "")
    feed_desc = (feed_meta or {}).get("feed_description", "")

    conn.execute("BEGIN")
    try:
        # Update source record
        conn.execute(
            """UPDATE sources SET
                 status = 'done',
                 error_message = NULL,
                 articles_fetched = ?,
                 fetched_at = ?,
                 site_url = ?,
                 feed_title = ?,
                 feed_description = ?
               WHERE xml_url = ?""",
            [len(articles), now, site_url, feed_title, feed_desc, source.xml_url],
        )

        # Get source_id
        sid_row = conn.execute(
            "SELECT source_id FROM sources WHERE xml_url = ?", [source.xml_url]
        ).fetchone()
        if sid_row is None:
            conn.execute("ROLLBACK")
            return
        sid = sid_row[0]

        # Insert articles (bulk VALUES - fast even for many rows)
        if articles:
            value_tuples = []
            for a in articles:
                vals = ", ".join([
                    str(sid),
                    _escape_sql_str(a.title),
                    _escape_sql_str(a.url),
                    _escape_sql_str(a.published),
                    _escape_sql_str(a.summary),
                    _escape_sql_str(a.content_text),
                ])
                value_tuples.append(f"({vals})")
            conn.execute(
                "INSERT INTO articles"
                " (source_id, title, url, published, summary, content_text)"
                " VALUES " + ", ".join(value_tuples)
            )
        conn.execute("COMMIT")
    except Exception:
        conn.execute("ROLLBACK")
        raise


def mark_source_failed(
    conn: duckdb.DuckDBPyConnection, source: SourceRecord, error: str
) -> None:
    """Mark a source as failed."""
    now = datetime.now(timezone.utc).isoformat()
    conn.execute(
        """UPDATE sources SET status = 'failed', error_message = ?, fetched_at = ?
           WHERE xml_url = ?""",
        [error[:1000], now, source.xml_url],
    )


# ---------------------------------------------------------------------------
# Phase 5 – Export to Parquet
# ---------------------------------------------------------------------------


def export_parquet(db_path: str, output_path: str) -> None:
    """Export the joined sources+articles view to a single Parquet file."""
    conn = duckdb.connect(db_path)
    count = conn.execute("SELECT COUNT(*) FROM articles").fetchone()[0]
    print(f"Exporting {count} articles from DuckDB → {output_path} ...")

    conn.execute(
        f"""
        COPY (
            SELECT
                s.source_title,
                s.xml_url,
                s.site_url,
                s.feed_title,
                s.feed_description,
                s.category,
                s.subcategory,
                s.language,
                s.region,
                s.country,
                s.opml_file,
                a.title AS article_title,
                a.url   AS article_url,
                a.published AS article_date,
                a.summary AS article_summary,
                a.content_text AS article_content
            FROM sources s
            JOIN articles a ON a.source_id = s.source_id
            ORDER BY s.category, s.source_title, a.published
        ) TO '{output_path}' (FORMAT PARQUET, COMPRESSION ZSTD)
        """
    )
    print(f"Done.  Exported to {output_path}")


# ---------------------------------------------------------------------------
# Main orchestration
# ---------------------------------------------------------------------------


async def run_fetch(
    db_path: str,
    sources: list[SourceRecord],
    concurrency: int,
    batch_commit_interval: int = 200,
    limit: int = 0,
) -> None:
    """Main async loop: fetch all pending sources, store results via a writer thread."""

    # Load skip list for resume (open a temp read connection)
    read_conn = duckdb.connect(db_path)
    done_urls: set[str] = {
        r[0] for r in read_conn.execute(
            "SELECT xml_url FROM sources WHERE status = 'done'"
        ).fetchall()
    }
    read_conn.close()

    pending = [s for s in sources if s.xml_url not in done_urls]

    # Deduplicate by canonical url
    seen: dict[str, SourceRecord] = {}
    for s in pending:
        key = canonical_url(s.xml_url)
        if key not in seen:
            seen[key] = s
    pending = list(seen.values())

    if limit and limit < len(pending):
        pending = pending[:limit]

    total = len(pending)
    done_count = len(done_urls)
    print(f"\nTotal sources in DB: {len(sources)}")
    print(f"Already done:       {done_count}")
    print(f"Pending to fetch:   {total}")
    sys.stdout.flush()
    if total == 0:
        print("Nothing to do.")
        return

    # Writer queue + thread
    from concurrent.futures import ThreadPoolExecutor
    from queue import Queue as ThreadQueue

    write_queue: ThreadQueue = ThreadQueue()

    def _writer():
        """Thread worker: consumes results and writes to DuckDB."""
        wconn = duckdb.connect(db_path)
        try:
            while True:
                item = write_queue.get()
                if item is None:  # sentinel — flush and stop
                    break
                source, articles, feed_meta = item
                try:
                    mark_source_done(wconn, source, articles, feed_meta)
                except Exception:
                    mark_source_failed(wconn, source, "write error")
        finally:
            wconn.close()

    def _write_error(source: SourceRecord, error: str):
        """Thread-safe error writer via queue."""
        wconn2 = duckdb.connect(db_path)
        try:
            mark_source_failed(wconn2, source, error)
        finally:
            wconn2.close()

    executor = ThreadPoolExecutor(max_workers=1)
    writer_future = executor.submit(_writer)

    # Progress bar
    pbar = tqdm(total=total, desc="Fetching feeds", unit="feed")

    completed = 0
    failed = 0
    batched = 0
    batch_sources: list[SourceRecord] = []
    batch_articles: list[list[ArticleRecord]] = []
    batch_metas: list[dict | None] = []
    batch_errors: list[tuple[SourceRecord, str]] = []

    # Graceful shutdown on Ctrl+C
    shutdown = False
    original_sigint = signal.getsignal(signal.SIGINT)

    def _on_sigint(signum, frame):
        nonlocal shutdown
        shutdown = True
        tqdm.write("\n[ctrl+c] Shutting down gracefully — saving progress...")

    signal.signal(signal.SIGINT, _on_sigint)

    try:
        async with FeedFetcher(concurrency=concurrency) as fetcher:
            # Wrap each fetch to return (source, result) for easy matching
            async def _fetch_with_source(source):
                result = await fetcher.fetch_one(source)
                return (source, result)

            tasks = [
                asyncio.create_task(_fetch_with_source(source))
                for source in pending
            ]

            # Process as they complete (not blocked by slowest)
            for coro in asyncio.as_completed(tasks):
                if shutdown:
                    break
                try:
                    source, result = await coro
                except Exception as exc:
                    failed += 1
                    pbar.update(1)
                    continue

                _, articles, error, feed_meta = result

                if error:
                    batch_errors.append((source, error))
                    failed += 1
                else:
                    batch_sources.append(source)
                    batch_articles.append(articles)
                    batch_metas.append(feed_meta)
                    batched += 1

                completed += 1
                pbar.update(1)

                # Commit batch to DuckDB (via writer thread)
                if batched >= batch_commit_interval:
                    for s, arts, meta in zip(batch_sources, batch_articles, batch_metas):
                        write_queue.put((s, arts, meta))
                    batch_sources.clear()
                    batch_articles.clear()
                    batch_metas.clear()
                    batched = 0

                # Write errors in bulk
                if len(batch_errors) >= batch_commit_interval:
                    for s, e in batch_errors:
                        _write_error(s, e)
                    batch_errors.clear()

                if completed % 50 == 0:
                    pbar.set_postfix(done=completed, fail=failed)

    finally:
        signal.signal(signal.SIGINT, original_sigint)

    # Final flush
    for s, arts, meta in zip(batch_sources, batch_articles, batch_metas):
        write_queue.put((s, arts, meta))
    for source, error in batch_errors:
        _write_error(source, error)

    # Signal writer to stop
    write_queue.put(None)
    executor.shutdown(wait=True)

    pbar.close()
    print(f"\nDone. {completed} processed ({failed} failed).")


def stats(conn: duckdb.DuckDBPyConnection) -> None:
    """Print summary statistics."""
    print("\n--- Database Stats ---")
    total_sources = conn.execute("SELECT COUNT(*) FROM sources").fetchone()[0]
    done = conn.execute("SELECT COUNT(*) FROM sources WHERE status = 'done'").fetchone()[0]
    failed = conn.execute("SELECT COUNT(*) FROM sources WHERE status = 'failed'").fetchone()[0]
    pending = conn.execute("SELECT COUNT(*) FROM sources WHERE status = 'pending'").fetchone()[0]
    total_articles = conn.execute("SELECT COUNT(*) FROM articles").fetchone()[0]

    print(f"Sources:  {total_sources} total | {done} done | {failed} failed | {pending} pending")
    print(f"Articles: {total_articles}")

    if done > 0:
        avg = conn.execute(
            "SELECT AVG(articles_fetched) FROM sources WHERE status = 'done'"
        ).fetchone()[0]
        print(f"Avg articles per source: {avg:.1f}")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(
        description="FeedMine Corpus Builder — downloads all RSS/Atom articles to DuckDB"
    )
    parser.add_argument(
        "--reset", action="store_true",
        help="Drop existing data and start fresh."
    )
    parser.add_argument(
        "--limit", type=int, default=0,
        help="Only fetch N sources (for testing). 0 = all."
    )
    parser.add_argument(
        "--concurrency", type=int, default=MAX_CONCURRENT,
        help=f"Max concurrent HTTP requests (default: {MAX_CONCURRENT})."
    )
    parser.add_argument(
        "--timeout", type=float, default=REQUEST_TIMEOUT,
        help=f"Request timeout in seconds (default: {REQUEST_TIMEOUT})."
    )
    parser.add_argument(
        "--export-parquet", type=str, nargs="?", const=str(DEFAULT_EXPORT), default=None,
        help="Export DuckDB to Parquet and exit. Optional path argument."
    )
    parser.add_argument(
        "--db", type=str, default=str(DB_PATH),
        help=f"Path to DuckDB file (default: {DB_PATH})."
    )
    parser.add_argument(
        "--feeds-dir", type=str, default=str(FEEDS_DIR),
        help=f"Path to Feeds directory (default: {FEEDS_DIR})."
    )
    parser.add_argument(
        "--skip-fetch", action="store_true",
        help="Only parse OPMLs and populate sources table, then exit."
    )
    parser.add_argument(
        "--stats", action="store_true",
        help="Print DB statistics and exit."
    )

    args = parser.parse_args()

    # Stats only mode
    if args.stats:
        if not Path(args.db).exists():
            print(f"No database at {args.db}")
            sys.exit(1)
        conn = init_db(args.db)
        stats(conn)
        conn.close()
        return

    # Export-only mode
    if args.export_parquet:
        if not Path(args.db).exists():
            print(f"No database at {args.db}")
            sys.exit(1)
        export_parquet(args.db, args.export_parquet)
        return

    # --- Main pipeline ---
    print("=" * 60)
    print("FeedMine Corpus Builder")
    print("=" * 60)
    print(f"Feeds dir: {args.feeds_dir}")
    print(f"Database:  {args.db}")
    print(f"Concurrency: {args.concurrency}")
    if args.limit:
        print(f"Limit:     {args.limit} sources")
    if args.reset:
        print("[reset] Starting fresh.")

    # 1. Parse OPMLs → SourceRecords
    manifest = load_manifest()
    all_sources = discover_sources(Path(args.feeds_dir), manifest)

    # Deduplicate by canonical URL
    seen: dict[str, SourceRecord] = {}
    for s in all_sources:
        key = canonical_url(s.xml_url)
        if key not in seen:
            seen[key] = s
    all_sources = list(seen.values())
    print(f"\nParsed {len(all_sources)} unique sources from OPMLs.")

    # 2. Init DuckDB + insert sources
    conn = init_db(args.db, reset=args.reset)
    insert_sources_batch(conn, all_sources)
    print("Sources table populated.")

    # Stats after insert
    stats(conn)

    if args.skip_fetch:
        print("\n[skip-fetch] Done. Sources inserted, no feeds fetched.")
        conn.close()
        return

    # 3. Fetch feeds
    conn.close()  # close main connection before async work to avoid locks

    asyncio.run(
        run_fetch(
            db_path=args.db,
            sources=all_sources,
            concurrency=args.concurrency,
            limit=args.limit,
        )
    )

    # Re-open for final stats
    conn = init_db(args.db)

    # 4. Final stats
    stats(conn)
    conn.close()
    print("\nAll done. Use --export-parquet to export to Parquet.")


if __name__ == "__main__":
    main()
