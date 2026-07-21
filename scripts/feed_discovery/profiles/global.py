from __future__ import annotations

from ._schema import CountryProfile, SourceConfig

GLOBAL_PROFILE = CountryProfile(
    country="*",
    sources={
        # Free, open, 4M+ podcasts -- best first stop for any country
        "podcast_index": SourceConfig(priority=1, params={}),
        # iTunes Top 100 Podcasts chart per country (free, no auth)
        "itunes_charts": SourceConfig(priority=2, params={}),
        # Free, no auth, strong in LatAm/Africa/Europe
        "deezer": SourceConfig(priority=3, params={}),
        # Official API, 10K quota/day, replaces scraping
        "youtube_api": SourceConfig(priority=3, params={}),
        # YouTube mostPopular chart — trending videos per country (1 quota unit)
        "youtube_trending": SourceConfig(priority=4, params={}),
        # DDG web search for text/news feeds (existing, refactored)
        "ddg_text": SourceConfig(priority=5, params={}),
        # iTunes Search API (existing, refactored) -- Apple ecosystem only
        "itunes": SourceConfig(priority=6, params={}),
        # Wikipedia most-subscribed YouTube channels (static data, no API calls)
        "youtube_top_subscribed": SourceConfig(priority=7, params={}),
        # Premium podcast search, 250 req/month free -- use sparingly
        "listen_notes": SourceConfig(priority=8, params={}),
        # Spotify podcast catalog -- OAuth required
        "spotify": SourceConfig(priority=9, params={}),
        # 40M+ RSS feeds indexed -- OAuth required
        "feedly": SourceConfig(priority=10, params={}),
        # Google News RSS feeds by country (free, no auth)
        "google_news": SourceConfig(priority=10, params={}),
        # Wikipedia award-winning YouTube channels (static data, no API calls)
        "youtube_awards": SourceConfig(priority=11, params={}),
        # Kaggle top YouTube channels by country (CSV dataset, no API calls)
        "youtube_kaggle": SourceConfig(priority=12, params={}),
        # Social Blade top 50 YouTube channels per country (scraped, no API calls)
        "youtube_socialblade": SourceConfig(priority=13, params={}),
        # Wikipedia top 100 most-subscribed (Diamond Play Button, 50M+ subs)
        "youtube_diamond": SourceConfig(priority=14, params={}),
        # Reddit RSS feeds per country/subreddit (free, no auth)
        "reddit": SourceConfig(priority=15, params={}),
    },
)
