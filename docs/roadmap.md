# Feedmine — Roadmap de Pendências

Organizado em ondas sequenciais. Cada onda desbloqueia a próxima.

---

## Onda 1: Estabilidade

> Fazer o que tem funcionar direito.

| # | Item | Detalhe |
|---|------|---------|
| 1.1 | shakeToRefresh batch UPDATE | Usar `WHERE id IN (...)` em vez de loop per-item |
| 1.2 | Region filter no applyFilters | Items de região errada podem vazar — adicionar check in-memory |
| 1.3 | MoodFilter word boundaries | "AI" matcha "said" — usar `\b` regex ou NLTagger |
| 1.4 | ImageCache callers → async | `image(for:)` deprecated mas ainda chamado — migrar para `diskImage(for:)` |
| 1.5 | Testes filter system | Debounce, race conditions, combinações de filtros |

**Esforço estimado:** ~4-6h  
**Impacto:** App funciona corretamente em todos os cenários.

---

## Onda 2: Habilitação de Uso

> O que um usuário precisa para usar o app no dia a dia.

| # | Item | Detalhe |
|---|------|---------|
| 2.1 | Canais de importação | Pipeline pronto. Implementar: paste URL, share sheet, URL scheme |
| 2.2 | Dark mode | Palettes só claras. Adicionar variantes escuras ou forçar `.preferredColorScheme(.light)` |
| 2.3 | Onboarding | Primeiro uso com 101 países OFF sem explicação. Guiar o user |

**Esforço estimado:** ~8-12h  
**Impacto:** App viável para uso real por terceiros.

---

## Onda 3: Qualidade de Código

> Facilitar todo trabalho futuro.

| # | Item | Detalhe |
|---|------|---------|
| 3.1 | Decompor FeedStore | Extrair BookmarkStore, SearchEngine, WhatsNewManager (~800 linhas) |
| 3.2 | Dependency injection | Eliminar AppContext.shared, SessionTracker.shared, AudioPlayerManager.shared |
| 3.3 | ImportPipeline tests | Probe, media detection, OPML parse — nova feature sem cobertura |
| 3.4 | print() → OSLog completo | Padrão estabelecido, migrar os ~90% restantes |

**Esforço estimado:** ~12-16h  
**Impacto:** Velocidade de desenvolvimento 2× depois.

---

## Onda 4: Polimento

> Experiência premium.

| # | Item | Detalhe |
|---|------|---------|
| 4.1 | iCloud sync | Bookmarks e imports perdidos na troca de device |
| 4.2 | Export enriquecido | Exportar mediaKind, região, estado enabled/disabled |
| 4.3 | UserDefaults consolidação | AppSettings.swift existe mas chaves não foram migradas |
| 4.4 | MomentGreeting simplificação | 28KB sem cobertura — simplificar ou testar completamente |
| 4.5 | Background actors completo | `interleave()` e `persistFetchedItems` ainda no MainActor |

**Esforço estimado:** ~16-20h  
**Impacto:** Experiência de app premium, pronto para publicação.

---

## Onda 5: Profissionalização

> Publicação e manutenção sustentável.

| # | Item | Detalhe |
|---|------|---------|
| 5.1 | CI/CD | GitHub Actions — build + test automático |
| 5.2 | SwiftLint | Consistência de código enforced |
| 5.3 | Crash reporting | Sentry ou Crashlytics |
| 5.4 | Analytics | Saber quais features são usadas |
| 5.5 | App Store prep | Screenshots, description, ASO, metadata |
| 5.6 | Testes restantes | FeedStore integration, MomentGreeting slots |

**Esforço estimado:** ~20h  
**Impacto:** App publicável e mantível a longo prazo.

---

## Estado das Ondas

```
Onda 1 (bugs)     [ ] não iniciada
Onda 2 (features) [ ] não iniciada
Onda 3 (arch)     [ ] não iniciada
Onda 4 (polish)   [ ] não iniciada
Onda 5 (ship)     [ ] não iniciada
```

---

## Decisões Arquiteturais

- **OPMLs ficam no repo como source of truth.** Parse cache resolve performance.
- **Import pipeline centralizado.** Todo canal novo (paste, share, drag) é apenas UI → `FeedLoader.importFeeds()`.
- **Filtros operam em duas camadas.** SQL (pré-filter eficiente) + applyFilters in-memory (safety gate).
- **Reservoir é filter-agnostic.** Armazena tudo; barreira de filtros é na saída (visibleItems).
- **Concurrency model:** @MainActor para state, actors para I/O (fetcher, prefetcher, import pipeline).
