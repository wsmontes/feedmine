import argparse
import json
import tempfile
import unittest
from pathlib import Path

from scripts.publish_catalog_update import publish


class PublishCatalogUpdateTests(unittest.TestCase):
    def test_publish_increments_revision_and_removes_obsolete_opml(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            destination = root / "destination"
            bundle_manifest = root / "bundle-manifest.json"
            source.mkdir()
            (source / "first.opml").write_text(
                '<opml><body><outline type="rss" xmlUrl="https://example.com/first.xml" /></body></opml>',
                encoding="utf-8",
            )
            catalog_manifest = root / "catalog-manifest.json"
            catalog_manifest.write_text(
                json.dumps({"source_count": 1, "file_count": 1}),
                encoding="utf-8",
            )

            first = publish(self.args(source, destination, catalog_manifest, bundle_manifest))
            self.assertEqual(first["revision"], 1)
            self.assertEqual(first["fileCount"], 1)
            self.assertEqual((destination / "manifest.json").read_bytes(), bundle_manifest.read_bytes())

            (source / "first.opml").unlink()
            nested = source / "topic"
            nested.mkdir()
            (nested / "second.opml").write_text(
                '<opml><body><outline type="rss" xmlUrl="https://example.com/second.xml" /></body></opml>',
                encoding="utf-8",
            )
            second = publish(self.args(source, destination, catalog_manifest, bundle_manifest))

            self.assertEqual(second["revision"], 2)
            self.assertFalse((destination / "Feeds" / "first.opml").exists())
            self.assertTrue((destination / "Feeds" / "topic" / "second.opml").exists())
            self.assertEqual(second["files"][0]["path"], "Feeds/topic/second.opml")

    @staticmethod
    def args(source, destination, catalog_manifest, bundle_manifest):
        return argparse.Namespace(
            source_root=source,
            destination=destination,
            catalog_manifest=catalog_manifest,
            bundle_manifest=bundle_manifest,
            revision=None,
            generated_at="2026-07-20T00:00:00Z",
        )


if __name__ == "__main__":
    unittest.main()
