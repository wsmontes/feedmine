# scripts/feed_discovery/subregion/test_integration.py

import json
import tempfile
from pathlib import Path
from unittest.mock import AsyncMock, patch

import pytest

from scripts.feed_discovery.models import Candidate, SubRegion
from scripts.feed_discovery.pipeline import Config
from scripts.feed_discovery.subregion.discover_subregion import discover_subregion
from scripts.feed_discovery.subregion.enrich_countries import enrich, humanize_slug
from scripts.feed_discovery.subregion.opml_writer import read_existing_feeds, write_subregion_opml


@pytest.mark.asyncio
async def test_discover_subregion_returns_candidates():
    """Smoke test: discover_subregion should run without crashing and return a list."""
    sub = SubRegion(
        slug="nigeria-lagos", name="Lagos", parent_country="nigeria",
        iso2="ng", iso3="NGA", ddg_region="ng-en",
        opml_path="/tmp/test.opml",
    )
    cfg = Config(max_results=2, timeout=5, concurrency=2, fresh=False)

    import aiohttp
    async with aiohttp.ClientSession() as session:
        candidates = await discover_subregion(
            sub, "Nigeria", "Nigeria", set(), session, cfg,
        )
    assert isinstance(candidates, list)


def test_enrich_and_write_roundtrip():
    """Test that enrich + write produces valid OPML with feed URLs."""
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)

        # Create a minimal countries.json
        countries = {
            "testland": {
                "name": "Testland", "native_name": "Testland",
                "cctld": "tl", "use_cctld": True, "lang": "en",
                "ddg_region": "tl-en", "iso2": "tl", "iso3": "TST",
                "cities": ["Test City"],
            }
        }
        countries_json = tmp / "countries.json"
        countries_json.write_text(json.dumps(countries))

        # Create a sub-region OPML directory with one empty OPML
        opml_dir = tmp / "testland"
        opml_dir.mkdir()
        sub_opml = opml_dir / "testland-test-city.opml"
        sub_opml.write_text(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<opml version="1.0">\n'
            '  <head><title>Test City Feeds</title></head>\n'
            '  <body>\n</body>\n</opml>\n'
        )

        # Run enrich
        enriched_path = tmp / "enriched.json"
        result = enrich(opml_dir.parent, countries_json, enriched_path)

        assert "testland" in result
        assert len(result["testland"]["subregions"]) == 1
        assert result["testland"]["subregions"][0]["name"] == "Test City"

        # Write a candidate to the OPML
        cand = Candidate(
            url="https://testcitynews.com/feed/", category="News",
            title="Test City News", genre="Local",
        )
        count = write_subregion_opml(sub_opml, [cand])
        assert count == 1

        # Read back
        feeds = read_existing_feeds(sub_opml)
        assert "https://testcitynews.com/feed" in feeds

        # Write again — should dedup
        count2 = write_subregion_opml(sub_opml, [cand])
        assert count2 == 0


def test_humanize_slug_all_patterns():
    assert humanize_slug("usa-texas") == "Texas"
    assert humanize_slug("brazil-rio-de-janeiro") == "Rio De Janeiro"
    assert humanize_slug("romania-bucuresti") == "Bucuresti"
    assert humanize_slug("china-hong-kong") == "Hong Kong"
