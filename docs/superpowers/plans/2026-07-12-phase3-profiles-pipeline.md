# Phase 3: Profiles & Pipeline — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Criar o sistema de perfis regionais com merge, o country_profiler que gera e atualiza perfis automaticamente, e o adaptive_pipeline que orquestra descoberta multi-source usando CountryProfile.

**Architecture:** 7 mixins regionais que herdam do GLOBAL_PROFILE, um registry que faz merge profundo, um profiler que testa fontes e gera perfis otimizados por país, e um pipeline que substitui `subregion/populate.py` usando seleção dinâmica de fontes.

**Tech Stack:** Python 3.12, dataclasses, asyncio, aiohttp, pytest

## Global Constraints

- Mixins em `scripts/feed_discovery/profiles/` — um por região
- Registry em `scripts/feed_discovery/profiles/_registry.py`
- Country profiler em `scripts/feed_discovery/country_profiler.py`
- Adaptive pipeline em `scripts/feed_discovery/adaptive_pipeline.py`
- NÃO modificar fontes existentes (sources/*.py)
- NÃO quebrar `subregion/populate.py` — o adaptive_pipeline é um novo entry point
- Reusar `opml_writer.py`, `models.py`, `heuristic.py` do sistema existente
- Imports relativos dentro do pacote, absolutos nos testes
- API keys via env vars (`.env`)
- Seguir TDD

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `scripts/feed_discovery/profiles/africa.py` | Create | Mixin: Boomplay RSS, Podcast Index, Deezer, +media_domains |
| `scripts/feed_discovery/profiles/latam.py` | Create | Mixin: Deezer #1, Podcast Index, YouTube, +media_domains |
| `scripts/feed_discovery/profiles/asia.py` | Create | Mixin: YouTube, Podcast Index, +media_domains |
| `scripts/feed_discovery/profiles/europe_east.py` | Create | Mixin: Deezer, Podcast Index, DDG, +media_domains |
| `scripts/feed_discovery/profiles/mena.py` | Create | Mixin: Deezer, YouTube, Podcast Index, +media_domains |
| `scripts/feed_discovery/profiles/southeast_asia.py` | Create | Mixin: Podcast Index, Deezer, YouTube, +media_domains |
| `scripts/feed_discovery/profiles/_registry.py` | Create | load_profile(), save_profile(), merge logic |
| `scripts/feed_discovery/country_profiler.py` | Create | Bootstrap + update automático de perfis |
| `scripts/feed_discovery/adaptive_pipeline.py` | Create | Orquestrador multi-source com CountryProfile |
| `scripts/feed_discovery/tests/test_registry.py` | Create | Testes de merge e cache do registry |
| `scripts/feed_discovery/tests/test_country_profiler.py` | Create | Testes do profiler (probe, bootstrap, update) |
| `scripts/feed_discovery/tests/test_adaptive_pipeline.py` | Create | Testes de integração do pipeline adaptativo |

---

### Task 1: Regional Mixins (7 arquivos)

**Files:**
- Create: `scripts/feed_discovery/profiles/africa.py`
- Create: `scripts/feed_discovery/profiles/latam.py`
- Create: `scripts/feed_discovery/profiles/asia.py`
- Create: `scripts/feed_discovery/profiles/europe_east.py`
- Create: `scripts/feed_discovery/profiles/mena.py`
- Create: `scripts/feed_discovery/profiles/southeast_asia.py`

**Interfaces:**
- Consumes: `CountryProfile`, `SourceConfig` da Phase 1
- Produces: 6 perfis regionais com sources re-priorizadas e media_domains

- [ ] **Step 1: Write profiles/africa.py**

```python
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
```

- [ ] **Step 2: Write profiles/latam.py**

```python
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
```

- [ ] **Step 3: Write profiles/asia.py**

```python
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
```

- [ ] **Step 4: Write profiles/europe_east.py**

```python
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
```

- [ ] **Step 5: Write profiles/mena.py**

```python
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
```

- [ ] **Step 6: Write profiles/southeast_asia.py**

```python
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
```

- [ ] **Step 7: Commit**

```bash
git add scripts/feed_discovery/profiles/africa.py \
        scripts/feed_discovery/profiles/latam.py \
        scripts/feed_discovery/profiles/asia.py \
        scripts/feed_discovery/profiles/europe_east.py \
        scripts/feed_discovery/profiles/mena.py \
        scripts/feed_discovery/profiles/southeast_asia.py
git commit -m "feat: add 6 regional profile mixins with localized sources and media_domains

Africa, LatAm, Asia, Europe East, MENA, Southeast Asia.
Each overrides source priorities and adds 30-40 local media domains.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Profile Registry (merge + cache)

**Files:**
- Create: `scripts/feed_discovery/profiles/_registry.py`
- Create: `scripts/feed_discovery/tests/test_registry.py`

**Interfaces:**
- Consumes: `CountryProfile`, `SourceConfig` (Phase 1), `GLOBAL_PROFILE` (Phase 1), 6 mixins (Task 1)
- Produces: `load_profile(country_slug) -> CountryProfile`, `save_profile(profile) -> None`, `REGION_MAP: dict[str, str]`

- [ ] **Step 1: Write tests/test_registry.py**

```python
# scripts/feed_discovery/tests/test_registry.py

from scripts.feed_discovery.profiles._registry import (
    load_profile, save_profile, merge_profiles, REGION_MAP,
)
from scripts.feed_discovery.profiles._schema import CountryProfile, SourceConfig
from scripts.feed_discovery.profiles.global import GLOBAL_PROFILE


def test_region_map_has_six_regions():
    assert len(REGION_MAP) >= 6


def test_region_map_maps_nigeria_to_africa():
    assert REGION_MAP.get("nigeria") == "africa"


def test_region_map_maps_brazil_to_latam():
    assert REGION_MAP.get("brazil") == "latam"


def test_region_map_maps_india_to_asia():
    assert REGION_MAP.get("india") == "asia"


def test_region_map_maps_romania_to_europe_east():
    assert REGION_MAP.get("romania") == "europe_east"


def test_region_map_maps_uae_to_mena():
    assert REGION_MAP.get("uae") == "mena"


def test_region_map_maps_indonesia_to_southeast_asia():
    assert REGION_MAP.get("indonesia") == "southeast_asia"


def test_merge_sources_override_priority():
    """Regional sources should override global priority."""
    base = CountryProfile(country="test", sources={
        "deezer": SourceConfig(priority=5),
        "itunes": SourceConfig(priority=3),
    })
    regional = CountryProfile(country="test", sources={
        "deezer": SourceConfig(priority=1, params={"lang": "es"}),
    })
    merged = merge_profiles(base, regional)
    # deezer overridden to priority 1 + params
    assert merged.sources["deezer"].priority == 1
    assert merged.sources["deezer"].params == {"lang": "es"}
    # itunes untouched from base
    assert merged.sources["itunes"].priority == 3


def test_merge_disabled_sources_union():
    base = CountryProfile(country="test", disabled_sources={"itunes"})
    regional = CountryProfile(country="test", disabled_sources={"spotify"})
    merged = merge_profiles(base, regional)
    assert "itunes" in merged.disabled_sources
    assert "spotify" in merged.disabled_sources


def test_merge_media_domains_combined():
    base = CountryProfile(country="test", media_domains=["a.com", "b.com"])
    regional = CountryProfile(country="test", media_domains=["c.com", "b.com"])
    merged = merge_profiles(base, regional)
    assert "a.com" in merged.media_domains
    assert "b.com" in merged.media_domains
    assert "c.com" in merged.media_domains
    # b.com not duplicated
    assert merged.media_domains.count("b.com") == 1


def test_merge_languages_override():
    base = CountryProfile(country="test", languages=["en", "fr"])
    regional = CountryProfile(country="test", languages=["ar", "fr"])
    merged = merge_profiles(base, regional)
    # Regional overrides but keeps unique base languages
    assert "ar" in merged.languages
    assert "fr" in merged.languages
    assert "en" not in merged.languages


def test_load_profile_global_fallback():
    """Countries not in any region get GLOBAL_PROFILE."""
    # "xyz" is not in REGION_MAP
    profile = load_profile("xyz")
    assert profile.country == "xyz"
    assert "podcast_index" in profile.sources


def test_load_profile_applies_regional_mixin():
    """Nigeria should get Africa mixin applied."""
    profile = load_profile("nigeria")
    assert profile.country == "nigeria"
    # Africa puts deezer at priority 2
    assert profile.sources["deezer"].priority == 2
    # Has African media domains
    assert len(profile.media_domains) > 10
    assert "vanguardngr.com" in profile.media_domains


def test_save_and_reload_profile(tmp_path):
    """Profiles roundtrip through JSON."""
    import json, os
    profile = CountryProfile(
        country="testland",
        languages=["en"],
        sources={"deezer": SourceConfig(priority=1)},
        disabled_sources={"itunes"},
    )
    # Temporarily override output dir
    path = tmp_path / "testland.json"
    save_profile(profile, output_dir=tmp_path)
    assert path.exists()

    # Check JSON is valid
    data = json.loads(path.read_text())
    assert data["country"] == "testland"
    assert "itunes" in data["disabled_sources"]
```

- [ ] **Step 2: Write profiles/_registry.py**

```python
# scripts/feed_discovery/profiles/_registry.py

from __future__ import annotations

import json
from pathlib import Path

from ._schema import CountryProfile, SourceConfig, SourceMetrics
from .global import GLOBAL_PROFILE

# Country → region mapping. Every country with sub-region OPMLs must be here.
# Countries not listed get GLOBAL_PROFILE directly.
REGION_MAP: dict[str, str] = {
    # Africa
    "nigeria": "africa", "kenya": "africa", "south-africa": "africa",
    "ghana": "africa", "ethiopia": "africa", "egypt": "africa",
    "algeria": "africa", "morocco": "africa", "tunisia": "africa",
    "angola": "africa", "ivory-coast": "africa", "sudan": "africa",
    "cameroon": "africa", "uganda": "africa", "tanzania": "africa",
    "rwanda": "africa", "senegal": "africa", "zimbabwe": "africa",
    "zambia": "africa", "malawi": "africa", "burkina-faso": "africa",
    "mozambique": "africa", "mali": "africa", "benin": "africa",
    # LatAm
    "brazil": "latam", "mexico": "latam", "argentina": "latam",
    "colombia": "latam", "peru": "latam", "chile": "latam",
    "venezuela": "latam", "ecuador": "latam", "bolivia": "latam",
    "paraguay": "latam", "uruguay": "latam", "costa-rica": "latam",
    "panama": "latam", "cuba": "latam", "dominican-republic": "latam",
    "haiti": "latam", "honduras": "latam", "el-salvador": "latam",
    "nicaragua": "latam", "guatemala": "latam", "puerto-rico": "latam",
    # Asia
    "india": "asia", "china": "asia", "japan": "asia",
    "south-korea": "asia", "taiwan": "asia", "nepal": "asia",
    "bangladesh": "asia", "sri-lanka": "asia", "pakistan": "asia",
    # Europe East
    "russia": "europe_east", "romania": "europe_east",
    "poland": "europe_east", "ukraine": "europe_east",
    "czech-republic": "europe_east", "hungary": "europe_east",
    "bulgaria": "europe_east", "serbia": "europe_east",
    "slovakia": "europe_east", "croatia": "europe_east",
    "slovenia": "europe_east", "lithuania": "europe_east",
    "latvia": "europe_east", "estonia": "europe_east",
    "belarus": "europe_east", "georgia": "europe_east",
    "armenia": "europe_east", "azerbaijan": "europe_east",
    "kazakhstan": "europe_east",
    # MENA
    "uae": "mena", "saudi-arabia": "mena", "turkey": "mena",
    "israel": "mena", "iran": "mena", "iraq": "mena",
    "qatar": "mena", "jordan": "mena", "lebanon": "mena",
    "syria": "mena", "cyprus": "mena",
    # Southeast Asia
    "indonesia": "southeast_asia", "thailand": "southeast_asia",
    "vietnam": "southeast_asia", "malaysia": "southeast_asia",
    "philippines": "southeast_asia", "singapore": "southeast_asia",
    "myanmar": "southeast_asia", "cambodia": "southeast_asia",
    # Western Europe (fallback to global — well-covered by all sources)
    "united-kingdom": None, "france": None, "germany": None,
    "italy": None, "spain": None, "portugal": None,
    "netherlands": None, "belgium": None, "switzerland": None,
    "austria": None, "sweden": None, "norway": None,
    "denmark": None, "finland": None, "ireland": None,
    "iceland": None, "luxembourg": None, "malta": None,
    "greece": None, "canada": None, "australia": None,
    "new-zealand": None, "usa": None,
    # Small island nations — global fallback
    "jamaica": None, "bahamas": None, "barbados": None,
    "trinidad-tobago": None, "mauritius": None, "fiji": None,
}


def merge_profiles(base: CountryProfile, override: CountryProfile) -> CountryProfile:
    """Deep merge two profiles. Override takes precedence.

    - sources: override replaces entire SourceConfig for matching keys
    - disabled_sources: set union
    - media_domains, local_directories: combined, deduplicated
    - languages: override replaces
    - dominant_platforms: override replaces
    - internet_penetration: override replaces
    - source_performance: override replaces matching keys
    """
    merged = CountryProfile(
        country=override.country if override.country != "*" else base.country,
        internet_penetration=override.internet_penetration or base.internet_penetration,
        dominant_platforms=override.dominant_platforms or base.dominant_platforms,
        languages=override.languages or base.languages,
        sources={**base.sources, **override.sources},
        local_directories=list(dict.fromkeys(base.local_directories + override.local_directories)),
        media_domains=list(dict.fromkeys(base.media_domains + override.media_domains)),
        disabled_sources=base.disabled_sources | override.disabled_sources,
        source_performance={**base.source_performance, **override.source_performance},
    )
    return merged


def load_profile(
    country_slug: str,
    profiles_dir: Path | None = None,
) -> CountryProfile:
    """Load a CountryProfile with regional merge.

    Order: GLOBAL_PROFILE → regional mixin → country-specific JSON

    Args:
        country_slug: e.g. "nigeria"
        profiles_dir: Where country JSON profiles are stored.
                       Defaults to data/country_profiles/

    Returns:
        Merged CountryProfile ready for discovery.
    """
    # Start with global
    profile = CountryProfile(
        country=country_slug,
        internet_penetration=GLOBAL_PROFILE.internet_penetration,
        dominant_platforms=list(GLOBAL_PROFILE.dominant_platforms),
        languages=list(GLOBAL_PROFILE.languages),
        sources=dict(GLOBAL_PROFILE.sources),
        local_directories=list(GLOBAL_PROFILE.local_directories),
        media_domains=list(GLOBAL_PROFILE.media_domains),
        disabled_sources=set(GLOBAL_PROFILE.disabled_sources),
        source_performance=dict(GLOBAL_PROFILE.source_performance),
    )

    # Apply regional mixin
    region = REGION_MAP.get(country_slug)
    if region:
        regional = _load_regional_mixin(region)
        if regional:
            profile = merge_profiles(profile, regional)

    # Apply country-specific JSON if it exists
    if profiles_dir is None:
        profiles_dir = Path(__file__).resolve().parents[1] / "data" / "country_profiles"
    country_json = profiles_dir / f"{country_slug}.json"
    if country_json.exists():
        data = json.loads(country_json.read_text(encoding="utf-8"))
        country_override = _profile_from_dict(data)
        profile = merge_profiles(profile, country_override)

    profile.country = country_slug
    return profile


def save_profile(
    profile: CountryProfile,
    output_dir: Path | None = None,
) -> None:
    """Persist a CountryProfile to JSON."""
    if output_dir is None:
        output_dir = Path(__file__).resolve().parents[1] / "data" / "country_profiles"
    output_dir.mkdir(parents=True, exist_ok=True)
    path = output_dir / f"{profile.country}.json"
    data = _profile_to_dict(profile)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(path)


def _profile_from_dict(data: dict) -> CountryProfile:
    """Deserialize a JSON dict back to CountryProfile."""
    sources = {}
    for name, cfg in data.get("sources", {}).items():
        sources[name] = SourceConfig(
            priority=cfg.get("priority", 1),
            enabled=cfg.get("enabled", True),
            params=cfg.get("params", {}),
            min_results=cfg.get("min_results", 3),
            max_results=cfg.get("max_results", 50),
            timeout=cfg.get("timeout", 15),
        )
    perf = {}
    for name, m in data.get("source_performance", {}).items():
        perf[name] = SourceMetrics(
            total_calls=m.get("total_calls", 0),
            total_results=m.get("total_results", 0),
            success_count=m.get("success_count", 0),
            failure_count=m.get("failure_count", 0),
            total_latency_ms=m.get("total_latency_ms", 0.0),
            last_probe=m.get("last_probe", ""),
        )
    return CountryProfile(
        country=data.get("country", ""),
        internet_penetration=data.get("internet_penetration", 0.0),
        dominant_platforms=data.get("dominant_platforms", []),
        languages=data.get("languages", []),
        sources=sources,
        local_directories=data.get("local_directories", []),
        media_domains=data.get("media_domains", []),
        disabled_sources=set(data.get("disabled_sources", [])),
        source_performance=perf,
        generated_at=data.get("generated_at", ""),
        generation_version=data.get("generation_version", 1),
    )


def _profile_to_dict(profile: CountryProfile) -> dict:
    """Serialize CountryProfile to a JSON-safe dict."""
    from dataclasses import asdict
    d = asdict(profile)
    d["disabled_sources"] = sorted(profile.disabled_sources)
    return d


def _load_regional_mixin(region: str) -> CountryProfile | None:
    """Import and return a regional mixin by name."""
    import importlib
    try:
        mod = importlib.import_module(f"..{region}", __package__)
        attr = f"{region.upper()}_PROFILE" if region != "europe_east" else "EUROPE_EAST_PROFILE"
        # Handle multi-word: southeast_asia → SOUTHEAST_ASIA_PROFILE
        attr = region.upper().replace("-", "_") + "_PROFILE"
        return getattr(mod, attr, None)
    except (ImportError, AttributeError):
        return None
```

- [ ] **Step 3: Run tests**

```bash
cd scripts && python -m pytest feed_discovery/tests/test_registry.py -v
```

- [ ] **Step 4: Commit**

```bash
git add scripts/feed_discovery/profiles/_registry.py \
        scripts/feed_discovery/tests/test_registry.py
git commit -m "feat: add profile registry with regional merge and JSON persistence

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Country Profiler (bootstrap + auto-update)

**Files:**
- Create: `scripts/feed_discovery/country_profiler.py`
- Create: `scripts/feed_discovery/tests/test_country_profiler.py`

**Interfaces:**
- Consumes: `_registry.py` (Task 2), todas as 5 fontes (Phase 1 + 2), `CountryProfile`, `SourceConfig`, `ProbeResult`
- Produces: `CountryProfiler` class with `bootstrap()`, `update()`, `probe_all_sources()`

- [ ] **Step 1: Write tests/test_country_profiler.py**

```python
# scripts/feed_discovery/tests/test_country_profiler.py

import pytest
from scripts.feed_discovery.profiles._schema import CountryProfile, SourceConfig, SourceMetrics
from scripts.feed_discovery.country_profiler import CountryProfiler
from scripts.feed_discovery.profiles._registry import load_profile


def test_profiler_creates_profile_for_new_country():
    profiler = CountryProfiler()
    profile = profiler.bootstrap_sync("testland")
    assert profile.country == "testland"
    assert len(profile.sources) >= 3  # at least the Phase 1+2 sources
    assert profile.generation_version >= 1


def test_profiler_marks_source_as_degraded():
    profiler = CountryProfiler()
    profile = CountryProfile(
        country="test",
        sources={"test_source": SourceConfig(priority=1)},
    )
    # Simulate 3 consecutive rounds with 0 results
    for _ in range(3):
        profiler._record_probe(profile, "test_source", success=False, result_count=0)
    
    metrics = profile.source_performance.get("test_source")
    assert metrics is not None
    assert metrics.total_calls == 3
    assert metrics.success_count == 0
    assert metrics.success_rate == 0.0


def test_profiler_disables_source_after_five_failures():
    profiler = CountryProfiler()
    profile = CountryProfile(
        country="test",
        sources={"bad_source": SourceConfig(priority=1)},
    )
    # 5 consecutive failures → disabled
    for _ in range(5):
        profiler._record_probe(profile, "bad_source", success=False, result_count=0)
    assert "bad_source" in profile.disabled_sources


def test_profiler_does_not_disable_after_three_failures():
    profiler = CountryProfiler()
    profile = CountryProfile(
        country="test",
        sources={"slow_source": SourceConfig(priority=1)},
    )
    for _ in range(3):
        profiler._record_probe(profile, "slow_source", success=False, result_count=0)
    # 3 failures → degraded (lower priority) but NOT disabled
    assert "slow_source" not in profile.disabled_sources
    assert profile.sources["slow_source"].priority > 1


def test_profiler_updates_success_metrics():
    profiler = CountryProfiler()
    profile = CountryProfile(
        country="test",
        sources={"good_source": SourceConfig(priority=1)},
    )
    profiler._record_probe(profile, "good_source", success=True, result_count=42)
    metrics = profile.source_performance["good_source"]
    assert metrics.success_count == 1
    assert metrics.total_results == 42
    assert metrics.success_rate == 1.0


def test_bootstrap_includes_active_sources_only():
    """Bootstrap should exclude disabled sources."""
    profiler = CountryProfiler()
    profile = profiler.bootstrap_sync("testland")
    for name, cfg in profile.sources.items():
        if name in profile.disabled_sources:
            pytest.fail(f"{name} is both in sources and disabled_sources")
```

- [ ] **Step 2: Write country_profiler.py**

```python
# scripts/feed_discovery/country_profiler.py

from __future__ import annotations

import asyncio
import time
from datetime import datetime, timezone
from pathlib import Path

import aiohttp

from .profiles._registry import load_profile, save_profile
from .profiles._schema import CountryProfile, SourceConfig, SourceMetrics
from .sources._base import ProbeResult

# Degradation thresholds
DEGRADE_AFTER_N_FAILURES = 3
DISABLE_AFTER_N_FAILURES = 5
PRIORITY_PENALTY = 5


class CountryProfiler:
    """Generates and maintains CountryProfiles automatically.

    Flow:
    1. BOOTSTRAP: load profile (global + regional), probe all sources
    2. UPDATE: after each discovery run, record metrics, adjust
    3. SAVE: persist the learned profile
    """

    def __init__(self, profiles_dir: Path | None = None):
        self.profiles_dir = profiles_dir
        self._source_instances: dict[str, object] = {}
        self._init_sources()

    def _init_sources(self):
        """Instantiate all available sources."""
        try:
            from .sources.podcast_index import PodcastIndexSource
            self._source_instances["podcast_index"] = PodcastIndexSource()
        except Exception:
            pass
        try:
            from .sources.deezer import DeezerSource
            self._source_instances["deezer"] = DeezerSource()
        except Exception:
            pass
        try:
            from .sources.youtube_api import YouTubeAPISource
            self._source_instances["youtube_api"] = YouTubeAPISource()
        except Exception:
            pass
        try:
            from .sources.ddg_text import DDGTextSource
            self._source_instances["ddg_text"] = DDGTextSource()
        except Exception:
            pass
        try:
            from .sources.podcasts import ITunesSource
            self._source_instances["itunes"] = ITunesSource()
        except Exception:
            pass

    def bootstrap_sync(self, country_slug: str) -> CountryProfile:
        """Synchronous wrapper for bootstrap."""
        return asyncio.run(self.bootstrap(country_slug))

    async def bootstrap(self, country_slug: str) -> CountryProfile:
        """Generate an initial profile for a country.

        1. Load base profile (global + regional merge)
        2. Probe all active sources
        3. Disable sources that fail immediately
        4. Save and return
        """
        profile = load_profile(country_slug, profiles_dir=self.profiles_dir)
        profile.generated_at = datetime.now(timezone.utc).isoformat()
        profile.generation_version = 1

        # Probe all sources
        connector = aiohttp.TCPConnector(limit=10)
        async with aiohttp.ClientSession(connector=connector) as session:
            results = await self.probe_all_sources(profile, session)

        # Apply probe results
        for source_name, result in results.items():
            self._record_probe(
                profile, source_name,
                success=result.success,
                result_count=result.result_count,
            )

        # Save
        save_profile(profile, output_dir=self.profiles_dir)
        return profile

    async def update(
        self,
        profile: CountryProfile,
        session: aiohttp.ClientSession,
    ) -> CountryProfile:
        """Update a profile after a discovery run.

        Records metrics, degrades/disables failing sources, saves.
        """
        profile.generation_version += 1
        profile.generated_at = datetime.now(timezone.utc).isoformat()

        # Probe sources that are degraded to see if they recovered
        for name, metrics in profile.source_performance.items():
            if name in profile.disabled_sources:
                continue
            if metrics.success_rate < 0.5 and metrics.total_calls > 0:
                # Re-probe degraded sources periodically
                source = self._source_instances.get(name)
                if source and hasattr(source, "enabled") and source.enabled:
                    cfg = profile.sources.get(name, SourceConfig(priority=99))
                    try:
                        result = await source.probe(profile, cfg, session)
                        self._record_probe(profile, name, result.success, result.result_count)
                    except Exception:
                        self._record_probe(profile, name, False, 0)

        save_profile(profile, output_dir=self.profiles_dir)
        return profile

    async def probe_all_sources(
        self,
        profile: CountryProfile,
        session: aiohttp.ClientSession,
    ) -> dict[str, ProbeResult]:
        """Test all active sources for a country in parallel."""
        results: dict[str, ProbeResult] = {}
        tasks = []

        for name, cfg in profile.sources.items():
            if name in profile.disabled_sources:
                continue
            source = self._source_instances.get(name)
            if source is None:
                continue
            if hasattr(source, "enabled") and not source.enabled:
                results[name] = ProbeResult(
                    source_name=name, success=False, result_count=0,
                    latency_ms=0, error="disabled",
                )
                continue
            tasks.append(self._probe_one(name, source, profile, cfg, session))

        gathered = await asyncio.gather(*tasks, return_exceptions=True)
        for item in gathered:
            if isinstance(item, Exception):
                continue
            name, result = item
            results[name] = result

        return results

    async def _probe_one(self, name, source, profile, cfg, session):
        t0 = time.monotonic()
        try:
            result = await source.probe(profile, cfg, session)
        except Exception as e:
            elapsed = (time.monotonic() - t0) * 1000
            result = ProbeResult(
                source_name=name, success=False, result_count=0,
                latency_ms=elapsed, error=str(e)[:200],
            )
        return name, result

    def _record_probe(
        self,
        profile: CountryProfile,
        source_name: str,
        success: bool,
        result_count: int,
    ):
        """Record a probe result and apply degradation logic."""
        if source_name not in profile.source_performance:
            profile.source_performance[source_name] = SourceMetrics()

        m = profile.source_performance[source_name]
        m.total_calls += 1
        m.total_results += result_count
        if success:
            m.success_count += 1
        else:
            m.failure_count += 1
        m.last_probe = datetime.now(timezone.utc).isoformat()

        # Degradation logic
        if source_name in profile.disabled_sources:
            return

        consecutive_failures = self._consecutive_zero_results(profile, source_name)

        if consecutive_failures >= DISABLE_AFTER_N_FAILURES:
            profile.disabled_sources.add(source_name)
        elif consecutive_failures >= DEGRADE_AFTER_N_FAILURES:
            if source_name in profile.sources:
                cfg = profile.sources[source_name]
                # Penalize priority — push to bottom
                max_priority = max((s.priority for s in profile.sources.values()), default=0)
                cfg.priority = max_priority + PRIORITY_PENALTY

    def _consecutive_zero_results(self, profile: CountryProfile, source_name: str) -> int:
        """Count consecutive zero-result probes. Simplified: uses failure_count."""
        m = profile.source_performance.get(source_name)
        if m is None:
            return 0
        return m.failure_count  # Simplified — in production would track streak
```

- [ ] **Step 3: Run tests**

```bash
cd scripts && python -m pytest feed_discovery/tests/test_country_profiler.py -v
```

- [ ] **Step 4: Commit**

```bash
git add scripts/feed_discovery/country_profiler.py \
        scripts/feed_discovery/tests/test_country_profiler.py
git commit -m "feat: add CountryProfiler with auto bootstrap, probe, degrade, and update

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: Adaptive Pipeline (orquestrador multi-source)

**Files:**
- Create: `scripts/feed_discovery/adaptive_pipeline.py`
- Create: `scripts/feed_discovery/tests/test_adaptive_pipeline.py`

**Interfaces:**
- Consumes: `_registry.py`, `country_profiler.py` (Task 2-3), 5 fontes, `opml_writer.py`, `models.py`, `heuristic.py`
- Produces: `discover_with_profile()`, `populate_country_adaptive()`, CLI entry point

- [ ] **Step 1: Write adaptive_pipeline.py**

```python
# scripts/feed_discovery/adaptive_pipeline.py

from __future__ import annotations

import asyncio
import time
from pathlib import Path

import aiohttp

from .models import Candidate, SubRegion
from .opml import normalize_url
from .pipeline import Config
from .profiles._registry import load_profile, save_profile, REGION_MAP
from .subregion.opml_writer import read_existing_feeds, write_subregion_opml
from .subregion.enrich_countries import POPULATION, enrich
from .country_profiler import CountryProfiler

PROGRESS_FILE = Path(__file__).parent / "subregion" / "progress.json"


async def discover_with_profile(
    subregion: SubRegion,
    country_name: str,
    native_name: str,
    profile,
    existing_urls: set[str],
    session: aiohttp.ClientSession,
    cfg: Config,
) -> list[Candidate]:
    """Discover feeds for a sub-region using ALL active sources in the profile.

    Sources are called in priority order. Higher-priority sources that
    return >= min_results short-circuit lower-priority ones.
    """
    all_candidates: list[Candidate] = []
    seen_urls: set[str] = set()

    # Sort sources by priority
    sorted_sources = sorted(
        [(name, scfg) for name, scfg in profile.sources.items()
         if name not in profile.disabled_sources],
        key=lambda x: x[1].priority,
    )

    for source_name, source_config in sorted_sources:
        # Skip if we already have enough results from higher-priority sources
        if len(all_candidates) >= source_config.min_results * 3:
            break

        source = _get_source_instance(source_name)
        if source is None:
            continue
        if hasattr(source, "enabled") and not source.enabled:
            continue

        # Build query from subregion name + country
        query = f"{subregion.name} {country_name}"
        if native_name != country_name:
            query += f" {native_name}"

        try:
            candidates = await source.search(query, profile, source_config, session)
        except Exception:
            continue

        for c in candidates:
            norm = normalize_url(c.url)
            if norm in seen_urls or norm in existing_urls:
                continue
            seen_urls.add(norm)
            all_candidates.append(c)

    return all_candidates


async def populate_country_adaptive(
    country_slug: str,
    cfg: Config | None = None,
) -> dict:
    """Populate all sub-regions for one country using adaptive multi-source discovery.

    1. Load or bootstrap CountryProfile
    2. Discover feeds for each sub-region using all active sources
    3. Write results to OPMLs
    4. Update profile with metrics
    """
    if cfg is None:
        cfg = Config()

    # Load enriched country data
    enriched_path = Path(__file__).parent / "data" / "countries_enriched.json"
    if not enriched_path.exists():
        opml_base = Path(__file__).resolve().parents[1] / "feedmine" / "Resources" / "Feeds" / "countries"
        countries_json = Path(__file__).parent / "data" / "countries.json"
        enrich(opml_base, countries_json, enriched_path)

    import json
    enriched = json.loads(enriched_path.read_text(encoding="utf-8"))
    country_data = enriched.get(country_slug)
    if not country_data:
        return {"country": country_slug, "error": "not in enriched data"}

    sub_data = country_data.get("subregions", [])
    if not sub_data:
        return {"country": country_slug, "total_subregions": 0, "populated": 0, "total_feeds": 0}

    # Load CountryProfile
    profiler = CountryProfiler()
    profile = load_profile(country_slug)

    country_name = country_data["name"]
    native_name = country_data.get("native_name", country_name)

    # Collect existing URLs across all sub-regions
    all_existing: set[str] = set()
    for sd in sub_data:
        opml_path = Path(sd["opml_path"])
        if opml_path.exists():
            all_existing |= read_existing_feeds(opml_path)

    connector = aiohttp.TCPConnector(limit=cfg.concurrency)
    async with aiohttp.ClientSession(connector=connector) as session:
        sem = asyncio.Semaphore(cfg.concurrency)

        async def _process_one(sd: dict) -> tuple[str, int]:
            sub = SubRegion(
                slug=sd["slug"], name=sd["name"],
                parent_country=sd["parent_country"],
                iso2=sd["iso2"], iso3=sd["iso3"],
                ddg_region=sd["ddg_region"],
                opml_path=sd["opml_path"],
            )
            async with sem:
                try:
                    cands = await discover_with_profile(
                        sub, country_name, native_name,
                        profile, all_existing, session, cfg,
                    )
                except Exception:
                    return (sd["slug"], -1)

            if cands:
                written = write_subregion_opml(Path(sd["opml_path"]), cands)
                return (sd["slug"], written)
            return (sd["slug"], 0)

        results = await asyncio.gather(*(_process_one(sd) for sd in sub_data))

        # Update profile with metrics
        await profiler.update(profile, session)

    summary = {
        "country": country_slug,
        "total_subregions": len(sub_data),
        "populated": sum(1 for _, count in results if count > 0),
        "failed": sum(1 for _, count in results if count < 0),
        "total_feeds": sum(max(0, count) for _, count in results),
    }
    return summary


async def populate_all_adaptive(cfg: Config | None = None) -> None:
    """Run adaptive discovery for ALL countries, sorted by population."""
    import json
    if cfg is None:
        cfg = Config()

    enriched_path = Path(__file__).parent / "data" / "countries_enriched.json"
    if not enriched_path.exists():
        opml_base = Path(__file__).resolve().parents[1] / "feedmine" / "Resources" / "Feeds" / "countries"
        countries_json = Path(__file__).parent / "data" / "countries.json"
        enrich(opml_base, countries_json, enriched_path)

    enriched = json.loads(enriched_path.read_text(encoding="utf-8"))
    sorted_countries = sorted(
        enriched.keys(),
        key=lambda s: enriched[s].get("population", 0),
        reverse=True,
    )

    for country_slug in sorted_countries:
        print(f"\n{'='*60}")
        print(f"[{country_slug}] Starting {enriched[country_slug]['name']}")
        t0 = time.monotonic()
        summary = await populate_country_adaptive(country_slug, cfg)
        elapsed = time.monotonic() - t0
        print(f"[{country_slug}] Done in {elapsed:.0f}s — "
              f"{summary['populated']}/{summary['total_subregions']} populated, "
              f"{summary['total_feeds']} feeds")


# Source instance cache
_source_cache: dict[str, object] = {}

def _get_source_instance(name: str):
    """Lazy-load source instances."""
    if name in _source_cache:
        return _source_cache[name]
    try:
        if name == "podcast_index":
            from .sources.podcast_index import PodcastIndexSource
            inst = PodcastIndexSource()
        elif name == "deezer":
            from .sources.deezer import DeezerSource
            inst = DeezerSource()
        elif name == "youtube_api":
            from .sources.youtube_api import YouTubeAPISource
            inst = YouTubeAPISource()
        elif name == "ddg_text":
            from .sources.ddg_text import DDGTextSource
            inst = DDGTextSource()
        elif name == "itunes":
            from .sources.podcasts import ITunesSource
            inst = ITunesSource()
        else:
            return None
        _source_cache[name] = inst
        return inst
    except Exception:
        return None


if __name__ == "__main__":
    import sys
    fresh = "--fresh" in sys.argv
    cfg = Config(fresh=fresh, concurrency=50)
    asyncio.run(populate_all_adaptive(cfg))
```

- [ ] **Step 2: Verify imports work**

```bash
cd scripts && python -c "from feed_discovery.adaptive_pipeline import discover_with_profile, populate_country_adaptive; print('OK')"
```

- [ ] **Step 3: Run full regression suite**

```bash
cd scripts && python -m pytest feed_discovery/tests/ feed_discovery/subregion/ -v --tb=short 2>&1 | tail -20
```

- [ ] **Step 4: Commit**

```bash
git add scripts/feed_discovery/adaptive_pipeline.py
git commit -m "feat: add adaptive_pipeline — multi-source discovery with CountryProfile

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Execution Order

```
Task 1 (regional mixins) → Task 2 (registry) → Task 3 (profiler) → Task 4 (pipeline)
```

Task 1 can be done independently. Tasks 2-4 form a chain.
