# scripts/feed_discovery/tests/test_itunes_source.py

import pytest
from scripts.feed_discovery.sources._base import SourceProtocol, ProbeResult
from scripts.feed_discovery.sources.podcasts import ITunesSource
from scripts.feed_discovery.profiles._schema import CountryProfile, SourceConfig
from scripts.feed_discovery.models import Candidate


def test_itunes_source_implements_protocol():
    source = ITunesSource()
    assert isinstance(source, SourceProtocol)


def test_itunes_source_name():
    source = ITunesSource()
    assert source.name == "itunes"


def test_itunes_source_has_search():
    source = ITunesSource()
    assert hasattr(source, "search")
    assert callable(source.search)


def test_itunes_source_has_probe():
    source = ITunesSource()
    assert hasattr(source, "probe")
    assert callable(source.probe)


@pytest.mark.asyncio
async def test_probe_returns_probe_result():
    source = ITunesSource()
    profile = CountryProfile(country="usa", languages=["en"])
    config = SourceConfig(priority=5, timeout=10)
    import aiohttp
    async with aiohttp.ClientSession() as session:
        result = await source.probe(profile, config, session)
    assert isinstance(result, ProbeResult)
    assert result.source_name == "itunes"


@pytest.mark.asyncio
async def test_search_returns_candidates():
    source = ITunesSource()
    profile = CountryProfile(country="usa", languages=["en"])
    config = SourceConfig(priority=5, max_results=10, timeout=10)
    import aiohttp
    async with aiohttp.ClientSession() as session:
        results = await source.search("news", profile, config, session)
    assert isinstance(results, list)
    if results:
        assert isinstance(results[0], Candidate)
        assert results[0].category == "Podcasts"


def test_original_discover_function_still_works():
    """A funcao discover() original deve continuar existindo para pipeline.py."""
    from scripts.feed_discovery.sources.podcasts import discover
    import asyncio
    assert callable(discover)
