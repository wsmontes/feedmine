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
