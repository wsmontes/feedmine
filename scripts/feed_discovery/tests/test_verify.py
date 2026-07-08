from __future__ import annotations

from scripts.feed_discovery.verify import parse_feed

RSS = b"""<?xml version="1.0"?><rss version="2.0"><channel>
  <title>My Feed</title><item><title>Post</title></item></channel></rss>"""
ATOM = b"""<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom">
  <title>Atom Feed</title></feed>"""
NOT_FEED = b"<html><body>hello</body></html>"
# A large feed whose body is cut off (no closing tags) — the real-world case
# that broke a full-document XML parse.
TRUNCATED = (
    b'<?xml version="1.0"?><rss version="2.0"><channel>'
    b"<title>Big Feed</title>" + b"<item><title>x</title><description>y</description></item>" * 500
)
CDATA = b"""<?xml version="1.0"?><rss><channel><title><![CDATA[Caf\xc3\xa9 & Co]]></title></channel></rss>"""


def test_parses_rss_title():
    assert parse_feed(RSS) == (True, "My Feed")


def test_parses_atom_title():
    assert parse_feed(ATOM) == (True, "Atom Feed")


def test_rejects_non_feed():
    assert parse_feed(NOT_FEED) == (False, "")


def test_rejects_garbage():
    assert parse_feed(b"\x00\x01 not xml") == (False, "")


def test_accepts_truncated_feed_body():
    # Truncated mid-document must still be recognized as a live feed.
    assert parse_feed(TRUNCATED[:2000]) == (True, "Big Feed")


def test_parses_cdata_title_with_entities():
    assert parse_feed(CDATA) == (True, "Café & Co")
