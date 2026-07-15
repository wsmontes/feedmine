# Taxonomy Performance & UX Fixes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix taxonomy filter (empty results), menu freezing (15s clicks), ChipBar space waste, and add language filtering (Levels A+B+C) to the FeedMine app.

**Architecture:** Push taxonomy and language filtering into SQLite queries using indexed columns and batched IN clauses. Replace recursive `DisclosureGroup` tree with flat `NavigationStack` drill-down (already implemented in `TaxonomyBrowseView`). Add language column to `feed_item`, make scheduler taxonomy-aware with priority URLs, default language to device locale.

**Tech Stack:** Swift 6, SwiftUI, GRDB (SQLite), Observation framework, NLLanguageRecognizer

## Global Constraints

- Feed is sacred: screen only changes by user action, items appear below fold as they arrive
- Database is source of truth: filter = query change, not a network fetch
- Disney Fast Pass: filtered sources jump the fetch queue
- No filter = no work: all fetch pipelines pause when nothing is enabled
- Empty states explain what's happening, never show a refresh button (except "No Sources" which has "Open Filters" to navigate)
- `language` column is nullable — historical items remain NULL until re-fetched
- NLLanguageRecognizer is best-effort fallback; OPML `language` attribute is authoritative
- SQLite parameter limit: 999 per query → batch IN clauses for large taxonomy nodes
- Filters auto-expire after 4 hours of inactivity (existing behavior, preserved)

---

### Task 1: Database Migration v7 — Language Column

**Files:**
- Modify: `feedmine/Services/FeedStore.swift` (migration block)

**Interfaces:**
- Consumes: nothing (first task)
- Produces: `feed_item.language TEXT` column, `idx_item_language` index

- [ ] **Step 1: Add v7 migration**

In `FeedStore.migrate(_:)`, after the v6 registration, add:

```swift
migrator.registerMigration("v7_language") { db in
    try db.alter(table: "feed_item") { t in
        t.add(column: "language", .text)
    }
    try db.create(index: "idx_item_language", on: "feed_item", columns: ["language"])
}
```

- [ ] **Step 2: Verify migration compiles**

```bash
xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Write migration test**

Create test in `feedmineTests/TaxonomyStoreTests.swift` or a dedicated test file. Since this is a FeedStore migration, add to an existing FeedStore test or create a simple one:

```swift
func testV7MigrationAddsLanguageColumn() throws {
    // Use in-memory database to verify migration
    let store = try FeedStore(inMemory: true)
    try store.db.write { db in
        // Verify column exists by inserting a row with language
        try db.execute(sql: """
            INSERT INTO feed_item (id, source_url, source_title, region, category,
                                   title, excerpt, url, published_at, fetched_at, language)
            VALUES ('test-id', 'https://example.com/feed', 'Test', 'global', 'News',
                    'Title', 'Excerpt', 'https://example.com', 0, 0, 'en')
        """)
        let lang: String? = try String.fetchOne(db, sql: "SELECT language FROM feed_item WHERE id = 'test-id'")
        XCTAssertEqual(lang, "en")
    }
}
```

- [ ] **Step 4: Run test**

```bash
xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:feedmineTests/TaxonomyStoreTests/testV7MigrationAddsLanguageColumn 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add feedmine/Services/FeedStore.swift feedmineTests/
git commit -m "feat: add v7 migration — language column + index on feed_item"
```

---

### Task 2: FeedItem + FeedItemRecord — Language Field

**Files:**
- Modify: `feedmine/Models/FeedItem.swift`
- Modify: `feedmine/Services/FeedStore.swift` (FeedItemRecord)

**Interfaces:**
- Consumes: v7 migration (Task 1)
- Produces: `FeedItem.language: String?`, `FeedItemRecord.language: String?`, updated `init(from:region:language:)`, updated `toFeedItem()`

- [ ] **Step 1: Add language to FeedItem**

In `FeedItem.swift`, add the `language` field:

```swift
struct FeedItem: Identifiable, Sendable, Codable, Equatable {
    let id: String
    let sourceTitle: String
    let sourceURL: String
    let category: String
    let title: String
    let excerpt: String
    let url: String
    let imageURL: String?
    let publishedAt: Date
    let audioURL: String?
    let duration: TimeInterval?
    let region: String
    let language: String?   // NEW: ISO 639-1 code from OPML or NLLanguageRecognizer
    // ... rest unchanged
```

- [ ] **Step 2: Update FeedItem initializer**

Add `language` parameter with default `nil` for backward compat:

```swift
init(id: String, sourceTitle: String, sourceURL: String, category: String,
     title: String, excerpt: String, url: String, imageURL: String?,
     publishedAt: Date, audioURL: String? = nil, duration: TimeInterval? = nil,
     region: String = "global", language: String? = nil) {
    self.id = id
    self.sourceTitle = sourceTitle
    self.sourceURL = sourceURL
    self.category = category
    self.title = title
    self.excerpt = excerpt
    self.url = url
    self.imageURL = imageURL
    self.publishedAt = publishedAt
    self.audioURL = audioURL
    self.duration = duration
    self.region = region
    self.language = language
}
```

- [ ] **Step 3: Update withoutAudio()**

Preserve language in the copy:

```swift
func withoutAudio() -> FeedItem {
    FeedItem(
        id: id, sourceTitle: sourceTitle, sourceURL: sourceURL, category: category,
        title: title, excerpt: excerpt, url: url, imageURL: imageURL,
        publishedAt: publishedAt, audioURL: nil, duration: nil, region: region,
        language: language
    )
}
```

- [ ] **Step 4: Add language to FeedItemRecord**

In `FeedStore.swift`, update `FeedItemRecord`:

```swift
struct FeedItemRecord: Codable, PersistableRecord, FetchableRecord {
    var id: String
    var sourceURL: String
    var sourceTitle: String
    var region: String
    var category: String
    var title: String
    var excerpt: String
    var url: String
    var imageURL: String?
    var audioURL: String?
    var duration: TimeInterval?
    var publishedAt: Int
    var fetchedAt: Int
    var isRead: Bool
    var openedAt: Int?
    var language: String?   // NEW

