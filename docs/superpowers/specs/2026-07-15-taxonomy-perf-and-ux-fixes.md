# Taxonomy Performance & UX Fixes — Design Spec

**Date:** 2026-07-15
**Status:** Draft
**Follows:** `2026-07-15-feed-taxonomy-design.md`

---

## 1. Context

The taxonomy system shipped (design spec `2026-07-15-feed-taxonomy-design.md`) but four structural problems emerged at real scale — 18,145 OPML files, ~7,500 sources, 39 languages, thousands of taxonomy nodes:

| Problem | Root Cause | Impact |
|---------|-----------|--------|
| Menu freezes (15s clicks) | Recursive `DisclosureGroup` in `TaxonomyTreeView` — SwiftUI evaluates body of all nodes even collapsed | Unusable filter UI |
| Filter shows no content | SQL query uses `LIMIT 200` without taxonomy filtering; scheduler ignores taxonomy selection | Empty feed after filter |
| ChipBar wastes space | Always visible, shows "All" when nothing selected | ~56px of dead space |
| Language is invisible | Parsed and stored but never used — no filter UI, no SQL filter, no scheduler awareness | 39 languages of content, zero user control |

### Design Principles (from user)

1. **The feed is sacred.** The screen never changes on its own — only by user action. Items appear below the fold as they arrive; never reorder or scroll-jump.
2. **Database is the source of truth.** Filter = query change, not a fetch. Show everything matching immediately, regardless of age or read status.
3. **Disney Fast Pass.** When user selects a filter, those sources jump the queue — stop background work, fetch them urgently, return to normal after.
4. **Ferrari outside, tank inside.** UI must be smooth and responsive at all times. Heavy work happens invisibly.
5. **No filter = no work.** Deselect everything and the app stops fetching.
6. **Empty states explain.** Never show a blank screen with a refresh button. Explain what's happening or why nothing was found.

---

## 2. Part 1: SQL-Level Taxonomy Filter + Scheduler Priority

### 2.1 Filter Flow (User Action → Screen Update)

```
User taps checkbox for "Coffee & Tea" (node ID: "coffee-tea")
  │
  ▼
FeedLoader.toggleNode("coffee-tea")
  │
  ▼
TaxonomyStore.toggle("coffee-tea")          // updates selectedNodeIDs
  │
  ▼
FeedStore.setFilter(nodeIDs: {"coffee-tea"}, ...)
  │
  ├─▶ cachedTaxonomyFeedURLs = feedURLs(inSubtreesOf: {"coffee-tea"})
  │   // Pre-computed Set<String> of all source URLs in that subtree.
  │   // O(n) single pass over feedToNodeID, cached until selection changes.
  │
  ├─▶ applyUpdate(.flush)
  │     │
  │     ├─▶ Cancel progressiveFetch + background refresh
  │     │
  │     ├─▶ reloadFromSQLite(taxonomyURLs: cachedTaxonomyFeedURLs)
  │     │     │
  │     │     ├─▶ SQL: SELECT ... FROM feed_item
  │     │     │       WHERE fetched_at > 30d_cutoff
  │     │     │       AND is_read = 0
  │     │     │       AND source_url IN (?, ?, ...)    ← NEW: taxonomy filter in SQL
  │     │     │       ORDER BY published_at DESC
  │     │     │       -- NO LIMIT when taxonomy active ← NEW
  │     │     │
  │     │     ├─▶ Reservoir.seed(items: result)         // pre-filtered, no applyFilters needed
  │     │     └─▶ visibleItems = reservoir.visibleItems  // appears on screen instantly
  │     │
  │     └─▶ fetchNextBatch(prioritySourceURLs: cachedTaxonomyFeedURLs)
  │           │
  │           └─▶ Scheduler: priority URLs jump to front
  │               Remaining slots filled by normal entropy algorithm
  │
  └─▶ New items arrive → throttledReservoirAppend → reservoir grows
      visibleItems unchanged (feed is sacred)
      User scrolls → loadMoreIfNeeded → new items appear below fold
```

### 2.2 SQL Query Change

**Before (current — broken):**
```swift
var request = FeedItemRecord
    .filter(Column("fetched_at") > Self.thirtyDayCutoffEpoch)
    .filter(Column("is_read") == 0)
    // NO taxonomy filter — LIMIT 200 hits wrong items
    .order(Column("published_at").desc)
    .limit(200)
```

