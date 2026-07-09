# Feedmine — Loop Focus Areas

Correções estruturais de engenharia. Não alteram features existentes.

---

## 1. Decompor FeedStore em módulos menores

**FeedStore.swift** tem 1.496 linhas e acumula ~8 responsabilidades distintas. Extrair:

- `FeedPersistence` — SQLite CRUD, migrations, expurgo
- `FilterManager` — state + persistência de filtros ativos
- `ReadStateManager` — read/unread tracking
- `BookmarkManager` — listas de bookmarks
- `SearchEngine` — FTS5 queries
- `WhatsNewManager` — baseline, carousel logic
- `SourceHealthStore` — health persistence batch

`FeedStore` fica como orquestrador fino que compõe esses objetos.

---

## 2. Batch persistence — eliminar per-item transactions

`persistFetchedItems` faz um `db.write` por item individualmente. Com centenas de items por ciclo de fetch, isso é ordens de magnitude mais lento que necessário.

**Fix:** Uma única transaction com `SAVEPOINT` por item (partial rollback em falha). Manter tracking de `loadedIDs` apenas para items que passaram.

---

## 3. Mover processamento pesado para background actors

Interleave, dedup, `applyFilters` e persistência não precisam rodar no `@MainActor`. Criar actors dedicados ou usar `Task.detached` para essas operações e devolver apenas o resultado final ao main thread.

**Risco atual:** Jank em scroll quando fetch + filter + interleave rodam na main com 800+ sources.

---

## 4. Dependency injection — eliminar singletons

Substituir:
- `AppContext.shared`
- `CircadianEngine.shared`
- `AudioPlayerManager.shared`
- `SessionTracker.shared`

Por instâncias injetadas via `@Environment` ou inicializador. Facilita testabilidade e elimina estado global mutável.

---

## 5. Adicionar testes unitários para lógica core do iOS

Criar target de testes. Cobertura mínima:

- `Reservoir` — seed, append, moveToVisible, interleave fairness
- `SourceScheduler` — nextBatch, estimatedBufferNeeded, cooldown
- `CircadianEngine` — period from hour, palette resolution
- `SourceRegistry` — toggle, isSourceEnabled, O(1) resolution
- `FeedItem` — generateID, isYouTube, isTimeless, audioPlaybackURL

---

## 6. Adicionar `.loop_progress.json` ao `.gitignore`

Arquivo de 93KB de tracking de progresso de geração de OPMLs. Não deveria estar versionado.

---

## 7. Adicionar README.md

Documentar:
- O que é o projeto
- Como buildar (Makefile, project.yml / xcodegen)
- Como rodar o pipeline Python (feedmine-verify, feed_discovery)
- Estrutura de diretórios
- Dependências (FeedKit, GRDB, aiohttp, ddgs)

---

## 8. Extrair OPMLs do repositório para geração at build-time

Manter um formato canônico compacto (JSON de sources por país/categoria) e gerar OPMLs via script no build. Reduz 1.919 arquivos commitados e diffs enormes a cada atualização de conteúdo.

---

## 9. Reduzir complexidade do MomentGreeting

28KB de lógica de saudação sem testes. Opções:

- **Se manter:** adicionar testes para os slot fillers e o candidate selector
- **Simplificar:** template-based com dados JSON em vez de 500+ linhas de Swift procedural

---

## 10. Corrigir UserDefaults como store de filtros persistidos

Filtros, streaks, e configurações usam UserDefaults com chaves string espalhadas pelo código. Consolidar num `struct AppSettings: Codable` único com uma camada fina de persistência. Evita typos em keys e facilita reset/migration.
