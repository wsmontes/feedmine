import unittest

from scripts.build_feed_recovery_queues import failed_queue, queue_for


class BuildFeedRecoveryQueuesTests(unittest.TestCase):
    def test_dispositions_route_to_explicit_queues(self):
        self.assertEqual(queue_for({"disposition": "unattempted_editorial"}), "editorial_unattempted")
        self.assertEqual(queue_for({"disposition": "processed_empty"}), "processed_empty")
        self.assertIsNone(queue_for({"disposition": "unattempted_synthetic"}))
        self.assertIsNone(queue_for({"disposition": "production"}))

    def test_failed_rows_are_split_by_recovery_strategy(self):
        cases = [
            ({"http_status": "200", "last_error": "Parse error: junk"}, "failed_parse_or_html"),
            ({"http_status": "404", "last_error": "Not Found"}, "failed_gone_or_moved"),
            ({"http_status": "403", "last_error": "Forbidden"}, "failed_access_blocked"),
            ({"http_status": "503", "last_error": "Unavailable"}, "failed_transient"),
            ({"http_status": "", "last_error": "DNS name or service not known"}, "failed_network"),
            ({"http_status": "", "last_error": ""}, "failed_unknown"),
        ]
        for row, expected in cases:
            with self.subTest(expected=expected):
                self.assertEqual(failed_queue(row), expected)


if __name__ == "__main__":
    unittest.main()
