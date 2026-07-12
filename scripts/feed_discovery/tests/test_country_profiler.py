# scripts/feed_discovery/tests/test_country_profiler.py

import pytest
from scripts.feed_discovery.profiles._schema import CountryProfile, SourceConfig, SourceMetrics
from scripts.feed_discovery.country_profiler import CountryProfiler
from scripts.feed_discovery.profiles._registry import load_profile


def test_profiler_creates_profile_for_new_country():
    profiler = CountryProfiler()
    profile = profiler.bootstrap_sync("testland")
    assert profile.country == "testland"
    assert len(profile.sources) >= 3  # at least the Phase 1+2 sources
    assert profile.generation_version >= 1


def test_profiler_marks_source_as_degraded():
    profiler = CountryProfiler()
    profile = CountryProfile(
        country="test",
        sources={"test_source": SourceConfig(priority=1)},
    )
    # Simulate 3 consecutive rounds with 0 results
    for _ in range(3):
        profiler._record_probe(profile, "test_source", success=False, result_count=0)

    metrics = profile.source_performance.get("test_source")
    assert metrics is not None
    assert metrics.total_calls == 3
    assert metrics.success_count == 0
    assert metrics.success_rate == 0.0


def test_profiler_disables_source_after_five_failures():
    profiler = CountryProfiler()
    profile = CountryProfile(
        country="test",
        sources={"bad_source": SourceConfig(priority=1)},
    )
    # 5 consecutive failures -> disabled
    for _ in range(5):
        profiler._record_probe(profile, "bad_source", success=False, result_count=0)
    assert "bad_source" in profile.disabled_sources


def test_profiler_does_not_disable_after_three_failures():
    profiler = CountryProfiler()
    profile = CountryProfile(
        country="test",
        sources={"slow_source": SourceConfig(priority=1)},
    )
    for _ in range(3):
        profiler._record_probe(profile, "slow_source", success=False, result_count=0)
    # 3 failures -> degraded (lower priority) but NOT disabled
    assert "slow_source" not in profile.disabled_sources
    assert profile.sources["slow_source"].priority > 1


def test_profiler_updates_success_metrics():
    profiler = CountryProfiler()
    profile = CountryProfile(
        country="test",
        sources={"good_source": SourceConfig(priority=1)},
    )
    profiler._record_probe(profile, "good_source", success=True, result_count=42)
    metrics = profile.source_performance["good_source"]
    assert metrics.success_count == 1
    assert metrics.total_results == 42
    assert metrics.success_rate == 1.0


def test_bootstrap_includes_active_sources_only():
    """Bootstrap should exclude disabled sources."""
    profiler = CountryProfiler()
    profile = profiler.bootstrap_sync("testland")
    for name, cfg in profile.sources.items():
        if name in profile.disabled_sources:
            pytest.fail(f"{name} is both in sources and disabled_sources")
