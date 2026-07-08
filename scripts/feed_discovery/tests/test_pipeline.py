from __future__ import annotations

from scripts.feed_discovery.models import Candidate
from scripts.feed_discovery.pipeline import candidates_to_opml_map


def test_only_new_national_live_feeds_are_emitted():
    cands = [
        Candidate(url="https://a.br/f", category="News", title="A",
                  national=True, is_live=True, is_new=True),
        Candidate(url="https://b.br/f", category="News", title="B",
                  national=True, is_live=True, is_new=False),   # dropped: not new
        Candidate(url="https://c.com/f", category="News", title="C",
                  national=False, is_live=True, is_new=True),   # dropped: not national
        Candidate(url="https://d.br/f", category="News", title="D",
                  national=True, is_live=False, is_new=True),   # dropped: not live
    ]
    m = candidates_to_opml_map(cands)
    assert m == {"News": [("A", "https://a.br/f", "")]}


def test_untitled_feed_falls_back_to_host():
    cands = [Candidate(url="https://noticias.br/rss", category="News", title="",
                       national=True, is_live=True, is_new=True)]
    m = candidates_to_opml_map(cands)
    assert m["News"] == [("noticias.br", "https://noticias.br/rss", "")]


def test_genre_is_carried_into_the_map():
    cands = [Candidate(url="https://p.bo/feed", category="Podcasts", title="Pod",
                       genre="Historia", national=True, is_live=True, is_new=True)]
    m = candidates_to_opml_map(cands)
    assert m["Podcasts"] == [("Pod", "https://p.bo/feed", "Historia")]


def test_process_country_routes_podcasts_and_youtube(monkeypatch):
    import asyncio

    from scripts.feed_discovery import pipeline
    from scripts.feed_discovery.models import Country

    bo = Country("bolivia", "Bolivia", "bo", True, "es", "bo-es", [], "Bolivia",
                 [], iso2="bo", iso3="BOL")

    async def fake_pod(country, session, cfg):
        return [Candidate(url="https://feeds.x/p", category="Podcasts", title="P",
                          genre="Historia", national=True, is_new=True)]

    async def fake_yt(country, session, cfg):
        return [Candidate(url="https://www.youtube.com/feeds/videos.xml?channel_id=UCx",
                          category="YouTube", title="C", national=True, is_new=True)]

    async def fake_verify(session, url, timeout):
        return (True, 200, "verified-title")

    monkeypatch.setattr(pipeline.podcasts, "discover", fake_pod)
    monkeypatch.setattr(pipeline.youtube, "discover", fake_yt)
    monkeypatch.setattr(pipeline.verify, "verify_feed", fake_verify)

    cfg = pipeline.Config(delay=0)
    cands = asyncio.run(pipeline.process_country(
        bo, ["Podcasts", "YouTube"], {}, set(), set(), None, cfg))
    by_cat = {c.category: c for c in cands if c.is_live}
    assert by_cat["Podcasts"].url == "https://feeds.x/p"
    assert by_cat["Podcasts"].genre == "Historia"
    assert by_cat["YouTube"].url.endswith("channel_id=UCx")
