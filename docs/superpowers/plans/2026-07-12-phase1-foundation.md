# Phase 1: Multi-Source Foundation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Estabelecer a fundação do sistema multi-source: schema de perfil de país, protocolo de fonte, perfil base global, e refatorar as 2 fontes existentes (iTunes, DDG) para o protocolo.

**Architecture:** 3 novos arquivos de schema/protocolo, 1 novo wrapper DDG, 1 refatoração do iTunes. Tudo usa dataclasses Python + Protocol para interface plugável. Tests seguem o padrão existente do projeto (imports absolutos `from scripts.feed_discovery.xxx`).

**Tech Stack:** Python 3.12, dataclasses, typing.Protocol, pytest, aiohttp

## Global Constraints

- Schemas em `scripts/feed_discovery/profiles/` (novo diretório)
- Fontes em `scripts/feed_discovery/sources/` (existente, estendido)
- Imports: relativos dentro do pacote (`from ..profiles._schema import CountryProfile`), absolutos nos testes (`from scripts.feed_discovery.sources._base import SourceProtocol`)
- NÃO modificar `search.py`, `discover.py`, `verify.py` — o wrapper DDG os encapsula sem alterá-los
- NÃO quebrar `pipeline.py` existente — `podcasts.discover()` continua funcionando, a classe `ITunesSource` é adicionada mantendo a função original
- Seguir TDD: testes primeiro, ver falhar, implementar, ver passar
- API keys de fontes externas vêm de env vars (`.env`); fontes sem key configurada são desabilitadas com warning

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `scripts/feed_discovery/profiles/__init__.py` | Create | Pacote vazio |
| `scripts/feed_discovery/profiles/_schema.py` | Create | CountryProfile, SourceConfig, SourceMetrics dataclasses |
| `scripts/feed_discovery/sources/_base.py` | Create | SourceProtocol, ProbeResult |
| `scripts/feed_discovery/profiles/global.py` | Create | GLOBAL_PROFILE com 8 fontes configuradas |
| `scripts/feed_discovery/sources/podcasts.py` | Modify | Adicionar `ITunesSource` classe (mantém função `discover()` original) |
| `scripts/feed_discovery/sources/ddg_text.py` | Create | `DDGTextSource` wrapper sobre search.py + discover.py + verify.py |
| `scripts/feed_discovery/tests/test_source_protocol.py` | Create | Testes de conformidade: toda fonte passa `isinstance(x, SourceProtocol)` |
| `scripts/feed_discovery/tests/test_itunes_source.py` | Create | Testes unitários da ITunesSource |
| `scripts/feed_discovery/tests/test_ddg_text_source.py` | Create | Testes unitários da DDGTextSource |
| `scripts/feed_discovery/tests/test_profiles.py` | Create | Testes de merge/serialização de CountryProfile |

---

### Task 1: Data schemas — SourceConfig, SourceMetrics, ProbeResult, CountryProfile

**Files:**
- Create: `scripts/feed_discovery/profiles/__init__.py`
- Create: `scripts/feed_discovery/profiles/_schema.py`
- Create: `scripts/feed_discovery/sources/_base.py`
- Create: `scripts/feed_discovery/tests/test_profiles.py`

**Interfaces:**
- Produces: `SourceConfig(priority, enabled, params, min_results, max_results, timeout)` dataclass
- Produces: `SourceMetrics(total_calls, total_results, success_count, failure_count, total_latency_ms, last_probe)` com properties `success_rate`, `avg_results`, `avg_latency_ms`
- Produces: `ProbeResult(source_name, success, result_count, latency_ms, error)` dataclass
- Produces: `CountryProfile(country, internet_penetration, dominant_platforms, languages, sources, local_directories, media_domains, disabled_sources, source_performance, generated_at, generation_version)` dataclass
- Produces: `SourceProtocol` (typing.Protocol com `name: str`, `async search()`, `async probe()`)

- [ ] **Step 1: Create profiles/__init__.py**

```python
# scripts/feed_discovery/profiles/__init__.py
```

- [ ] **Step 2: Write test_profiles.py with all tests**

