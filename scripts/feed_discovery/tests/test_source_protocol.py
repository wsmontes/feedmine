import pytest
from scripts.feed_discovery.sources._base import SourceProtocol
from scripts.feed_discovery.sources.podcasts import ITunesSource
from scripts.feed_discovery.sources.ddg_text import DDGTextSource
from scripts.feed_discovery.sources.podcast_index import PodcastIndexSource
from scripts.feed_discovery.sources.deezer import DeezerSource
from scripts.feed_discovery.sources.youtube_api import YouTubeAPISource


ALL_SOURCES = [
    ITunesSource(),
    DDGTextSource(),
    PodcastIndexSource(),
    DeezerSource(),
    YouTubeAPISource(),
]


@pytest.mark.parametrize("source", ALL_SOURCES, ids=lambda s: s.name)
def test_source_implements_protocol(source):
    assert isinstance(source, SourceProtocol), \
        f"{source.name} does not implement SourceProtocol"


@pytest.mark.parametrize("source", ALL_SOURCES, ids=lambda s: s.name)
def test_source_has_name(source):
    assert isinstance(source.name, str)
    assert len(source.name) > 0


@pytest.mark.parametrize("source", ALL_SOURCES, ids=lambda s: s.name)
def test_source_has_search_callable(source):
    assert callable(source.search)


@pytest.mark.parametrize("source", ALL_SOURCES, ids=lambda s: s.name)
def test_source_has_probe_callable(source):
    assert callable(source.probe)


def test_all_source_names_unique():
    names = [s.name for s in ALL_SOURCES]
    assert len(names) == len(set(names)), f"Duplicate source names: {names}"


def test_registry_can_discover_sources():
    """Simulate how the future _registry.py will discover sources.

    In Phase 3, _registry.py will dynamically find all SourceProtocol
    implementations. This test validates the pattern works.
    """
    # For now, manually list. Phase 3 will auto-discover.
    registry: dict[str, SourceProtocol] = {}
    for source in ALL_SOURCES:
        registry[source.name] = source
    assert "itunes" in registry
    assert "ddg_text" in registry
    assert "podcast_index" in registry
    assert "deezer" in registry
    assert "youtube_api" in registry
    assert len(registry) == 5
