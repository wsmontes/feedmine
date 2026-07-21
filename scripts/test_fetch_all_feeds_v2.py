from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import duckdb
import feedparser

from scripts.fetch_all_feeds_v2 import (
    FetchAttempt,
    FetchResult,
    MembershipRecord,
    SourceRecord,
    clean_html,
    clean_text,
    export_parquets,
    extract_articles,
    flush_parquet_batch,
    init_db,
    normalize_published,
    parse_opml,
    register_catalog,
    stable_id,
    store_result,
)


class TextCleaningTests(unittest.TestCase):
    def test_html_cleaner_has_no_cross_call_state(self):
        first = clean_html('<p>A <abbr title="Friday">Fri</abbr> update.</p>')
        second = clean_html("<p>An unrelated story.</p>")

        self.assertEqual(first, "A Fri update.")
        self.assertEqual(second, "An unrelated story.")
        self.assertNotIn("Friday", second or "")

    def test_decodes_numeric_entities_even_when_double_escaped(self):
        value = clean_text("Tom &amp;#38; Ana &amp;#8217;s &amp;#8220;story&amp;#8221;")
        self.assertEqual(value, "Tom & Ana ’s “story”")
        self.assertNotIn("&#", value)


class CatalogParsingTests(unittest.TestCase):
    def test_nested_outline_keeps_claimed_language_and_membership(self):
        xml = """<?xml version="1.0"?>
        <opml version="2.0">
          <head><title>Example catalog</title><language>en</language></head>
          <body><outline text="Podcasts"><outline title="Uno" language="es"
            xmlUrl="https://example.com/feed.xml" mediaKind="audio" /></outline></body>
        </opml>"""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "sample.opml"
            path.write_text(xml, encoding="utf-8")
            records = parse_opml(path, "countries/nicaragua/sample.opml", {})

        self.assertEqual(len(records), 1)
        title, url, membership = records[0]
        self.assertEqual((title, url), ("Uno", "https://example.com/feed.xml"))
        self.assertEqual(membership.subcategory, "Podcasts")
        self.assertEqual(membership.claimed_language, "es")
        self.assertEqual(membership.claimed_country, "nicaragua")
        self.assertEqual(membership.claimed_media_kind, "audio")


class ArticleExtractionTests(unittest.TestCase):
    def test_deduplicates_items_and_normalizes_dates(self):
        feed = feedparser.FeedParserDict()
        feed.entries = [
            feedparser.FeedParserDict({
                "title": "Same &amp; title",
                "link": "https://example.com/story?utm_source=x",
                "published": "Fri, 17 Jul 2026 10:00:00 GMT",
                "summary": "<p>Hello &#8217; world</p>",
            }),
            feedparser.FeedParserDict({
                "title": "Duplicate",
                "link": "https://example.com/story?utm_source=y",
                "published": "Fri, 17 Jul 2026 10:00:00 GMT",
            }),
        ]

        articles = extract_articles(feed, "source-1")

        self.assertEqual(len(articles), 1)
        self.assertEqual(articles[0]["canonical_url"], "https://example.com/story")
        self.assertEqual(articles[0]["title"], "Same & title")
        self.assertEqual(articles[0]["content_text"], "Hello ’ world")
        self.assertTrue(articles[0]["published_valid"])
        self.assertTrue(articles[0]["published_at"].startswith("2026-07-17T10:00:00"))

    def test_rejects_implausible_date_but_keeps_raw_value(self):
        feed = feedparser.FeedParserDict()
        feed.entries = [feedparser.FeedParserDict({
            "title": "Old typo",
            "link": "https://example.com/old",
            "published": "1 Jan 0024 00:00:00 GMT",
        })]

        article = extract_articles(feed, "source-1")[0]

        self.assertIsNone(article["published_at"])
        self.assertFalse(article["published_valid"])
        self.assertIn("0024", article["published_raw"])

    def test_uses_created_date_when_primary_dates_are_missing(self):
        entry = feedparser.FeedParserDict({
            "created": "Thu, 16 Jul 2026 12:00:00 GMT",
        })

        published_at, published_raw, published_valid = normalize_published(entry)

        self.assertTrue(published_valid)
        self.assertEqual(published_raw, "Thu, 16 Jul 2026 12:00:00 GMT")
        self.assertTrue(published_at.startswith("2026-07-16T12:00:00"))

    def test_infers_date_from_canonical_url_when_feed_omits_dates(self):
        feed = feedparser.FeedParserDict()
        feed.entries = [feedparser.FeedParserDict({
            "title": "Architecture dispatch",
            "link": "https://example.com/2026/07/11/story?utm_source=x",
        })]

        article = extract_articles(feed, "source-1")[0]

        self.assertTrue(article["published_valid"])
        self.assertEqual(article["published_raw"], "inferred:2026/07/11")
        self.assertTrue(article["published_at"].startswith("2026-07-11T00:00:00"))

    def test_infers_month_name_date_from_title_when_feed_omits_dates(self):
        feed = feedparser.FeedParserDict()
        feed.entries = [feedparser.FeedParserDict({
            "title": "Book Riot's Deals of the Day for July 16, 2026",
            "link": "https://example.com/deals",
        })]

        article = extract_articles(feed, "source-1")[0]

        self.assertTrue(article["published_valid"])
        self.assertEqual(article["published_raw"], "inferred:July 16, 2026")
        self.assertTrue(article["published_at"].startswith("2026-07-16T00:00:00"))


class PersistenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.db_path = self.root / "corpus.duckdb"
        self.conn = init_db(self.db_path, reset=True)
        canonical = "https://example.com/feed.xml"
        membership = MembershipRecord(
            "countries", "sample", "Podcasts", "es", "latam", "nicaragua",
            "countries/nicaragua/sample.opml", "Sample", "audio",
        )
        self.source = SourceRecord(
            stable_id("source", canonical), "Example", canonical, canonical, [membership]
        )
        register_catalog(self.conn, [self.source])

    def tearDown(self):
        self.conn.close()
        self.temp.cleanup()

    def _result(self) -> FetchResult:
        item_url = "https://example.com/item"
        article = {
            "item_id": stable_id("item-url", item_url),
            "position": 0,
            "title": "Item",
            "raw_url": item_url,
            "canonical_url": item_url,
            "published_at": "2026-07-17T10:00:00+00:00",
            "published_raw": "Fri, 17 Jul 2026 10:00:00 GMT",
            "published_valid": True,
            "summary": None,
            "content_text": "Useful body",
        }
        attempt = FetchAttempt(
            1, "2026-07-17T10:00:00+00:00", "2026-07-17T10:00:00.250000+00:00",
            250, 80, 200, 4096, self.source.xml_url, "application/rss+xml", None,
        )
        meta = {
            "feed_title": "Example Feed",
            "feed_description": "Description",
            "feed_reported_language": "en",
            "site_url": "https://example.com",
            "final_url": self.source.xml_url,
            "http_status": 200,
            "content_type": "application/rss+xml",
            "response_bytes": 4096,
            "response_time_ms": 250,
            "ttfb_ms": 80,
        }
        return FetchResult(self.source, "done", [article], [attempt], 275, meta)

    def test_rerun_is_idempotent_and_keeps_response_metrics(self):
        store_result(self.conn, self._result(), "run-one")
        store_result(self.conn, self._result(), "run-two")

        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM items").fetchone()[0], 1)
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM source_items").fetchone()[0], 1)
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM fetch_attempts").fetchone()[0], 2)
        metrics = self.conn.execute(
            "SELECT response_time_ms, ttfb_ms, response_bytes, http_status, feed_reported_language FROM sources"
        ).fetchone()
        self.assertEqual(metrics, (250, 80, 4096, 200, "en"))

    def test_exports_have_explicit_nonduplicated_schema(self):
        store_result(self.conn, self._result(), "run-one")
        part = flush_parquet_batch(self.conn, self.root / "corpus")
        outputs = export_parquets(self.conn, self.root / "corpus")

        reader = duckdb.connect()
        columns = [row[0] for row in reader.execute(
            f"DESCRIBE SELECT * FROM '{part}'"
        ).fetchall()]
        reader.close()
        self.assertEqual(columns.count("source_id"), 1)
        self.assertNotIn("source_id_1", columns)
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM items").fetchone()[0], 0)
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM source_items").fetchone()[0], 0)
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM parquet_parts").fetchone()[0], 1)
        self.assertTrue(all(path.exists() for path in outputs.values()))


if __name__ == "__main__":
    unittest.main()
