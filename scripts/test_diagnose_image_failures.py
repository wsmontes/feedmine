from __future__ import annotations

import asyncio
import io
import sqlite3
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import httpx
from PIL import Image

from scripts.diagnose_image_failures import (
    ItemSample,
    load_samples,
    probe_sample,
    summarize,
)


def png(width: int, height: int) -> bytes:
    output = io.BytesIO()
    Image.new("RGB", (width, height), "red").save(output, format="PNG")
    return output.getvalue()


class ImageHandler(BaseHTTPRequestHandler):
    valid_image = png(20, 10)
    tiny_image = png(1, 1)

    def do_GET(self):
        if self.path == "/valid.png":
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            body = self.valid_image
        elif self.path == "/tiny.png":
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            body = self.tiny_image
        elif self.path == "/html":
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            body = b"<html>blocked</html>"
        else:
            self.send_response(404)
            self.send_header("Content-Type", "text/plain")
            body = b"not found"
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass


class ImageProbeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), ImageHandler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base_url = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def sample(self, image_url: str | None) -> ItemSample:
        return ItemSample("1", "https://feed.test/rss", "Test Feed", "Item", "https://feed.test/1", image_url, 1)

    def probe(self, image_url: str | None):
        async def run():
            async with httpx.AsyncClient(follow_redirects=True) as client:
                return await probe_sample(self.sample(image_url), client)
        return asyncio.run(run())

    def test_accepts_decodable_image(self):
        result = self.probe(f"{self.base_url}/valid.png")
        self.assertEqual(result.status, "ok")
        self.assertEqual((result.width, result.height), (20, 10))

    def test_classifies_missing_and_http_failure(self):
        self.assertEqual(self.probe(None).status, "missing_url")
        self.assertEqual(self.probe(f"{self.base_url}/missing.png").status, "http_404")

    def test_classifies_non_image_and_tiny_image(self):
        self.assertEqual(self.probe(f"{self.base_url}/html").status, "non_image_response")
        self.assertEqual(self.probe(f"{self.base_url}/tiny.png").status, "too_small")

    def test_classifies_invalid_data_url(self):
        result = self.probe("data:image/png;base64,not-valid-base64")
        self.assertEqual(result.status, "invalid_data_url")

    def test_summary_groups_failures_by_feed(self):
        results = [
            self.probe(f"{self.base_url}/valid.png"),
            self.probe(f"{self.base_url}/missing.png"),
        ]
        summary, feeds = summarize(results)
        self.assertEqual(summary["failure_count"], 1)
        self.assertEqual(summary["feeds_with_failures"], 1)
        self.assertEqual(feeds[0]["statuses"], {"ok": 1, "http_404": 1})


class DatabaseSamplingTests(unittest.TestCase):
    def test_loads_latest_items_per_feed_including_missing_urls(self):
        with tempfile.TemporaryDirectory() as directory:
            database = Path(directory) / "feedmine.sqlite"
            with sqlite3.connect(database) as connection:
                connection.execute("""
                    CREATE TABLE feed_item (
                        id TEXT PRIMARY KEY, source_url TEXT, source_title TEXT,
                        title TEXT, url TEXT, image_url TEXT,
                        published_at INTEGER, fetched_at INTEGER
                    )
                """)
                connection.executemany(
                    "INSERT INTO feed_item VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    [
                        ("old", "feed-a", "A", "Old", "article-old", "image-old", 1, 1),
                        ("new", "feed-a", "A", "New", "article-new", None, 2, 2),
                        ("b", "feed-b", "B", "B", "article-b", "image-b", 3, 3),
                    ],
                )

            samples = load_samples(database, samples_per_feed=1)

        self.assertEqual({sample.item_id for sample in samples}, {"new", "b"})
        self.assertIsNone(next(sample for sample in samples if sample.item_id == "new").image_url)


if __name__ == "__main__":
    unittest.main()
