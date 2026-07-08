from __future__ import annotations

from scripts.feed_discovery.verify import parse_feed

RSS = b"""<?xml version="1.0"?><rss version="2.0"><channel>
  <title>My Feed</title><item><title>Post</title></item></channel></rss>"""
ATOM = b"""<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom">
  <title>Atom Feed</title></feed>"""
NOT_FEED = b"<html><body>hello</body></html>"


def test_parses_rss_title():
    assert parse_feed(RSS) == (True, "My Feed")


def test_parses_atom_title():
    assert parse_feed(ATOM) == (True, "Atom Feed")


def test_rejects_non_feed():
    assert parse_feed(NOT_FEED) == (False, "")


def test_rejects_garbage():
    assert parse_feed(b"\x00\x01 not xml") == (False, "")
