# scripts/feed_discovery/tests/test_registry.py

from __future__ import annotations

from scripts.feed_discovery.profiles._registry import (
    load_profile, save_profile, merge_profiles, REGION_MAP,
)
from scripts.feed_discovery.profiles._schema import CountryProfile, SourceConfig


def test_region_map_has_six_regions():
    assert len(REGION_MAP) >= 6


def test_region_map_maps_nigeria_to_africa():
    assert REGION_MAP.get("nigeria") == "africa"


def test_region_map_maps_brazil_to_latam():
    assert REGION_MAP.get("brazil") == "latam"


def test_region_map_maps_india_to_asia():
    assert REGION_MAP.get("india") == "asia"


def test_region_map_maps_romania_to_europe_east():
    assert REGION_MAP.get("romania") == "europe_east"


def test_region_map_maps_uae_to_mena():
    assert REGION_MAP.get("uae") == "mena"


def test_region_map_maps_indonesia_to_southeast_asia():
    assert REGION_MAP.get("indonesia") == "southeast_asia"


def test_merge_sources_override_priority():
    """Regional sources should override global priority."""
    base = CountryProfile(country="test", sources={
        "deezer": SourceConfig(priority=5),
        "itunes": SourceConfig(priority=3),
    })
    regional = CountryProfile(country="test", sources={
        "deezer": SourceConfig(priority=1, params={"lang": "es"}),
    })
    merged = merge_profiles(base, regional)
    # deezer overridden to priority 1 + params
    assert merged.sources["deezer"].priority == 1
    assert merged.sources["deezer"].params == {"lang": "es"}
    # itunes untouched from base
    assert merged.sources["itunes"].priority == 3


def test_merge_disabled_sources_union():
    base = CountryProfile(country="test", disabled_sources={"itunes"})
    regional = CountryProfile(country="test", disabled_sources={"spotify"})
    merged = merge_profiles(base, regional)
    assert "itunes" in merged.disabled_sources
    assert "spotify" in merged.disabled_sources


def test_merge_media_domains_combined():
    base = CountryProfile(country="test", media_domains=["a.com", "b.com"])
    regional = CountryProfile(country="test", media_domains=["c.com", "b.com"])
    merged = merge_profiles(base, regional)
    assert "a.com" in merged.media_domains
    assert "b.com" in merged.media_domains
    assert "c.com" in merged.media_domains
    # b.com not duplicated
    assert merged.media_domains.count("b.com") == 1


def test_merge_languages_override():
    base = CountryProfile(country="test", languages=["en", "fr"])
    regional = CountryProfile(country="test", languages=["ar", "fr"])
    merged = merge_profiles(base, regional)
    # Regional overrides
    assert "ar" in merged.languages
    assert "fr" in merged.languages
    assert "en" not in merged.languages


def test_load_profile_global_fallback():
    """Countries not in any region get GLOBAL_PROFILE."""
    # "xyz" is not in REGION_MAP
    profile = load_profile("xyz")
    assert profile.country == "xyz"
    assert "podcast_index" in profile.sources


def test_load_profile_applies_regional_mixin():
    """Nigeria should get Africa mixin applied."""
    profile = load_profile("nigeria")
    assert profile.country == "nigeria"
    # Africa puts deezer at priority 2
    assert profile.sources["deezer"].priority == 2
    # Has African media domains
    assert len(profile.media_domains) > 10
    assert "vanguardngr.com" in profile.media_domains


def test_save_and_reload_profile(tmp_path):
    """Profiles roundtrip through JSON."""
    import json, os
    profile = CountryProfile(
        country="testland",
        languages=["en"],
        sources={"deezer": SourceConfig(priority=1)},
        disabled_sources={"itunes"},
    )
    # Temporarily override output dir
    path = tmp_path / "testland.json"
    save_profile(profile, output_dir=tmp_path)
    assert path.exists()

    # Check JSON is valid
    data = json.loads(path.read_text())
    assert data["country"] == "testland"
    assert "itunes" in data["disabled_sources"]
