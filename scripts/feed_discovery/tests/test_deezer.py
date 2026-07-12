# scripts/feed_discovery/tests/test_deezer.py

import pytest
from scripts.feed_discovery.sources._base import SourceProtocol, ProbeResult
from scripts.feed_discovery.sources.deezer import DeezerSource
from scripts.feed_discovery.profiles._schema import CountryProfile, SourceConfig
from scripts.feed_discovery.models import Candidate


def test_implements_protocol():
    assert isinstance(DeezerSource(), SourceProtocol)


def test_name():
    assert DeezerSource().name == "deezer"


def test_always_enabled():
    """Deezer needs no auth — always enabled."""
    assert DeezerSource().enabled is True


def test_has_search_and_probe():
    source = DeezerSource()
    assert callable(source.search)
    assert callable(source.probe)


@pytest.mark.asyncio
async def test_search_returns_candidates():
    source = DeezerSource()
    profile = CountryProfile(country="brazil", languages=["pt"])
    config = SourceConfig(priority=2, max_results=10, timeout=15)
    import aiohttp
    async with aiohttp.ClientSession() as session:
        results = await source.search("brasil podcast", profile, config, session)
    assert isinstance(results, list)
    if results:
        assert isinstance(results[0], Candidate)
        assert results[0].category == "Podcasts"


@pytest.mark.asyncio
async def test_probe_returns_probe_result():
    source = DeezerSource()
    profile = CountryProfile(country="brazil", languages=["pt"])
    config = SourceConfig(priority=2, max_results=5, timeout=15)
    import aiohttp
    async with aiohttp.ClientSession() as session:
        result = await source.probe(profile, config, session)
    assert isinstance(result, ProbeResult)
    assert result.source_name == "deezer"


@pytest.mark.asyncio
async def test_search_no_auth_required():
    """Deezer search endpoint is public — no auth needed."""
    source = DeezerSource()
    profile = CountryProfile(country="france", languages=["fr"])
    config = SourceConfig(priority=2, max_results=5, timeout=15)
    import aiohttp
    async with aiohttp.ClientSession() as session:
        results = await source.search("france podcast", profile, config, session)
    assert isinstance(results, list)
