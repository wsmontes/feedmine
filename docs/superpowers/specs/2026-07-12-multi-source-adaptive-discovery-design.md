# Multi-Source Adaptive Discovery — Design Spec

**Date:** 2026-07-12
**Status:** ready
**Goal:** Substituir o pipeline de descoberta de 3 fontes fixas (DDG, iTunes, YouTube scraping) por um sistema multi-source adaptativo com perfil de internet por país, capaz de descobrir feeds em todos os 101 países.

---

## Problem

O pipeline atual (`subregion/populate.py`) usou 3 fontes (DDG search, iTunes Search API, YouTube scraping) para descobrir feeds em 1421 sub-regiões de 101 países. Resultado: **61 países retornaram zero feeds**. A conclusão não é que esses países não têm conteúdo — é que DDG + iTunes + YouTube não os cobrem.

Cada país tem um ecossistema digital diferente:
- **África**: Boomplay e WhatsApp dominam; iTunes é irrelevante; YouTube cresce mas canais não têm metadados de país
- **Índia**: 16+ idiomas; JioSaavn e Gaana são os agregadores reais; iTunes só cobre inglês
- **Leste Europeu**: VK e Telegram para mídia; RSS comum mas em cirílico; DDG indexa mal
- **Oriente Médio**: Mídia estatal controlada; Podeo e Anghami para podcasts; barreira linguística
- **Sudeste Asiático**: Joox, Noice; internet mobile-first; poucos sites com RSS tradicional

Tratar todos os países com as mesmas 3 fontes é garantia de falha em 60%+ deles.

---

## Design Decisions

