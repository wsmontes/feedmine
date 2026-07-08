from __future__ import annotations

import json
from pathlib import Path

from scripts.feed_discovery import search
from scripts.feed_discovery.models import Country

BO = Country("bolivia", "Bolivia", "bo", True, "es", "bo-es", [], "Bolivia",
             ["La Paz", "Santa Cruz"])


def test_build_query_uses_first_term_and_rss():
    assert search.build_query(["notícias"]) == "notícias RSS feed"
    assert search.build_query([]) == "news RSS feed"


def test_build_queries_anchors_country_and_cities_for_local_category():
    kw = {"News": {"es": ["noticias", "diario"]}}
    qs = search.build_queries(BO, "News", kw)
    assert "noticias Bolivia RSS" in qs
    assert "diario Bolivia RSS" in qs          # synonym anchored to country
    assert "noticias La Paz RSS" in qs         # city anchoring (local category)
    assert "noticias Santa Cruz RSS" in qs


def test_build_queries_skips_cities_for_global_category():
    kw = {"Programming": {"en": ["programming"]}}
    qs = search.build_queries(BO, "Programming", kw)
    assert qs == ["programming Bolivia RSS"]   # no city anchoring


def test_build_queries_adds_native_name_when_different():
    br = Country("brazil", "Brazil", "br", True, "pt", "br-pt", [], "Brasil", ["São Paulo"])
    kw = {"News": {"pt": ["notícias"]}}
    qs = search.build_queries(br, "News", kw)
    assert "notícias Brazil RSS" in qs
    assert "notícias Brasil RSS" in qs         # native name anchor


def test_search_returns_cached_without_network(tmp_path: Path):
    cache = tmp_path / "News.json"
    cache.write_text(json.dumps(["https://a.br/", "https://b.br/"]), encoding="utf-8")
    # No network: cache hit returns immediately.
    urls = search.search("q", "br-pt", 12, cache, delay=0, fresh=False)
    assert urls == ["https://a.br/", "https://b.br/"]