**After (fixed):**
```swift
let taxonomyURLs = activeNodeIDs.isEmpty ? nil : cachedTaxonomyFeedURLs

if let urls = taxonomyURLs, !urls.isEmpty {
    // Taxonomy active: filter by source_url IN (...).
    // IN clause is batched for nodes with >999 feeds (SQLite parameter limit).
    // No LIMIT — user wants ALL content from selected categories.
    let batches = Array(urls).chunked(into: 999)
    var allItems: [FeedItemRecord] = []
    for batch in batches {
        let placeholders = batch.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT * FROM feed_item
            WHERE fetched_at > ?
              AND is_read = 0
              AND source_url IN (\(placeholders))
            ORDER BY published_at DESC
        """
        let batchItems = try db.execute(sql: sql, arguments: [cutoff] + batch)
        allItems.append(contentsOf: batchItems)
    }
    items = allItems
} else {
    // No taxonomy filter: current behavior with LIMIT 200
    items = try request.limit(200).fetchAll(db)
}
```

**Index**: `idx_item_source_pub` already exists on `(source_url, published_at)` — this query uses it efficiently.

**Performance**: For a typical subcategory with ~50 feeds, the IN clause has 50 parameters — well within limits. For large nodes like "Countries" (~3,200 feeds), 4 batches of 999 each. Each batch hits the composite index. Estimated: <20ms for 50 feeds, <100ms for 3,200 feeds cold.

### 2.3 Scheduler Changes

**New parameter:**
```swift
func nextBatch(
    reservoir: [FeedItem],
    sourcesByRegion: [String: [FeedSource]],
    activeRegion: String?,
    activeContentType: String?,
    prioritySourceURLs: Set<String> = []   // NEW
) -> [FeedSource]
```

**Logic change — prepend priority sources:**
```swift
var selected: [FeedSource] = []
var selectedURLs = Set<String>()

// Phase 1: Priority sources jump the queue (Disney Fast Pass)
if !prioritySourceURLs.isEmpty {
    for region in regions {
        guard let sources = sourcesByRegion[region] else { continue }
        for source in sources {
            guard prioritySourceURLs.contains(source.url) else { continue }
            guard selectedURLs.insert(source.url).inserted else { continue }
            // Clear cooldown — treat as never-fetched so it runs immediately
            lastFetchedAt.removeValue(forKey: source.url)
            consecutiveFailures.removeValue(forKey: source.url)
            selected.append(source)
        }
    }
}

// Phase 2: Fill remaining slots with normal entropy algorithm
let remaining = maxSelect - selected.count
if remaining > 0 {
    // ... existing scoring/sorting logic, excluding already-selected URLs
}
```

### 2.4 Fetch Pipeline Changes

**When taxonomy filter is active:**
- `progressiveFetch()` is cancelled (its 200-source budget is wasteful when user wants 4 categories)
- `backgroundRefresh` is paused temporarily
- A NEW `urgentTaxonomyFetch` races to fetch the priority sources
- After urgent fetch completes, background refresh resumes

**New method in FeedStore:**
```swift
private func fetchUrgentTaxonomyBatch(sourceURLs: Set<String>) async {
    let sources = registry.enabledSources.filter { sourceURLs.contains($0.url) }
    guard !sources.isEmpty else { return }
    // Fetch all matching sources concurrently (up to 15 at a time)
    let result = await fetcher.fetchAll(sources, maxConcurrent: 15)
    // Normal pipeline: persist → reservoir → surface on scroll
    let actualNew = await persistFetchedItems(result.items)
    throttledReservoirAppend(actualNew)
    collectWhatsNewCandidates(actualNew)
    prefetchImagesIfEnabled(for: actualNew)
}
```

### 2.5 "No Filter = No Work"

When `selectedNodeIDs` is empty AND no region/content-type/mood filter is active, AND all sources are disabled (user turned off Global + all Countries):

- `registry.enabledSources` returns `[]`
- `fetchNextBatch()` guard: `guard !registry.enabledSources.isEmpty else { return }` — already exists
- `progressiveFetch()`: same guard — already exists
- `startBackgroundRefresh()`: same guard — already exists
- UI shows the "No Sources Enabled" empty state (see Part 3)

---

## 3. Part 2: Replace Recursive Tree with NavigationStack Drill-Down

### 3.1 Problem

`TaxonomyTreeView` (file: `Views/TaxonomyTreeView.swift`) uses recursive `DisclosureGroup`:

```swift
DisclosureGroup {
    ForEach(children) { child in
        TaxonomyTreeRow(node: child, ...)  // recursive — each has its own DisclosureGroup
    }
}
```

SwiftUI evaluates the body of every `DisclosureGroup` in the hierarchy, even collapsed ones. With ~5,000+ taxonomy nodes, expanding any level triggers a cascade of body evaluations. This is a known SwiftUI limitation — recursive `DisclosureGroup` does not benefit from `List` cell reuse.

### 3.2 Solution

`TaxonomyBrowseView` (file: `Views/TaxonomyBrowseView.swift`) already implements the correct pattern: `NavigationStack` with `NavigationLink` for each level. Each level is a flat `List` with proper `UITableView` cell reuse.

**Change required**: The `FilterSheetView` currently embeds `TaxonomyTreeView()` directly inside the sheet. Replace it with a `NavigationLink` to `TaxonomyBrowseView()`.

**Before (FilterSheetView, line ~59-67):**
```swift
Section("Topics") {
    TaxonomyTreeView()   // ← recursive DisclosureGroup inside sheet — broken

    NavigationLink {
        TaxonomyBrowseView()
    } label: {
        Label("Browse All Topics", systemImage: "list.bullet.rectangle")
    }
}
```

**After:**
```swift
Section("Topics") {
    NavigationLink {
        TaxonomyBrowseView()
    } label: {
        HStack {
            Label("Browse Topics", systemImage: "list.bullet.rectangle")
            Spacer()
            if !loader.selectedNodeNames.isEmpty {
                Text(loader.selectedNodeNames.prefix(3).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
```

### 3.3 What to Keep, What to Remove

| Keep | Remove |
|------|--------|
| `TaxonomyBrowseView.swift` | `TaxonomyTreeView.swift` (the recursive DisclosureGroup view) |
| `TaxonomyLevelView` (already correct) | Reference in `FilterSheetView` |
| Search functionality in `TaxonomyBrowseView` (add it there) | |

The search bar currently in `TaxonomyTreeView` should be moved to `TaxonomyBrowseView` as the first element of the root `TaxonomyLevelView`.

### 3.4 TaxonomyBrowseView Enhancement

Add a search bar to the root level that filters the flat index and shows results in a flat list — same behavior as current `TaxonomyTreeView` search, but inside the `NavigationStack`. Tapping a search result selects the node and navigates to its parent level.

---

## 4. Part 3: Conditional ChipBar + Empty States

### 4.1 ChipBar Visibility

**Rule**: The `TaxonomyChipBar` is only visible when at least one filter is active.

```swift
// FeedScreen.swift — compactHeader
var body: some View {
    VStack(spacing: 0) {
        // ... header row ...
        
        // Show chip bar only when there's something to show
        if loader.hasActiveFilters {
            TaxonomyChipBar { showFilters = true }
        }
        
        // Active filter banner
        if loader.hasActiveFilters {
            filterActiveBanner
        }
    }
}
```

`hasActiveFilters` = `hasTaxonomySelection || selectedMood != .all || selectedContentType != .all`

When no filter is active, the ChipBar and banner disappear completely, reclaiming ~56px + ~28px = ~84px of vertical space.

### 4.2 ChipBar "All" Behavior

**Current**: Shows "All" chip always.
**New**: "All" chip only appears when other chips are present (as a quick-reset option). When nothing is selected, the ChipBar itself is hidden, so "All" is implicit.

### 4.3 Empty States

Three states replace the current generic `ContentUnavailableView`:

#### State A: Content Found, Loading First Items

Shown for <1 second after filter, while SQL query runs. In practice this flashes so briefly it may not be visible. No dedicated UI needed — the existing loading state covers it.

#### State B: "Fetching from Sources"

Shown when the database has NO items for the selected taxonomy, but sources are being fetched:

```
┌──────────────────────────────────────────┐
│                                          │
│                 🔍                       │
│        Searching for {topic}...          │
│                                          │
│     We're fetching the latest articles   │
│     from {N} sources. They'll appear     │
│     here as they arrive.                 │
│                                          │
│     ⚡ Fetched {M} of {N} sources...     │
│                                          │
└──────────────────────────────────────────┘
```

- `{topic}` = comma-joined `selectedNodeNames`
- `{N}` = count of `cachedTaxonomyFeedURLs`
- `{M}` = running count, updated as fetches complete
- This view is replaced by real content the moment the first item arrives
- No refresh button — the work is already happening