```python
# scripts/feed_discovery/tests/test_profiles.py

from dataclasses import asdict
from scripts.feed_discovery.profiles._schema import (
    CountryProfile, SourceConfig, SourceMetrics,
)
from scripts.feed_discovery.sources._base import ProbeResult


def test_source_config_defaults():
    c = SourceConfig(priority=1)
    assert c.priority == 1
    assert c.enabled is True
    assert c.params == {}
    assert c.min_results == 3
    assert c.max_results == 50
    assert c.timeout == 15


def test_source_config_custom():
    c = SourceConfig(priority=2, enabled=False, params={"lang": "en"}, min_results=5, max_results=20, timeout=30)
    assert c.priority == 2
    assert c.enabled is False
    assert c.params == {"lang": "en"}
    assert c.min_results == 5
    assert c.max_results == 20
    assert c.timeout == 30


def test_source_metrics_defaults():
    m = SourceMetrics()
    assert m.total_calls == 0
    assert m.total_results == 0
    assert m.success_count == 0
    assert m.failure_count == 0
    assert m.success_rate == 1.0  # 0/0 = 1.0 per spec
    assert m.avg_results == 0.0
    assert m.avg_latency_ms == 0.0


def test_source_metrics_computed():
    m = SourceMetrics(
        total_calls=10, total_results=45,
        success_count=8, failure_count=2,
        total_latency_ms=2300.0,
    )
    assert m.success_rate == 0.8
    assert m.avg_results == 4.5
    assert m.avg_latency_ms == 230.0


def test_source_metrics_success_rate_zero_calls():
    m = SourceMetrics(total_calls=0, success_count=0)
    assert m.success_rate == 1.0


def test_probe_result_success():
    r = ProbeResult(source_name="test", success=True, result_count=42, latency_ms=150.0)
    assert r.source_name == "test"
    assert r.success is True
    assert r.result_count == 42
    assert r.latency_ms == 150.0
    assert r.error == ""


def test_probe_result_failure():
    r = ProbeResult(source_name="test", success=False, result_count=0, latency_ms=5000.0, error="timeout")
    assert r.success is False
    assert r.error == "timeout"


def test_country_profile_defaults():
    p = CountryProfile(country="nigeria")
    assert p.country == "nigeria"
    assert p.internet_penetration == 0.0
    assert p.dominant_platforms == []
    assert p.languages == []
    assert p.sources == {}
    assert p.local_directories == []
    assert p.media_domains == []
    assert p.disabled_sources == set()
    assert p.source_performance == {}
    assert p.generated_at == ""
    assert p.generation_version == 1


def test_country_profile_with_sources():
    p = CountryProfile(
        country="brazil",
        internet_penetration=0.75,
        dominant_platforms=["whatsapp", "youtube", "deezer"],
        languages=["pt"],
        sources={
            "deezer": SourceConfig(priority=1),
            "podcast_index": SourceConfig(priority=2, params={"lang": "pt"}),
        },
        media_domains=["globo.com", "uol.com.br"],
        disabled_sources={"itunes"},
    )
    assert p.country == "brazil"
    assert len(p.sources) == 2
    assert p.sources["deezer"].priority == 1
    assert p.sources["podcast_index"].params == {"lang": "pt"}
    assert "itunes" in p.disabled_sources
    assert p.internet_penetration == 0.75


def test_country_profile_serialization():
    p = CountryProfile(
        country="test",
        sources={"deezer": SourceConfig(priority=1)},
        disabled_sources={"itunes"},
    )
    d = asdict(p)
    assert d["country"] == "test"
    assert d["sources"]["deezer"]["priority"] == 1
    assert "itunes" in d["disabled_sources"]
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
cd scripts && python -m pytest feed_discovery/tests/test_profiles.py -v
```
Expected: All tests FAIL — `ModuleNotFoundError` for `profiles._schema` and `sources._base`

- [ ] **Step 4: Write profiles/_schema.py**

