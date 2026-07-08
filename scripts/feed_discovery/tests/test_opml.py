from __future__ import annotations

from pathlib import Path

from scripts.feed_discovery import opml

FIX = Path(__file__).parent / "fixtures" / "sample_country"


def test_normalize_url_canonicalizes():
    assert opml.normalize_url("HTTP://Example.com/Feed/") == "https://example.com/feed"
    assert opml.normalize_url("https://example.com/feed") == "https://example.com/feed"


def test_existing_feed_urls_reads_opml_normalized():
    urls = opml.existing_feed_urls(FIX)
    assert "https://existing.com.br/feed" in urls


def test_emit_opml_matches_project_format():
    xml = opml.emit_opml(
        "Iceland",
        {"News": [("RÚV", "https://www.ruv.is/rss/frettir")]},
        ["News", "Sports"],
    )
    assert xml.startswith('<?xml version="1.0" encoding="UTF-8"?>')
    assert "<title>Iceland Feeds (candidates)</title>" in xml
    assert '    <outline text="News">' in xml
    assert '      <outline title="RÚV" xmlUrl="https://www.ruv.is/rss/frettir" type="rss" />' in xml
    assert "Sports" not in xml  # empty categories are omitted


def test_emit_opml_escapes_special_chars():
    xml = opml.emit_opml("X", {"News": [("A & B", "https://a.br/feed?x=1&y=2")]}, ["News"])
    assert "&amp;" in xml
