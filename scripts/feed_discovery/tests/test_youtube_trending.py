import os

import pytest

from scripts.feed_discovery.sources._base import SourceProtocol, ProbeResult
from scripts.feed_discovery.sources.youtube_trending import YouTubeTrendingSource


@pytest.fixture
def source():
    return YouTubeTrendingSource()


def test_implements_protocol(source):
    assert isinstance(source, SourceProtocol), \
        "YouTubeTrendingSource does not implement SourceProtocol"


def test_source_name(source):
    assert source.name == "youtube_trending"


def test_has_search_callable(source):
    assert callable(source.search)


def test_has_probe_callable(source):
    assert callable(source.probe)


def test_disabled_without_api_key(monkeypatch):
    """When YOUTUBE_API_KEY is not set, enabled should be False."""
    monkeypatch.delenv("YOUTUBE_API_KEY", raising=False)
    s = YouTubeTrendingSource()
    assert s.enabled is False


def test_enabled_with_api_key(monkeypatch):
    """When YOUTUBE_API_KEY is set, enabled should be True."""
    monkeypatch.setenv("YOUTUBE_API_KEY", "test-key-123")
    s = YouTubeTrendingSource()
    assert s.enabled is True


def test_channel_rss_url_format(source):
    url = source._channel_rss_url("UC_TEST123")
    assert url == "https://www.youtube.com/feeds/videos.xml?channel_id=UC_TEST123"


@pytest.mark.asyncio
async def test_search_disabled_without_api_key(source, monkeypatch):
    """search() returns empty list when disabled."""
    monkeypatch.delenv("YOUTUBE_API_KEY", raising=False)
    s = YouTubeTrendingSource()
    assert s.enabled is False

    import aiohttp
    from scripts.feed_discovery.profiles._schema import CountryProfile, SourceConfig

    profile = CountryProfile(country="br")
    config = SourceConfig(priority=4, timeout=5, max_results=10)

    async with aiohttp.ClientSession() as session:
        results = await s.search("", profile, config, session)
        assert results == []


@pytest.mark.asyncio
async def test_search_empty_without_region_code(source, monkeypatch):
    """search() returns empty list when no regionCode is available."""
    monkeypatch.setenv("YOUTUBE_API_KEY", "test-key")
    s = YouTubeTrendingSource()

    import aiohttp
    from scripts.feed_discovery.profiles._schema import CountryProfile, SourceConfig

    # Profile with no usable country code
    profile = CountryProfile(country="")
    config = SourceConfig(priority=4, params={}, timeout=5, max_results=10)

    async with aiohttp.ClientSession() as session:
        results = await s.search("", profile, config, session)
        assert results == []


@pytest.mark.asyncio
async def test_probe_disabled(source, monkeypatch):
    """probe() returns failed ProbeResult when disabled."""
    monkeypatch.delenv("YOUTUBE_API_KEY", raising=False)
    s = YouTubeTrendingSource()

    import aiohttp
    from scripts.feed_discovery.profiles._schema import CountryProfile, SourceConfig

    profile = CountryProfile(country="br")
    config = SourceConfig(priority=4)

    async with aiohttp.ClientSession() as session:
        result = await s.probe(profile, config, session)
        assert isinstance(result, ProbeResult)
        assert result.source_name == "youtube_trending"
        assert result.success is False
        assert "disabled" in result.error.lower()
