from __future__ import annotations

from pathlib import Path

from scripts.feed_discovery import registry
from scripts.feed_discovery.models import Country

FIX = Path(__file__).parent / "fixtures"


def test_categories_are_26_in_fixed_order():
    assert len(registry.CATEGORIES) == 26
    assert registry.CATEGORIES[0] == "News"
    assert registry.CATEGORIES[-1] == "YouTube"


def test_load_countries_parses_entries():
    countries = registry.load_countries(FIX / "countries.sample.json")
    br = countries["brazil"]
    assert isinstance(br, Country)
    assert br.cctld == "br"
    assert br.lang == "pt"
    assert br.use_cctld is True
    assert br.ddg_region == "br-pt"


def test_keywords_for_falls_back_to_english():
    kw = {"News": {"en": ["news"], "pt": ["notícias"]}}
    assert registry.keywords_for(kw, "News", "pt") == ["notícias"]
    assert registry.keywords_for(kw, "News", "xx") == ["news"]  # unknown lang → en
    assert registry.keywords_for(kw, "Unknown", "pt") == []      # unknown category → empty
