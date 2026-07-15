import pytest

from scripts.feed_discovery.sources._base import SourceProtocol, ProbeResult
from scripts.feed_discovery.sources.youtube_socialblade import YouTubeSocialBladeSource


@pytest.fixture
def source():
    return YouTubeSocialBladeSource()


def test_implements_protocol(source):
    assert isinstance(source, SourceProtocol)


def test_source_name(source):
    assert source.name == "youtube_socialblade"


def test_has_search_callable(source):
    assert callable(source.search)


def test_has_probe_callable(source):
    assert callable(source.probe)


def test_enabled(source):
    assert source.enabled is True


def test_loads_data(source):
    """Should load data for all 101 countries."""
    assert len(source._by_country) == 101
    assert len(source._channels) > 1000


def test_brazil_data(source):
    """Brazil should have top channels."""
    br = source._by_country.get("brazil", [])
    assert len(br) == 50
    names = [c["channel_name"] for c in br]
    assert "Canal KondZilla" in names


def test_usa_data(source):
    """USA should have top channels."""
    us = source._by_country.get("usa", [])
    assert len(us) == 50
    names = [c["channel_name"] for c in us]
    assert "MrBeast" in names


def test_all_channels_have_feed_urls(source):
    """Every channel must have a feed_url."""
    for ch in source._channels:
        assert ch.get("feed_url", "").startswith(
            "https://www.youtube.com/feeds/videos.xml?channel_id=UC"
        ), f"Bad feed_url for {ch.get('channel_name', '?')}"


@pytest.mark.asyncio
async def test_search_brazil(source):
    import aiohttp
    from scripts.feed_discovery.profiles._schema import CountryProfile, SourceConfig

    profile = CountryProfile(country="brazil", languages=["pt"])
    config = SourceConfig(priority=13, timeout=5, max_results=10)

    async with aiohttp.ClientSession() as session:
        results = await source.search("", profile, config, session)
        assert len(results) == 10
        names = [c.title for c in results]
        assert "Canal KondZilla" in names
        for c in results:
            assert c.category == "YouTube"
            assert "socialblade" in c.national_reason


@pytest.mark.asyncio
async def test_search_empty_for_unknown_country(source):
    import aiohttp
    from scripts.feed_discovery.profiles._schema import CountryProfile, SourceConfig

    profile = CountryProfile(country="atlantis", languages=["xx"])
    config = SourceConfig(priority=13, timeout=5, max_results=10)

    async with aiohttp.ClientSession() as session:
        results = await source.search("", profile, config, session)
        assert results == []


@pytest.mark.asyncio
async def test_probe_brazil(source):
    import aiohttp
    from scripts.feed_discovery.profiles._schema import CountryProfile, SourceConfig

    profile = CountryProfile(country="brazil")
    config = SourceConfig(priority=13)

    async with aiohttp.ClientSession() as session:
        result = await source.probe(profile, config, session)
        assert isinstance(result, ProbeResult)
        assert result.source_name == "youtube_socialblade"
        assert result.success is True
        assert result.result_count > 0
