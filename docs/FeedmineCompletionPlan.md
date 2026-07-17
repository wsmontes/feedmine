# Feedmine — Plano de Conclusao do App

**Ultima atualizacao:** 2026-07-17  
**Status atual:** primeira vertical do FeedEngine concluida: OPML/pastas -> `catalog.sqlite` derivado -> browse paginado -> busca local.  
**Objetivo deste documento:** listar tudo que ainda falta para o Feedmine virar o app planejado, e como cada parte deve ser feita sem quebrar o comportamento atual.

---

## 1. Estado Atual Confirmado

O Feedmine ainda roda a experiencia principal pelo backend legado:

```text
FeedStore
  -> SourceRegistry
  -> OPMLParser
  -> TaxonomyStore
  -> RSSFetcher
  -> feedmine.sqlite
  -> Reservoir
  -> SwiftUI
```

O novo caminho ja existe, mas ainda nao alimenta a tela principal:

```text
feedmine/Resources/Feeds
  -> scripts/build_catalog.py
  -> feedmine/Resources/FeedEngine/catalog.sqlite
  -> SQLiteCatalogRepository
  -> browse/search paginados
```

Catalogo pre-compilado atual:

| Metrica | Valor |
|---|---:|
| OPMLs | 4.534 |
| fontes unicas | 39.717 |
| nos de catalogo | 8.798 |
| placements editoriais | 57.650 |
| placements duplicados preservados | 17.933 |
| tamanho do `catalog.sqlite` | 34 MB |

Regra central: OPMLs e pastas continuam sendo a fonte de verdade editorial. SQLite e apenas indice derivado.

---

## 2. Principios Para Terminar o App

1. **Nada de big-bang rewrite.** Migrar por verticais pequenas, testaveis e reversiveis.
2. **Cold-start e sagrado.** Launch nao pode compilar OPML, escanear o catalogo inteiro, buscar rede ou materializar todas as fontes.
3. **UI pede paginas, nunca catalogos inteiros.** Qualquer API nova deve aceitar cursor/limit.
4. **SQLite e operacional.** Apagar `catalog.sqlite` deve ser recuperavel a partir dos OPMLs.
5. **Estado do usuario fica fora do catalogo.** Bookmarks, toggles, queries e historico pertencem a `user.sqlite`.
6. **Conteudo operacional fica fora do catalogo.** Itens, ETag, Last-Modified, jobs e cache pertencem a `content.sqlite`.
7. **Compatibilidade antes de remocao.** So remover `FeedStore`/`SourceRegistry`/`TaxonomyStore` depois de paridade medida.
8. **Toda fase precisa de teste e simulador.** Build verde nao basta quando muda fluxo de UI ou startup.

---

## 3. Ordem Correta de Execucao

### Fase 1 — Estabilizar o Legado Antes de Migrar Mais

Objetivo: corrigir bugs conhecidos que podem mascarar regressao da arquitetura nova.

#### 1.1 Reconstruir `nodeToFeedURLs` no cache quente do `TaxonomyStore`

Problema: `TaxonomyStore.loadFromCache()` restaura indices parciais, mas pode deixar queries de subtree vazias.

Como fazer:

- Abrir `feedmine/Services/TaxonomyStore.swift`.
- Ao carregar cache, reconstruir `nodeToFeedURLs` a partir de `feedToNodeID` + `flatIndex`.
- Preferir funcao privada explicita, por exemplo `rebuildNodeToFeedURLs()`.
- Adicionar teste que simula build -> save cache -> clear memory -> load cache -> subtree retorna URLs.

Pronto quando:

- filtros por taxonomia retornam as mesmas fontes no cold e warm path;
- teste unitario cobre o warm-cache path.

#### 1.2 Tornar `flushPendingReservoir()` awaitable

Problema: refresh pode acontecer antes do interleave terminar.

Como fazer:

- Localizar `flushPendingReservoir()` em `FeedStore`.
- Evitar `Task.detached` que retorna antes da mutacao observavel.
- Fazer a funcao aguardar append + refresh ou encapsular os dois em uma operacao actor-isolated.
- Adicionar teste de ordenacao: append pendente deve aparecer antes da proxima refresh.