| Decisão | Escolha | Rationale |
|---------|---------|-----------|
| Arquitetura de fontes | Plug-in via `SourceProtocol` | Adicionar fonte nova = 1 arquivo, sem mexer no core |
| Configuração | `CountryProfile` por país com merge de herança | Cada país herda um perfil regional, sobrescreve o que precisa |
| Descoberta de perfil | Automática (probe → learn → enrich) | Sem curadoria manual inicial; o sistema descobre o que funciona |
| YouTube | Migrar scraping → YouTube Data API v3 | Oficial, 10K quota/dia, mais confiável |
| Fallback | Manter scraping como fallback quando API não cobre | YouTube API não retorna country metadata em todos os canais |
| Orquestração | `adaptive_pipeline.py` — mesmo padrão do `populate.py` | Reusa progress tracking, resume, paralelismo |
| Fontes prioritárias | Podcast Index (#1, gratuito, 4M+ podcasts) + Deezer (#2, sem auth) | Máximo alcance com zero custo |

---

## Architecture

```
scripts/feed_discovery/
│
├── sources/                         # Fontes de descoberta (uma por arquivo)
│   ├── __init__.py
│   ├── _base.py                     # SourceProtocol + SourceConfig + ProbeResult
│   ├── podcast_index.py             # Podcast Index API → Candidate[]
│   ├── deezer.py                    # Deezer API (sem auth) → Candidate[]
│   ├── youtube_api.py               # YouTube Data API v3 → Candidate[]
│   ├── youtube_scrape.py            # (existente, refatorado como fallback)
│   ├── listen_notes.py              # Listen Notes API → Candidate[]
│   ├── spotify.py                   # Spotify API (OAuth) → Candidate[]
│   ├── feedly.py                    # Feedly API (OAuth) → Candidate[]
│   ├── itunes.py                    # (existente, adaptado ao protocolo)
│   └── ddg_text.py                  # (existente - search.py + discover.py, adaptado)
│
├── profiles/                        # Perfis de internet por país
│   ├── __init__.py
│   ├── _registry.py                 # Carrega, faz merge, cacheia CountryProfiles
│   ├── _schema.py                   # Dataclasses: CountryProfile, SourceConfig, SourceMetrics
│   ├── global.py                    # Perfil base (fontes universais para todos)
│   ├── africa.py                    # Mixin: Boomplay RSS patterns, Podcast Index, Deezer
│   ├── latam.py                     # Mixin: Deezer, iVoox RSS patterns, Podcast Index
│   ├── asia.py                      # Mixin: JioSaavn RSS, Podcast Index, YouTube API
│   ├── europe_east.py               # Mixin: VK RSS, Yandex, Podcast Index, DDG
│   ├── mena.py                      # Mixin: Podeo RSS patterns, Deezer, YouTube API
│   └── southeast_asia.py            # Mixin: Joox RSS, Podcast Index, Deezer
│
├── country_profiler.py              # Gera/atualiza perfil automaticamente
├── adaptive_pipeline.py             # Orquestrador multi-source com CountryProfile
└── profile_schema.py                # Re-export de profiles/_schema.py

data/
├── country_profiles/                # Perfis gerados (JSON, commitados)
│   ├── nigeria.json
│   ├── brazil.json
│   ├── india.json
│   └── ...
└── _profiles_meta.json              # Métricas globais de todas as fontes
```

---

## Componentes

### 1. `sources/_base.py` — Protocolo de fonte

Toda fonte de descoberta implementa esta interface. Adicionar uma fonte nova é criar um arquivo `.py` com uma classe que implementa `SourceProtocol`.

```python
from dataclasses import dataclass, field
from typing import Protocol, runtime_checkable

@dataclass
class SourceConfig:
    """Configuração de uma fonte para um país específico."""
    priority: int                    # 1 = mais importante
    enabled: bool = True
    params: dict[str, str] = field(default_factory=dict)  # {"lang": "en", "region": "ng"}
    min_results: int = 3             # abaixo disso por N rodadas → degraded
    max_results: int = 50            # limite por query
    timeout: int = 15                # segundos

@dataclass
class ProbeResult:
    """Resultado de um probe de fonte."""
    source_name: str
    success: bool
    result_count: int
    latency_ms: float
    error: str = ""

@dataclass
class SourceMetrics:
    """Métricas acumuladas de performance."""
    total_calls: int = 0
    total_results: int = 0
    success_count: int = 0
    failure_count: int = 0
    total_latency_ms: float = 0.0
    last_probe: str = ""             # ISO timestamp

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


@runtime_checkable
class SourceProtocol(Protocol):
    """Interface que toda fonte de descoberta deve implementar."""
    name: str

    async def search(
        self,
        query: str,
        profile: "CountryProfile",
        config: SourceConfig,
        session: aiohttp.ClientSession,
    ) -> list["Candidate"]: ...

    async def probe(
        self,
        profile: "CountryProfile",
        config: SourceConfig,
        session: aiohttp.ClientSession,
    ) -> ProbeResult:
        """Testa se a fonte retorna resultados para este país.

        Deve usar uma query genérica (ex: nome do país) para verificar
        se a fonte tem cobertura na região. Não deve fazer mais de 3
        chamadas de rede.
        """
        ...
```

### 2. `profiles/_schema.py` — Perfil de país

```python
@dataclass
class CountryProfile:
    country: str                          # "nigeria"
    internet_penetration: float = 0.0     # 0.55 = 55%
    dominant_platforms: list[str] = field(default_factory=list)
    languages: list[str] = field(default_factory=list)

    # Fontes ativas com prioridade e config
    sources: dict[str, SourceConfig] = field(default_factory=dict)

    # URLs de diretórios locais descobertos
    local_directories: list[str] = field(default_factory=list)

    # Domínios de mídia local (allowlist para is_local)
    media_domains: list[str] = field(default_factory=list)

    # Fontes desabilitadas (aprendido com falhas)
    disabled_sources: set[str] = field(default_factory=set)

    # Métricas de performance por fonte (atualizadas a cada rodada)
    source_performance: dict[str, SourceMetrics] = field(default_factory=dict)

    # Metadata
    generated_at: str = ""                # ISO timestamp
    generation_version: int = 1
```

### 3. `profiles/global.py` — Perfil base

```python
GLOBAL_PROFILE = CountryProfile(
    country="*",
    sources={
        "podcast_index": SourceConfig(priority=1, params={}),
        "deezer": SourceConfig(priority=2, params={}),
        "youtube_api": SourceConfig(priority=3, params={}),
        "ddg_text": SourceConfig(priority=4, params={}),
        "itunes": SourceConfig(priority=5, params={}),
        "listen_notes": SourceConfig(priority=6, params={}),
        "spotify": SourceConfig(priority=7, params={}),
        "feedly": SourceConfig(priority=8, params={}),
        "youtube_scrape": SourceConfig(priority=9, params={}, enabled=False),  # fallback
    },
)
```

### 4. `profiles/_registry.py` — Merge de perfis

```python
def load_profile(country_slug: str) -> CountryProfile:
    """Carrega o perfil de um país, fazendo merge na ordem:

    1. global.py (base)
    2. Mixin regional (africa.py, latam.py, etc.) — aplica overrides
    3. Arquivo específico do país (data/country_profiles/nigeria.json) — se existir
    4. Metrics aprendidas de rodadas anteriores

    O merge de sources é profundo: fontes do país sobrescrevem
    totalmente a config da mesma fonte no perfil regional/global.
    Disabled sources são removidas.
    """

def save_profile(profile: CountryProfile) -> None:
    """Persiste o perfil em data/country_profiles/{country}.json."""

def all_profiles() -> dict[str, CountryProfile]:
    """Carrega todos os perfis cacheados."""
```

### 5. Mixins regionais

Cada mixin regional adiciona:
- **`dominant_platforms`**: plataformas dominantes na região
- **`languages`**: idiomas mais comuns (para parametrizar queries)
- **`media_domains`**: seed de domínios locais conhecidos
- **Source overrides**: ajusta `priority`, `params`, `min_results` para a região

Exemplo — `profiles/africa.py`:

```python
AFRICA_PROFILE = CountryProfile(
    country="africa",
    dominant_platforms=["whatsapp", "facebook", "boomplay", "audiomack"],
    languages=["en", "fr", "ar", "sw"],
    sources={
        # Podcast Index é #1 na África — indexa Boomplay e Audiomack RSS
        "podcast_index": SourceConfig(priority=1, params={}),
        # Deezer cobre bem o Norte da África e África do Sul
        "deezer": SourceConfig(priority=2, params={}),
        # YouTube API com regionCode do país
        "youtube_api": SourceConfig(priority=3, params={}),
        # DDG com locale africano
        "ddg_text": SourceConfig(priority=4, params={}),
        # iTunes é fraco na África — prioridade baixa
        "itunes": SourceConfig(priority=5, params={}),
        # Spotify só funciona bem na África do Sul e Nigéria
        "spotify": SourceConfig(priority=6, params={}),
        # Listen Notes tem cobertura limitada na África
        "listen_notes": SourceConfig(priority=7, params={}),
    },
    media_domains=[
        "vanguardngr.com", "punchng.com", "thisdaylive.com",
        "channelstv.com", "premiumtimesng.com", "guardian.ng",
        "nation.africa", "citizen.digital", "standardmedia.co.ke",
        "herald.co.zw", "mg.co.za", "news24.com", "iol.co.za",
        "alahram.org.eg", "africanews.com", "apanews.net",
    ],
)
```

Exemplo — `profiles/latam.py`:

```python
LATAM_PROFILE = CountryProfile(
    country="latam",
    dominant_platforms=["whatsapp", "instagram", "youtube", "deezer", "ivoox"],
    languages=["es", "pt"],
    sources={
        # Deezer é fortíssimo no Brasil e México
        "deezer": SourceConfig(priority=1, params={}),
        # Podcast Index indexa RSS de iVoox, Anchor, Spreaker
        "podcast_index": SourceConfig(priority=2, params={}),
        # YouTube API — YouTube é muito popular na América Latina
        "youtube_api": SourceConfig(priority=3, params={
            "relevanceLanguage": "es,pt",
        }),
        # iTunes cobre razoavelmente bem
        "itunes": SourceConfig(priority=4, params={}),
        # DDG com ccTLD local (.br, .mx, .ar)
        "ddg_text": SourceConfig(priority=5, params={}),
        # Spotify API cobre México, Brasil, Argentina, Colômbia
        "spotify": SourceConfig(priority=6, params={}),
    },
    media_domains=[
        "globo.com", "uol.com.br", "folha.uol.com.br", "estadao.com.br",
        "eluniversal.com.mx", "jornada.com.mx", "milenio.com",
        "clarin.com", "lanacion.com.ar", "infobae.com",
        "eltiempo.com", "elespectador.com", "semana.com",
        "elcomercio.pe", "latercera.com", "emol.com",
        "elpais.com.uy", "abc.com.py", "eldeber.com.bo",
    ],
)
```

### 6. Fontes de descoberta

#### 6.1 `sources/podcast_index.py`

```python
class PodcastIndexSource:
    name = "podcast_index"

    BASE = "https://api.podcastindex.org/api/1.0"

    def __init__(self, api_key: str, api_secret: str):
        self.api_key = api_key
        self.api_secret = api_secret

    async def search(self, query, profile, config, session):
        """Usa /search/byterm para buscar podcasts.

        Parâmetros:
        - q: query string (nome do país/cidade + idioma)
        - max: config.max_results
        - lang: profile.languages (separado por vírgula)

        Retorna Candidate(url=feedUrl, title=title, category="Podcasts", ...)
        """

    async def probe(self, profile, config, session):
        """Busca pelo nome do país. Se retornar ≥ 5 resultados, a fonte funciona."""
```

**Auth:** X-Auth-Key + X-Auth-Date + Authorization header (HMAC-SHA1). API key grátis em api.podcastindex.org.

#### 6.2 `sources/deezer.py`

```python
class DeezerSource:
    name = "deezer"

    BASE = "https://api.deezer.com"

    async def search(self, query, profile, config, session):
        """Usa /search/podcast?q={query} para buscar podcasts.

        Sem autenticação necessária. Retorna JSON com id, title, description.
        O feed RSS do podcast no Deezer é: https://www.deezer.com/show/{id}
        (pode não ser RSS direto — verificar se há enclosure links).

        Fallback: tenta /search?q={query}&type=podcast
        """

    async def probe(self, profile, config, session):
        """Busca pelo nome do país. Deezer tem cobertura global mas
        catálogo varia por região (baseado em IP)."""
```

#### 6.3 `sources/youtube_api.py`

```python
class YouTubeAPISource:
    name = "youtube_api"

    BASE = "https://www.googleapis.com/youtube/v3"

    def __init__(self, api_key: str):
        self.api_key = api_key

    async def search(self, query, profile, config, session):
        """Usa /search?part=snippet&type=channel&q={query}&regionCode={iso2}

        Depois /channels?part=snippet,brandingSettings&id={channel_id}
        para extrair país do canal.

        Quota: ~100 units por query (search=100, channels=1).
        Free tier: 10,000 units/dia → ~100 queries/dia.
        """

    async def probe(self, profile, config, session):
        """1 chamada search → verifica se retorna canais para o país."""
```

#### 6.4 `sources/listen_notes.py`

```python
class ListenNotesSource:
    name = "listen_notes"

    BASE = "https://listen-api.listennotes.com/api/v2"

    def __init__(self, api_key: str):
        self.api_key = api_key

    async def search(self, query, profile, config, session):
        """Usa /search?q={query}&type=podcast&language={lang}&offset=0

        Free tier: 250-300 req/mês. Usar com moderação — apenas para
        países onde outras fontes falharam. Cache agressivo dos resultados.
        """

    async def probe(self, profile, config, session):
        """1 chamada search. Se 429, marca como rate_limited."""
```

#### 6.5 `sources/spotify.py`

```python
class SpotifySource:
    name = "spotify"

    BASE = "https://api.spotify.com/v1"

    def __init__(self, client_id: str, client_secret: str):
        self.client_id = client_id
        self.client_secret = client_secret

    async def _get_token(self, session):
        """OAuth client credentials flow → access_token."""

    async def search(self, query, profile, config, session):
        """Usa /search?q={query}&type=show&market={iso2}&limit=50

        Retorna shows (podcasts) disponíveis no mercado do país.
        O feed RSS não está diretamente na resposta — precisa chamar
        /shows/{id}/episodes para extrair informações.
        """

    async def probe(self, profile, config, session):
        """1 chamada search. Verifica se há shows para o mercado."""
```

#### 6.6 `sources/feedly.py`

```python
class FeedlySource:
    name = "feedly"

    BASE = "https://cloud.feedly.com/v3"

    def __init__(self, access_token: str):
        self.access_token = access_token

    async def search(self, query, profile, config, session):
        """Usa /search/feeds?q={query}&n={max_results}&locale={lang}

        Feedly indexa 40M+ feeds RSS globais. Ideal para descobrir
        blogs e sites de notícias em países onde DDG não indexa bem.

        Auth: OAuth access token (user-level).
        Rate limit: generoso para search.
        """

    async def probe(self, profile, config, session):
        """1 chamada search. Feedly tem cobertura quase universal."""
```

#### 6.7 Fontes existentes refatoradas

- **`itunes.py`** → adaptado ao `SourceProtocol`, sem mudança na lógica interna
- **`ddg_text.py`** → wrapper que unifica `search.py` + `discover.py` + `verify.py` sob o protocolo
- **`youtube_scrape.py`** → refatorado como fallback, `enabled=False` por padrão

### 7. `country_profiler.py` — Gerador automático de perfil

```python
class CountryProfiler:
    """Gera e mantém perfis de internet por país.

    Fluxo:
    1. BOOTSTRAP: carrega perfil regional (ou global se não existe regional)
    2. PROBE: testa cada fonte ativa com queries genéricas
    3. LEARN: analisa resultados, ajusta prioridades, desabilita fontes ruins
    4. ENRICH: extrai domínios de mídia dos resultados, adiciona ao allowlist
    5. SAVE: persiste o perfil em data/country_profiles/{slug}.json
    """

    async def bootstrap(self, country_slug: str) -> CountryProfile:
        """Primeira execução para um país: aplica mixin regional,
        faz probe de todas as fontes, gera perfil inicial."""

    async def update(self, profile: CountryProfile, session) -> CountryProfile:
        """Atualiza um perfil existente com métricas da última rodada.

        - Fontes com success_rate < 0.1 em 5+ tentativas → disabled
        - Fontes com avg_results > 50 → aumenta priority
        - Descobre novos media_domains nos resultados
        """

    async def probe_all_sources(
        self, profile: CountryProfile, session
    ) -> dict[str, ProbeResult]:
        """Testa todas as fontes ativas em paralelo.

        Cada fonte recebe uma query genérica (nome do país no idioma local)
        e deve retornar um ProbeResult. Fontes que falham 3x consecutivas
        são marcadas como degraded e movidas para prioridade baixa.
        """
```

### 8. `adaptive_pipeline.py` — Orquestrador

Mesmo padrão do `populate.py` existente, mas com seleção dinâmica de fontes:

```python
async def discover_for_subregion(
    subregion: SubRegion,
    profile: CountryProfile,
    existing_urls: set[str],
    session: aiohttp.ClientSession,
    cfg: Config,
) -> list[Candidate]:
    """Descobre feeds para uma sub-região usando TODAS as fontes ativas
    no CountryProfile, em paralelo, ordenadas por prioridade.

    Fontes com priority mais baixa só são chamadas se as de alta
    prioridade não atingirem min_results.
    """

async def discover_for_country(
    country_slug: str,
    session: aiohttp.ClientSession,
    cfg: Config,
) -> list[Candidate]:
    """Descobre feeds para o país como um todo (nacional, não sub-região).
    Usado para preencher {pais}.opml.
    """

async def adaptive_populate(
    country_slug: str,
    cfg: Config | None = None,
) -> dict:
    """Orquestrador principal:

    1. Carrega ou gera CountryProfile
    2. Para cada sub-região (em paralelo, semaphore):
       - discover_for_subregion() com todas as fontes ativas
    3. Deduplica entre sub-regiões
    4. Escreve OPMLs (reusa opml_writer.py)
    5. Atualiza CountryProfile com métricas
    6. Salva progresso
    """
```

---

## Fontes confirmadas

| Fonte | Tipo | Auth | Custo | Rate Limit | Cobertura |
|-------|------|------|-------|------------|-----------|
| **Podcast Index** | Podcasts | API key | Grátis | Generoso | 4M+ podcasts, global |
| **Deezer API** | Podcasts | Nenhuma | Grátis | Não documentado | Forte BR/MX/CO/Europa/África |
| **YouTube Data API v3** | Vídeo | API key | Grátis (10K quota/dia) | 10K units/dia | Global |
| **iTunes Search** | Podcasts | Nenhuma | Grátis | ~20 req/s | Países com Apple ID |
| **DDG Search** | Texto/News | Nenhuma | Grátis | ~1 req/2s (politeness) | Web global, viés inglês |
| **Listen Notes** | Podcasts | API key | Grátis (250/mês) | 250-300 req/mês | 2M+ podcasts |
| **Spotify API** | Podcasts | OAuth (client creds) | Grátis | Rate limit | Países Spotify |
| **Feedly API** | RSS feeds | OAuth (user) | Grátis (limitado) | Rate limit | 40M+ feeds, global |

### APIs pesquisadas e descartadas

| Plataforma | Motivo |
|------------|--------|
| iVoox | Sem API pública. Mas podcasts do iVoox têm RSS feeds indexados pelo Podcast Index |
| Anghami | Sem API pública |
| Podeo | Sem API pública documentada |
| Boomplay | Sem API pública. Podcasts usam Anchor RSS → indexados pelo Podcast Index |
| JioSaavn | API fechada, requer parceria |
| Ximalaya | API fechada, requer registro de empresa chinesa |
| SoundCloud | API requer key (aplicação manual), rate limit baixo, despriorizado |
| Google News RSS | Existente via news.google.com/rss, já coberto indiretamente pelo DDG |

---

## Métricas de sucesso

### Por país

| Nível | Critério |
|-------|----------|
| Mínimo | 5+ fontes respondendo com ≥ 10 resultados cada |
| Bom | 3+ fontes com ≥ 30 resultados, 2+ tipos de conteúdo (texto + áudio) |
| Ótimo | ≥ 50 feeds descobertos no total, mix de texto + podcasts + YouTube |

### Por fonte (global)

| Fonte | Meta de cobertura |
|-------|-------------------|
| Podcast Index | ≥ 90 países com resultados |
| Deezer | ≥ 60 países |
| YouTube API | ≥ 80 países |
| Feedly | ≥ 70 países |

---

## API Key Management

Todas as credenciais ficam em **variáveis de ambiente** (nunca commitadas):

```bash
# .env (gitignored)
PODCAST_INDEX_KEY=xxx
PODCAST_INDEX_SECRET=xxx
YOUTUBE_API_KEY=xxx
LISTEN_NOTES_API_KEY=xxx
SPOTIFY_CLIENT_ID=xxx
SPOTIFY_CLIENT_SECRET=xxx
FEEDLY_ACCESS_TOKEN=xxx
```

Fontes sem auth (Deezer, iTunes, DDG) não precisam de configuração.

No código, cada fonte lê suas credenciais no `__init__`. Se a env var não existe, a fonte é desabilitada automaticamente com warning no log.

## Degradation Thresholds

| Estado | Condição | Efeito |
|--------|----------|--------|
| **active** | success_rate ≥ 0.5 E avg_results ≥ min_results | Prioridade normal |
| **degraded** | 3 rodadas consecutivas com avg_results < min_results | Prioridade reduzida em 5, probe a cada 10 rodadas |
| **disabled** | 5 rodadas consecutivas com 0 resultados OU 3 probes com falha | Removida das fontes ativas |
| **reactivated** | Probe bem-sucedido após N rodadas disabled | Volta como degraded, priority = max + 1 |

## O que NÃO faz parte deste escopo

- UI no app Swift para gerenciar fontes ou perfis
- Tradução automática de títulos de feeds
- Verificação de qualidade do conteúdo além de liveness (já existe)
- Modificação dos OPMLs de país já populados (só adiciona, não remove)
- Integração com o app (os OPMLs estão no bundle)

---

## Dependências

- **Reusa:** `opml_writer.py`, `models.py` (Candidate, SubRegion, Country), `heuristic.py`, `verify.py`
- **Novo:** 9 fontes, 7 mixins regionais, `CountryProfile` schema, `country_profiler.py`, `adaptive_pipeline.py`
- **Dados existentes:** `countries.json`, `countries_enriched.json`, OPMLs em `feedmine/Resources/Feeds/countries/`
- **APIs externas:** Podcast Index, Deezer, YouTube Data v3, Listen Notes, Spotify, Feedly, iTunes, DDG
- **Substitui:** `pipeline.py`, `subregion/populate.py`, `subregion/discover_subregion.py` (lógica de descoberta migra para o adaptive_pipeline)

## Phased Implementation Order

Esta spec é grande. A implementação deve ser faseada:

**Phase 1 — Foundation (entregue primeiro)**
- `profiles/_schema.py` — CountryProfile, SourceConfig, SourceMetrics
- `sources/_base.py` — SourceProtocol, ProbeResult
- `profiles/global.py` — perfil base
- Refatorar `itunes.py` e `ddg_text.py` para SourceProtocol

**Phase 2 — Big 3 Sources (máximo impacto, zero custo)**
- `sources/podcast_index.py` — grátis, maior cobertura global
- `sources/deezer.py` — grátis, sem auth, forte em LatAm/África/Europa
- `sources/youtube_api.py` — substitui scraping, 10K quota/dia

**Phase 3 — Profiles & Pipeline**
- `profiles/_registry.py` — merge e cache
- Mixins regionais (7 arquivos)
- `country_profiler.py` — bootstrap + update automático
- `adaptive_pipeline.py` — orquestrador com CountryProfile

**Phase 4 — Premium Sources (limitados, usar com moderação)**
- `sources/listen_notes.py` — 250 req/mês, só para países sem cobertura
- `sources/spotify.py` — OAuth, cobre mercados Spotify
- `sources/feedly.py` — OAuth, 40M+ feeds RSS

**Phase 5 — Test & Validate**
- Rodar pipeline em todos os 101 países
- Comparar métricas antes/depois (feed count por país)
- Ajustar thresholds de degradation