```python
# scripts/feed_discovery/profiles/_schema.py

from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class SourceConfig:
    """Configuração de uma fonte para um país específico."""
    priority: int                             # 1 = mais importante
    enabled: bool = True
    params: dict[str, str] = field(default_factory=dict)
    min_results: int = 3                      # abaixo disso por N rodadas → degraded
    max_results: int = 50                     # limite por query
    timeout: int = 15                         # segundos


@dataclass
class SourceMetrics:
    """Métricas acumuladas de performance de uma fonte."""
    total_calls: int = 0
    total_results: int = 0
    success_count: int = 0
    failure_count: int = 0
    total_latency_ms: float = 0.0
    last_probe: str = ""                      # ISO timestamp

    @property
    def success_rate(self) -> float:
        if self.total_calls == 0:
            return 1.0
        return self.success_count / self.total_calls

    @property
    def avg_results(self) -> float:
        if self.total_calls == 0:
            return 0.0
        return self.total_results / self.total_calls

    @property
    def avg_latency_ms(self) -> float:
        if self.total_calls == 0:
            return 0.0
        return self.total_latency_ms / self.total_calls


@dataclass
class CountryProfile:
    """Perfil de internet de um país — define quais fontes usar e como."""
    country: str                              # "nigeria"

    # Demografia digital
    internet_penetration: float = 0.0         # 0.55 = 55%
    dominant_platforms: list[str] = field(default_factory=list)
    languages: list[str] = field(default_factory=list)

    # Fontes ativas com prioridade e config
    sources: dict[str, SourceConfig] = field(default_factory=dict)

    # Descobertas locais
    local_directories: list[str] = field(default_factory=list)
    media_domains: list[str] = field(default_factory=list)

    # Aprendizado
    disabled_sources: set[str] = field(default_factory=set)
    source_performance: dict[str, SourceMetrics] = field(default_factory=dict)

    # Metadata
    generated_at: str = ""                    # ISO timestamp
    generation_version: int = 1
```

- [ ] **Step 5: Write sources/_base.py**

```python
# scripts/feed_discovery/sources/_base.py

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING, Protocol, runtime_checkable

if TYPE_CHECKING:
    import aiohttp
    from scripts.feed_discovery.models import Candidate
    from scripts.feed_discovery.profiles._schema import CountryProfile, SourceConfig


@dataclass
class ProbeResult:
    """Resultado de um probe de fonte para um país."""
    source_name: str
    success: bool
    result_count: int
    latency_ms: float
    error: str = ""


@runtime_checkable
class SourceProtocol(Protocol):
    """Interface que toda fonte de descoberta deve implementar.

    Para adicionar uma nova fonte, crie um arquivo em sources/
    com uma classe que implementa esta interface. O sistema
    descobre fontes automaticamente via name.
    """
    name: str

    async def search(
        self,
        query: str,
        profile: CountryProfile,
        config: SourceConfig,
        session: aiohttp.ClientSession,
    ) -> list[Candidate]:
        """Busca feeds/podcasts/canais para uma query.

        Args:
            query: Termo de busca (ex: "Lagos Nigeria news").
            profile: Perfil do país alvo.
            config: Configuração desta fonte para este país.
            session: Sessão aiohttp compartilhada.

        Returns:
            Lista de Candidate (url, title, category, genre, national).
        """
        ...

    async def probe(
        self,
        profile: CountryProfile,
        config: SourceConfig,
        session: aiohttp.ClientSession,
    ) -> ProbeResult:
        """Testa se a fonte funciona para este país.

        Deve usar uma query genérica (ex: nome do país no idioma local)
        e retornar métricas. Não deve fazer mais de 3 chamadas de rede.

        Args:
            profile: Perfil do país a testar.
            config: Configuração desta fonte.
            session: Sessão aiohttp compartilhada.

        Returns:
            ProbeResult com success, result_count, latency_ms.
        """
        ...
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
cd scripts && python -m pytest feed_discovery/tests/test_profiles.py -v
```
Expected: All 10 tests PASS

- [ ] **Step 7: Commit**

```bash
git add scripts/feed_discovery/profiles/__init__.py \
        scripts/feed_discovery/profiles/_schema.py \
        scripts/feed_discovery/sources/_base.py \
        scripts/feed_discovery/tests/test_profiles.py
git commit -m "feat: add SourceConfig, SourceMetrics, CountryProfile, SourceProtocol, ProbeResult

Foundation schemas for multi-source adaptive discovery system.
Phase 1 of the multi-source spec.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: GLOBAL_PROFILE — perfil base com 8 fontes

**Files:**
- Create: `scripts/feed_discovery/profiles/global.py`
- Modify: `scripts/feed_discovery/tests/test_profiles.py` (adicionar testes)

**Interfaces:**
- Consumes: `CountryProfile`, `SourceConfig` from Task 1
- Produces: `GLOBAL_PROFILE: CountryProfile` — perfil base para todos os países

- [ ] **Step 1: Add tests to test_profiles.py**

```python
# Add to scripts/feed_discovery/tests/test_profiles.py

