import tempfile
from pathlib import Path

from scripts.feed_discovery.models import Candidate
from scripts.feed_discovery.subregion.opml_writer import (
    write_subregion_opml,
    read_existing_feeds,
)


SAMPLE_EMPTY_OPML = """<?xml version="1.0" encoding="UTF-8"?>
<opml version="1.0">
  <head>
    <title>Lagos Feeds</title>
  </head>
  <body>
</body>
</opml>
"""

SAMPLE_POPULATED_OPML = """<?xml version="1.0" encoding="UTF-8"?>
<opml version="1.0">
  <head>
    <title>Texas Feeds</title>
  </head>
  <body>
    <outline text="News">
      <outline title="Houston Chronicle" xmlUrl="https://www.houstonchronicle.com/rss" type="rss"/>
    </outline>
</body>
</opml>
"""


def test_write_into_empty_opml():
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "test.opml"
        path.write_text(SAMPLE_EMPTY_OPML)

        candidates = [
            Candidate(url="https://lagosnews.com/feed/", category="News",
                      title="Lagos News", genre=""),
            Candidate(url="https://lagos.podcast.com/feed/", category="Podcasts",
                      title="Lagos Pod", genre="Talk"),
        ]
        count = write_subregion_opml(path, candidates)
        assert count == 2

        result = path.read_text()
        assert "Lagos News" in result
        assert 'xmlUrl="https://lagosnews.com/feed/"' in result
        assert "Lagos Pod" in result
        assert 'xmlUrl="https://lagos.podcast.com/feed/"' in result


def test_write_preserves_existing_feeds():
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "test.opml"
        path.write_text(SAMPLE_POPULATED_OPML)

        candidates = [
            Candidate(url="https://new-texas-blog.com/feed/", category="Blogs",
                      title="New Texas Blog", genre=""),
        ]
        count = write_subregion_opml(path, candidates)
        assert count == 1

        result = path.read_text()
        # Existing feed preserved
        assert "Houston Chronicle" in result
        assert "houstonchronicle.com" in result
        # New feed added
        assert "New Texas Blog" in result
        # Original categories preserved
        assert 'text="News"' in result
        assert 'text="Blogs"' in result


def test_read_existing_feeds_from_empty_opml():
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "test.opml"
        path.write_text(SAMPLE_EMPTY_OPML)
        feeds = read_existing_feeds(path)
        assert feeds == set()


def test_read_existing_feeds_from_populated_opml():
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "test.opml"
        path.write_text(SAMPLE_POPULATED_OPML)
        feeds = read_existing_feeds(path)
        assert "https://www.houstonchronicle.com/rss" in feeds


def test_write_deduplicates_existing():
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "test.opml"
        path.write_text(SAMPLE_POPULATED_OPML)

        candidates = [
            Candidate(url="https://www.houstonchronicle.com/rss", category="News",
                      title="Houston Chronicle", genre=""),
            Candidate(url="https://new-one.com/feed/", category="News",
                      title="New One", genre=""),
        ]
        count = write_subregion_opml(path, candidates)
        # Only the new feed should be written; Houston Chronicle was already there
        assert count == 1
        assert "New One" in path.read_text()