#### State C: "Nothing Found" (after fetch completes with zero results)

```
┌──────────────────────────────────────────┐
│                                          │
│                 📭                       │
│      No articles found for {topic}       │
│                                          │
│     These sources may not have           │
│     published recently. Try a            │
│     different topic or check back        │
│     later.                               │
│                                          │
└──────────────────────────────────────────┘
```

No refresh button. Pull-to-refresh still works if user wants to force-retry (pre-existing behavior).

#### State D: "No Sources Enabled"

When all sources are disabled (no region, no country, no global feeds checked):

```
┌──────────────────────────────────────────┐
│                                          │
│                 🌍                       │
│        No sources enabled                │
│                                          │
│     Enable some countries or topics      │
│     in Filters to start seeing content.  │
│                                          │
│           [ Open Filters ]               │
│                                          │
└──────────────────────────────────────────┘
```

The "Open Filters" button is the only CTA button in any empty state — it navigates, doesn't refresh.

### 4.4 Implementation

New view: `Views/FeedEmptyStateView.swift` (replaces/extends existing). The existing `FeedEmptyStateView` already handles the global empty case; extend it to accept a mode enum:

```swift
enum FeedEmptyMode {
    case noSourcesEnabled       // nothing enabled at all
    case fetching(topic: String, fetched: Int, total: Int)  // actively fetching
    case noResults(topic: String)  // fetch completed, nothing found
    case generic                // fallback
}
```

---

## 5. Part 4: Language Filtering (Levels A + B + C)

### 5.1 Current State (Gap Analysis)

Language is parsed from OPML (`<head><language>` and `<outline language="...">`) with proper inheritance (outline → parent → file-level → nil). It's stored on `FeedSource.language` and `TaxonomyNode.language`. But it is **completely invisible** to the user and has **zero effect** on any pipeline:

| Layer | Status |
|-------|--------|
| OPML parsing | ✅ parsed with inheritance |
| `FeedSource.language` | ✅ stored |
| `TaxonomyNode.language` | ✅ stored |
| `feed_item` table | ❌ no language column |
| `applyFilters` | ❌ no language filter |
| SQL query | ❌ no language filter |
| `FilterSheetView` | ❌ no language section |
| `TaxonomyBrowseView` | ❌ no language badge on nodes |
| `TaxonomyChipBar` | ❌ no language chips |
| `FeedScreen` | ❌ no language indicator |
| `SourceScheduler` | ❌ no language prioritization |
| UI strings | ❌ hardcoded English only |

### 5.2 Level A: Basic Language Filter

#### 5.2.1 Database Migration v7

```sql
ALTER TABLE feed_item ADD COLUMN language TEXT;
CREATE INDEX idx_item_language ON feed_item(language);
```

The column is nullable — historical items without language remain `NULL`.

#### 5.2.2 Populate at Insert Time

`FeedItemRecord.init(from:region:)` already has access to the `FeedSource` via `SourceRegistry`. Add language lookup:

```swift
// In FeedItemRecord.init
init(from item: FeedItem, region: String, language: String?) {
    // ... existing fields ...
    self.language = language  // ISO 639-1 code or nil
}
```

`persistFetchedItems` already resolves the region via `registry.regionFor(sourceURL:)`; add a parallel language resolution:

```swift
let itemsWithRegions: [(item: FeedItem, region: String, language: String?)] = actualNew.map { item in
    let resolvedRegion = regionOverride ?? registry.regionFor(sourceURL: item.sourceURL)
    let resolvedLanguage = registry.languageFor(sourceURL: item.sourceURL)
    return (item, resolvedRegion, resolvedLanguage)
}
```

#### 5.2.3 Filter State

Add to `FeedStore`:

```swift
var activeLanguages: Set<String> = []
```

Add to `FeedLoader`:

```swift
var selectedLanguages: Set<String> { store.activeLanguages }
var hasLanguageSelection: Bool { !store.activeLanguages.isEmpty }
```

#### 5.2.4 applyFilters

