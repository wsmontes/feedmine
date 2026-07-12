from __future__ import annotations

import pytest
from scripts.feed_discovery.sources._base import SourceProtocol, ProbeResult
from scripts.feed_discovery.sources.ddg_text import DDGTextSource
from scripts.feed_discovery.profiles._schema import CountryProfile, SourceConfig
from scripts.feed_discovery.models import Candidate


def test_ddg_text_source_implements_protocol():
    source = DDGTextSource()
    assert isinstance(source, SourceProtocol)


def test_ddg_text_source_name():
    source = DDGTextSource()
    assert source.name == "ddg_text"


def test_ddg_text_source_has_search():
    source = DDGTextSource()
    assert hasattr(source, "search")
    assert callable(source.search)


def test_ddg_text_source_has_probe():
    source = DDGTextSource()
    assert hasattr(source, "probe")
    assert callable(source.probe)


@pytest.mark.asyncio
async def test_probe_returns_probe_result():
    source = DDGTextSource()
    profile = CountryProfile(country="usa", languages=["en"])
    config = SourceConfig(priority=4, max_results=5, timeout=10)
    import aiohttp
    async with aiohttp.ClientSession() as session:
        result = await source.probe(profile, config, session)
    assert isinstance(result, ProbeResult)
    assert result.source_name == "ddg_text"


@pytest.mark.asyncio
async def test_search_returns_candidates():
    source = DDGTextSource()
    profile = CountryProfile(country="usa", languages=["en"])
    config = SourceConfig(priority=4, max_results=5, timeout=10)
    import aiohttp
    async with aiohttp.ClientSession() as session:
        results = await source.search("texas news", profile, config, session)
    assert isinstance(results, list)
    if results:
        assert isinstance(results[0], Candidate)
