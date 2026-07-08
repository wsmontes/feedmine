from __future__ import annotations

from scripts.feed_discovery.discover import find_feeds_in_html

HTML = """
<html><head>
  <link rel="alternate" type="application/rss+xml" title="RSS" href="/feed/">
  <link rel="alternate" type="application/atom+xml" href="https://x.br/atom.xml">
  <link rel="stylesheet" href="/style.css">
</head></html>
"""


def test_finds_rss_and_atom_links_resolved_to_absolute():
    feeds = find_feeds_in_html(HTML, "https://x.br/blog/")
    assert "https://x.br/feed/" in feeds
    assert "https://x.br/atom.xml" in feeds
    assert all(".css" not in f for f in feeds)


def test_deduplicates_preserving_order():
    html = ('<link rel="alternate" type="application/rss+xml" href="/feed/">'
            '<link rel="alternate" type="application/rss+xml" href="/feed/">')
    assert find_feeds_in_html(html, "https://x.br/") == ["https://x.br/feed/"]


def test_excludes_wordpress_comment_feeds():
    html = ('<link rel="alternate" type="application/rss+xml" href="/feed/">'
            '<link rel="alternate" type="application/rss+xml" href="/comments/feed/">')
    feeds = find_feeds_in_html(html, "https://x.br/")
    assert feeds == ["https://x.br/feed/"]  # comment feed dropped
