# scripts/feed_discovery/profiles/europe_east.py

from __future__ import annotations
from ._schema import CountryProfile, SourceConfig

EUROPE_EAST_PROFILE = CountryProfile(
    country="europe_east",
    internet_penetration=0.75,
    dominant_platforms=["telegram", "vk", "youtube", "facebook", "instagram"],
    languages=["ru", "pl", "cs", "sk", "hu", "ro", "bg", "sr", "uk", "lt", "lv", "et"],
    sources={
        "deezer": SourceConfig(priority=1, params={}),
        "podcast_index": SourceConfig(priority=2, params={}),
        "youtube_api": SourceConfig(priority=3, params={}),
        "ddg_text": SourceConfig(priority=4, params={}),
        "itunes": SourceConfig(priority=5, params={}),
        "spotify": SourceConfig(priority=6, params={}),
        "feedly": SourceConfig(priority=7, params={}),
        "listen_notes": SourceConfig(priority=8, params={}),
    },
    media_domains=[
        # Russia
        "tass.ru", "ria.ru", "interfax.ru", "kommersant.ru",
        "vedomosti.ru", "rbc.ru", "meduza.io", "novayagazeta.ru",
        # Poland
        "onet.pl", "wp.pl", "gazeta.pl", "tvn24.pl",
        "rp.pl", "wyborcza.pl", "polskieradio.pl",
        # Romania
        "digi24.ro", "hotnews.ro", "mediafax.ro", "g4media.ro",
        "adevarul.ro", "ziare.com",
        # Czech / Slovakia
        "idnes.cz", "aktualne.cz", "denikn.cz", "sme.sk",
        "dennikn.sk", "pravda.sk",
        # Hungary
        "index.hu", "telex.hu", "444.hu", "hvg.hu", "nepszava.hu",
        # Bulgaria
        "dnevnik.bg", "capital.bg", "mediapool.bg", "nova.bg",
        # Serbia / Balkans
        "b92.net", "blic.rs", "danas.rs", "n1info.rs",
        "slobodnaevropa.org", "balkaninsight.com",
        # Ukraine
        "pravda.com.ua", "kyivindependent.com", "censor.net",
        "unian.ua", "liga.net",
        # Baltics
        "delfi.ee", "postimees.ee", "delfi.lv", "lsm.lv",
        "delfi.lt", "lrt.lt", "15min.lt",
    ],
)
