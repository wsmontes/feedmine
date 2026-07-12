# scripts/feed_discovery/profiles/southeast_asia.py

from __future__ import annotations
from ._schema import CountryProfile, SourceConfig

SOUTHEAST_ASIA_PROFILE = CountryProfile(
    country="southeast_asia",
    internet_penetration=0.67,
    dominant_platforms=["facebook", "youtube", "instagram", "tiktok", "line"],
    languages=["en", "id", "th", "vi", "ms", "tl", "my", "km"],
    sources={
        "youtube_api": SourceConfig(priority=1, params={}),
        "podcast_index": SourceConfig(priority=2, params={}),
        "deezer": SourceConfig(priority=3, params={}),
        "ddg_text": SourceConfig(priority=4, params={}),
        "itunes": SourceConfig(priority=5, params={}),
        "spotify": SourceConfig(priority=6, params={}),
        "listen_notes": SourceConfig(priority=7, params={}),
        "feedly": SourceConfig(priority=8, params={}),
    },
    media_domains=[
        # Indonesia (already in asia.py, duplicated for standalone use)
        "kompas.com", "detik.com", "tempo.co", "jakartapost.com",
        "republika.co.id", "antaranews.com", "cnnindonesia.com",
        # Thailand
        "bangkokpost.com", "nationthailand.com", "thaipbs.or.th",
        "khaosodenglish.com", "prachatai.com",
        # Vietnam
        "vnexpress.net", "tuoitre.vn", "thanhnien.vn",
        "vietnamnews.vn", "saigoneer.com",
        # Malaysia
        "thestar.com.my", "malaysiakini.com", "freemalaysiatoday.com",
        "nst.com.my", "malaymail.com", "theedgemarkets.com",
        # Philippines
        "inquirer.net", "philstar.com", "rappler.com",
        "abs-cbn.com", "gmanetwork.com", "mb.com.ph",
        # Singapore
        "straitstimes.com", "channelnewsasia.com", "todayonline.com",
        # Cambodia / Myanmar
        "phnompenhpost.com", "cambodiadaily.com",
        "irrawaddy.com", "mmtimes.com", "frontiermyanmar.net",
    ],
)