    enum CodingKeys: String, CodingKey {
        case id
        case sourceURL = "source_url"
        case sourceTitle = "source_title"
        case region
        case category
        case title
        case excerpt
        case url
        case imageURL = "image_url"
        case audioURL = "audio_url"
        case duration
        case publishedAt = "published_at"
        case fetchedAt = "fetched_at"
        case isRead = "is_read"
        case openedAt = "opened_at"
        case language  // NEW
    }
```

- [ ] **Step 5: Update FeedItemRecord.init(from:region:)**

Add language parameter:

```swift
init(from item: FeedItem, region: String, language: String? = nil) {
    self.id = item.id
    self.sourceURL = item.sourceURL
    self.sourceTitle = item.sourceTitle
    self.region = region
    self.category = item.category
    self.title = item.title
    self.excerpt = item.excerpt
    self.url = item.url
    self.imageURL = item.bestImageURL
    self.audioURL = item.audioURL
    self.duration = item.duration
    self.publishedAt = Int(item.publishedAt.timeIntervalSince1970)
    self.fetchedAt = Int(Date().timeIntervalSince1970)
    self.isRead = false
    self.openedAt = nil
    self.language = language  // NEW
}
```

- [ ] **Step 6: Update FeedItemRecord.toFeedItem()**

```swift
func toFeedItem() -> FeedItem {
    FeedItem(
        id: id,
        sourceTitle: sourceTitle,
        sourceURL: sourceURL,
        category: category,
        title: title,
        excerpt: excerpt,
        url: url,
        imageURL: imageURL,
        publishedAt: Date(timeIntervalSince1970: TimeInterval(publishedAt)),
        audioURL: audioURL,
        duration: duration,
        region: region,
        language: language  // NEW
    )
}
```

- [ ] **Step 7: Verify build**

```bash
xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | grep -E "error:|BUILD"
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 8: Run existing tests to verify no regressions**

```bash
xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "passed|failed|TEST"
```

Expected: All tests pass.

- [ ] **Step 9: Commit**

```bash
git add feedmine/Models/FeedItem.swift feedmine/Services/FeedStore.swift
git commit -m "feat: add language field to FeedItem and FeedItemRecord"
```

---

### Task 3: SourceRegistry.languageFor + Persist Language

**Files:**
- Modify: `feedmine/Services/SourceRegistry.swift`
- Modify: `feedmine/Services/FeedStore.swift` (persistFetchedItems)

**Interfaces:**
- Consumes: `FeedSource.language` (already exists), Task 2
- Produces: `SourceRegistry.languageFor(sourceURL:) -> String?`

- [ ] **Step 1: Add language lookup to SourceRegistry**

```swift
// In SourceRegistry, add after the existing regionFor method:

private var _languageMap: [String: String?]?
var languageMap: [String: String?] {
    if let cached = _languageMap { return cached }
    let map = Dictionary(sources.map { ($0.url, $0.language) }, uniquingKeysWith: { first, _ in first })
    _languageMap = map
    return map
}

func languageFor(sourceURL: String) -> String? {
    languageMap[sourceURL] ?? nil
}
```

Invalidate `_languageMap` in `rebuildCaches()` alongside `_regionMap`:

```swift
private func rebuildCaches() {
    sourceByURL = Dictionary(uniqueKeysWithValues: sources.map { ($0.url, $0) })
    _regionMap = nil
    _languageMap = nil  // NEW
}
```

- [ ] **Step 2: Update persistFetchedItems to resolve and pass language**

In `FeedStore.persistFetchedItems`, update the itemsWithRegions mapping:

```swift
let itemsWithRegions: [(item: FeedItem, region: String, language: String?)] = actualNew.map { item in
    let resolvedRegion = regionOverride ?? registry.regionFor(sourceURL: item.sourceURL)
    let resolvedLanguage = registry.languageFor(sourceURL: item.sourceURL)
    return (item, resolvedRegion, resolvedLanguage)
}
```

And update the write closure:

```swift
let succeeded: [FeedItem] = try await db.write { db -> [FeedItem] in
    var ok: [FeedItem] = []
    for (item, region, language) in itemsWithRegions {
        do {
            let record = FeedItemRecord(from: item, region: region, language: language)
            try record.insert(db)
            ok.append(item)
        } catch {
            Log.db.warning("persistFetchedItems: skip \(item.id): \(error)")
        }
    }
    return ok
}
```

- [ ] **Step 3: Verify build**

```bash
xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | grep -E "error:|BUILD"
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add feedmine/Services/SourceRegistry.swift feedmine/Services/FeedStore.swift
git commit -m "feat: resolve and persist language from SourceRegistry at fetch time"
```

---

### Task 4: Taxonomy SQL Filter in reloadFromSQLite

**Files:**
- Modify: `feedmine/Services/FeedStore.swift` (reloadFromSQLite)

**Interfaces:**
- Consumes: `cachedTaxonomyFeedURLs` (already exists), `activeNodeIDs` (already exists)
- Produces: filtered SQL results, no LIMIT when taxonomy active

- [ ] **Step 1: Write the test**

Add to `feedmineTests/FeedStoreTests.swift` or a new test file. Since FeedStore initialization requires GRDB, use an in-memory store:

```swift
@MainActor
func testReloadFromSQLiteFiltersByTaxonomySourceURL() async throws {
    let store = try FeedStore(inMemory: true)

    // Seed sources and taxonomy
    let source = FeedSource(title: "Coffee Blog", url: "https://coffee.com/feed",
                            category: "Coffee", region: "global")
    store.registry.sources = [source]
    await TaxonomyStore.shared.build(from: [source])

    // Select the taxonomy node
    let nodeID = TaxonomyStore.shared.nodeID(for: "https://coffee.com/feed")!
    store.activeNodeIDs = [nodeID]
    store.cachedTaxonomyFeedURLs = TaxonomyStore.shared.feedURLs(inSubtreesOf: [nodeID])

    // Insert test items — one matching, one not
    let matchingItem = FeedItemRecord(
        from: FeedItem(id: "match", sourceTitle: "S", sourceURL: "https://coffee.com/feed",
                       category: "Coffee", title: "Match", excerpt: "E",
                       url: "https://coffee.com/1", publishedAt: Date()),
        region: "global", language: nil
    )
    let nonMatchingItem = FeedItemRecord(
        from: FeedItem(id: "nomatch", sourceTitle: "S", sourceURL: "https://other.com/feed",
                       category: "Other", title: "No Match", excerpt: "E",
                       url: "https://other.com/1", publishedAt: Date()),
        region: "global", language: nil
    )
    try await store.db.write { db in
        try matchingItem.insert(db)
        try nonMatchingItem.insert(db)
    }

    // Trigger reload via applyUpdate(.flush)
    store.setFilter(region: nil, nodeIDs: [nodeID], type: .all, mood: .all)

    // Wait for pipeline
    try await Task.sleep(for: .milliseconds(500))

    // Verify only matching item appears
    XCTAssertEqual(store.visibleItems.count, 1)
    XCTAssertEqual(store.visibleItems.first?.sourceURL, "https://coffee.com/feed")
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:feedmineTests 2>&1 | grep -E "passed|failed"
```

Expected: Test fails — taxonomy filter not applied in SQL yet.

- [ ] **Step 3: Implement SQL taxonomy filter**

In `reloadFromSQLite`, replace the query building section. Find the block starting at `let items: [FeedItemRecord] = ...` and modify:

```swift
private func reloadFromSQLite(prepend: [FeedItem] = [], skipRead: Bool = false) async {
    guard !isSearching else { return }
    let region = activeRegion
    let contentType = activeContentType
    let taxonomyURLs: Set<String>? = activeNodeIDs.isEmpty ? nil : cachedTaxonomyFeedURLs
    let languages = activeLanguages

    let items: [FeedItemRecord] = (try? await db.read { db in
        // Base query
        var request = FeedItemRecord
            .filter(Column("fetched_at") > Self.thirtyDayCutoffEpoch)
            .filter(Column("is_read") == 0)

        if let r = region {
            request = request.filter(Column("region") == r)
        }

        switch contentType {
        case .audio: request = request.filter(Column("audio_url") != nil)
        case .video: request = request.filter(Column("source_url").like("%youtube%"))
        case .text:  request = request.filter(Column("audio_url") == nil)
                        .filter(!Column("source_url").like("%youtube%"))
                        .filter(!Column("source_url").like("%reddit%"))
        case .forum: request = request.filter(Column("source_url").like("%reddit%"))
        case .all: break
        }

        // Taxonomy filter — batch IN clause for >999 URLs
        if let urls = taxonomyURLs, !urls.isEmpty {
            let urlArray = Array(urls)
            let batchSize = 999
            var allItems: [FeedItemRecord] = []
            for chunkStart in stride(from: 0, to: urlArray.count, by: batchSize) {
                let chunk = Array(urlArray[chunkStart..<min(chunkStart + batchSize, urlArray.count)])
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                let chunkRequest = request.filter(
                    sql: "source_url IN (\(placeholders))",
                    arguments: StatementArguments(chunk)
                )
                let batchItems = try chunkRequest
                    .order(Column("published_at").desc)
                    .fetchAll(db)
                allItems.append(contentsOf: batchItems)
            }
            // Sort merged batches by published_at desc
            allItems.sort { $0.publishedAt > $1.publishedAt }
            return allItems
        }

        // Language filter (small cardinality — no batching needed)
        if !languages.isEmpty {
            let placeholders = languages.map { _ in "?" }.joined(separator: ",")
            request = request.filter(
                sql: "language IN (\(placeholders))",
                arguments: StatementArguments(languages.map { $0 as String? })
            )
        }

        return try request
            .order(Column("published_at").desc)
            .limit(200)
            .fetchAll(db)
    }) ?? []

    // ... rest of the method unchanged (map to FeedItem, loadedIDs, seed, markSurfaced, etc.)
```

- [ ] **Step 4: Verify build**

```bash
xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | grep -E "error:|BUILD"
```

- [ ] **Step 5: Run the taxonomy filter test**

```bash
xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:feedmineTests/FeedStoreTests/testReloadFromSQLiteFiltersByTaxonomySourceURL 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add feedmine/Services/FeedStore.swift feedmineTests/
git commit -m "feat: taxonomy SQL filter with batched IN clause in reloadFromSQLite"
```

---

### Task 5: SourceScheduler — Priority URLs + Language Scoring

**Files:**
- Modify: `feedmine/Services/SourceScheduler.swift`

**Interfaces:**
- Consumes: `prioritySourceURLs: Set<String>` (from FeedStore), `activeLanguages: Set<String>` (from FeedStore)
- Produces: prioritized batch with language scoring boost

- [ ] **Step 1: Write scheduler tests**

Add to `feedmineTests/SourceSchedulerTests.swift`:

```swift
@MainActor
func testPriorityURLsJumpToFront() {
    let scheduler = SourceScheduler()
    let priorityURL = "https://priority.com/feed"
    let normalURL = "https://normal.com/feed"

    let sourcesByRegion: [String: [FeedSource]] = [
        "global": [
            FeedSource(title: "Priority", url: priorityURL, category: "News", region: "global"),
            FeedSource(title: "Normal", url: normalURL, category: "News", region: "global"),
        ]
    ]

    let batch = scheduler.nextBatch(
        reservoir: [],
        sourcesByRegion: sourcesByRegion,
        activeRegion: nil,
        activeContentType: nil,
        prioritySourceURLs: [priorityURL]
    )

    XCTAssertEqual(batch.first?.url, priorityURL, "Priority URL must be first in batch")
}

@MainActor
func testLanguageScoringBoost() {
    let scheduler = SourceScheduler()
    let ptURL = "https://pt.com/feed"
    let enURL = "https://en.com/feed"

    let sourcesByRegion: [String: [FeedSource]] = [
        "global": [
            FeedSource(title: "PT", url: ptURL, category: "News", region: "global", language: "pt"),
            FeedSource(title: "EN", url: enURL, category: "News", region: "global", language: "en"),
        ]
    ]

    let batch = scheduler.nextBatch(
        reservoir: [],
        sourcesByRegion: sourcesByRegion,
        activeRegion: nil,
        activeContentType: nil,
        prioritySourceURLs: [],
        activeLanguages: ["pt"]
    )

    // Both should appear (language filter doesn't exclude, just boosts)
    XCTAssertEqual(batch.count, 2)
    // Portuguese source should be first (boosted)
    XCTAssertEqual(batch.first?.url, ptURL, "Language-matching source should be first")
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:feedmineTests/SourceSchedulerTests 2>&1 | grep -E "passed|failed"
```

Expected: Both tests fail — new parameters not yet accepted.

- [ ] **Step 3: Update nextBatch signature**

```swift
func nextBatch(
    reservoir: [FeedItem],
    sourcesByRegion: [String: [FeedSource]],
    activeRegion: String?,
    activeContentType: String? = nil,
    prioritySourceURLs: Set<String> = [],     // NEW
    activeLanguages: Set<String> = []          // NEW
) -> [FeedSource]
```

- [ ] **Step 4: Add priority phase at the start of nextBatch**

After the guard on `regions.isEmpty` and before the scoring loop, add:

```swift
var selected: [FeedSource] = []
var selectedURLs = Set<String>()
selectedURLs.reserveCapacity(maxSelect)

// Phase 1: Priority sources jump the queue (Disney Fast Pass)
if !prioritySourceURLs.isEmpty {
    for region in regions {
        guard let sources = sourcesByRegion[region] else { continue }
        for source in sources {
            guard prioritySourceURLs.contains(source.url) else { continue }
            guard selectedURLs.insert(source.url).inserted else { continue }
            // Clear cooldown — treat as never-fetched
            lastFetchedAt.removeValue(forKey: source.url)
            consecutiveFailures.removeValue(forKey: source.url)
            selected.append(source)
        }
    }
}
```

- [ ] **Step 5: Add language boost to scoring loop**

In the existing scoring loop (inside `for source in sources`), add after the `contentTypeBoost` calculation:

```swift
let languageBoost: Double = activeLanguages.isEmpty ? 1.0
    : (activeLanguages.contains(source.language ?? "") ? 3.0 : 0.5)

let score = regionDeficit * catDeficit * timeFactor * contentTypeBoost * languageBoost
```

- [ ] **Step 6: Fill remaining slots after priority**

After Phase 1, add:

```swift
let remaining = maxSelect - selected.count
if remaining > 0 {
    // Only score sources not already selected
    var scored: [(source: FeedSource, score: Double)] = []
    scored.reserveCapacity(sourcesByRegion.values.map(\.count).reduce(0, +))

    for region in regions {
        guard let sources = sourcesByRegion[region] else { continue }
        let regionDeficit = max(0, regionDeficits[region] ?? 0)
        for source in sources {
            guard !selectedURLs.contains(source.url) else { continue }
            // ... existing scoring logic with languageBoost ...
        }
    }
    scored.sort(by: { $0.score > $1.score })
    for (source, _) in scored {
        guard selected.count < maxSelect else { break }
        guard selectedURLs.insert(source.url).inserted else { continue }
        selected.append(source)
    }
}

return selected
```

- [ ] **Step 7: Verify build + run tests**

```bash
xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | grep -E "error:|BUILD"
xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:feedmineTests/SourceSchedulerTests 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`, `** TEST SUCCEEDED **`

- [ ] **Step 8: Commit**

```bash
git add feedmine/Services/SourceScheduler.swift feedmineTests/SourceSchedulerTests.swift
git commit -m "feat: priority URLs and language scoring boost in SourceScheduler"
```

---

### Task 6: FeedStore — Filter Pipeline + Language State

**Files:**
- Modify: `feedmine/Services/FeedStore.swift`
- Modify: `feedmine/Services/AppSettings.swift`

**Interfaces:**
- Consumes: Tasks 3, 4, 5
- Produces: `activeLanguages`, `hasInitializedLanguageDefault`, `urgentFetchTask`, updated `setFilter`, updated `applyFilters`, updated `fetchNextBatch`, updated `persistFilters`/`restoreFilters`

- [ ] **Step 1: Add activeLanguages state to FeedStore**

```swift
var activeLanguages: Set<String> = []
```

- [ ] **Step 2: Add language filter to applyFilters**

In the `applyFilters` method, add after the region check and before the contentType check:

```swift
&& (languages.isEmpty || item.language.map { languages.contains($0) } ?? false)
```

Full updated filter closure:

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

- [ ] **Step 3: Wire prioritySourceURLs + activeLanguages into fetchNextBatch**

In `fetchNextBatch()`, update the `scheduler.nextBatch` call:

```swift
let batch = scheduler.nextBatch(
    reservoir: reservoir.reservoir,
    sourcesByRegion: sourcesByRegion,
    activeRegion: activeRegion,
    activeContentType: contentTypeStr,
    prioritySourceURLs: activeNodeIDs.isEmpty ? [] : cachedTaxonomyFeedURLs,
    activeLanguages: activeLanguages
)
```

- [ ] **Step 4: Add urgent taxonomy fetch**

Add a new method and tracking property:

```swift
private var urgentFetchTask: Task<Void, Never>?

private func fetchUrgentTaxonomyBatch(sourceURLs: Set<String>) async {
    let sources = registry.enabledSources.filter { sourceURLs.contains($0.url) }
    guard !sources.isEmpty else { return }
    let result = await fetcher.fetchAll(sources, maxConcurrent: 15)
    let actualNew = await persistFetchedItems(result.items)
    guard !actualNew.isEmpty else { return }
    throttledReservoirAppend(actualNew)
    collectWhatsNewCandidates(actualNew)
    prefetchImagesIfEnabled(for: actualNew)
}
```

- [ ] **Step 5: Update setFilter to cancel/pause background work**

In `setFilter`, after the debounce and before `applyUpdate(.flush)`, add:

```swift
// Cancel progressive fetch — waste of budget when user wants specific content
progressiveFetchTask?.cancel()
// Cancel any previous urgent fetch
urgentFetchTask?.cancel()

// Kick off urgent fetch for taxonomy sources
let priorityURLs = TaxonomyStore.shared.feedURLs(inSubtreesOf: activeNodeIDs)
if !priorityURLs.isEmpty {
    urgentFetchTask = Task { [weak self] in
        guard let self else { return }
        await self.fetchUrgentTaxonomyBatch(sourceURLs: priorityURLs)
        // Resume background refresh after urgent work completes
        self.startBackgroundRefresh()
    }
}
```

- [ ] **Step 6: Add AppSettings for language filter persistence**

In `AppSettings.swift`, add to `Keys`:

```swift
static let filterLanguages = "filterLanguages"
static let hasInitializedLanguageDefault = "hasInitializedLanguageDefault"
```

In `Settings`:

```swift
static var filterLanguages: [String] {
    get { d.stringArray(forKey: Keys.filterLanguages) ?? [] }
    set { d.set(newValue, forKey: Keys.filterLanguages) }
}
static var hasInitializedLanguageDefault: Bool {
    get { d.bool(forKey: Keys.hasInitializedLanguageDefault) }
    set { d.set(newValue, forKey: Keys.hasInitializedLanguageDefault) }
}
```

- [ ] **Step 7: Update persistFilters and restoreFilters for language**

In `persistFilters()`:

```swift
private func persistFilters() {
    Settings.filterRegion = activeRegion
    Settings.filterTaxonomyNodes = Array(activeNodeIDs)
    Settings.filterContentType = activeContentType.rawValue
    Settings.filterLanguages = Array(activeLanguages)  // NEW
    Settings.filterSetAt = Date().timeIntervalSince1970
}
```

In `restoreFilters()`, after restoring content type and before the closing brace:

```swift
activeLanguages = Set(Settings.filterLanguages)
```

And in the auto-expire section, clear language too:

```swift
Settings.filterLanguages = []  // Add to the expiry reset block
```

- [ ] **Step 8: Add device language default on first launch**

In `FeedStore.start()`, after `await registry.loadFromOPML()`:

```swift
// Set language default on first launch
if !Settings.hasInitializedLanguageDefault {
    let deviceLang = Locale.current.language.languageCode?.identifier
    if let lang = deviceLang {
        let availableLangs = Set(registry.sources.compactMap(\.language))
        if availableLangs.contains(lang) {
            activeLanguages = [lang]
        }
    }
    Settings.hasInitializedLanguageDefault = true
}
```

- [ ] **Step 9: Add empty state progress tracking**

Add properties for the "fetching" empty state:

```swift
var emptyStateFetchedCount: Int = 0
var emptyStateFetchTotal: Int = 0
```

Update `fetchUrgentTaxonomyBatch` to set these:

```swift
emptyStateFetchTotal = sourceURLs.count
emptyStateFetchedCount = 0
// After each source completes (in the fetch loop):
emptyStateFetchedCount = result.sourceStatuses.count
```

- [ ] **Step 10: Verify build + run all tests**

```bash
xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | grep -E "error:|BUILD"
xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "passed|failed|TEST"
```

Expected: `** BUILD SUCCEEDED **`, all tests pass.

- [ ] **Step 11: Commit**

```bash
git add feedmine/Services/FeedStore.swift feedmine/Services/AppSettings.swift
git commit -m "feat: language filter state, device default, urgent taxonomy fetch, pipeline changes"
```

---

### Task 7: FeedLoader — Language + Filter Bindings

**Files:**
- Modify: `feedmine/Services/FeedLoader.swift`

**Interfaces:**
- Consumes: Task 6 (`activeLanguages`, `hasInitializedLanguageDefault`)
- Produces: `selectedLanguages`, `toggleLanguage`, `availableLanguages`, `hasActiveFilters`, `hasLanguageSelection`, `LanguageInfo`

- [ ] **Step 1: Add LanguageInfo struct**

At the top of `FeedLoader.swift`, add:

```swift
struct LanguageInfo: Identifiable {
    var id: String { code }
    let code: String       // ISO 639-1
    let name: String       // localized display name
    let flag: String       // emoji flag
    let feedCount: Int
}
```

- [ ] **Step 2: Add language properties**

```swift
var selectedLanguages: Set<String> { store.activeLanguages }
var hasLanguageSelection: Bool { !store.activeLanguages.isEmpty }
```

- [ ] **Step 3: Add availableLanguages computed property**

```swift
var availableLanguages: [LanguageInfo] {
    let grouped = Dictionary(grouping: store.registry.sources.filter { $0.language != nil }, by: \.language!)
    return grouped.compactMap { code, sources -> LanguageInfo? in
        LanguageInfo(
            code: code,
            name: Locale.current.localizedString(forLanguageCode: code) ?? code,
            flag: flagEmoji(for: code),
            feedCount: sources.count
        )
    }.sorted { $0.feedCount > $1.feedCount }
}

private func flagEmoji(for languageCode: String) -> String {
    // Map ISO 639-1 to country flag. For common languages, use the most associated country.
    let base: UInt32 = 127397 // Unicode regional indicator offset
    let mapping: [String: String] = [
        "pt": "BR", "en": "US", "es": "ES", "fr": "FR", "de": "DE",
        "it": "IT", "ja": "JP", "ko": "KR", "zh": "CN", "ru": "RU",
        "ar": "SA", "hi": "IN", "nl": "NL", "sv": "SE", "no": "NO",
        "da": "DK", "fi": "FI", "pl": "PL", "tr": "TR", "th": "TH",
        "vi": "VN", "id": "ID", "ms": "MY", "fil": "PH", "he": "IL",
        "el": "GR", "cs": "CZ", "ro": "RO", "hu": "HU", "uk": "UA",
        "ca": "ES", "eu": "ES", "gl": "ES",
    ]
    guard let country = mapping[languageCode] else { return "🌐" }
    return country.unicodeScalars.map {
        String(UnicodeScalar(base + $0.value)!)
    }.joined()
}
```

- [ ] **Step 4: Add toggleLanguage method**

```swift
func toggleLanguage(_ code: String) {
    var langs = store.activeLanguages
    if langs.contains(code) {
        langs.remove(code)
    } else {
        langs.insert(code)
    }
    store.setFilter(region: store.activeRegion,
                    nodeIDs: store.activeNodeIDs,
                    type: store.activeContentType,
                    mood: store.activeMood,
                    languages: langs)
    Task { await loadWhatsNew() }
}
```

- [ ] **Step 5: Update setFilter in FeedStore to accept languages**

The existing `setFilter` doesn't accept languages. Update:

```swift
func setFilter(region: String?, nodeIDs: Set<String>, type: FeedLoader.ContentType,
               mood: FeedLoader.MoodFilter = .all, languages: Set<String>? = nil) {
    activeRegion = region
    activeNodeIDs = nodeIDs
    activeContentType = type
    activeMood = mood
    if let langs = languages {
        activeLanguages = langs
    }
    // ... rest unchanged
}
```

- [ ] **Step 6: Add hasActiveFilters computed property**

```swift
var hasActiveFilters: Bool {
    hasTaxonomySelection || selectedMood != .all || selectedContentType != .all || hasLanguageSelection
}
```

- [ ] **Step 7: Verify build**

```bash
xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | grep -E "error:|BUILD"
```

- [ ] **Step 8: Commit**

```bash
git add feedmine/Services/FeedLoader.swift feedmine/Services/FeedStore.swift
git commit -m "feat: language bindings, toggleLanguage, availableLanguages, hasActiveFilters in FeedLoader"
```

---

### Task 8: UI — FilterSheetView Language Section + Browse/Tree/Chip Changes

**Files:**
- Modify: `feedmine/Views/FilterSheetView.swift`
- Modify: `feedmine/Views/TaxonomyBrowseView.swift`
- Modify: `feedmine/Views/TaxonomyChipBar.swift`

**Interfaces:**
- Consumes: Task 7 (`selectedLanguages`, `toggleLanguage`, `availableLanguages`, `hasActiveFilters`)
- Produces: Language section in FilterSheet, search bar + language badges in BrowseView, language chip in ChipBar

- [ ] **Step 1: Add language section to FilterSheetView**

After the existing "Topics" section, add:

```swift
Section("Language") {
    if loader.availableLanguages.isEmpty {
        Text("No language data available")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    } else {
        ForEach(loader.availableLanguages) { lang in
            Button {
                loader.toggleLanguage(lang.code)
            } label: {
                HStack {
                    Text(lang.flag)
                    Text(lang.name)
                        .foregroundStyle(.primary)
                    Spacer()
                    if loader.selectedLanguages.contains(lang.code) {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.blue)
                    }
                    Text("\(lang.feedCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
```

- [ ] **Step 2: Replace TaxonomyTreeView with NavigationLink in FilterSheetView**

In the Topics section, replace:

```swift
TaxonomyTreeView()

NavigationLink {
    TaxonomyBrowseView()
} label: {
    Label("Browse All Topics", systemImage: "list.bullet.rectangle")
}
```

With:

```swift
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
```

- [ ] **Step 3: Add search bar to TaxonomyBrowseView root level**

In `TaxonomyBrowseView`, replace the body to add search:

```swift
var body: some View {
    NavigationStack {
        if let root = store.root {
            TaxonomyLevelView(node: root, isRoot: true)
                .navigationTitle("Topics")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}
```

Update `TaxonomyLevelView` to accept `isRoot: Bool = false` and show search bar when `isRoot`:

```swift
private struct TaxonomyLevelView: View {
    @Environment(FeedLoader.self) private var loader
    @State private var store = TaxonomyStore.shared
    @State private var searchText = ""
    @State private var searchResults: [TaxonomyNode] = []
    let node: TaxonomyNode
    var isRoot: Bool = false

    var body: some View {
        let children = store.children(of: node.id)
        List {
            // Search bar at root level only
            if isRoot {
                Section {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search topics...", text: $searchText)
                            .textFieldStyle(.plain)
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                                searchResults = []
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .onChange(of: searchText) { _, query in
                    guard !query.isEmpty else {
                        searchResults = []
                        return
                    }
                    searchResults = store.search(query)
                }
            }

            // Show search results or normal children
            if !searchText.isEmpty {
                ForEach(searchResults) { result in
                    searchResultRow(result)
                }
            } else {
                // ... existing children list ...
            }
        }
        .listStyle(.plain)
    }

    private func searchResultRow(_ node: TaxonomyNode) -> some View {
        Button {
            loader.toggleNode(node.id)
            searchText = ""
            searchResults = []
        } label: {
            HStack {
                Image(systemName: store.selectedNodeIDs.contains(node.id)
                      ? "checkmark.circle.fill"
                      : "circle")
                    .foregroundStyle(store.selectedNodeIDs.contains(node.id) ? .blue : .secondary.opacity(0.3))
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name)
                        .font(.subheadline)
                    if let lang = node.language {
                        Text(lang.uppercased())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text("\(node.feedCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 4: Add language badges to taxonomy node rows**

In the existing taxonomy row (both the "All" button and the ForEach rows), add language badge:

```swift
// After the node name Text
if let lang = node.language ?? child.language {  // whichever context
    Text(lang.uppercased())
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4).padding(.vertical, 1)
        .background(.quaternary, in: Capsule())
}
```

- [ ] **Step 5: Update TaxonomyChipBar to show language chips**

In `TaxonomyChipBar`, after the taxonomy node chips and before the overflow indicator, add:

```swift
// Language chips
ForEach(Array(loader.selectedLanguages).sorted(), id: \.self) { lang in
    TaxonomyChip(
        title: langDisplay(lang),
        isSelected: true,
        color: .green
    ) {
        loader.toggleLanguage(lang)
    }
}
```

Add a helper:

```swift
private func langDisplay(_ code: String) -> String {
    let name = Locale.current.localizedString(forLanguageCode: code) ?? code
    return "\(name) (\(code.uppercased()))"
}
```

- [ ] **Step 6: Remove always-visible "All" chip**

In `TaxonomyChipBar`, change the logic so "All" only appears when other chips are present:

```swift
var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
            if loader.hasActiveFilters {
                // "All" as quick-reset when filters are active
                TaxonomyChip(title: "All", isSelected: false, color: .gray) {
                    loader.clearAllFilters()
                }
            }
            // ... rest of chips ...
        }
    }
}
```

- [ ] **Step 7: Verify build**

```bash
xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | grep -E "error:|BUILD"
```

- [ ] **Step 8: Commit**

```bash
git add feedmine/Views/FilterSheetView.swift feedmine/Views/TaxonomyBrowseView.swift feedmine/Views/TaxonomyChipBar.swift
git commit -m "feat: language UI — FilterSheet section, BrowseView search+badges, ChipBar language chips"
```

---

### Task 9: UI — FeedScreen Conditional ChipBar + Empty States

**Files:**
- Modify: `feedmine/Views/FeedScreen.swift`
- Modify: `feedmine/Views/FeedEmptyStateView.swift`

**Interfaces:**
- Consumes: Task 7 (`hasActiveFilters`), Task 6 (`emptyStateFetchedCount`, `emptyStateFetchTotal`)
- Produces: Conditional ChipBar, 4 empty state modes

- [ ] **Step 1: Add FeedEmptyMode enum**

In `FeedEmptyStateView.swift`, replace the file content:

```swift
import SwiftUI

