import tempfile
import unittest
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

from scripts.enrich_feed_descriptions import load_article_samples, safe_text


class EnrichFeedDescriptionsTests(unittest.TestCase):
    def test_safe_text_does_not_send_nan_as_feed_metadata(self):
        self.assertEqual(safe_text(float("nan")), "")
        self.assertEqual(safe_text(None), "")
        self.assertEqual(safe_text(" Feed title "), "Feed title")

    def test_article_samples_are_bounded_and_content_derived(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "part.parquet"
            pq.write_table(pa.table({
                "source_id": ["one", "one", "two"],
                "title": ["First", "Second", "Other"],
                "summary": ["Astronomy story", "Telescope review", "Cooking"],
                "content_text": [None, None, None],
                "position": [0, 1, 0],
            }), path)

            samples = load_article_samples(Path(directory), max_per_source=1)

            self.assertEqual(samples["one"], ["First — Astronomy story"])
            self.assertEqual(samples["two"], ["Other — Cooking"])


if __name__ == "__main__":
    unittest.main()
