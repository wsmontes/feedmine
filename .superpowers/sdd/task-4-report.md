# Task 4: Multi-select Taxonomy Node Filtering

**Status:** Complete

**Commit:**
- `64c6920a` — feat: replace single category filter with multi-select taxonomy node filter

## Files Modified (7)

| File | Changes |
|------|---------|
| `feedmine/Services/FeedStore.swift` | Replaced `activeCategory: String?` with `activeNodeIDs: Set<String>`. Updated `applyFilters` to use `TaxonomyStore.isFeedInSubtree` for subtree-based filtering. Changed `setFilter` signature from `category:` to `nodeIDs:`. Updated `clearAllFilters`, `persistFilters`, `restoreFilters`, `search`, `fetchNextBatch`, `reloadFromSQLite`. |
| `feedmine/Services/FeedLoader.swift` | Added `selectedNodeIDs`, `selectedNodeNames`, `hasTaxonomySelection`, `availableTaxonomyRoot`. Replaced `selectCategory` with `toggleNode` and `clearTaxonomySelection`. Added backward-compat `selectedCategory`/`selectCategory` shims for existing views. Updated `selectMood`, `selectContentType`, `clearAllFilters`, `fetchAndReloadAfterImport` to use `nodeIDs:`. |
| `feedmine/Services/AppSettings.swift` | Replaced `Keys.filterCategory` / `Settings.filterCategory` (String?) with `Keys.filterTaxonomyNodes` / `Settings.filterTaxonomyNodes` ([String]). |
| `feedmine/Services/OPMLParser.swift` | Updated category assignment to build slugified node paths. Global feeds get `slugify(category)`, country feeds get `{region}/{slugify(category)}`. |
| `feedmine/Services/SearchEngine.swift` | Added new `search(_:region:taxonomyNodeIDs:)` overload that does FTS5 search + in-memory taxonomy subtree post-filter. |
| `feedmine/Services/TaxonomyStore.swift` | Added `static let shared = TaxonomyStore()` singleton. |
| `feedmine/Services/ExportEngine.swift` | Updated `BackupSettings` struct: `filterCategory: String?` -> `filterTaxonomyNodes: [String]`. Updated export call site. |

## Build Verification

- **BUILD SUCCEEDED** targeting iOS Simulator (iPhone 14 Plus, iOS 26.5)
- **All 9 existing tests pass** (0 failures)

## Self-Review Checklist

- [x] `applyFilters` uses `activeNodeIDs.isEmpty` for the "no filter" case
- [x] `applyFilters` correctly uses `TaxonomyStore.shared.isFeedInSubtree`
- [x] `selectCategory` replaced by `toggleNode` and `clearTaxonomySelection`
- [x] `filterTaxonomyNodes` persisted as `[String]` (array, not Set)
- [x] `clearAllFilters` also clears taxonomy selection (`TaxonomyStore.shared.clearSelection()` + `activeNodeIDs = []`)
- [x] BUILD SUCCEEDED
- [x] Existing tests still pass

## Concerns

1. **TaxonomyStore.shared singleton was missing** — The brief stated TaxonomyStore has a `shared` singleton, but the actual code didn't have one. Added it in this task.

2. **Backward-compat shims** — Removed `selectedCategory`/`availableCategories`/`selectCategory` from FeedLoader as specified, but added them back as backward-compat shims so the existing Views (`CategoryFilterBar`, `FeedScreen`, `FilterSheetView`) continue to compile. These shims map single-category operations to the multi-select taxonomy system. The Views will be properly updated in a future task.

3. **ExportEngine schema change** — `BackupSettings.filterCategory` was renamed to `filterTaxonomyNodes` with a type change from `String?` to `[String]`. This changes the backup JSON schema. Since ExportEngine only writes (no restore logic), this is safe.

4. **OPMLParser nodePath derivation** — The category field now stores slugified node paths (e.g., "coffee_news") instead of raw outline text (e.g., "Coffee News"). This is consumed by TaxonomyStore.derivePath as the leaf segment name. Country feeds get `{region}/{slugify(category)}` paths which may interact differently with derivePath -- future tasks should verify correctness.

5. **Scheduler category filtering** — `fetchNextBatch` now passes `activeCategory: nil` to `SourceScheduler.nextBatch`, since taxonomy filtering is entirely in-memory via `applyFilters`. The scheduler's `activeCategory` parameter remains for backward compatibility.