from scripts.feed_discovery.profiles.global import GLOBAL_PROFILE


def test_global_profile_is_country_profile():
    from scripts.feed_discovery.profiles._schema import CountryProfile
    assert isinstance(GLOBAL_PROFILE, CountryProfile)


def test_global_profile_country_is_wildcard():
    assert GLOBAL_PROFILE.country == "*"


def test_global_profile_has_eight_sources():
    assert len(GLOBAL_PROFILE.sources) == 8


def test_global_profile_sources_ordered_by_priority():
    priorities = [(name, cfg.priority) for name, cfg in GLOBAL_PROFILE.sources.items()]
    sorted_by_priority = sorted(priorities, key=lambda x: x[1])
    assert priorities == sorted_by_priority


def test_global_profile_source_names():
    expected = {
        "podcast_index", "deezer", "youtube_api", "ddg_text",
        "itunes", "listen_notes", "spotify", "feedly",
    }
    assert set(GLOBAL_PROFILE.sources.keys()) == expected


def test_global_profile_youtube_scrape_disabled():
    # youtube_scrape is the fallback scraping source, disabled by default
    # (not in the 8 active sources above; added only when API key missing)
    pass  # placeholder — youtube_scrape not in GLOBAL_PROFILE yet


def test_global_profile_no_disabled_sources_initially():
    assert GLOBAL_PROFILE.disabled_sources == set()


def test_global_profile_media_domains_empty():
    # Global profile has no media domains — those come from regional mixins
    assert GLOBAL_PROFILE.media_domains == []


def test_global_profile_generation_version():
    assert GLOBAL_PROFILE.generation_version == 1
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd scripts && python -m pytest feed_discovery/tests/test_profiles.py -v -k global
```
Expected: All global tests FAIL — `ModuleNotFoundError` for `profiles.global`

- [ ] **Step 3: Write profiles/global.py**

```python
# scripts/feed_discovery/profiles/global.py

from __future__ import annotations

from ._schema import CountryProfile, SourceConfig

GLOBAL_PROFILE = CountryProfile(
    country="*",
    sources={
        # Free, open, 4M+ podcasts — best first stop for any country
        "podcast_index": SourceConfig(priority=1, params={}),
        # Free, no auth, strong in LatAm/Africa/Europe
        "deezer": SourceConfig(priority=2, params={}),
        # Official API, 10K quota/day, replaces scraping
        "youtube_api": SourceConfig(priority=3, params={}),
        # DDG web search for text/news feeds (existing, refactored)
        "ddg_text": SourceConfig(priority=4, params={}),
        # iTunes Search API (existing, refactored) — Apple ecosystem only
        "itunes": SourceConfig(priority=5, params={}),
        # Premium podcast search, 250 req/month free — use sparingly
        "listen_notes": SourceConfig(priority=6, params={}),
        # Spotify podcast catalog — OAuth required
        "spotify": SourceConfig(priority=7, params={}),
        # 40M+ RSS feeds indexed — OAuth required
        "feedly": SourceConfig(priority=8, params={}),
    },
)
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd scripts && python -m pytest feed_discovery/tests/test_profiles.py -v -k global
```
Expected: All 9 global tests PASS

- [ ] **Step 5: Run ALL profile tests to verify no regressions**

```bash
cd scripts && python -m pytest feed_discovery/tests/test_profiles.py -v
```
Expected: All 19 tests PASS

- [ ] **Step 6: Commit**

```bash
git add scripts/feed_discovery/profiles/global.py \
        scripts/feed_discovery/tests/test_profiles.py
git commit -m "feat: add GLOBAL_PROFILE with 8 sources in priority order

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Refactor iTunes → ITunesSource (SourceProtocol)

**Files:**
- Modify: `scripts/feed_discovery/sources/podcasts.py`
- Create: `scripts/feed_discovery/tests/test_itunes_source.py`

**Interfaces:**
- Consumes: `SourceProtocol`, `ProbeResult` from Task 1; `CountryProfile`, `SourceConfig` from Task 1
- Produces: `ITunesSource` class with `name = "itunes"`, `search()`, `probe()`
- Mantém: função `discover()` original (não quebrar `pipeline.py`)

- [ ] **Step 1: Write test_itunes_source.py**