enum FeedEmptyMode {
    case noSourcesEnabled
    case fetching(topic: String, fetched: Int, total: Int)
    case noResults(topic: String)
    case generic
}

struct FeedEmptyStateView: View {
    @Environment(FeedLoader.self) private var loader
    @State private var engine = CircadianEngine.shared

    var mode: FeedEmptyMode = .generic

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            if loader.loadingState == .refreshing {
                ProgressView()
                    .tint(engine.accent)
                    .scaleEffect(1.2)
            }

            ZStack {
                Circle()
                    .fill(engine.accent.opacity(0.1))
                    .frame(width: 100, height: 100)
                Image(systemName: iconName)
                    .font(.system(size: 40))
                    .foregroundStyle(engine.accent)
            }

            Text(title)
                .font(.title3)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)

            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            if case .fetching(let topic, let fetched, let total) = mode {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Fetched \(fetched) of \(total) sources...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }

            if showButton {
                Button {
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                    showFilters = true
                } label: {
                    HStack {
                        Image(systemName: "line.3.horizontal.decrease")
                        Text("Open Filters")
                    }
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .frame(maxWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .tint(engine.accent)
                .controlSize(.large)
            }

            Spacer()
        }
        .padding(.top, 40)
    }

    @State private var showFilters = false

    private var iconName: String {
        switch mode {
        case .noSourcesEnabled: return "globe.americas.fill"
        case .fetching: return "magnifyingglass"
        case .noResults: return "tray"
        case .generic:
            if loader.fetchErrorCount > 0 && loader.totalFetched == 0 { return "wifi.slash" }
            if loader.sources.isEmpty { return "folder.badge.questionmark" }
            return "newspaper.fill"
        }
    }

    private var title: String {
        switch mode {
        case .noSourcesEnabled: return "No sources enabled"
        case .fetching(let topic, _, _): return "Searching for \(topic)..."
        case .noResults(let topic): return "No articles found for \(topic)"
        case .generic:
            if loader.loadingState == .initial { return "Loading your feed..." }
            if loader.fetchErrorCount > 0 && loader.totalFetched == 0 { return "Couldn't load feeds" }
            if loader.sources.isEmpty { return "No sources found" }
            return "No articles yet"
        }
    }

    private var description: String {
        switch mode {
        case .noSourcesEnabled:
            return "Enable some countries or topics in Filters to start seeing content."
        case .fetching(let topic, _, let total):
            return "We're fetching the latest articles from \(total) sources in \(topic). They'll appear here as they arrive."
        case .noResults:
            return "These sources may not have published recently. Try a different topic or check back later."
        case .generic:
            if loader.loadingState == .initial {
                return "Fetching articles from \(loader.sourceCount) sources."
            } else if loader.fetchErrorCount > 0 && loader.totalFetched == 0 {
                return "All \(loader.fetchErrorCount) sources failed to load. Check your internet connection."
            } else if loader.sources.isEmpty {
                return "Add .opml files to the Resources/Feeds folder."
            } else {
                return circadianNoArticlesMessage
            }
        }
    }

    private var showButton: Bool {
        if case .noSourcesEnabled = mode { return true }
        return false
    }

    private var circadianNoArticlesMessage: String {
        switch engine.period {
        case .dawn:    return "The world's still quiet. Stories are on their way."
        case .morning: return "Nothing here yet. Good time to add a source?"
        case .afternoon: return "All caught up. Quick and clean."
        case .evening: return "All caught up. These are worth the slow read."
        case .night:   return "All caught up. Sleep well."
        }
    }

    // Sheet for "Open Filters" button
    private struct FilterSheetWrapper: View {
        var body: some View {
            FilterSheetView()
        }
    }
}
```

- [ ] **Step 2: Wire empty state mode in FeedScreen**

In `FeedScreen.swift`, compute the appropriate mode:

```swift
private var emptyMode: FeedEmptyMode {
    if loader.sources.isEmpty || (!loader.isGlobalFeedsEnabled && !loader.isAnyCountryEnabled) {
        return .noSourcesEnabled
    }
    if loader.hasActiveFilters && loader.items.isEmpty && loader.loadingState == .refreshing {
        return .fetching(
            topic: loader.selectedNodeNames.joined(separator: ", "),
            fetched: 0,  // TODO: wire actual count from FeedStore
            total: loader.selectedNodeIDs.reduce(0) { $0 + (TaxonomyStore.shared.node(id: $1)?.feedCount ?? 0) }
        )
    }
    if loader.hasActiveFilters && loader.items.isEmpty && loader.loadingState == .idle {
        return .noResults(topic: loader.selectedNodeNames.joined(separator: ", "))
    }
    return .generic
}
```

Replace `FeedEmptyStateView()` with:

```swift
FeedEmptyStateView(mode: emptyMode)
```

- [ ] **Step 3: Make ChipBar conditional on hasActiveFilters**

Find `TaxonomyChipBar` in `FeedScreen.swift`'s `compactHeader` and wrap it:

```swift
// Taxonomy chip bar — only visible when filters are active
if loader.hasActiveFilters {
    TaxonomyChipBar {
        showFilters = true
    }
}
```

The `filterActiveBanner` already only appears when filters are active — verify the condition matches:

```swift
if loader.hasActiveFilters {  // was: loader.hasTaxonomySelection || loader.selectedMood != .all || loader.selectedContentType != .all
    filterActiveBanner
}
```

- [ ] **Step 4: Verify build**

```bash
xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | grep -E "error:|BUILD"
```

- [ ] **Step 5: Commit**

```bash
git add feedmine/Views/FeedScreen.swift feedmine/Views/FeedEmptyStateView.swift
git commit -m "feat: conditional ChipBar visibility, 4-mode empty states, Open Filters button"
```

---

### Task 10: Remove TaxonomyTreeView + Final Cleanup

**Files:**
- Remove: `feedmine/Views/TaxonomyTreeView.swift`
- Modify: `feedmine.xcodeproj/project.pbxproj` (remove file reference)
- Verify: `feedmine/Views/FilterSheetView.swift` (no remaining import or reference)

- [ ] **Step 1: Verify no remaining references to TaxonomyTreeView**

```bash
grep -rn "TaxonomyTreeView" feedmine/ --include="*.swift"
```

Expected: No results (or only in the file being deleted).

- [ ] **Step 2: Remove the file from Xcode project**

Remove `TaxonomyTreeView.swift` from the Xcode project. This can be done by deleting the file and removing the reference from `project.pbxproj`, or via:

```bash
rm feedmine/Views/TaxonomyTreeView.swift
```

Then edit `feedmine.xcodeproj/project.pbxproj` to remove all lines containing `TaxonomyTreeView`.

- [ ] **Step 3: Verify build after removal**

```bash
xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | grep -E "error:|BUILD"
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Run full test suite**

