# Feed Architecture v2 — Design

## Contexto

O Feedmine tem ~1500 fontes RSS (100+ países, cada um com dezenas de feeds, mais categorias globais). O modelo atual é "baixar tudo e filtrar" — `fetchFreshContent` baixa até 200 fontes por ciclo, `refillReservoir` baixa 40 por ciclo de scroll. Com dezenas de países habilitados, isso é insustentável em rede e injusto na distribuição de conteúdo.

### Objetivos

1. Download sob demanda com justiça entre regiões — sem baixar 200 fontes às cegas
2. SQLite como memória longa — scroll back de 30 dias, busca full-text, analytics
3. Filtro bidirecional — controla tanto o que aparece na tela quanto o que o download busca
4. Busca persistente — queries salvas que capturam itens novos automaticamente e funcionam como feed composto
5. Toggle ON/OFF imediato — remoção instantânea da UI, cancelamento de fetch em voo

---

## 1. Schema SQLite

```sql
CREATE TABLE feed_item (
    id TEXT PRIMARY KEY,              -- SHA256(sourceURL|guid|link)
    source_url  TEXT NOT NULL,
    source_title TEXT NOT NULL,
    region      TEXT NOT NULL,        -- "global" | "countries/brazil"
    category    TEXT NOT NULL,
    title       TEXT NOT NULL,
    excerpt     TEXT NOT NULL,
    url         TEXT NOT NULL,
    image_url   TEXT,
    audio_url   TEXT,
    duration    REAL,
    published_at INTEGER NOT NULL,    -- Unix timestamp
    fetched_at   INTEGER NOT NULL,    -- quando baixamos (expurgo 30d)
    is_read      INTEGER NOT NULL DEFAULT 0,
    opened_at    INTEGER
);

-- Feed principal: filtro + scroll
CREATE INDEX idx_item_region_date ON feed_item(region, published_at);
-- Expurgo de 30 dias
CREATE INDEX idx_item_fetched ON feed_item(fetched_at);
-- Lidos (permanentes)
CREATE INDEX idx_item_read ON feed_item(is_read) WHERE is_read = 1;

-- Full-text search
CREATE VIRTUAL TABLE feed_item_fts USING fts5(
    title, excerpt, source_title, category,
    content='feed_item', content_rowid='rowid'
);

-- Listas de bookmarks (manuais ou buscas persistentes)
CREATE TABLE bookmark_list (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    sort_order INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    is_default INTEGER NOT NULL DEFAULT 0,   -- lista "Favorites" padrão
    search_query TEXT,                       -- NULL = lista manual
    search_region TEXT,                      -- NULL = qualquer região
    search_category TEXT,                    -- NULL = qualquer categoria
    search_active INTEGER NOT NULL DEFAULT 0 -- 1 = busca persistente ativa
);

-- Pivô many-to-many
CREATE TABLE bookmark_item (
    list_id INTEGER NOT NULL REFERENCES bookmark_list(id) ON DELETE CASCADE,
    item_id TEXT NOT NULL REFERENCES feed_item(id) ON DELETE CASCADE,
    added_at INTEGER NOT NULL,
    sort_order INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (list_id, item_id)
);

CREATE INDEX idx_bookmark_item_list ON bookmark_item(list_id, sort_order);
CREATE INDEX idx_bookmark_item_item ON bookmark_item(item_id);
```

### Política de retenção

- **30 dias**: `fetched_at > unixepoch() - 2592000`
- **Permanente**: `is_read = 1` OU item está em qualquer `bookmark_item`
- **Por fonte**: máximo 50 itens (dentro dos 30 dias), FIFO
- **Expurgo**: `DELETE FROM feed_item WHERE fetched_at < ? AND is_read = 0 AND id NOT IN (SELECT item_id FROM bookmark_item)`

---

## 2. Arquitetura: FeedStore vs FeedLoader

O `FeedLoader` atual (1593 linhas) é dividido em duas classes:

### FeedStore (novo, dono dos dados)