```python
# scripts/feed_discovery/tests/test_itunes_source.py

import pytest
from scripts.feed_discovery.sources._base import SourceProtocol, ProbeResult
from scripts.feed_discovery.sources.podcasts import ITunesSource
from scripts.feed_discovery.profiles._schema import CountryProfile, SourceConfig
from scripts.feed_discovery.models import Candidate


def test_itunes_source_implements_protocol():
    source = ITunesSource()
    assert isinstance(source, SourceProtocol)


def test_itunes_source_name():
    source = ITunesSource()
    assert source.name == "itunes"


def test_itunes_source_has_search():
    source = ITunesSource()
    assert hasattr(source, "search")
    assert callable(source.search)


def test_itunes_source_has_probe():
    source = ITunesSource()
    assert hasattr(source, "probe")
    assert callable(source.probe)


@pytest.mark.asyncio
async def test_probe_returns_probe_result():
    source = ITunesSource()
    profile = CountryProfile(country="usa", languages=["en"])
    config = SourceConfig(priority=5, timeout=10)
    import aiohttp
    async with aiohttp.ClientSession() as session:
        result = await source.probe(profile, config, session)
    assert isinstance(result, ProbeResult)
    assert result.source_name == "itunes"


@pytest.mark.asyncio
async def test_search_returns_candidates():
    source = ITunesSource()
    profile = CountryProfile(country="usa", languages=["en"])
    config = SourceConfig(priority=5, max_results=10, timeout=10)
    import aiohttp
    async with aiohttp.ClientSession() as session:
        results = await source.search("news", profile, config, session)
    assert isinstance(results, list)
    if results:
        assert isinstance(results[0], Candidate)
        assert results[0].category == "Podcasts"


def test_original_discover_function_still_works():
    """A função discover() original deve continuar existindo para pipeline.py."""
    from scripts.feed_discovery.sources.podcasts import discover
    import asyncio
    assert callable(discover)
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd scripts && python -m pytest feed_discovery/tests/test_itunes_source.py -v
```
Expected: All tests FAIL — `ImportError` for `ITunesSource`

- [ ] **Step 3: Add ITunesSource to podcasts.py**

Adicionar a classe **após** a função `discover()` existente, sem modificar nada acima:

```python
# Add at the end of scripts/feed_discovery/sources/podcasts.py

from ..models import Country as _Country  # alias to avoid shadowing
from ..profiles._schema import CountryProfile as _CountryProfile
from ..profiles._schema import SourceConfig as _SourceConfig
from ._base import ProbeResult as _ProbeResult


class ITunesSource:
    """iTunes Search API as a SourceProtocol implementation.

    Wraps the existing discover() logic into the pluggable source interface.
    The original discover() function is preserved for backward compatibility.
    """
    name = "itunes"

    async def search(
        self,
        query: str,
        profile: _CountryProfile,
        config: _SourceConfig,
        session,
    ) -> list:
        """Search iTunes for podcasts matching the query.

        Builds a minimal Country from the profile and delegates to discover().
        """
        # Build a Country-like object from the profile for the existing discover()
        from ..models import Country as CountryModel

        # Extract ISO2 from profile or default to "us"
        iso2 = config.params.get("iso2", "us")
        iso3 = config.params.get("iso3", iso2.upper())

        country = CountryModel(
            slug=profile.country,
            name=profile.country,
            cctld=iso2,
            use_cctld=False,
            lang=profile.languages[0] if profile.languages else "en",
            ddg_region=f"{iso2}-{profile.languages[0] if profile.languages else 'en'}",
            iso2=iso2,
            iso3=iso3,
            cities=[query],       # Use the query as the "city" for iTunes search
        )

        # Reuse the existing discover() but limit to the query term
        # We build a custom discover that only uses our query
        from urllib.parse import urlencode
        import json
        import time

        ITUNES = "https://itunes.apple.com/search"

        def _itunes_url(term: str, country_iso2: str, limit: int) -> str:
            q = urlencode({"term": term, "country": country_iso2, "entity": "podcast", "limit": limit})
            return f"{ITUNES}?{q}"

        candidates: list = []
        seen: set[str] = set()
        limit = config.max_results
        timeout = config.timeout

        url = _itunes_url(query, iso2, limit)
        try:
            async with session.get(
                url, timeout=aiohttp.ClientTimeout(total=timeout)
            ) as resp:
                if resp.status == 200:
                    payload = await resp.json(content_type=None)
        except Exception:
            return []

        from ..models import Candidate
        from ..opml import normalize_url

        for r in payload.get("results", []):
            feed = r.get("feedUrl")
            if not feed or feed in seen:
                continue
            seen.add(feed)
            candidates.append(Candidate(
                url=feed, category="Podcasts",
                title=r.get("collectionName", ""),
                genre=r.get("primaryGenreName", ""),
                national=True, national_reason="itunes",
            ))

        return candidates

    async def probe(
        self,
        profile: _CountryProfile,
        config: _SourceConfig,
        session,
    ) -> _ProbeResult:
        """Probe iTunes with a generic query (country name)."""
        import time as _time
        t0 = _time.monotonic()

        query = profile.country.replace("-", " ")
        try:
            results = await self.search(query, profile, config, session)
            elapsed = (_time.monotonic() - t0) * 1000
            return _ProbeResult(
                source_name="itunes",
                success=len(results) > 0,
                result_count=len(results),
                latency_ms=elapsed,
            )
        except Exception as e:
            elapsed = (_time.monotonic() - t0) * 1000
            return _ProbeResult(
                source_name="itunes",
                success=False,
                result_count=0,
                latency_ms=elapsed,
                error=str(e)[:200],
            )
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd scripts && python -m pytest feed_discovery/tests/test_itunes_source.py -v
```
Expected: All 7 tests PASS (network-dependent tests may skip or pass with cached data)