```swift
private func applyFilters(_ items: [FeedItem]) -> [FeedItem] {
    let region = activeRegion
    let contentType = filterContentType
    let languages = activeLanguages
    let contentFilters = ContentFilterStore.shared.isEnabled
        ? ContentFilterStore.shared.activeFilters : []
    return items.filter { item in
        isItemEnabled(item)
        && (region == nil || item.region == region || item.region.hasPrefix(region! + "/"))
        && (cachedTaxonomyFeedURLs.isEmpty || cachedTaxonomyFeedURLs.contains(item.sourceURL))
        && (languages.isEmpty || item.language.map { languages.contains($0) } ?? false)
        && contentType(item)
        && !contentFilterExcludes(item, filters: contentFilters)
    }
}
```

Note: items with `language == nil` are **excluded** when a language filter is active. If the user selects "English", content without a declared language is hidden. This is intentional — language filtering is an opt-in precision tool.

#### 5.2.5 SQL Query

Add to the `reloadFromSQLite` query:

```swift
if !activeLanguages.isEmpty {
    let placeholders = activeLanguages.map { _ in "?" }.joined(separator: ",")
    request = request.filter(
        sql: "language IN (\(placeholders))",
        arguments: StatementArguments(activeLanguages.map { $0 as String? })
    )
}
```

#### 5.2.6 UI: Language Section in FilterSheetView

New section in `FilterSheetView`:

```swift
Section("Language") {
    ForEach(loader.availableLanguages, id: \.code) { lang in
        Button { loader.toggleLanguage(lang.code) } label: {
            HStack {
                Label("\(lang.flag) \(lang.name)", systemImage: "")
                Spacer()
                if loader.selectedLanguages.contains(lang.code) {
                    Image(systemName: "checkmark").foregroundStyle(.blue)
                }
                Text("\(lang.feedCount)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
```

`availableLanguages` is computed from `SourceRegistry`:

```swift
struct LanguageInfo {
    let code: String       // "pt", "en", "ja"
    let name: String       // "Português", "English", "日本語"
    let flag: String       // "🇧🇷", "🇺🇸", "🇯🇵"
    let feedCount: Int     // number of sources with this language
}

var availableLanguages: [LanguageInfo] {
    let grouped = Dictionary(grouping: registry.sources, by: \.language)
    return grouped.compactMap { code, sources -> LanguageInfo? in
        guard let code else { return nil }
        return LanguageInfo(
            code: code,
            name: Locale.current.localizedString(forLanguageCode: code) ?? code,
            flag: flagEmoji(for: code),
            feedCount: sources.count
        )
    }.sorted { $0.feedCount > $1.feedCount }
}
```

### 5.3 Level B: Language Awareness in Tree

#### 5.3.1 Language Badge on Taxonomy Nodes

Each node in `TaxonomyBrowseView` shows its language as a subtle badge:

```swift
// In TaxonomyLevelView row
HStack {
    Image(systemName: store.selectedNodeIDs.contains(node.id)
          ? "checkmark.circle.fill" : "circle")
    Text(node.name)
    if let lang = node.language {
        Text(lang.uppercased())
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }
    Spacer()
    Text("\(node.feedCount)")
        .font(.caption).foregroundStyle(.secondary)
}
```

#### 5.3.2 Language Chip in ChipBar

When a language filter is active, it appears as a chip alongside taxonomy chips:

```
[Coffee ×] [Brazil ×] [🇧🇷 pt ×] [+1] ✎
```

Same behavior: tap `×` to deselect, tap chip body to open filters.

#### 5.3.3 Auto-Detect for nil-Language Feeds

For feeds whose OPML didn't declare a language, use `NLLanguageRecognizer` as a fallback. The code skeleton already exists in `logNonEnglishItems` — extract and generalize it:

```swift
// New utility in SourceRegistry or a dedicated LanguageDetector
nonisolated static func detectLanguage(title: String, excerpt: String) -> String? {
    let text = "\(title) \(excerpt)".trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.count >= 12 else { return nil }
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    guard let lang = recognizer.dominantLanguage else { return nil }
    return lang.rawValue  // ISO 639-1
}
```

Called at persist time for items where `FeedSource.language` is nil. The detected language is stored in `feed_item.language` but does NOT overwrite `FeedSource.language` (the OPML declaration remains authoritative).

```
Priority chain: OPML <outline> attr → OPML <head> → NLLanguageRecognizer → nil
```

### 5.4 Level C: Smart Default + Scheduler Priority

#### 5.4.1 Device Language as Default

On first launch, detect the device language and auto-select it as the active language filter:

```swift
// In FeedStore.start(), after registry.loadFromOPML()
if !Settings.hasInitializedLanguageDefault {
    let deviceLang = Locale.current.language.languageCode?.identifier
    if let lang = deviceLang, availableLanguagesInRegistry.contains(lang) {
        activeLanguages = [lang]
    }
    Settings.hasInitializedLanguageDefault = true
}
```

This means a Brazilian user opening the app for the first time sees Portuguese content by default. They can still browse all languages by clearing the filter.

#### 5.4.2 Language in the Scheduler

`SourceScheduler.nextBatch()` gets the active languages and boosts sources matching them:

```swift
func nextBatch(
    reservoir: [FeedItem],
    sourcesByRegion: [String: [FeedSource]],
    activeRegion: String?,
    activeContentType: String?,
    prioritySourceURLs: Set<String> = [],
    activeLanguages: Set<String> = []     // NEW
) -> [FeedSource]
```

In the scoring loop, sources matching the active language get a `languageBoost`:

```swift
let languageBoost: Double = activeLanguages.isEmpty ? 1.0
    : (activeLanguages.contains(source.language ?? "") ? 3.0 : 0.5)

let score = regionDeficit * catDeficit * timeFactor * contentTypeBoost * languageBoost
```

This doesn't exclude non-matching sources — it just deprioritizes them. The user can still see content in other languages; their language just shows up first.

#### 5.4.3 Language Toggle = Disney Fast Pass

When the user changes the language filter, the same `applyUpdate(.flush)` + `fetchNextBatch` pipeline from Part 1 applies. Sources matching the new language get `prioritySourceURLs` status. The urgent taxonomy fetch works identically — language sources jump the queue.

#### 5.4.4 Persistence

Language filter is persisted alongside other filters:

```swift
Settings.filterLanguages = Array(activeLanguages)  // [String]
```

Restored in `restoreFilters()` with the same 4-hour auto-expire logic.

### 5.5 Language Filter Composition

Filters compose with AND semantics:

```
visible = all
  ∩ taxonomyFilter(selectedNodeIDs)     // UNION of subtrees
  ∩ languageFilter(activeLanguages)     // UNION of selected languages
  ∩ contentTypeFilter(selectedType)
  ∩ moodFilter(selectedMood)
  ∩ regionFilter(enabledRegions)
  ∩ searchQuery(query)
  ∩ contentFilters(activeKeywords)
```

A user can say: "show me Coffee & Tea feeds, in Portuguese OR English, text only, from Brazil."

---

## 6. File Manifest

| File | Action | Description |
|------|--------|-------------|
| `Services/FeedStore.swift` | MODIFY | SQL taxonomy + language filter in `reloadFromSQLite`; urgent taxonomy fetch; pause/resume background on filter; `activeLanguages` state; language default logic |
| `Services/SourceScheduler.swift` | MODIFY | `prioritySourceURLs` + `activeLanguages` params in `nextBatch`; language scoring boost |
| `Views/FilterSheetView.swift` | MODIFY | Replace `TaxonomyTreeView` with `NavigationLink` to `TaxonomyBrowseView`; add Language section |
| `Views/TaxonomyBrowseView.swift` | MODIFY | Add search bar at root level; language badge on each node |
| `Views/TaxonomyTreeView.swift` | REMOVE | No longer needed — replaced by `TaxonomyBrowseView` |
| `Views/TaxonomyChipBar.swift` | MODIFY | Remove always-visible "All"; show language chip when active |
| `Views/FeedScreen.swift` | MODIFY | Conditional ChipBar visibility; wire `hasActiveFilters` (includes language) |
| `Views/FeedEmptyStateView.swift` | MODIFY | Add mode enum and state-specific content |
| `Services/FeedLoader.swift` | MODIFY | `hasActiveFilters`; `selectedLanguages`; `hasLanguageSelection`; `availableLanguages`; `toggleLanguage` |
| `Models/FeedItem.swift` | MODIFY | Add `language: String?` field |
| `Services/OPMLParser.swift` | MODIFY | Extract language detection to reusable utility |
| `Services/SourceRegistry.swift` | MODIFY | `languageFor(sourceURL:)` lookup |
| `feed_item` table | MIGRATE v7 | Add `language TEXT` column + index |

---

## 7. Performance Targets

