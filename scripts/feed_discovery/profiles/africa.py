# scripts/feed_discovery/profiles/africa.py

from __future__ import annotations
from ._schema import CountryProfile, SourceConfig

AFRICA_PROFILE = CountryProfile(
    country="africa",
    internet_penetration=0.36,
    dominant_platforms=["whatsapp", "facebook", "boomplay", "audiomack", "youtube"],
    languages=["en", "fr", "ar", "sw", "pt"],
    sources={
        "podcast_index": SourceConfig(priority=1, params={}),
        "deezer": SourceConfig(priority=2, params={}),
        "youtube_api": SourceConfig(priority=3, params={}),
        "ddg_text": SourceConfig(priority=4, params={}),
        "itunes": SourceConfig(priority=5, params={}),
        "listen_notes": SourceConfig(priority=6, params={}),
        "spotify": SourceConfig(priority=7, params={}),
        "feedly": SourceConfig(priority=8, params={}),
    },
    media_domains=[
        # Nigeria
        "vanguardngr.com", "punchng.com", "thisdaylive.com",
        "channelstv.com", "premiumtimesng.com", "guardian.ng",
        "dailypost.ng", "thecable.ng", "saharareporters.com",
        # Kenya
        "nation.africa", "citizen.digital", "standardmedia.co.ke",
        "the-star.co.ke", "capitalfm.co.ke",
        # South Africa
        "mg.co.za", "news24.com", "iol.co.za", "timeslive.co.za",
        "ewn.co.za", "dailymaverick.co.za",
        # Ghana
        "ghananewsagency.org", "myjoyonline.com", "citinewsroom.com",
        "graphic.com.gh", "peacefmonline.com",
        # Ethiopia
        "addisfortune.news", "thereporterethiopia.com",
        "ethiopianreporter.com",
        # Pan-Africa
        "africanews.com", "apanews.net", "allafrica.com",
        "theeastafrican.co.ke", "africanarguments.org",
        # Francophone Africa
        "jeuneafrique.com", "lefaso.net", "abidjan.net",
        "seneweb.com", "koaci.com",
    ],
)