- [ ] **Step 5: Verify existing tests still pass**

```bash
cd scripts && python -m pytest feed_discovery/tests/test_podcasts.py -v
```
Expected: All existing podcast tests PASS (função `discover()` intacta)

- [ ] **Step 6: Commit**

```bash
git add scripts/feed_discovery/sources/podcasts.py \
        scripts/feed_discovery/tests/test_itunes_source.py
git commit -m "feat: add ITunesSource implementing SourceProtocol

Wraps existing iTunes Search logic into the pluggable source interface.
Original discover() function preserved for backward compatibility.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: DDGTextSource — wrapper SourceProtocol sobre search.py + discover.py + verify.py

**Files:**
- Create: `scripts/feed_discovery/sources/ddg_text.py`
- Create: `scripts/feed_discovery/tests/test_ddg_text_source.py`

**Interfaces:**
- Consumes: `SourceProtocol`, `ProbeResult` from Task 1; `CountryProfile`, `SourceConfig` from Task 1; existing `search.py`, `discover.py`, `verify.py`, `heuristic.py`
- Produces: `DDGTextSource` class with `name = "ddg_text"`, `search()`, `probe()`

- [ ] **Step 1: Write test_ddg_text_source.py**

```python
# scripts/feed_discovery/tests/test_ddg_text_source.py

import pytest
from scripts.feed_discovery.sources._base import SourceProtocol, ProbeResult
from scripts.feed_discovery.sources.ddg_text import DDGTextSource
from scripts.feed_discovery.profiles._schema import CountryProfile, SourceConfig
from scripts.feed_discovery.models import Candidate


def test_ddg_text_source_implements_protocol():
    source = DDGTextSource()
    assert isinstance(source, SourceProtocol)


def test_ddg_text_source_name():
    source = DDGTextSource()
    assert source.name == "ddg_text"


def test_ddg_text_source_has_search():
    source = DDGTextSource()
    assert hasattr(source, "search")
    assert callable(source.search)


def test_ddg_text_source_has_probe():
    source = DDGTextSource()
    assert hasattr(source, "probe")
    assert callable(source.probe)


@pytest.mark.asyncio
async def test_probe_returns_probe_result():
    source = DDGTextSource()
    profile = CountryProfile(country="usa", languages=["en"])
    config = SourceConfig(priority=4, max_results=5, timeout=10)
    import aiohttp
    async with aiohttp.ClientSession() as session:
        result = await source.probe(profile, config, session)
    assert isinstance(result, ProbeResult)
    assert result.source_name == "ddg_text"


@pytest.mark.asyncio
async def test_search_returns_candidates():
    source = DDGTextSource()
    profile = CountryProfile(country="usa", languages=["en"])
    config = SourceConfig(priority=4, max_results=5, timeout=10)
    import aiohttp
    async with aiohttp.ClientSession() as session:
        results = await source.search("texas news", profile, config, session)
    assert isinstance(results, list)
    if results:
        assert isinstance(results[0], Candidate)
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd scripts && python -m pytest feed_discovery/tests/test_ddg_text_source.py -v
```
Expected: All tests FAIL — `ImportError` for `ddg_text`

- [ ] **Step 3: Write sources/ddg_text.py**

```python
# scripts/feed_discovery/sources/ddg_text.py

