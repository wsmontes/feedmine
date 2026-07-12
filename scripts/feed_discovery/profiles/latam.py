# scripts/feed_discovery/profiles/latam.py

from __future__ import annotations
from ._schema import CountryProfile, SourceConfig

LATAM_PROFILE = CountryProfile(
    country="latam",
    internet_penetration=0.72,
    dominant_platforms=["whatsapp", "instagram", "youtube", "deezer", "facebook"],
    languages=["es", "pt"],
    sources={
        "deezer": SourceConfig(priority=1, params={}),
        "podcast_index": SourceConfig(priority=2, params={"lang": "es,pt"}),
        "youtube_api": SourceConfig(priority=3, params={"relevanceLanguage": "es,pt"}),
        "itunes": SourceConfig(priority=4, params={}),
        "ddg_text": SourceConfig(priority=5, params={}),
        "spotify": SourceConfig(priority=6, params={}),
        "listen_notes": SourceConfig(priority=7, params={}),
        "feedly": SourceConfig(priority=8, params={}),
    },
    media_domains=[
        # Brazil
        "globo.com", "uol.com.br", "folha.uol.com.br", "estadao.com.br",
        "g1.globo.com", "r7.com", "terra.com.br", "ig.com.br",
        "correiobraziliense.com.br", "otempo.com.br",
        # Mexico
        "eluniversal.com.mx", "jornada.com.mx", "milenio.com",
        "reforma.com", "excelsior.com.mx", "proceso.com.mx",
        "elfinanciero.com.mx", "animalpolitico.com",
        # Argentina
        "clarin.com", "lanacion.com.ar", "infobae.com",
        "pagina12.com.ar", "perfil.com", "ambito.com",
        # Colombia
        "eltiempo.com", "elespectador.com", "semana.com",
        "elpais.com.co", "lafm.com.co", "rcnradio.com",
        # Chile
        "latercera.com", "emol.com", "biobiochile.cl",
        "elmostrador.cl", "cooperativa.cl",
        # Peru
        "elcomercio.pe", "larepublica.pe", "gestion.pe",
        "rpp.pe", "andina.pe",
        # Rest of LatAm
        "elpais.com.uy", "abc.com.py", "eldeber.com.bo",
        "eluniverso.com", "nacion.com", "prensalibre.com",
        "laprensa.hn", "elnuevodiario.com.ni", "elsalvador.com",
    ],
)
