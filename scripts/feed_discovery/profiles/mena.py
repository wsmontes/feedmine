# scripts/feed_discovery/profiles/mena.py

from __future__ import annotations
from ._schema import CountryProfile, SourceConfig

MENA_PROFILE = CountryProfile(
    country="mena",
    internet_penetration=0.68,
    dominant_platforms=["whatsapp", "facebook", "instagram", "youtube", "telegram"],
    languages=["ar", "en", "fa", "tr", "he", "ku"],
    sources={
        "deezer": SourceConfig(priority=1, params={}),
        "podcast_index": SourceConfig(priority=2, params={"lang": "ar,fa,tr"}),
        "youtube_api": SourceConfig(priority=3, params={}),
        "ddg_text": SourceConfig(priority=4, params={}),
        "itunes": SourceConfig(priority=5, params={}),
        "spotify": SourceConfig(priority=6, params={}),
        "listen_notes": SourceConfig(priority=7, params={}),
        "feedly": SourceConfig(priority=8, params={}),
    },
    media_domains=[
        # Saudi Arabia / Gulf
        "arabnews.com", "saudigazette.com.sa", "alriyadh.com",
        "gulfnews.com", "khaleejtimes.com", "thenational.ae",
        "aljazeera.net", "aljazeera.com", "alaraby.co.uk",
        # Egypt
        "alahram.org.eg", "egyptindependent.com", "madamasr.com",
        "dailynewsegypt.com", "almasryalyoum.com",
        # Turkey
        "hurriyet.com.tr", "sabah.com.tr", "cumhuriyet.com.tr",
        "dailysabah.com", "ahvalnews.com", "duvarenglish.com",
        # Iran
        "tehrantimes.com", "ifpnews.com", "farsnews.ir",
        "tasnimnews.com", "irna.ir",
        # Israel
        "timesofisrael.com", "jpost.com", "haaretz.com",
        "ynetnews.com", "globes.co.il",
        # Lebanon / Jordan / Iraq
        "dailystar.com.lb", "naharnet.com", "jordantimes.com",
        "rudaw.net", "iraqinews.com",
        # Morocco / Tunisia / Algeria
        "hespress.com", "lematin.ma", "moroccoworldnews.com",
        "tunisienumerique.com", "algeriepatriotique.com",
        # Pan-Arab
        "alarabiya.net", "skynewsarabia.com", "bbc.com/arabic",
        "middleeasteye.net", "middleeastmonitor.com",
    ],
)
