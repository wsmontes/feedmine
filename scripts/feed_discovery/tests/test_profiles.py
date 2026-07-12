from dataclasses import asdict
from scripts.feed_discovery.profiles._schema import (
    CountryProfile, SourceConfig, SourceMetrics,
)
from scripts.feed_discovery.sources._base import ProbeResult


def test_source_config_defaults():
    c = SourceConfig(priority=1)
    assert c.priority == 1
    assert c.enabled is True
    assert c.params == {}
    assert c.min_results == 3
    assert c.max_results == 50
    assert c.timeout == 15


def test_source_config_custom():
    c = SourceConfig(priority=2, enabled=False, params={"lang": "en"}, min_results=5, max_results=20, timeout=30)
    assert c.priority == 2
    assert c.enabled is False
    assert c.params == {"lang": "en"}
    assert c.min_results == 5
    assert c.max_results == 20
    assert c.timeout == 30


def test_source_metrics_defaults():
    m = SourceMetrics()
    assert m.total_calls == 0
    assert m.total_results == 0
    assert m.success_count == 0
    assert m.failure_count == 0
    assert m.success_rate == 1.0  # 0/0 = 1.0 per spec
    assert m.avg_results == 0.0
    assert m.avg_latency_ms == 0.0


def test_source_metrics_computed():
    m = SourceMetrics(
        total_calls=10, total_results=45,
        success_count=8, failure_count=2,
        total_latency_ms=2300.0,
    )
    assert m.success_rate == 0.8
    assert m.avg_results == 4.5
    assert m.avg_latency_ms == 230.0


def test_source_metrics_success_rate_zero_calls():
    m = SourceMetrics(total_calls=0, success_count=0)
    assert m.success_rate == 1.0


def test_probe_result_success():
    r = ProbeResult(source_name="test", success=True, result_count=42, latency_ms=150.0)
    assert r.source_name == "test"
    assert r.success is True
    assert r.result_count == 42
    assert r.latency_ms == 150.0
    assert r.error == ""


def test_probe_result_failure():
    r = ProbeResult(source_name="test", success=False, result_count=0, latency_ms=5000.0, error="timeout")
    assert r.success is False
    assert r.error == "timeout"


def test_country_profile_defaults():
    p = CountryProfile(country="nigeria")
    assert p.country == "nigeria"
    assert p.internet_penetration == 0.0
    assert p.dominant_platforms == []
    assert p.languages == []
    assert p.sources == {}
    assert p.local_directories == []
    assert p.media_domains == []
    assert p.disabled_sources == set()
    assert p.source_performance == {}
    assert p.generated_at == ""
    assert p.generation_version == 1


def test_country_profile_with_sources():
    p = CountryProfile(
        country="brazil",
        internet_penetration=0.75,
        dominant_platforms=["whatsapp", "youtube", "deezer"],
        languages=["pt"],
        sources={
            "deezer": SourceConfig(priority=1),
            "podcast_index": SourceConfig(priority=2, params={"lang": "pt"}),
        },
        media_domains=["globo.com", "uol.com.br"],
        disabled_sources={"itunes"},
    )
    assert p.country == "brazil"
    assert len(p.sources) == 2
    assert p.sources["deezer"].priority == 1
    assert p.sources["podcast_index"].params == {"lang": "pt"}
    assert "itunes" in p.disabled_sources
    assert p.internet_penetration == 0.75


def test_country_profile_serialization():
    p = CountryProfile(
        country="test",
        sources={"deezer": SourceConfig(priority=1)},
        disabled_sources={"itunes"},
    )
    d = asdict(p)
    assert d["country"] == "test"
    assert d["sources"]["deezer"]["priority"] == 1
    assert "itunes" in d["disabled_sources"]


# ---- GLOBAL_PROFILE tests ----
# NOTE: importlib is required because 'global' is a Python keyword,
# so 'from profiles.global import ...' is a SyntaxError at parse time.

import importlib
_global_mod = importlib.import_module(
    "scripts.feed_discovery.profiles.global"
)
GLOBAL_PROFILE = _global_mod.GLOBAL_PROFILE


def test_global_profile_is_country_profile():
    from scripts.feed_discovery.profiles._schema import CountryProfile
    assert isinstance(GLOBAL_PROFILE, CountryProfile)


def test_global_profile_country_is_wildcard():
    assert GLOBAL_PROFILE.country == "*"


def test_global_profile_has_eight_sources():
    assert len(GLOBAL_PROFILE.sources) == 8


def test_global_profile_sources_ordered_by_priority():
    priorities = [(name, cfg.priority) for name, cfg in GLOBAL_PROFILE.sources.items()]
    sorted_by_priority = sorted(priorities, key=lambda x: x[1])
    assert priorities == sorted_by_priority


def test_global_profile_source_names():
    expected = {
        "podcast_index", "deezer", "youtube_api", "ddg_text",
        "itunes", "listen_notes", "spotify", "feedly",
    }
    assert set(GLOBAL_PROFILE.sources.keys()) == expected


def test_global_profile_youtube_scrape_disabled():
    pass  # placeholder -- youtube_scrape not in GLOBAL_PROFILE yet


def test_global_profile_no_disabled_sources_initially():
    assert GLOBAL_PROFILE.disabled_sources == set()


def test_global_profile_media_domains_empty():
    assert GLOBAL_PROFILE.media_domains == []


def test_global_profile_generation_version():
    assert GLOBAL_PROFILE.generation_version == 1
