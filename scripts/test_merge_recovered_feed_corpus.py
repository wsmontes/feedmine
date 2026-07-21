import unittest

import pandas as pd

from scripts.merge_recovered_feed_corpus import (
    POLICY_EXCLUSION_REASON,
    apply_editorial_policy,
    canonical_url,
    is_redundant_google_topic,
    merge_source_frames,
)


class MergeRecoveredFeedCorpusTests(unittest.TestCase):
    def test_policy_excludes_topic_endpoint_but_keeps_local_headlines(self):
        frame = pd.DataFrame([
            {
                "xml_url": "https://news.google.com/rss?hl=pt&gl=BR&ceid=BR:pt&topic=science",
                "status": "done", "error_message": None,
            },
            {
                "xml_url": "https://news.google.com/rss?hl=pt&gl=BR&ceid=BR:pt",
                "status": "done", "error_message": None,
            },
            {
                "xml_url": "https://example.com/feed.xml",
                "status": "done", "error_message": None,
            },
        ])

        result = apply_editorial_policy(frame)

        self.assertEqual(result.loc[0, "status"], "excluded_policy")
        self.assertEqual(result.loc[0, "error_message"], POLICY_EXCLUSION_REASON)
        self.assertEqual(result.loc[1, "status"], "done")
        self.assertEqual(result.loc[2, "status"], "done")

    def test_audited_source_id_exclusion_records_reason(self):
        frame = pd.DataFrame([{
            "source_id": "compromised", "xml_url": "https://example.com/feed",
            "status": "done", "error_message": None,
        }])

        result = apply_editorial_policy(
            frame, {"compromised": "domain serves unrelated SEO spam"}
        )

        self.assertEqual(result.loc[0, "status"], "excluded_policy")
        self.assertIn("unrelated SEO spam", result.loc[0, "error_message"])

    def test_identity_and_google_detection_match_runtime_rules(self):
        self.assertEqual(
            canonical_url("http://www.Example.com/feed/?utm_source=test"),
            "https://example.com/feed",
        )
        self.assertTrue(is_redundant_google_topic(
            "https://news.google.com/rss?hl=en&gl=CA&topic=health"
        ))
        self.assertFalse(is_redundant_google_topic(
            "https://news.google.com/rss?hl=en&gl=CA"
        ))

    def test_existing_failed_row_can_be_replaced_without_changing_identity(self):
        base = pd.DataFrame([
            {"source_id": "same", "xml_url": "http://www.example.com/feed/", "status": "failed"}
        ])
        recovery = pd.DataFrame([
            {"source_id": "same", "xml_url": "https://example.com/feed", "status": "done"},
            {"source_id": "new", "xml_url": "https://new.example/feed", "status": "empty"},
        ])

        merged, new_ids, existing_ids, remapped, replaced = merge_source_frames(
            base, recovery, allow_existing=True
        )

        self.assertEqual(len(merged), 2)
        self.assertEqual(merged.loc[0, "status"], "done")
        self.assertEqual(new_ids, {"new"})
        self.assertEqual(existing_ids, {"same"})
        self.assertEqual(remapped, {})
        self.assertEqual(replaced, 1)

    def test_repeated_failure_keeps_the_original_diagnostic_row(self):
        base = pd.DataFrame([{
            "source_id": "same", "xml_url": "https://example.com/feed",
            "status": "failed", "error_message": "HTTP 503 from publisher",
        }])
        recovery = pd.DataFrame([{
            "source_id": "same", "xml_url": "https://example.com/feed",
            "status": "failed", "error_message": "timeout after 20 seconds",
        }])

        merged, _, _, _, replaced = merge_source_frames(base, recovery, allow_existing=True)

        self.assertEqual(replaced, 0)
        self.assertEqual(merged.loc[0, "error_message"], "HTTP 503 from publisher")

    def test_existing_runtime_identity_remaps_recomputed_source_id(self):
        base = pd.DataFrame([{
            "source_id": "historical", "xml_url": "http://www.example.com/feed/",
            "status": "failed",
        }])
        recovery = pd.DataFrame([{
            "source_id": "recomputed", "xml_url": "https://example.com/feed",
            "status": "done",
        }])

        merged, _, existing, remapped, replaced = merge_source_frames(
            base, recovery, allow_existing=True
        )

        self.assertEqual(merged.loc[0, "source_id"], "historical")
        self.assertEqual(existing, {"historical"})
        self.assertEqual(remapped, {"recomputed": "historical"})
        self.assertEqual(replaced, 1)


if __name__ == "__main__":
    unittest.main()
