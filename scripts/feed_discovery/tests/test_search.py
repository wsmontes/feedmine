from __future__ import annotations

import json
from pathlib import Path

from scripts.feed_discovery import search
from scripts.feed_discovery.models import Country

BO = Country("bolivia", "Bolivia", "bo", True, "es", "bo-es", [], "Bolivia",
             ["La Paz", "Santa Cruz"])
US = Country("usa", "USA", "us", False, "en", "us-en", ["nytimes.com"], "USA",
             ["New York", "Los Angeles"])


def test_build_query_uses_first_term_and_rss():
    assert search.build_query(["notícias"]) == "notícias RSS feed"
    assert search.build_query([]) == "news RSS feed"


def test_build_queries_uses_site_operator_for_cctld_country():
    kw = {"News": {"es": ["noticias", "diario"]}}
    qs = search.build_queries(BO, "News", kw)
    assert "noticias rss site:.bo" in qs
    assert "diario rss site:.bo" in qs          # synonym, TLD-constrained
    assert "Bolivia rss site:.bo" in qs         # country-name anchor
    assert "noticias La Paz rss site:.bo" in qs  # city anchoring (local category)


def test_build_queries_skips_cities_for_global_category():
    kw = {"Programming": {"es": ["programación"]}}
    qs = search.build_queries(BO, "Programming", kw)
    assert "programación rss site:.bo" in qs
    assert all("La Paz" not in q for q in qs)    # no city anchoring
    assert all(q.endswith("site:.bo") for q in qs)


def test_build_queries_without_cctld_anchors_by_name():
    kw = {"News": {"en": ["news"]}}
    qs = search.build_queries(US, "News", kw)
    assert all("site:" not in q for q in qs)     # no TLD filter when ccTLD unused
    assert any("USA" in q for q in qs)


def test_search_returns_cached_without_network(tmp_path: Path):
    cache = tmp_path / "News.json"
    cache.write_text(json.dumps(["https://a.br/", "https://b.br/"]), encoding="utf-8")
    # No network: cache hit returns immediately.
    urls = search.search("q", "br-pt", 12, cache, delay=0, fresh=False)
    assert urls == ["https://a.br/", "https://b.br/"]
