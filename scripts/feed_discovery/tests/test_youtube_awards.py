import pytest

from scripts.feed_discovery.sources._base import SourceProtocol, ProbeResult
from scripts.feed_discovery.sources.youtube_awards import YouTubeAwardsSource


@pytest.fixture
def source():
    return YouTubeAwardsSource()


def test_implements_protocol(source):
    assert isinstance(source, SourceProtocol), \
        "YouTubeAwardsSource does not implement SourceProtocol"


def test_source_name(source):
    assert source.name == "youtube_awards"


def test_has_search_callable(source):
    assert callable(source.search)


def test_has_probe_callable(source):
    assert callable(source.probe)


def test_enabled_is_boolean(source):
    """Source should report whether the awards data file exists."""
    assert isinstance(source.enabled, bool)


def test_disabled_without_data_file(source):
    """When awards JSON doesn't exist, enabled is False."""
    if not source.enabled:
        assert source._channels == []


@pytest.mark.asyncio
async def test_search_disabled_without_data(source):
    """search() returns empty list when data file doesn't exist."""
    if not source.enabled:
        import aiohttp
        from scripts.feed_discovery.profiles._schema import CountryProfile, SourceConfig

        profile = CountryProfile(country="us")
        config = SourceConfig(priority=11, timeout=5, max_results=10)

        async with aiohttp.ClientSession() as session:
            results = await source.search("", profile, config, session)
            assert results == []


@pytest.mark.asyncio
async def test_probe_disabled(source):
    """probe() returns failed ProbeResult when data file doesn't exist."""
    if not source.enabled:
        import aiohttp
        from scripts.feed_discovery.profiles._schema import CountryProfile, SourceConfig

        profile = CountryProfile(country="us")
        config = SourceConfig(priority=11)

        async with aiohttp.ClientSession() as session:
            result = await source.probe(profile, config, session)
            assert isinstance(result, ProbeResult)
            assert result.source_name == "youtube_awards"
            assert result.success is False