| Operation | Target | Mechanism |
|-----------|--------|-----------|
| Filter SQL query (50 feeds, taxonomy) | <20ms | Composite index `(source_url, published_at)` |
| Filter SQL query (3,200 feeds, taxonomy) | <100ms | Batched IN clause, same index |
| Filter SQL query (language only) | <10ms | `idx_item_language` index |
| Combined taxonomy + language SQL | <30ms | Both indexes used in query plan |
| Scheduler priority sort | <5ms | Hash set lookups, O(sources) |
| Scheduler language scoring | <2ms | Simple string comparison in scoring loop |
| TaxonomyBrowseView navigation push | <100ms | Flat `List`, no recursion |
| ChipBar show/hide | 0 frames | Pure conditional, no animation needed |
| First item appears after filter | <500ms | SQL query + seed + first render |
| Urgent fetch completion (15 sources) | <3s typical | Concurrent fetch, 15 at a time |
| NLLanguageRecognizer detection | <5ms per item | Single pass, already in background Task |

---

## 8. Edge Cases

1. **Rapid filter toggling**: `filterDebounceTask` already throttles to 300ms — multiple rapid toggles only trigger one flush.
2. **Network unavailable during filter**: SQL query still returns cached items. Empty state B shows "Fetching..." with progress stuck — transitions to state C after timeout (30s).
3. **Very large taxonomy node (>999 feeds)**: IN clause batched in chunks of 999. SQLite parameter limit is 999 on iOS by default.
4. **Empty taxonomy tree**: `TaxonomyStore.root` is nil → `TaxonomyBrowseView` shows "No topics available" content unavailable view.
5. **Filter then immediate unfilter**: `progressiveFetch` was cancelled; needs restart. On clearAllFilters, `applyUpdate(.flush)` restarts normal pipeline.
6. **Concurrent urgent fetches**: If user changes filter while urgent fetch is running, cancel the previous urgent task (tracked via `urgentFetchTask`).
7. **Language: nil-language items when filter is active**: Items without a declared language are excluded from results when any language filter is selected. This prevents "Unknown" content from leaking through. If ALL items become excluded, the feed shows empty state C.
8. **Language: device language not in available languages**: If the user's device is set to a language not present in any OPML (e.g., Korean when only en/pt/es exist), no language default is set — shows all languages unfiltered.
9. **Language: rapid language toggling**: Same debounce as taxonomy — 300ms gate on `setFilter`.
10. **Language: migration v7 on existing databases**: `ALTER TABLE ADD COLUMN` sets `language` to `NULL` for all existing rows. New fetches populate the column. Over time, the NULL proportion decreases naturally as old items expire (30-day window).
11. **NLLanguageRecognizer fallback accuracy**: Short titles (<12 chars) skip detection. Results are best-effort — OPML `language` attribute is always authoritative.
12. **Language + Taxonomy + ContentType all active simultaneously**: All filters compose as AND. SQL query has multiple WHERE clauses. Query planner uses the most selective index first.

---

## 9. Migration Path

### 9.1 Database Migration

One new migration (v7):

```sql
ALTER TABLE feed_item ADD COLUMN language TEXT;
CREATE INDEX idx_item_language ON feed_item(language);
```

Existing rows get `NULL` — populated on next fetch. No backfill needed (30-day retention window handles it naturally).

### 9.2 No OPML Changes Required

Language attributes already exist in the OPML files. The parser already handles them. No new OPML attributes or structure changes.

### 9.3 Implementation Order

1. **Part 4-A (DB + Model)** — Migration v7, `FeedItem.language`, `FeedItemRecord` update, `SourceRegistry.languageFor`, populate at persist
2. **Part 1 (SQL + Scheduler)** — Taxonomy SQL filter, priority URLs, urgent fetch
3. **Part 4-A (Filter Logic)** — `activeLanguages`, `applyFilters`, SQL language filter, `FeedLoader` bindings
4. **Part 4-B+C (Language UI + Smart Default)** — Language section in FilterSheet, badges on tree, device default, scheduler boost
5. **Part 2 (NavigationStack Menu)** — Replace TreeView with BrowseView entry point, add search bar
6. **Part 3 (ChipBar + Empty States)** — Conditional visibility, empty state modes
7. **Remove `TaxonomyTreeView.swift`**
8. **Full regression test** with 18K OPML dataset, validate language filtering end-to-end

### 9.4 Rollback Safety

- Language filter defaults to empty (all languages shown) — no behavior change for existing users on upgrade
- `language` column is nullable — no schema breakage for existing databases
- Device language default only applies on first launch (`hasInitializedLanguageDefault` flag)