```bash
xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "passed|failed|Executed"
```

Expected: All tests pass, no regressions.

- [ ] **Step 5: Final commit**

```bash
git add -A
git commit -m "refactor: remove TaxonomyTreeView, replaced by TaxonomyBrowseView NavigationStack"
```

---

## Verification Checklist

After all 10 tasks are complete, verify manually:

- [ ] App launches on simulator without crash
- [ ] Filter by taxonomy node → matching content appears
- [ ] Filter by language → matching content appears
- [ ] Combined taxonomy + language filter works (AND semantics)
- [ ] Filter then unfilter → all content returns
- [ ] `TaxonomyBrowseView` opens from FilterSheet → navigates levels smoothly (no freeze)
- [ ] Search in `TaxonomyBrowseView` finds topics by name
- [ ] ChipBar hidden when no filters active
- [ ] ChipBar visible with taxonomy + language chips when filters active
- [ ] Tapping `×` on chip deselects that filter
- [ ] "Clear All Filters" resets everything
- [ ] Empty state shows progress when fetching from sources
- [ ] Empty state shows "No sources enabled" with Open Filters button when all disabled
- [ ] Language default sets on first launch (check with fresh simulator)
- [ ] Language badge appears on taxonomy nodes in BrowseView
- [ ] Pull-to-refresh still works
- [ ] Bookmark feed still works
- [ ] What's New carousel still works