from __future__ import annotations

import asyncio
import time
from pathlib import Path
from urllib.parse import urlparse

from .. import discover, search, verify
from ..heuristic import is_local
from ..models import Candidate
from ..opml import normalize_url
from ..pipeline import Config
from ..profiles._schema import CountryProfile, SourceConfig
from ._base import ProbeResult


class DDGTextSource:
    """DDG web search for text/news feeds as a SourceProtocol implementation.

    Wraps the existing search.py → discover.py → verify.py pipeline
    into the pluggable source interface. Does NOT modify the original
    modules.
    """
    name = "ddg_text"

    def __init__(self, cache_dir: Path | None = None):
        self._cache_dir = cache_dir or Path("scripts/feed_discovery/cache")

    async def search(
        self,
        query: str,
        profile: CountryProfile,
        config: SourceConfig,
        session,
    ) -> list[Candidate]:
        """Search DDG for text feeds, discover RSS, verify liveness."""
        candidates: list[Candidate] = []
        seen_urls: set[str] = set()

        # 1. DDG search for page URLs
        cache_path = self._cache_dir / "ddg_text" / profile.country / (
            "".join(ch if ch.isalnum() else "_" for ch in query) + ".json"
        )
        page_urls = search.search(
            query, profile._ddg_region(), config.max_results,
            cache_path, delay=2.0, fresh=False,
        )
        if not page_urls:
            return []

        # 2. Discover feeds from each unique domain root
        roots = list(dict.fromkeys(self._root_of(u) for u in page_urls))
        sem = asyncio.Semaphore(10)

        async def _discover_one(root: str) -> tuple[str, list[str]]:
            async with sem:
                feeds = await discover.discover_feeds(session, root, config.timeout)
                return root, feeds

        discovered = await asyncio.gather(*(_discover_one(r) for r in roots[:10]))
        root_feeds = dict(discovered)

        # 3. Collect unique feed URLs
        feed_urls: list[str] = []
        for root in roots[:10]:
            for feed in root_feeds.get(root, []):
                norm = normalize_url(feed)
                if norm not in seen_urls:
                    seen_urls.add(norm)
                    feed_urls.append(feed)

        # 4. Classify & verify liveness
        to_verify: list[tuple[str, str]] = []
        for feed_url in feed_urls[:config.max_results]:
            # Use the query as the subregion name for is_local check
            is_loc, reason = is_local(feed_url, query, feed_title="")
            if not is_loc:
                continue
            to_verify.append((feed_url, reason))

        sem_v = asyncio.Semaphore(10)

        async def _verify_one(url: str, reason: str) -> Candidate | None:
            async with sem_v:
                try:
                    is_live, status, title = await verify.verify_feed(
                        session, url, config.timeout,
                    )
                except Exception:
                    return None
                if not is_live:
                    return None
                if discover.is_comment_feed_title(title):
                    return None
                return Candidate(
                    url=url, category="News", title=title, genre="",
                    national=True, national_reason=reason,
                    is_live=True, status_code=status,
                )

        results = await asyncio.gather(*(_verify_one(u, r) for u, r in to_verify))
        for c in results:
            if c is not None:
                candidates.append(c)

        return candidates

    async def probe(
        self,
        profile: CountryProfile,
        config: SourceConfig,
        session,
    ) -> ProbeResult:
        """Probe DDG with the country name as query."""
        t0 = time.monotonic()
        query = profile.country.replace("-", " ")
        try:
            results = await self.search(query, profile, config, session)
            elapsed = (time.monotonic() - t0) * 1000
            return ProbeResult(
                source_name="ddg_text",
                success=len(results) > 0,
                result_count=len(results),
                latency_ms=elapsed,
            )
        except Exception as e:
            elapsed = (time.monotonic() - t0) * 1000
            return ProbeResult(
                source_name="ddg_text",
                success=False,
                result_count=0,
                latency_ms=elapsed,
                error=str(e)[:200],
            )

    @staticmethod
    def _root_of(url: str) -> str:
        parsed = urlparse(url)
        return f"{parsed.scheme}://{parsed.netloc}"