```swift
@Observable
final class FeedStore {
    // --- Subcomponentes internos ---
    let db: DatabaseQueue              // GRDB SQLite
    let registry: SourceRegistry       // fontes parseadas do OPML
    let scheduler: SourceScheduler     // orquestrador por entropia
    let reservoir: Reservoir           // buffer em memória + interleave
    let fetcher: RSSFetcher            // actor de fetch HTTP

    // --- Estado público (lido pelo FeedLoader) ---
    private(set) var visibleItems: [FeedItem] = []
    private(set) var reservoirCount: Int = 0

    // --- Filtro ativo (bidirecional) ---
    var activeRegion: String?          // nil = todas habilitadas
    var activeCategory: String?
    var activeContentType: ContentType

    // --- Ações ---
    func start() async
    func loadMore() async
    func refreshIfStale() async
    func setFilter(region: String?, category: String?, type: ContentType)
    func search(_ query: String)
    func clearSearch()
    func toggleRegion(_ region: String, enabled: Bool)
    func toggleSource(_ url: String, enabled: Bool)
    func markAsRead(_ id: String)
    func toggleBookmark(_ id: String, listID: Int64?)
    func createBookmarkList(_ name: String, searchQuery: String?, region: String?, category: String?) -> Int64
    func deleteBookmarkList(_ id: Int64)
    func emergencyTrim()
}
```

### FeedLoader (ViewModel enxuto)

```swift
@Observable
final class FeedLoader {
    private let store: FeedStore

    // UI state
    var items: [FeedItem] { store.visibleItems }
    var dateSections: [DateSection] { ... }
    var layout: FeedLayout
    var loadingState: FeedLoadingState
    var searchQuery: String

    // Filtros expostos pra UI
    var selectedCategory: String?
    var selectedMood: MoodFilter
    var selectedContentType: ContentType
    var activeSearches: [ActiveSearch]  // buscas persistentes ativas

    // Bookmarks
    var bookmarkLists: [BookmarkList]
    var bookmarkedItems: [FeedItem]

    // Countries (delegado pro SourceRegistry)
    var availableCountries: [Country] { store.registry.availableCountries }
    var enabledSources: [FeedSource] { store.registry.enabledSources }

    // Ações
    func loadMoreIfNeeded(currentItem: FeedItem) async
    func selectCategory(_ category: String?)
    func selectMood(_ mood: MoodFilter)
    func clearAllFilters()
    func markAllAsRead()
    func shakeToRefresh()
    func whatsNewItems() -> [FeedItem]
}
```

### O que sai do FeedLoader

| Responsabilidade | Destino |
|------------------|---------|
| `sources`, `opmlFileCount` | `SourceRegistry` |
| `loadedIDs`, `registerLoadedIDs` | SQLite PK + Bloom filter |
| `reservoir`, `capReservoir`, `interleave` | `Reservoir` |
| `fetchFreshContent`, `refillReservoir` | `SourceScheduler` |
| `sourceHealth` | `SourceScheduler` |
| `disabledSourceIDs`, `disabledRegions` | `SourceRegistry` |
| `filteredOutItems` | Morre (SQLite é a fonte) |
| `buildState`, `restoreState`, `saveNow` | `FeedStore` interno |

---

## 3. SourceScheduler por Entropia

O scheduler olha o reservoir atual e pergunta: **"o que está faltando?"**. O batch de fetch é consequência dos déficits, não de um número fixo.

### Algoritmo

1. **Medir consumo**: taxa de scroll/minuto → meta de reserva em minutos de leitura
2. **Medir entropia do reservoir**: distribuição atual de regiões, categorias, tipos
3. **Calcular distribuição ideal**: raiz quadrada do nº de fontes por região (√n), uniforme entre categorias e tipos
4. **Identificar déficits**: `déficit = ideal - atual` para cada dimensão
5. **Selecionar fontes que compensam déficits**: região com maior déficit, categoria também em déficit (duplo benefício), ordenadas por LRU
6. **Cooldown mole**: peso = déficit_região × déficit_categoria × min(1.0, minutos_desde_último_fetch / 30)

### Escopo do filtro ativo

- **Sem filtro**: scheduler opera sobre todas as regiões habilitadas (entropia global)
- **Com filtro de região**: scheduler opera só dentro daquela região (entropia local)
- **Com busca textual ativa**: scheduler pausado (busca é imediata, não fetch)

### Estrutura

```swift
final class SourceScheduler {
    private var lastFetchedAt: [String: Date] = [:]
    private var consecutiveFailures: [String: Int] = [:]
    private var consumptionWindow: [Date] = []

    func nextBatch(
        reservoir: [FeedItem],
        sourcesByRegion: [String: [FeedSource]],
        activeRegion: String?,     // escopo do filtro
        activeCategory: String?
    ) -> [FeedSource]

    func recordConsumption()        // scroll detectado
    func recordFetch(sourceURL: String, success: Bool)
    func prioritize(region: String) // toggle ON
    func remove(region: String)     // toggle OFF
}
```

