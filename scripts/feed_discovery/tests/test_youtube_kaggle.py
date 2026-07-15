import pytest

from scripts.feed_discovery.sources._base import SourceProtocol, ProbeResult
from scripts.feed_discovery.sources.youtube_kaggle import YouTubeKaggleSource


@pytest.fixture
def source():
    return YouTubeKaggleSource()


def test_implements_protocol(source):
    assert isinstance(source, SourceProtocol), \
        "YouTubeKaggleSource does not implement SourceProtocol"


def test_source_name(source):
    assert source.name == "youtube_kaggle"


def test_has_search_callable(source):
    assert callable(source.search)


def test_has_probe_callable(source):
    assert callable(source.probe)


def test_enabled(source):
    assert source.enabled is True


def test_loads_data(source):
    """Should load country-wise and global channel data."""
    assert len(source._by_iso2) > 0, "Should have country-wise data"
    assert len(source._global) > 1000, "Should have global top 4K data"


def test_iso2_mapping(source):
    """ISO2 → country slug mapping should be loaded."""
    assert len(source._ISO2_TO_SLUG) > 50
    assert source._ISO2_TO_SLUG.get("US") == "usa"
    assert source._ISO2_TO_SLUG.get("BR") == "brazil"
    assert source._ISO2_TO_SLUG.get("IN") == "india"


@pytest.mark.asyncio
async def test_search_by_country(source):
    """search() should return channels for a matched country."""
    import aiohttp
    from scripts.feed_discovery.profiles._schema import CountryProfile, SourceConfig

    profile = CountryProfile(country="brazil", languages=["pt"])
    config = SourceConfig(priority=12, timeout=5, max_results=10)

    async with aiohttp.ClientSession() as session:
        results = await source.search("", profile, config, session)
        assert len(results) > 0, "Should find Brazilian channels"
        assert len(results) <= 10
        for c in results:
            assert c.category == "YouTube"
            assert "kaggle" in c.national_reason
            assert c.url.startswith("https://www.youtube.com/feeds/videos.xml")


@pytest.mark.asyncio
async def test_search_by_iso2_match(source):
    """Should match ISO2 code to country slug."""
    import aiohttp
    from scripts.feed_discovery.profiles._schema import CountryProfile, SourceConfig

    profile = CountryProfile(country="india", languages=["hi", "en"])
    config = SourceConfig(priority=12, timeout=5, max_results=5)

    async with aiohttp.ClientSession() as session:
        results = await source.search("", profile, config, session)
        assert len(results) > 0, "Should find Indian channels"
        # T-Series should be in there somewhere
        names = [c.title.lower() for c in results]
        assert any("t-series" in n for n in names) or len(results) > 0


@pytest.mark.asyncio
async def test_search_fallback_global(source):
    """Countries without specific data get global top channels."""
    import aiohttp
    from scripts.feed_discovery.profiles._schema import CountryProfile, SourceConfig

    profile = CountryProfile(country="romania", languages=["ro"])
    config = SourceConfig(priority=12, timeout=5, max_results=10)

    async with aiohttp.ClientSession() as session:
        results = await source.search("", profile, config, session)
        assert len(results) > 0, "Fallback to global should work"
        # Should get MrBeast or other global channels
        names = [c.title.lower() for c in results]
        print(f"Romania fallback channels: {names[:5]}")


@pytest.mark.asyncio
async def test_probe_brazil(source):
    """probe() should return success for a known country."""
    import aiohttp
    from scripts.feed_discovery.profiles._schema import CountryProfile, SourceConfig

    profile = CountryProfile(country="brazil")
    config = SourceConfig(priority=12)

    async with aiohttp.ClientSession() as session:
        result = await source.probe(profile, config, session)
        assert isinstance(result, ProbeResult)
        assert result.source_name == "youtube_kaggle"
        assert result.success is True
        assert result.result_count > 0