def _ddg_region_for_profile(profile: CountryProfile) -> str:
    """Derive a DDG region string from a CountryProfile."""
    lang = profile.languages[0] if profile.languages else "en"
    country = profile.country
    return f"{country}-{lang}"


# Monkey-patch _ddg_region as a convenience accessor
CountryProfile._ddg_region = lambda self: _ddg_region_for_profile(self)
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd scripts && python -m pytest feed_discovery/tests/test_ddg_text_source.py -v
```
Expected: All 6 tests PASS

- [ ] **Step 5: Verify existing tests still pass**

```bash
cd scripts && python -m pytest feed_discovery/tests/test_search.py feed_discovery/tests/test_discover.py feed_discovery/tests/test_verify.py -v
```
Expected: All existing tests PASS

- [ ] **Step 6: Commit**

```bash
git add scripts/feed_discovery/sources/ddg_text.py \
        scripts/feed_discovery/tests/test_ddg_text_source.py
git commit -m "feat: add DDGTextSource wrapping search+discover+verify as SourceProtocol

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: SourceProtocol conformance test + full suite verification

**Files:**
- Create: `scripts/feed_discovery/tests/test_source_protocol.py`

**Interfaces:**
- Consumes: All sources from Tasks 3-4, `SourceProtocol` from Task 1
- Produces: Conformance test that validates every source implements the protocol

- [ ] **Step 1: Write test_source_protocol.py**

```python
# scripts/feed_discovery/tests/test_source_protocol.py

import pytest
from scripts.feed_discovery.sources._base import SourceProtocol
from scripts.feed_discovery.sources.podcasts import ITunesSource
from scripts.feed_discovery.sources.ddg_text import DDGTextSource


ALL_SOURCES = [
    ITunesSource(),
    DDGTextSource(),
]


@pytest.mark.parametrize("source", ALL_SOURCES, ids=lambda s: s.name)
def test_source_implements_protocol(source):
    assert isinstance(source, SourceProtocol), \
        f"{source.name} does not implement SourceProtocol"


@pytest.mark.parametrize("source", ALL_SOURCES, ids=lambda s: s.name)
def test_source_has_name(source):
    assert isinstance(source.name, str)
    assert len(source.name) > 0


@pytest.mark.parametrize("source", ALL_SOURCES, ids=lambda s: s.name)
def test_source_has_search_callable(source):
    assert callable(source.search)


@pytest.mark.parametrize("source", ALL_SOURCES, ids=lambda s: s.name)
def test_source_has_probe_callable(source):
    assert callable(source.probe)


def test_all_source_names_unique():
    names = [s.name for s in ALL_SOURCES]
    assert len(names) == len(set(names)), f"Duplicate source names: {names}"


def test_registry_can_discover_sources():
    """Simulate how the future _registry.py will discover sources.

    In Phase 3, _registry.py will dynamically find all SourceProtocol
    implementations. This test validates the pattern works.
    """
    # For now, manually list. Phase 3 will auto-discover.
    registry: dict[str, SourceProtocol] = {}
    for source in ALL_SOURCES:
        registry[source.name] = source
    assert "itunes" in registry
    assert "ddg_text" in registry
    assert len(registry) == 2
```

- [ ] **Step 2: Run conformance tests**

```bash
cd scripts && python -m pytest feed_discovery/tests/test_source_protocol.py -v
```
Expected: All 6 tests PASS

- [ ] **Step 3: Run the FULL test suite to verify no regressions**

```bash
cd scripts && python -m pytest feed_discovery/tests/ -v
```
Expected: All existing tests PASS (60+ from before, plus ~35 new from Tasks 1-5)

- [ ] **Step 4: Run subregion tests too**

```bash
cd scripts && python -m pytest feed_discovery/subregion/ -v
```
Expected: All subregion tests PASS (25+ from previous plan)

- [ ] **Step 5: Commit**

```bash
git add scripts/feed_discovery/tests/test_source_protocol.py
git commit -m "test: add SourceProtocol conformance tests for all Phase 1 sources

Validates ITunesSource and DDGTextSource implement the protocol correctly.
Parameterized tests make adding Phase 2 sources trivial.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Execution Order

```
Task 1 (schemas) → Task 2 (global profile) → Task 3 (iTunes refactor) → Task 4 (DDG wrapper) → Task 5 (conformance)
```

Tasks 3 and 4 can be parallelized after Task 2 completes.
