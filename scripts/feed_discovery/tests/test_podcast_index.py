# scripts/feed_discovery/tests/test_podcast_index.py

import os
import pytest
from scripts.feed_discovery.sources._base import SourceProtocol, ProbeResult
from scripts.feed_discovery.sources.podcast_index import PodcastIndexSource
from scripts.feed_discovery.profiles._schema import CountryProfile, SourceConfig
from scripts.feed_discovery.models import Candidate


def test_implements_protocol():
    source = PodcastIndexSource()
    assert isinstance(source, SourceProtocol)


def test_name():
    assert PodcastIndexSource().name == "podcast_index"


def test_disabled_without_env_vars(monkeypatch):
    """Source should be disabled (not crash) when API keys are missing."""
    monkeypatch.delenv("PODCAST_INDEX_KEY", raising=False)
    monkeypatch.delenv("PODCAST_INDEX_SECRET", raising=False)
    source = PodcastIndexSource()
    assert source.enabled is False


def test_enabled_with_env_vars(monkeypatch):
    monkeypatch.setenv("PODCAST_INDEX_KEY", "test-key")
    monkeypatch.setenv("PODCAST_INDEX_SECRET", "test-secret")
    source = PodcastIndexSource()
    assert source.enabled is True


def test_has_search_and_probe():
    source = PodcastIndexSource()
    assert callable(source.search)
    assert callable(source.probe)


@pytest.mark.asyncio
async def test_search_returns_candidates():
    if not os.getenv("PODCAST_INDEX_KEY"):
        pytest.skip("PODCAST_INDEX_KEY not set")
    source = PodcastIndexSource()
    profile = CountryProfile(country="nigeria", languages=["en"])
    config = SourceConfig(priority=1, max_results=10, timeout=15)
    import aiohttp
    async with aiohttp.ClientSession() as session:
        results = await source.search("lagos nigeria", profile, config, session)
    assert isinstance(results, list)
    if results:
        assert isinstance(results[0], Candidate)
        assert results[0].category == "Podcasts"


@pytest.mark.asyncio
async def test_probe_returns_probe_result():
    if not os.getenv("PODCAST_INDEX_KEY"):
        pytest.skip("PODCAST_INDEX_KEY not set")
    source = PodcastIndexSource()
    profile = CountryProfile(country="nigeria", languages=["en"])
    config = SourceConfig(priority=1, max_results=5, timeout=15)
    import aiohttp
    async with aiohttp.ClientSession() as session:
        result = await source.probe(profile, config, session)
    assert isinstance(result, ProbeResult)
    assert result.source_name == "podcast_index"


@pytest.mark.asyncio
async def test_search_disabled_returns_empty():
    """When disabled, search returns empty list without making API calls."""
    source = PodcastIndexSource()
    source.enabled = False
    profile = CountryProfile(country="nigeria")
    config = SourceConfig(priority=1)
    import aiohttp
    async with aiohttp.ClientSession() as session:
        results = await source.search("test", profile, config, session)
    assert results == []


@pytest.mark.asyncio
async def test_probe_disabled_returns_failure():
    source = PodcastIndexSource()
    source.enabled = False
    profile = CountryProfile(country="nigeria")
    config = SourceConfig(priority=1)
    import aiohttp
    async with aiohttp.ClientSession() as session:
        result = await source.probe(profile, config, session)
    assert result.success is False
    assert "disabled" in result.error.lower()