### Propriedades emergentes

- **Batch size varia naturalmente**: déficits grandes → mais fontes. Reservatório diverso → batch vazio
- **Fontes secas são despromovidas**: se traz 0 itens, não resolve o déficit → scheduler busca outra fonte da mesma região
- **Regiões pequenas não somem**: √n garante ~2% mínimo de representação. Quando cai a 0%, déficit positivo → fetch
- **Regiões grandes são limitadas**: se já domina o reservoir, déficit negativo → não busca mais até consumir

---

## 4. Filtragem Bidirecional

Filtro controla tanto a exibição quanto o download. É a regra de ouro: **download preenche o filtro ativo. Filtro ativo consome do SQLite. O que está fora do filtro dorme no disco.**

| Ação | Download | SQLite | UI |
|------|----------|--------|----|
| Filtra "Brasil" | Só fontes do Brasil | Query filtra região | Só Brasil |
| Remove filtro | Todas as enabled | Query sem filtro | Tudo |
| Busca "Lula" | Pausado | FTS5 query | Resultados FTS5 |
| Limpa busca | Retoma normal | Query padrão | Feed normal |
| Toggle OFF Brasil | Remove da rotação | Itens mantidos | Remove da UI |
| Toggle ON Brasil | Entra no scheduler | Itens antigos disponíveis | Aparece |

### Mudança de filtro

1. Limpa visibleItems
2. Query SQLite com novo filtro → LIMIT 200
3. Interleave → visibleItems (50) + reservoir (150)
4. Scheduler ajusta escopo
5. UI troca instantânea (itens já estão no SQLite)

### Toggle OFF com busca persistente dependente

Se o usuário desliga o Brasil mas tem busca persistente ativa "Lula" com filtro região=Brasil:
- Feed principal: Brasil some
- Download: CONTINUA para fontes brasileiras, alimentando exclusivamente a busca persistente
- Esses itens NÃO entram no feed principal
- Busca persistente tem precedência sobre toggle

---

## 5. Busca Persistente (Smart Bookmarks)

Uma busca salva é um `bookmark_list` com `search_query` preenchida. Todo item que matcha — passado, presente ou futuro — pertence a essa lista automaticamente.

### Schema

```sql
bookmark_list.search_query TEXT         -- NULL = lista manual
bookmark_list.search_active INTEGER     -- 1 = captura automática ligada
```

### Criação

1. Usuário busca "Lula", vê resultados
2. Toca "Salvar busca" → cria `bookmark_list` com `search_query="Lula"`, `search_active=1`
3. Itens atuais do resultado são inseridos em `bookmark_item`
4. Todos são permanentes a partir desse momento

### Captura contínua

1. Download traz item novo → `FeedStore.write(item)` → SQLite
2. Para cada `bookmark_list WHERE search_active = 1`: testa se item matcha (FTS5)
3. Se match → `INSERT INTO bookmark_item`
4. Se a lista for deletada: itens perdem a qualificação de permanentes (via `ON DELETE CASCADE`), voltam a ser temporários (30 dias)

### Feed composto (múltiplas buscas ativas)

Quando várias buscas persistentes estão com `search_active = 1`, o feed é ordenado por scoring. Cada `ActiveSearch` é uma entidade independente (ex: busca "Lula", busca "Bolsonaro", busca "Croácia" com `search_region="countries/croatia"`). O score de um item é **quantas buscas ativas ele matcha simultaneamente**.

Exemplo com 3 buscas ativas: "Lula" (texto), "Bolsonaro" (texto), "Croácia" (região).

```
TIER 1 (score 3): interseção tripla
  Itens da Croácia que mencionam Lula E Bolsonaro
  → matcha as 3 buscas simultaneamente, score máximo

TIER 2 (score 2): interseção dupla
  Itens da Croácia que mencionam Lula (match: Croácia + Lula)
  Itens da Croácia que mencionam Bolsonaro (match: Croácia + Bolsonaro)
  Itens de qualquer região que mencionam Lula E Bolsonaro (match: Lula + Bolsonaro)

TIER 3 (score 1): singular
  Itens que mencionam "Lula" (qualquer região)
  Itens que mencionam "Bolsonaro" (qualquer região)
  Itens da Croácia (qualquer texto)
  → 1 match cada, round-robin entre as buscas

Dentro de cada tier:
  - Tier com termo textual → fetched_at DESC (cronológico)
  - Tier sem termo textual (só região/categoria) → interleave padrão
```

