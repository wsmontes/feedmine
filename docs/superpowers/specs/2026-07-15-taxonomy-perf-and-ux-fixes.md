# Taxonomy Performance & UX Fixes — Design Spec

**Date:** 2026-07-15
**Status:** Draft
**Follows:** `2026-07-15-feed-taxonomy-design.md`

---

## 1. Context

The taxonomy system shipped (design spec `2026-07-15-feed-taxonomy-design.md`) but three structural problems emerged at real scale — 18,145 OPML files, ~7,500 sources, 39 languages, thousands of taxonomy nodes:

| Problem | Root Cause | Impact |
|---------|-----------|--------|
| Menu freezes (15s clicks) | Recursive `DisclosureGroup` in `TaxonomyTreeView` — SwiftUI evaluates body of all nodes even collapsed | Unusable filter UI |
| Filter shows no content | SQL query uses `LIMIT 200` without taxonomy filtering; scheduler ignores taxonomy selection | Empty feed after filter |
| ChipBar wastes space | Always visible, shows "All" when nothing selected | ~56px of dead space |

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

## 5. File Manifest

| File | Action | Description |
|------|--------|-------------|
| `Services/FeedStore.swift` | MODIFY | SQL taxonomy filter in `reloadFromSQLite`; urgent taxonomy fetch; pause/resume background on filter |
| `Services/SourceScheduler.swift` | MODIFY | `prioritySourceURLs` param in `nextBatch` |
| `Views/FilterSheetView.swift` | MODIFY | Replace `TaxonomyTreeView` with `NavigationLink` to `TaxonomyBrowseView` |
| `Views/TaxonomyBrowseView.swift` | MODIFY | Add search bar at root level |
| `Views/TaxonomyTreeView.swift` | REMOVE | No longer needed — replaced by `TaxonomyBrowseView` |
| `Views/TaxonomyChipBar.swift` | MODIFY | Remove always-visible "All"; accept `isVisible` binding or read from environment |
| `Views/FeedScreen.swift` | MODIFY | Conditional ChipBar visibility; wire `hasActiveFilters` |
| `Views/FeedEmptyStateView.swift` | MODIFY | Add mode enum and state-specific content |
| `Services/FeedLoader.swift` | MODIFY | Add `hasActiveFilters` computed property |

---

## 6. Performance Targets

| Operation | Target | Mechanism |
|-----------|--------|-----------|
| Filter SQL query (50 feeds) | <20ms | Composite index `(source_url, published_at)` |
| Filter SQL query (3,200 feeds) | <100ms | Batched IN clause, same index |
| Scheduler priority sort | <5ms | Hash set lookups, O(sources) |
| TaxonomyBrowseView navigation push | <100ms | Flat `List`, no recursion |
| ChipBar show/hide | 0 frames | Pure conditional, no animation needed |
| First item appears after filter | <500ms | SQL query + seed + first render |
| Urgent fetch completion (15 sources) | <3s typical | Concurrent fetch, 15 at a time |

---

## 7. Edge Cases

1. **Rapid filter toggling**: `filterDebounceTask` already throttles to 300ms — multiple rapid toggles only trigger one flush.
2. **Network unavailable during filter**: SQL query still returns cached items. Empty state B shows "Fetching..." with progress stuck — transitions to state C after timeout (30s).
3. **Very large taxonomy node (>999 feeds)**: IN clause batched in chunks of 999. SQLite parameter limit is 999 on iOS by default.
4. **Empty taxonomy tree**: `TaxonomyStore.root` is nil → `TaxonomyBrowseView` shows "No topics available" content unavailable view.
5. **Filter then immediate unfilter**: `progressiveFetch` was cancelled; needs restart. On clearAllFilters, `applyUpdate(.flush)` restarts normal pipeline.
6. **Concurrent urgent fetches**: If user changes filter while urgent fetch is running, cancel the previous urgent task (tracked via `urgentFetchTask`).

---

## 8. Migration Path

No database migration required. No OPML changes. No new persistence. All changes are in-memory query logic and SwiftUI view hierarchy.

1. Implement Part 1 (SQL + scheduler) → verify filters work
2. Implement Part 2 (NavigationStack menu) → verify no more freezing
3. Implement Part 3 (ChipBar + empty states) → verify space and messaging
4. Remove `TaxonomyTreeView.swift`
5. Full regression test with 18K OPML dataset