Pronto quando:

- nao houver corrida entre flush e refresh;
- nenhum item novo desaparece temporariamente por causa de ordering.

#### 1.3 Corrigir bookmark stamping

Problema: `setVisibleItems` passa `bookmarkItemIDs: []`, entao itens podem ser estampados como nao-bookmarked.

Como fazer:

- Manter um set atual de bookmarked item IDs no caminho principal.
- Passar esse set em `item.stamped(readItemIDs:bookmarkItemIDs:)`.
- Garantir que toggle de bookmark atualiza visible items sem reload completo.

Pronto quando:

- item salvo aparece marcado em feed normal, busca e bookmark feed;
- teste cobre reload a partir do banco.

#### 1.4 Suportar aliases `http://` legados sem normalizacao agressiva

Problema: linhas antigas em `feed_item.source_url` podem ficar fora de filtros SQL.

Como fazer:

- Criar funcao de aliases legados separada da identidade do FeedEngine.
- Aplicar apenas em queries sobre dados antigos.
- Nao declarar `http` e `https` equivalentes no catalogo novo.

Pronto quando:

- itens antigos voltam a aparecer em filtros;
- a politica conservadora de identidade do FeedEngine permanece intacta.

---

### Fase 2 — Transformar o Catalogo Pre-compilado em Caminho de Producao

Objetivo: parar de depender do catalogo legado em memoria para navegacao e busca.

#### 2.1 Formalizar o build do catalogo

Como fazer:

- Manter `scripts/build_catalog.py` como ferramenta inicial.
- Adicionar comando no `Makefile`, por exemplo:

```bash
make catalog
```

- Esse comando deve gerar:
  - `feedmine/Resources/FeedEngine/catalog.sqlite`
  - `feedmine/Resources/FeedEngine/catalog-manifest.json`
- Falhar o build se:
  - algum OPML for invalido;
  - houver colisao de `SourceID` ou `CatalogNodeID`;
  - o banco nao abrir;
  - FTS nao retornar resultados esperados de smoke test.

Pronto quando:

- qualquer pessoa consegue regenerar o catalogo com um comando;
- manifesto registra contagens, tamanho, digest e tempo de build.

#### 2.2 Adicionar manifest real de arquivos OPML

Como fazer:

- Criar tabela ou JSON com:
  - caminho relativo;
  - tamanho;
  - mtime;
  - SHA-256 do conteudo;
  - quantidade de sources extraidas;
  - erro, se houver.
- Usar isso para rebuild incremental futuro.

Pronto quando:

- alterar um OPML muda o manifest;
- o app consegue comparar manifest embutido com um manifest local sem escanear tudo no launch.

#### 2.3 Abrir `catalog.sqlite` read-only em producao

Como fazer:

- Criar um `FeedEngineContainer` ou factory pequena.
- No startup:
  - abrir `user.sqlite`;
  - abrir `catalog.sqlite` do bundle read-only;
  - abrir/criar `content.sqlite`;
  - restaurar ultima query;
  - buscar primeira pagina.
- Se o catalogo embutido estiver ausente/corrompido, mostrar erro recuperavel, nao compilar no launch.

Pronto quando:

- runtime nao cria catalogo em Application Support no caminho normal;
- debug diagnostics deixam de ser o unico consumidor do catalogo;
- instrumentacao confirma abertura read-only.

---

### Fase 3 — Migrar Browse/Search Para FeedEngine

Objetivo: a UI de exploracao e busca de fontes deve usar `SQLiteCatalogRepository`.

#### 3.1 Criar adapter/view model de catalogo

Como fazer:

- Criar algo como `CatalogBrowserViewModel`.
- Ele deve depender de `FeedEngineProtocol`, nao de `FeedStore`.
- Estado minimo:
  - pagina atual de nodes/sources;
  - stack de navegacao;
  - cursor;
  - loading/error;
  - texto de busca;
  - filtros.

Pronto quando:

- browse root lista nodes do catalogo sem acessar `SourceRegistry.sources`;
- paginacao funciona com `nextCursor`.

#### 3.2 Migrar tela de Sources/Explore

Como fazer:

- Comecar por uma tela nova ou caminho atras de debug flag.
- Nao alterar timeline ainda.
- Ao tocar numa fonte:
  - carregar `SourceDetails`;
  - mostrar placements;
  - permitir acao "subscribe/enable" apontando para estado do usuario.

Pronto quando:

- usuario consegue navegar por topicos, paises e idiomas;
- busca local responde sem rede;
- memoria nao cresce proporcionalmente ao catalogo total.

#### 3.3 Testar query plans e limites

Como fazer:

- Adicionar testes/diagnosticos que rodam:
  - browse root;
  - browse pais grande;
  - search por termo comum;
  - search com filtro de idioma;
  - load details de fonte com multiplos placements.
- Registrar `EXPLAIN QUERY PLAN` para queries principais.

Pronto quando:

- nenhuma query usa offset;
- nenhuma API retorna colecao ilimitada;
- limites sao respeitados para requests absurdos.

---

### Fase 4 — Separar `user.sqlite`

Objetivo: estado do usuario fica independente do catalogo e sobrevive a rebuilds.

#### 4.1 Definir schema inicial

Tabelas minimas:

```sql
subscription(source_id, created_at, is_enabled, user_title_override)
source_override(source_id, hidden, muted, preferred_language)
saved_query(id, title, query_json, created_at, updated_at)
reading_state(item_id, read_at, surfaced_at)
bookmark_list(id, name, sort_order, created_at)
bookmark_item(list_id, item_id, source_id, saved_at, note)
session_state(key, value_json, updated_at)
```

Como fazer:

- Criar `UserStateRepository` concreto.
- Migrar bookmarks primeiro, porque e um dominio isolado.
- Depois migrar toggles e saved queries.

Pronto quando:

- bookmarks nao dependem de `feedmine.sqlite`;
- source enable/disable usa `SourceID`;
- rebuild do catalogo nao apaga estado do usuario.

#### 4.2 Criar migracao do estado legado

Como fazer:

- Mapear URL legado -> `SourceID` via `catalog_source.key`.
- Para URLs sem match, manter tabela de pendencias/aliases.
- Rodar migracao idempotente.

Pronto quando:

- usuario existente nao perde bookmarks, reads ou disables;
- migracao pode ser repetida sem duplicar dados.

---

### Fase 5 — Separar `content.sqlite` e Timeline

Objetivo: itens e fetch state devem sair do `FeedStore` monolitico.

#### 5.1 Criar schema operacional

Tabelas minimas:

```sql
feed_item(
  id TEXT PRIMARY KEY,
  source_id INTEGER,
  title TEXT,
  excerpt TEXT,
  url TEXT,
  published_at INTEGER,
  image_url TEXT,
  audio_url TEXT,
  media_kind TEXT,
  language TEXT,
  searchable_text TEXT
)

source_fetch_state(
  source_id INTEGER PRIMARY KEY,
  request_url TEXT,
  etag TEXT,
  last_modified TEXT,
  last_fetch_at INTEGER,
  consecutive_failures INTEGER,
  next_fetch_after INTEGER
)

fetch_job(
  id INTEGER PRIMARY KEY,
  source_id INTEGER,
  priority INTEGER,
  status TEXT,
  created_at INTEGER,
  updated_at INTEGER
)
```

Como fazer:

- Criar `ContentRepository`.
- Persistir `source_id` junto dos itens novos.
- Manter compatibilidade temporaria com `source_url` legado.
- Adicionar FTS para item search depois da paridade basica.

Pronto quando:

- primeira pagina da timeline vem de query paginada;
- itens novos gravam `source_id`;
- fetch state nao fica preso a dictionaries em memoria.

#### 5.2 Implementar `TimelineRepository`

Como fazer:

- Implementar `loadTimeline(query:cursor:limit:)`.
- Cursor deve ser keyset: `(published_at, item_id)`.
- Resolver scopes em SQL:
  - all enabled;
  - source IDs;
  - catalog node subtree;
  - search text;
  - media/language filters.

Pronto quando:

- timeline nao precisa expandir node -> milhares de URLs em Swift;
- scroll infinito usa cursor;
- reload nao materializa tudo.

#### 5.3 Migrar Reservoir para working-set policy

Como fazer:

- Manter Reservoir como politica de apresentacao, nao como armazenamento primario.
- Entrada vem de `TimelineRepository`.
- Saida e pagina pequena de `TimelineItemSummary` ou `FeedItem` adaptado.

Pronto quando:

- Reservoir pode ser limpo sem perder conteudo persistido;
- feed renderiza primeira pagina sem fetch de rede.

---

### Fase 6 — Fetch/Ingestion Fora do MainActor

Objetivo: rede, parse e persistencia nao podem bloquear UI.

#### 6.1 Criar `FeedFetcher` real

Como fazer:

- Extrair logica de `RSSFetcher` para protocolo novo.
- Receber `SourceID` + request URL.
- Retornar payload e metadados HTTP.
- Respeitar ETag, Last-Modified, timeout e cancelamento.

Pronto quando:

- fetch pode rodar em actor/background;
- erros sao persistidos em `content.sqlite`.

#### 6.2 Criar `FeedIngestion` real

Como fazer:

- Parsear RSS/Atom/Podcast/YouTube.
- Normalizar item IDs.
- Deduplicar por item ID/canonical URL.
- Persistir em batch.

Pronto quando:

- ingestao de lote nao toca SwiftUI;
- testes cobrem feeds reais pequenos como fixtures.

#### 6.3 Scheduler incremental

Como fazer:

- Trocar dictionaries por queries em `source_fetch_state`.
- Priorizar:
  - fontes visiveis/assinadas;
  - fontes stale;
  - fontes com baixa falha;
  - refresh manual.

Pronto quando:

- refresh de background nao tenta varrer universo inteiro;
- prioridades sao explicaveis e testadas.

---

### Fase 7 — Cold-start Final em Fases

Objetivo: launch deve chegar rapido em conteudo util.

Fluxo alvo:

```text
process started
  -> open user.sqlite
  -> open bundled catalog.sqlite read-only
  -> open content.sqlite
  -> restore last session/query
  -> load first timeline page
  -> render UI
  -> start deferred maintenance
```

Deferred:

- verificar manifest de OPML;
- rebuild incremental;
- refresh feeds;
- imagens;
- traducao;
- diagnosticos;
- limpeza de cache.

Como fazer:

- Criar `AppStartupCoordinator`.
- Separar fase critical de deferred.
- Usar signposts ja existentes:
  - process started;
  - backend start;
  - first screen;
  - first useful content;
  - memory milestones.

Pronto quando:

- cold-start nao chama `OPMLParser.parseAll()`;
- primeira tela nao depende de rede;
- first useful content vem do cache local;
- metricas mostram tempos por fase.

---

### Fase 8 — Remover Dependencias Legadas

Objetivo: reduzir `FeedStore` ate virar apenas adapter temporario ou desaparecer.

Ordem segura:

1. Browse/search sai de `SourceRegistry`.
2. Timeline sai do reservoir legado.
3. Bookmarks saem de `feedmine.sqlite`.
4. Fetch state sai de dictionaries.
5. Taxonomy filtering deixa de expandir URL sets.
6. `OPMLParser.parseAll()` sai do startup.
7. `SourceRegistry` vira bridge de migracao e depois e removido.
8. `TaxonomyStore` vira bridge de UI antiga e depois e removido.

Pronto quando:

- o app abre sem materializar `registry.sources`;
- filtros trabalham com `SourceID`/`CatalogNodeID`;
- `FeedStore` nao concentra banco, rede, UI state e taxonomia.

---

### Fase 9 — Produto e UX

Objetivo: fazer o app ser entendivel e usavel por terceiros.

#### 9.1 Onboarding

Como fazer:

- Explicar que Feedmine e offline-first e baseado em fontes.
- Pedir primeiras escolhas:
  - temas;
  - paises;
  - idiomas;
  - podcasts/videos/forums.
- Salvar como `user.sqlite` subscriptions/queries.

Pronto quando:

- primeiro uso nao mostra vazio confuso;
- usuario entende como adicionar/importar fontes.

#### 9.2 Dark mode e acessibilidade

Como fazer:

- Revisar tokens em `DesignTokens`.
- Garantir contraste em cards, headers, debug bar e sheets.
- Testar Dynamic Type.

Pronto quando:

- app fica legivel em light/dark;
- botoes e textos nao sobrepoem em tamanhos grandes.

#### 9.3 Explore/Search de catalogo

Como fazer:

- Expor browse por:
  - Topicos;
  - Paises;
  - Idiomas;
  - Midia.
- Busca com filtros.
- Detalhe da fonte com placements e estado de assinatura.

Pronto quando:

- catalogo deixa de ser invisivel;
- usuario consegue descobrir e ativar fontes sem editar OPML.

---

### Fase 10 — Qualidade, CI e Publicacao

Objetivo: conseguir manter e publicar o app com seguranca.

#### 10.1 CI

Como fazer:

- GitHub Actions:
  - `scripts/build_catalog.py`;
  - `xcodebuild build`;
  - `xcodebuild test -only-testing:feedmineTests`;
  - smoke test do SQLite.

Pronto quando:

- PR quebrado nao entra sem build/test.

#### 10.2 Testes de performance

Como fazer:

- Criar suite manual ou automatizada para:
  - cold-start;
  - warm-start;
  - browse root;
  - search comum;
  - primeira timeline;
  - scroll 100 items;
  - memoria apos 5 minutos.

Pronto quando:

- baseline existe em device fisico;
- regressao relevante e visivel.

#### 10.3 Crash/reporting e logs

Como fazer:

- Padronizar OSLog.
- Definir o que pode ir para analytics sem expor conteudo do usuario.
- Adicionar crash reporting somente depois da politica de privacidade.

Pronto quando:

- crashes de beta sao acionaveis;
- logs nao vazam URLs privadas/importadas.

#### 10.4 App Store

Como fazer:

- Preparar:
  - icones finais;
  - screenshots;
  - descricao;
  - privacy nutrition labels;
  - termos/politica;
  - TestFlight.

Pronto quando:

- build de release instala;
- app passa checklist de privacidade;
- TestFlight tem roteiro de teste.

---

## 4. Checklist Global de Pronto

O Feedmine pode ser considerado concluido quando:

- [ ] launch nao parseia OPML nem compila catalogo;
- [ ] `catalog.sqlite` abre read-only no caminho principal;
- [ ] browse/search usam FeedEngine;
- [ ] timeline carrega primeira pagina de `content.sqlite`;
- [ ] rede roda apenas depois da primeira tela util;
- [ ] bookmarks e preferencias estao em `user.sqlite`;
- [ ] itens e fetch state estao em `content.sqlite`;
- [ ] filtros usam IDs numericos, nao URL sets gigantes;
- [ ] app nao materializa o catalogo inteiro em Swift;
- [ ] legacy bugs criticos estao corrigidos;
- [ ] testes unitarios e de integracao cobrem repositories principais;
- [ ] simulador passa em build/test/smoke launch;
- [ ] baseline em device fisico existe;
- [ ] onboarding, dark mode e acessibilidade basica estao prontos;
- [ ] CI roda catalog build + Xcode build + tests;
- [ ] TestFlight esta pronto.

---

## 5. O Que Nao Fazer

- Nao migrar timeline, bookmarks, fetch e UI inteira no mesmo PR.
- Nao transformar SQLite em fonte de verdade editorial.
- Nao normalizar agressivamente URLs para resolver bugs legados.
- Nao criar bitmap/mmap/custom database antes de medir necessidade real.
- Nao remover `FeedStore` antes de existir paridade testada.
- Nao colocar rebuild incremental no caminho critico do launch.
- Nao adicionar features visuais grandes enquanto o startup ainda depende do legado.

---

## 6. Proxima Sequencia Recomendada

1. Corrigir os quatro bugs legados da Fase 1.
2. Adicionar `make catalog` e smoke test do catalogo.
3. Criar factory runtime do FeedEngine abrindo o bundle read-only.
4. Criar `CatalogBrowserViewModel`.
5. Migrar uma tela de browse/search atras de debug flag.
6. Criar `user.sqlite` e migrar bookmarks.
7. Criar `content.sqlite` e implementar primeira pagina de timeline.
8. Tirar `OPMLParser.parseAll()` do cold-start.
9. Rodar baseline em device fisico.
10. So entao remover partes legadas.

