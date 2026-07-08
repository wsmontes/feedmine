from __future__ import annotations

from scripts.feed_discovery.models import Country
from scripts.feed_discovery.sources import youtube

BO = Country("bolivia", "Bolivia", "bo", True, "es", "bo-es", [], "Bolivia",
             ["La Paz", "Santa Cruz"], iso2="bo", iso3="BOL")

ABOUT_BO = (
    '<meta property="og:title" content="Canal Boliviano">'
    '{"aboutChannelViewModel":{"channelId":"UCabcdefghijklmnopqrstuv",'
    '"country":"Bolivia"}}'
)
ABOUT_US = (
    '<meta property="og:title" content="US Channel">'
    '{"aboutChannelViewModel":{"channelId":"UC00000000000000000000ab",'
    '"country":"United States"}}'
)
ABOUT_NO_COUNTRY = (
    '<meta property="og:title" content="Mystery">'
    '{"aboutChannelViewModel":{"channelId":"UC99999999999999999999zz"}}'
)


def test_seed_queries_target_youtube_with_anchors():
    qs = youtube.youtube_seed_queries(BO)
    assert "site:youtube.com Bolivia" in qs
    assert "site:youtube.com La Paz" in qs


def test_extract_channel_refs_keeps_channels_dedups_and_drops_videos():
    urls = [
        "https://www.youtube.com/channel/UCabcdefghijklmnopqrstuv",
        "https://www.youtube.com/channel/UCabcdefghijklmnopqrstuv?x=1",  # dup
        "https://m.youtube.com/@CanalBo",
        "https://www.youtube.com/watch?v=xyz",     # video: dropped
        "https://example.com/foo",                  # non-youtube: dropped
    ]
    refs = youtube.extract_channel_refs(urls)
    assert refs == [
        "https://www.youtube.com/channel/UCabcdefghijklmnopqrstuv",
        "https://www.youtube.com/@CanalBo",
    ]


def test_parse_channel_about_extracts_id_country_title():
    cid, country, title = youtube.parse_channel_about(ABOUT_BO)
    assert cid == "UCabcdefghijklmnopqrstuv"
    assert country == "Bolivia"
    assert title == "Canal Boliviano"


def test_channel_rss_url():
    assert youtube.channel_rss_url("UCabcdefghijklmnopqrstuv") == \
        "https://www.youtube.com/feeds/videos.xml?channel_id=UCabcdefghijklmnopqrstuv"


def test_candidate_kept_only_when_country_matches():
    ok = youtube.channel_candidate_from_html(ABOUT_BO, "Bolivia")
    assert ok is not None
    assert ok.url == "https://www.youtube.com/feeds/videos.xml?channel_id=UCabcdefghijklmnopqrstuv"
    assert ok.category == "YouTube" and ok.genre == "" and ok.national is True
    assert youtube.channel_candidate_from_html(ABOUT_US, "Bolivia") is None
    assert youtube.channel_candidate_from_html(ABOUT_NO_COUNTRY, "Bolivia") is None


def test_discover_uses_cached_ddg_and_about(tmp_path, monkeypatch):
    import asyncio

    from scripts.feed_discovery.pipeline import Config

    # Stub DDG: one channel URL surfaced, no network.
    monkeypatch.setattr(
        youtube.search, "search",
        lambda *a, **k: ["https://www.youtube.com/channel/UCabcdefghijklmnopqrstuv"],
    )
    cfg = Config(cache_dir=tmp_path, delay=0, fresh=False)
    # Pre-write the parsed /about cache for that channel.
    ch_cache = tmp_path / "youtube" / "bolivia" / "channel_UCabcdefghijklmnopqrstuv.json"
    ch_cache.parent.mkdir(parents=True, exist_ok=True)
    ch_cache.write_text(
        '{"channel_id": "UCabcdefghijklmnopqrstuv", "country": "Bolivia", "title": "Canal Bo"}',
        encoding="utf-8",
    )
    cands = asyncio.run(youtube.discover(BO, None, cfg))
    assert [c.url for c in cands] == \
        ["https://www.youtube.com/feeds/videos.xml?channel_id=UCabcdefghijklmnopqrstuv"]
    assert cands[0].category == "YouTube"
