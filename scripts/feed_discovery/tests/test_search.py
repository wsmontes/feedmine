from __future__ import annotations

import json
from pathlib import Path

from scripts.feed_discovery import search


def test_build_query_uses_first_term_and_rss():
    assert search.build_query(["notícias"]) == "notícias RSS feed"
    assert search.build_query([]) == "news RSS feed"


def test_search_returns_cached_without_network(tmp_path: Path):
    cache = tmp_path / "News.json"
    cache.write_text(json.dumps(["https://a.br/", "https://b.br/"]), encoding="utf-8")
    # No network: cache hit returns immediately.
    urls = search.search("q", "br-pt", 12, cache, delay=0, fresh=False)
    assert urls == ["https://a.br/", "https://b.br/"]
