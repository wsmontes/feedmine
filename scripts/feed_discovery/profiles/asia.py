# scripts/feed_discovery/profiles/asia.py

from __future__ import annotations
from ._schema import CountryProfile, SourceConfig

ASIA_PROFILE = CountryProfile(
    country="asia",
    internet_penetration=0.65,
    dominant_platforms=["whatsapp", "youtube", "instagram", "telegram", "wechat"],
    languages=["en", "hi", "zh", "ja", "ko", "id", "th", "vi"],
    sources={
        "youtube_api": SourceConfig(priority=1, params={}),
        "podcast_index": SourceConfig(priority=2, params={}),
        "ddg_text": SourceConfig(priority=3, params={}),
        "deezer": SourceConfig(priority=4, params={}),
        "itunes": SourceConfig(priority=5, params={}),
        "spotify": SourceConfig(priority=6, params={}),
        "feedly": SourceConfig(priority=7, params={}),
        "listen_notes": SourceConfig(priority=8, params={}),
    },
    media_domains=[
        # India
        "timesofindia.indiatimes.com", "thehindu.com",
        "hindustantimes.com", "indianexpress.com", "ndtv.com",
        "scroll.in", "thewire.in", "theprint.in", "newslaundry.com",
        "firstpost.com", "livemint.com", "thequint.com",
        # China (English)
        "scmp.com", "sixthtone.com", "caixinglobal.com",
        # Japan
        "asahi.com", "mainichi.jp", "japantimes.co.jp",
        "nikkei.com", "yomiuri.co.jp",
        # South Korea
        "koreaherald.com", "koreatimes.co.kr", "yonhapnews.co.kr",
        "chosun.com", "hani.co.kr",
        # Indonesia
        "kompas.com", "detik.com", "tempo.co", "jakartapost.com",
        "republika.co.id", "antaranews.com",
        # Thailand
        "bangkokpost.com", "nationthailand.com", "thaipbs.or.th",
        # Vietnam
        "vnexpress.net", "tuoitre.vn", "thanhnien.vn",
    ],
)
