from __future__ import annotations

from ._schema import CountryProfile, SourceConfig

GLOBAL_PROFILE = CountryProfile(
    country="*",
    sources={
        # Free, open, 4M+ podcasts -- best first stop for any country
        "podcast_index": SourceConfig(priority=1, params={}),
        # Free, no auth, strong in LatAm/Africa/Europe
        "deezer": SourceConfig(priority=2, params={}),
        # Official API, 10K quota/day, replaces scraping
        "youtube_api": SourceConfig(priority=3, params={}),
        # DDG web search for text/news feeds (existing, refactored)
        "ddg_text": SourceConfig(priority=4, params={}),
        # iTunes Search API (existing, refactored) -- Apple ecosystem only
        "itunes": SourceConfig(priority=5, params={}),
        # Premium podcast search, 250 req/month free -- use sparingly
        "listen_notes": SourceConfig(priority=6, params={}),
        # Spotify podcast catalog -- OAuth required
        "spotify": SourceConfig(priority=7, params={}),
        # 40M+ RSS feeds indexed -- OAuth required
        "feedly": SourceConfig(priority=8, params={}),
    },
)