**Match de uma busca contra um item:**
- `search_query` não-nulo → FTS5 match contra `title + excerpt`
- `search_region` não-nulo → `item.region == search_region`
- `search_category` não-nulo → `item.category == search_category`
- Se a busca tem múltiplos campos, TODOS precisam matchar (AND)

---

## 6. Hidratação do Reservoir

### Cold Start (SQLite vazio)

1. `OPMLParser.parseAll()` → SourceRegistry
2. Desabilita países por padrão
3. Scheduler → batch → fetch → SQLite → reservoir → interleave → visibleItems
4. UI: conteúdo aparece progressivamente

### Warm Start (SQLite tem dados)

1. OPMLParser → SourceRegistry
2. Query SQLite com filtro ativo → LIMIT 200 → interleave → visibleItems + reservoir
3. UI: instantâneo, sem skeleton
4. Scheduler roda em background, itens novos entram sem perturbar a UI

### Scroll

1. Reservoir → move 20 pra visibleItems
2. Reservoir baixo? → Scheduler → fetch → SQLite → reservoir
3. Scroll nunca bate no SQLite diretamente

### Busca por termo

1. Pausa scheduler
2. Query FTS5 → resultados vão direto pra visibleItems (sem interleave, ordem = rank)
3. Reservoir esvaziado
4. Ao limpar busca → retoma estado anterior

---

## 7. Manutenção

| Gatilho | Ação |
|---------|------|
| App launch | Expurgo leve: `DELETE ... LIMIT 500` |
| Ingestão (fonte > 50 itens) | FIFO por fonte |
| Background, 1x/semana | VACUUM, REINDEX, expurgo completo |

### Estimativa de storage

- 1500 fontes × ~30 itens médios (30 dias) = 45.000 itens
- ~500 bytes/item = ~22 MB
- FTS5 índice ~30% = ~7 MB
- **Total: ~30 MB** (teórico máximo ~50 MB)

---

## 8. O que NÃO muda

- `RSSFetcher` (actor, FeedKit, 15 concurrent)
- `OPMLParser` (parseAll, dedup, region encoding)
- `FeedSource`, `FeedItem` (models, com `Codable` mantido)
- `Country`, `Region`, `CountryStore` (models)
- `ImageCache`, `ImagePrefetcher`
- `NetworkMonitor`
- Views (CountriesListScreen, CountryDetailScreen, FeedScreen, etc.) — ajustes mínimos de binding
- `PersistenceManager` — removido (substituído pelo SQLite). Sem migração necessária (app ainda não tem usuários).

---

## 9. Arquivos novos

```
feedmine/
  Services/
    FeedStore.swift          // novo, central
    SourceRegistry.swift     // novo, extraído do FeedLoader
    SourceScheduler.swift    // novo
    Reservoir.swift          // novo, extraído do FeedLoader
  Models/
    BookmarkList.swift       // novo, model para bookmark_list
    ActiveSearch.swift       // novo, model para busca persistente ativa
```

### Arquivos modificados

```
feedmine/
  Services/
    FeedLoader.swift         // enxuto, vira ViewModel
    PersistenceManager.swift // removido
  Views/
    FeedScreen.swift         // binding ajustado
    FilterSheetView.swift    // binding ajustado
```

---

## 10. Decisões-chave

| Decisão | Escolha |
|---------|---------|
| Justiça entre regiões | √n (raiz quadrada do nº de fontes) |
| Prioridade de fetch | LRU com cooldown mole (não binário) |
| Memória vs disco | Híbrido: reservoir em RAM, SQLite persistente |
| Retenção | 30 dias + permanente (read + bookmark) |
| Teto por fonte | 50 itens (dentro dos 30 dias) |
| Migração | Fresh start (sem usuários) |
| Busca persistente × toggle | Busca tem precedência |
| Bookmark lists | Lista padrão "Favorites" + listas customizadas + buscas salvas |
| Termo de busca no feed | Pausa download, FTS5 direto |
| Múltiplas buscas ativas | Feed composto com scoring (interseção > parcial > singular) |
