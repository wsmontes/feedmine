# Feed Architecture v2 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the "download all, filter later" feed architecture with a fair-streaming system backed by SQLite persistent storage, source scheduler with entropy-based selection, and bidirectional filtering.

**Architecture:** FeedStore (central data owner: SQLite + SourceRegistry + SourceScheduler + Reservoir + RSSFetcher) replaces the monolithic FeedLoader. FeedLoader becomes a thin ViewModel exposing UI state. SQLite via GRDB provides 30-day retention, FTS5 search, and persistent bookmarks with custom lists and saved searches.

**Tech Stack:** Swift 6, iOS 18+, SwiftUI, @Observable, GRDB (GRDB.swift), FeedKit, Xcode-managed SPM dependencies

## Global Constraints

- iOS 18+ deployment target
- @Observable macro (iOS 17+ observation), not @ObservableObject
- No migration needed (app has zero production users)
- Swift Concurrency: `async/await`, `@MainActor` for UI-facing state, `actor` for RSSFetcher
- GRDB DatabaseQueue (not DatabasePool — single writer, WAL mode)
- FTS5 for full-text search, content-sync mode (no content duplication)
- FeedItem.id uses SHA256 hash (existing convention)
- All disk I/O off the main actor

---

## File Structure

```
feedmine/
  Services/
    FeedStore.swift            // NEW — central coordinator
    SourceRegistry.swift       // NEW — extracted source management
    SourceScheduler.swift      // NEW — entropy scheduler
    Reservoir.swift            // NEW — extracted interleave + buffer
    FeedLoader.swift           // MODIFIED — slim ViewModel (~400 lines)
    RSSFetcher.swift           // UNCHANGED
    OPMLParser.swift           // UNCHANGED
    PersistenceManager.swift   // REMOVED
    AppContext.swift           // UNCHANGED
    CircadianEngine.swift      // UNCHANGED
    ... (other Services unchanged)
  Models/
    FeedSource.swift           // UNCHANGED
    FeedItem.swift             // UNCHANGED
    FeedFetchBatch.swift       // UNCHANGED
    FeedFetchResult.swift      // UNCHANGED
    Country.swift              // UNCHANGED
    Region.swift               // UNCHANGED
    BookmarkList.swift         // NEW
    ActiveSearch.swift         // NEW
  Views/
    FeedScreen.swift           // MODIFIED — binding adjustments
    FilterSheetView.swift      // MODIFIED — binding adjustments
    BookmarksSheetView.swift   // MODIFIED — list support
    CountriesListScreen.swift  // MODIFIED — binding adjustments (minor)
    CountryDetailScreen.swift  // MODIFIED — binding adjustments (minor)
    ... (other Views unchanged)
  feedmineApp.swift            // MODIFIED — FeedStore injection
```

---

### Task 1: Add GRDB Dependency via Xcode SPM

**Files:**
- Modify: `feedmine.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `import GRDB` available project-wide

- [ ] **Step 1: Add GRDB package reference**

In Xcode: File → Add Package Dependencies → `https://github.com/groue/GRDB.swift` → Exact Version `7.4.0` → Add to feedmine target.

Alternatively, add to `project.pbxproj`:

```swift
// In Xcode project settings:
// Package: https://github.com/groue/GRDB.swift
// Version: 7.4.0 (exact)
// Product: GRDB
```

- [ ] **Step 2: Verify GRDB imports compile**

Create a temporary test file to verify:

```swift
// Temporary — delete after verification
import GRDB
print("GRDB \(GRDBVersion)")
```

- [ ] **Step 3: Build verification**

Run: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build`

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Clean up temp test file and commit**

```bash
git add feedmine.xcodeproj/project.pbxproj
git commit -m "chore: add GRDB 7.4.0 dependency

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Create SQLite Schema with GRDB Migrator

**Files:**
- Create: `feedmine/Services/FeedStore.swift`

**Interfaces:**
- Produces: `final class FeedStore` with `let db: DatabaseQueue`, schema v1 migration, and `func writeItems(_ items: [FeedItem]) async throws`

- [ ] **Step 1: Write schema migration**

```swift
// feedmine/Services/FeedStore.swift
import Foundation
import GRDB

final class FeedStore {
    let db: DatabaseQueue

    init() throws {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dbURL = docs.appendingPathComponent("feedmine.sqlite")
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        self.db = try DatabaseQueue(path: dbURL.path, configuration: config)
        try migrate()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "feed_item") { t in
                t.primaryKey("id", .text)
                t.column("source_url", .text).notNull()
                t.column("source_title", .text).notNull()
                t.column("region", .text).notNull()
                t.column("category", .text).notNull()
                t.column("title", .text).notNull()
                t.column("excerpt", .text).notNull()
                t.column("url", .text).notNull()
                t.column("image_url", .text)
                t.column("audio_url", .text)
                t.column("duration", .double)
                t.column("published_at", .integer).notNull()
                t.column("fetched_at", .integer).notNull()
                t.column("is_read", .integer).notNull().defaults(to: 0)
                t.column("opened_at", .integer)
            }
            try db.create(index: "idx_item_region_date",
                          on: "feed_item", columns: ["region", "published_at"])
            try db.create(index: "idx_item_fetched",
                          on: "feed_item", columns: ["fetched_at"])
            try db.create(index: "idx_item_read",
                          on: "feed_item", columns: ["is_read"],
                          condition: "is_read = 1")

            try db.create(table: "bookmark_list") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("created_at", .integer).notNull()
                t.column("is_default", .integer).notNull().defaults(to: 0)
                t.column("search_query", .text)
                t.column("search_region", .text)
                t.column("search_category", .text)
                t.column("search_active", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "bookmark_item") { t in
                t.column("list_id", .integer).notNull()
                    .references("bookmark_list", onDelete: .cascade)
                t.column("item_id", .text).notNull()
                    .references("feed_item", onDelete: .cascade)
                t.column("added_at", .integer).notNull()
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.primaryKey(["list_id", "item_id"])
            }
            try db.create(index: "idx_bookmark_item_list",
                          on: "bookmark_item", columns: ["list_id", "sort_order"])
            try db.create(index: "idx_bookmark_item_item",
                          on: "bookmark_item", columns: ["item_id"])

            try db.create(virtualTable: "feed_item_fts", using: FTS5()) { t in
                t.synchronize(withTable: "feed_item")
                t.column("title")
                t.column("excerpt")
                t.column("source_title")
                t.column("category")
            }

            // Default "Favorites" list
            try db.execute(sql: """
                INSERT INTO bookmark_list (name, sort_order, created_at, is_default)
                VALUES ('Favorites', 0, \(Int(Date().timeIntervalSince1970)), 1)
            """)
        }
        try migrator.migrate(db)
    }
}
```

- [ ] **Step 2: Add FeedItem GRDB conformance**

```swift
// Add at bottom of FeedStore.swift, after the class

// MARK: - FeedItem GRDB Record

extension FeedItem: FetchableRecord, PersistableRecord {
    // Table name
    public static var databaseTableName: String { "feed_item" }

    // Encodable — map Swift names to SQL columns
    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["source_url"] = sourceURL
        container["source_title"] = sourceTitle
        container["region"] = "global" // placeholder — set before insert
        container["category"] = category
        container["title"] = title
        container["excerpt"] = excerpt
        container["url"] = url
        container["image_url"] = imageURL
        container["audio_url"] = audioURL
        container["duration"] = duration
        container["published_at"] = Int(publishedAt.timeIntervalSince1970)
        container["fetched_at"] = Int(Date().timeIntervalSince1970)
        container["is_read"] = 0
        container["opened_at"] = nil
    }

    // Decodable — init from row
    public init(row: Row) throws {
        self.id = row["id"]
        self.sourceTitle = row["source_title"]
        self.sourceURL = row["source_url"]
        self.category = row["category"]
        self.title = row["title"]
        self.excerpt = row["excerpt"]
        self.url = row["url"]
        self.imageURL = row["image_url"]
        self.audioURL = row["audio_url"]
        self.duration = row["duration"]
        self.publishedAt = Date(timeIntervalSince1970: TimeInterval(row["published_at"]))
    }
}
```

Wait — `FeedItem` already conforms to `Codable` and has its own `init`. Adding GRDB `FetchableRecord` means we need `init(row:)`. But GRDB supports `Codable` records too — we can use `MutablePersistableRecord` and let the existing `Codable` handle encoding/decoding by mapping columns to coding keys.

Actually, GRDB can derive `FetchableRecord` and `PersistableRecord` from `Codable` when column names match property names. But our column names (`source_url`) don't match Swift names (`sourceURL`). We need either:
1. Custom `CodingKeys` with raw values matching column names
2. Manual `encode`/`init(row:)` as shown

Option 2 is more explicit. But we also need `region` which isn't part of `FeedItem`'s stored properties — it comes from `FeedSource.region` at insert time. This means we can't rely purely on `FeedItem`'s `Codable` conformance for GRDB. We need a thin wrapper or explicit encode.

Let me reconsider. Since `region` comes from the source, not the item, we should handle it at insert time in `FeedStore.writeItems`. The `FeedItem` record becomes:

```swift
// Simpler approach: define a "write record" struct
struct FeedItemRecord: Codable, PersistableRecord {
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
    var publishedAt: Date
    var fetchedAt: Date

    static var databaseTableName: String { "feed_item" }

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
    }

    init(from item: FeedItem, region: String) {
        self.id = item.id
        self.sourceURL = item.sourceURL
        self.sourceTitle = item.sourceTitle
        self.region = region
        self.category = item.category
        self.title = item.title
        self.excerpt = item.excerpt
        self.url = item.url
        self.imageURL = item.imageURL
        self.audioURL = item.audioURL
        self.duration = item.duration
        self.publishedAt = item.publishedAt
        self.fetchedAt = Date()
    }
}
```

This is cleaner — `FeedItem` stays pure domain model, `FeedItemRecord` handles persistence mapping. Let me rewrite the plan accordingly.

- [ ] **Step 2: Add FeedItemRecord for GRDB mapping**

```swift
// Add at bottom of FeedStore.swift

/// Thin persistence record — maps FeedItem to SQLite columns.
/// Separate from FeedItem to avoid polluting the domain model with GRDB details.
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
    var publishedAt: Date
    var fetchedAt: Date
    var isRead: Bool
    var openedAt: Date?

    static var databaseTableName: String { "feed_item" }

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
    }

    init(from item: FeedItem, region: String) {
        self.id = item.id
        self.sourceURL = item.sourceURL
        self.sourceTitle = item.sourceTitle
        self.region = region
        self.category = item.category
        self.title = item.title
        self.excerpt = item.excerpt
        self.url = item.url
        self.imageURL = item.imageURL
        self.audioURL = item.audioURL
        self.duration = item.duration
        self.publishedAt = item.publishedAt
        self.fetchedAt = Date()
        self.isRead = false
        self.openedAt = nil
    }

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
            publishedAt: publishedAt,
            audioURL: audioURL,
            duration: duration
        )
    }
}

// Bookmark models
struct BookmarkListRecord: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var name: String
    var sortOrder: Int
    var createdAt: Date
    var isDefault: Bool
    var searchQuery: String?
    var searchRegion: String?
    var searchCategory: String?
    var searchActive: Bool

    static var databaseTableName: String { "bookmark_list" }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case isDefault = "is_default"
        case searchQuery = "search_query"
        case searchRegion = "search_region"
        case searchCategory = "search_category"
        case searchActive = "search_active"
    }
}

struct BookmarkItemRecord: Codable, FetchableRecord, PersistableRecord {
    var listId: Int64
    var itemId: String
    var addedAt: Date
    var sortOrder: Int

    static var databaseTableName: String { "bookmark_item" }

    enum CodingKeys: String, CodingKey {
        case listId = "list_id"
        case itemId = "item_id"
        case addedAt = "added_at"
        case sortOrder = "sort_order"
    }
}
```

- [ ] **Step 3: Add writeItems method**

```swift
// Inside FeedStore class

/// Map source URLs to their regions for fast lookup during inserts.
private var sourceRegionMap: [String: String] = [:]

/// Bulk insert fetched items into SQLite. Skips duplicates (ON CONFLICT IGNORE via PK).
func writeItems(_ items: [FeedItem], region: String) async throws {
    let records = items.map { FeedItemRecord(from: $0, region: region) }
    try await db.write { db in
        for record in records {
            try record.insert(db)
        }
    }
}
```

- [ ] **Step 4: Build verification**

Run: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build`

Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add feedmine/Services/FeedStore.swift
git commit -m "feat: create FeedStore with GRDB schema v1

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Create SourceRegistry (extract from FeedLoader)

**Files:**
- Create: `feedmine/Services/SourceRegistry.swift`
- Read for reference: `feedmine/Services/FeedLoader.swift:290-334` (availableCountries), `:598-603` (enabledSources), `:606-617` (toggleSource), `:358-446` (toggleRegion)

**Interfaces:**
- Consumes: `FeedSource` model, `Country` model, `Region` model, `OPMLParser`
- Produces:
  - `final class SourceRegistry` with `var sources: [FeedSource]`, `var disabledRegions: Set<String>`, `var disabledSourceIDs: Set<String>`
  - `var enabledSources: [FeedSource]`
  - `var availableCountries: [Country]`
  - `func toggleRegion(_:)`, `func toggleSource(_:)`, `func toggleAllCountries()`
  - `func regionFor(sourceURL: String) -> String`

- [ ] **Step 1: Create SourceRegistry**

```swift
// feedmine/Services/SourceRegistry.swift
import Foundation
import Observation

/// Manages the feed source catalog: OPML parsing, enabled/disabled state,
/// country/region groupings. Extracted from FeedLoader.
@Observable
final class SourceRegistry {
    private(set) var sources: [FeedSource] = []
    var disabledRegions: Set<String> = []
    var disabledSourceIDs: Set<String> = []

    // Debug counters
    private(set) var opmlFileCount = 0
    private(set) var invalidSourceCount = 0
    private(set) var duplicateSourceCount = 0
    private(set) var opmlErrorCount = 0

    // MARK: - Enabled sources

    var enabledSources: [FeedSource] {
        sources.filter { source in
            if disabledSourceIDs.contains(source.url) { return false }
            if disabledRegions.contains(source.region) { return false }
            return true
        }
    }

    var sourceCount: Int { sources.count }

    // MARK: - Region lookup

    private var _regionMap: [String: String]?
    var regionMap: [String: String] {
        if let cached = _regionMap { return cached }
        let map = Dictionary(sources.map { ($0.url, $0.region) }, uniquingKeysWith: { first, _ in first })
        _regionMap = map
        return map
    }

    func regionFor(sourceURL: String) -> String {
        regionMap[sourceURL] ?? "global"
    }

    // MARK: - Countries

    var availableCountries: [Country] {
        let grouped = Dictionary(grouping: sources, by: \.region)
        let countryRegions = grouped.keys.filter { key in
            guard key.hasPrefix("countries/") else { return false }
            let remainder = key.replacingOccurrences(of: "countries/", with: "")
            return !remainder.contains("/")
        }
        return countryRegions.compactMap { region -> Country? in
            let slug = region.replacingOccurrences(of: "countries/", with: "")
            let countryFeeds = grouped[region] ?? []
            let regionPrefix = "\(region)/"
            let subRegions = grouped
                .filter { $0.key.hasPrefix(regionPrefix) }
                .compactMap { subRegionPath, feeds -> Region? in
                    let regionSlug = subRegionPath.replacingOccurrences(of: regionPrefix, with: "")
                    guard !regionSlug.isEmpty else { return nil }
                    return Region(
                        path: subRegionPath,
                        countrySlug: slug,
                        slug: regionSlug,
                        name: regionSlug.replacingOccurrences(of: "-", with: " ").capitalized,
                        feedCount: feeds.count,
                        categories: Array(Set(feeds.map(\.category))).sorted()
                    )
                }
                .sorted { $0.name < $1.name }
            return Country(
                region: region,
                name: CountryStore.countryName(for: slug),
                flag: CountryStore.countryFlag(for: slug),
                feedCount: countryFeeds.count,
                categories: Array(Set(countryFeeds.map(\.category))).sorted(),
                regions: subRegions
            )
        }
        .sorted { $0.name < $1.name }
    }

    // MARK: - Toggle actions

    func toggleRegion(_ region: String) {
        if disabledRegions.contains(region) {
            disabledRegions.remove(region)
            let prefix = "\(region)/"
            for subRegion in sources.map(\.region) where subRegion.hasPrefix(prefix) {
                disabledRegions.remove(subRegion)
            }
        } else {
            disabledRegions.insert(region)
            let prefix = "\(region)/"
            for subRegion in sources.map(\.region) where subRegion.hasPrefix(prefix) {
                disabledRegions.insert(subRegion)
            }
        }
    }

    func toggleAllCountries() {
        let allCountryRegions = Set(sources.filter { $0.isCountryFeed }.map(\.region))
        let anyEnabled = allCountryRegions.contains { !disabledRegions.contains($0) }
        if anyEnabled {
            disabledRegions.formUnion(allCountryRegions)
        } else {
            disabledRegions.subtract(allCountryRegions)
        }
    }

    var isAnyCountryEnabled: Bool {
        sources.contains { $0.isCountryFeed && !disabledRegions.contains($0.region) }
    }

    func toggleSource(_ sourceURL: String) {
        if disabledSourceIDs.contains(sourceURL) {
            disabledSourceIDs.remove(sourceURL)
        } else {
            disabledSourceIDs.insert(sourceURL)
        }
    }

    func isSourceEnabled(_ sourceURL: String) -> Bool {
        !disabledSourceIDs.contains(sourceURL)
    }

    func isRegionEnabled(_ region: String) -> Bool {
        !disabledRegions.contains(region)
    }

    // MARK: - Load

    func loadFromOPML() async {
        let result = await OPMLParser.parseAll()
        sources = result.sources
        opmlFileCount = result.fileCount
        opmlErrorCount = result.failedFileCount
        invalidSourceCount = result.invalidSourceCount
        duplicateSourceCount = result.duplicateSourceCount
        _regionMap = nil

        // Countries off by default on first launch
        if disabledRegions.isEmpty {
            let allCountryRegions = Set(sources.filter { $0.isCountryFeed }.map(\.region))
            disabledRegions.formUnion(allCountryRegions)
        }
    }
}
```

- [ ] **Step 2: Build verification**

Run: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build`

Expected: BUILD SUCCEEDED (FeedLoader still has its own copies — no conflicts yet)

- [ ] **Step 3: Commit**

```bash
git add feedmine/Services/SourceRegistry.swift
git commit -m "feat: create SourceRegistry extracted from FeedLoader

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: Create Reservoir (extract interleave from FeedLoader)

**Files:**
- Create: `feedmine/Services/Reservoir.swift`
- Read for reference: `feedmine/Services/FeedLoader.swift:700-980` (all interleave logic, capReservoir, moveFromReservoirToVisible, trimBufferIfNeeded)

**Interfaces:**
- Consumes: `FeedItem` model, `SourceRegistry.regionMap`
- Produces:
  - `final class Reservoir` with `var visibleItems: [FeedItem]`, `var reservoirCount: Int`
  - `func seed(items: [FeedItem])`, `func moveToVisible(count: Int)`, `func append(_ items: [FeedItem], fromRegion: String)`
  - `func removeRegion(_ region: String)`, `func clear()`, `func emergencyTrim()`

- [ ] **Step 1: Create Reservoir class with interleave engine**

```swift
// feedmine/Services/Reservoir.swift
import Foundation

/// In-memory buffer with fairness interleave and source/region diversity.
/// Extracted from FeedLoader. Does NOT touch SQLite — only holds FeedItem arrays.
final class Reservoir {
    static let maxBuffer = 300
    static let pageSize = 20
    static let loadMoreThreshold = 5
    static let discardBatchSize = 50
    static let reservoirLowWatermark = 30
    static let safetyZoneRadius = 50
    static let maxReservoirSize = 500
    static let surfacedCooldown: TimeInterval = 1800
    static let reshuffleInterval = 5

    private(set) var visibleItems: [FeedItem] = []
    private(set) var reservoir: [FeedItem] = []
    var reservoirCount: Int { reservoir.count }
    private var surfacedTimestamps: [String: Date] = [:]
    private var moveCountSinceReshuffle = 0

    /// URL → region lookup, provided by SourceRegistry
    var sourceRegionMap: [String: String] = [:]

    // MARK: - Seed (cold/warm start)

    func seed(items: [FeedItem]) {
        let interleaved = interleave(items)
        let w = min(Self.pageSize, interleaved.count)
        visibleItems = Array(interleaved.prefix(w))
        reservoir = Array(interleaved.dropFirst(w))
        capReservoir()
        markAsSurfaced(visibleItems)
    }

    // MARK: - Append new items from fetch

    func append(_ items: [FeedItem]) {
        reservoir.append(contentsOf: items)
        dedupReservoir()
        reservoir = interleave(reservoir)
        capReservoir()
    }

    // MARK: - Scroll: move from reservoir to visible

    func moveToVisible(count: Int) {
        guard !reservoir.isEmpty else { return }
        moveCountSinceReshuffle += 1
        if moveCountSinceReshuffle >= Self.reshuffleInterval && reservoir.count > count {
            reservoir = interleave(reservoir)
            moveCountSinceReshuffle = 0
        }
        let toMove = min(count, reservoir.count)
        let batch = Array(reservoir.prefix(toMove))
        visibleItems.append(contentsOf: batch)
        reservoir.removeFirst(toMove)
        markAsSurfaced(batch)
    }

    // MARK: - Trim buffer

    func trimBuffer(currentVisibleIndex: Int) {
        guard visibleItems.count > Self.maxBuffer else { return }
        let excess = visibleItems.count - Self.maxBuffer
        let toDiscard = min(Self.discardBatchSize, excess)
        let safeStart = max(0, currentVisibleIndex - Self.safetyZoneRadius)
        let aboveToDiscard = min(toDiscard, safeStart)
        if aboveToDiscard > 0 {
            visibleItems.removeFirst(aboveToDiscard)
        }
        let remaining = toDiscard - aboveToDiscard
        if remaining > 0 && visibleItems.count > Self.maxBuffer {
            let safeEnd = min(visibleItems.count, currentVisibleIndex + Self.safetyZoneRadius)
            if safeEnd < visibleItems.count {
                let belowToDiscard = min(remaining, visibleItems.count - safeEnd)
                if belowToDiscard > 0 {
                    visibleItems.removeLast(belowToDiscard)
                }
            }
        }
    }

    // MARK: - Remove region (toggle OFF)

    func removeRegion(_ region: String) {
        let isDisabled: (FeedItem) -> Bool = { item in
            (sourceRegionMap[item.sourceURL] ?? "global") == region
        }
        visibleItems.removeAll(where: isDisabled)
        reservoir.removeAll(where: isDisabled)
        // Top up visible if depleted
        if visibleItems.count < Self.pageSize && !reservoir.isEmpty {
            let needed = Self.pageSize - visibleItems.count
            let batch = Array(reservoir.prefix(needed))
            visibleItems.append(contentsOf: batch)
            reservoir.removeFirst(needed)
        }
    }

    // MARK: - Clear + emergency

    func clear() {
        visibleItems.removeAll()
        reservoir.removeAll()
        surfacedTimestamps.removeAll()
        moveCountSinceReshuffle = 0
    }

    func emergencyTrim() {
        let safeCount = Self.safetyZoneRadius * 2
        if visibleItems.count > safeCount {
            visibleItems = Array(visibleItems.suffix(safeCount))
        }
        reservoir.removeAll()
    }

    // MARK: - Interleave

    private func interleave(_ items: [FeedItem]) -> [FeedItem] {
        guard items.count > 1 else { return items }
        var bySource: [String: [FeedItem]] = [:]
        for item in items {
            bySource[item.sourceURL, default: []].append(item)
        }
        guard bySource.count > 1 else {
            return interleaveByTypeCategory(items)
        }
        // Within each source: surfaced → stale → recent, each spread by type+category
        let surfacedCutoff = Date().addingTimeInterval(-Self.surfacedCooldown)
        let staleNewsCutoff = Date().addingTimeInterval(-86400)
        let staleEvergreenCutoff = Date().addingTimeInterval(-604800)
        for key in bySource.keys {
            let bucket = bySource[key]!
            let surfacedIDs = Set(bucket.filter { item in
                guard let ts = surfacedTimestamps[item.id] else { return false }
                return ts > surfacedCutoff
            }.map(\.id))
            let staleIDs = Set(bucket.filter { item in
                if surfacedIDs.contains(item.id) { return false }
                let cutoff = item.isTimeless ? staleEvergreenCutoff : staleNewsCutoff
                return item.publishedAt < cutoff
            }.map(\.id))
            let recent = interleaveByTypeCategory(bucket.filter { !surfacedIDs.contains($0.id) && !staleIDs.contains($0.id) }.shuffled())
            let stale = interleaveByTypeCategory(bucket.filter { staleIDs.contains($0.id) }.shuffled())
            let surfaced = interleaveByTypeCategory(bucket.filter { surfacedIDs.contains($0.id) }.shuffled())
            bySource[key] = recent + stale + surfaced
        }
        // Weighted slots → spread → round-robin
        let minCount = max(1, bySource.values.map(\.count).min() ?? 1)
        let weights: [String: Int] = bySource.mapValues { min(5, max(1, $0.count / minCount)) }
        var slots: [String] = []
        for (sourceURL, srcItems) in bySource where !srcItems.isEmpty {
            let w = weights[sourceURL] ?? 1
            for _ in 0..<w { slots.append(sourceURL) }
        }
        slots = spreadSlots(slots)
        slots = spreadSlotsByCountry(slots)
        var result: [FeedItem] = []
        result.reserveCapacity(items.count)
        var indices: [String: Int] = Dictionary(uniqueKeysWithValues: bySource.keys.map { ($0, 0) })
        var added = true
        while added {
            added = false
            for sourceURL in slots {
                guard let list = bySource[sourceURL], indices[sourceURL]! < list.count else { continue }
                result.append(list[indices[sourceURL]!])
                indices[sourceURL]! += 1
                added = true
            }
        }
        return result
    }

    private func interleaveByTypeCategory(_ items: [FeedItem]) -> [FeedItem] {
        guard items.count > 1 else { return items }
        var buckets: [String: [FeedItem]] = [:]
        for item in items {
            let type = item.isPodcast ? "audio" : (item.isYouTube ? "video" : "text")
            buckets["\(type):\(item.category)", default: []].append(item)
        }
        guard buckets.count > 1 else { return items.shuffled() }
        for key in buckets.keys { buckets[key] = buckets[key]?.shuffled() }
        var result: [FeedItem] = []
        result.reserveCapacity(items.count)
        let keys = buckets.keys.shuffled()
        var indices = Dictionary(uniqueKeysWithValues: keys.map { ($0, 0) })
        var added = true
        while added {
            added = false
            for key in keys {
                guard let list = buckets[key], indices[key]! < list.count else { continue }
                result.append(list[indices[key]!])
                indices[key]! += 1
                added = true
            }
        }
        return result
    }

    private func spreadSlots(_ slots: [String]) -> [String] {
        var groups: [String: [String]] = [:]
        for slot in slots { groups[slot, default: []].append(slot) }
        guard groups.count > 1 else { return slots }
        for key in groups.keys { groups[key] = groups[key]?.shuffled() }
        var result: [String] = []
        result.reserveCapacity(slots.count)
        let keys = groups.keys.shuffled()
        var indices = Dictionary(uniqueKeysWithValues: keys.map { ($0, 0) })
        var added = true
        while added {
            added = false
            for key in keys {
                guard let list = groups[key], indices[key]! < list.count else { continue }
                result.append(list[indices[key]!])
                indices[key]! += 1
                added = true
            }
        }
        return result
    }

    private func spreadSlotsByCountry(_ slots: [String]) -> [String] {
        guard slots.count > 2 else { return slots }
        var result = slots
        var pass = 0
        var swapped = true
        while swapped && pass < 3 {
            swapped = false; pass += 1
            for i in 0..<(result.count - 1) {
                let countryA = sourceRegionMap[result[i]] ?? "global"
                let countryB = sourceRegionMap[result[i + 1]] ?? "global"
                guard countryA == countryB else { continue }
                var swapIdx: Int?
                for j in (i + 2)..<result.count {
                    if (sourceRegionMap[result[j]] ?? "global") != countryA { swapIdx = j; break }
                }
                if swapIdx == nil {
                    for j in stride(from: i - 1, through: 0, by: -1) {
                        if (sourceRegionMap[result[j]] ?? "global") != countryA { swapIdx = j; break }
                    }
                }
                if let j = swapIdx { result.swapAt(i + 1, j); swapped = true }
            }
        }
        return result
    }

    private func dedupReservoir() {
        var seen = Set<String>()
        reservoir = reservoir.filter { seen.insert($0.id).inserted }
    }

    private func capReservoir() {
        guard reservoir.count > Self.maxReservoirSize else { return }
        var bySource: [String: [FeedItem]] = [:]
        for item in reservoir { bySource[item.sourceURL, default: []].append(item) }
        let sourceCount = bySource.count
        guard sourceCount > 1 else {
            reservoir = Array(reservoir.prefix(Self.maxReservoirSize))
            return
        }
        let floorPerSource = 1
        let floorSlots = min(sourceCount * floorPerSource, Self.maxReservoirSize)
        let proportionalSlots = Self.maxReservoirSize - floorSlots
        var selected: [FeedItem] = []
        var remainingBySource: [String: [FeedItem]] = [:]
        for (sourceURL, items) in bySource {
            let take = min(floorPerSource, items.count)
            selected.append(contentsOf: items.prefix(take))
            if items.count > take { remainingBySource[sourceURL] = Array(items.dropFirst(take)) }
        }
        if proportionalSlots > 0, !remainingBySource.isEmpty {
            let totalRemaining = remainingBySource.values.map(\.count).reduce(0, +)
            for (sourceURL, items) in remainingBySource {
                let fraction = Double(items.count) / Double(max(1, totalRemaining))
                let extra = min(Int(fraction * Double(proportionalSlots)), items.count)
                if extra > 0 {
                    selected.append(contentsOf: items.prefix(extra))
                    if items.count > extra {
                        remainingBySource[sourceURL] = Array(items.dropFirst(extra))
                    } else {
                        remainingBySource.removeValue(forKey: sourceURL)
                    }
                }
            }
        }
        if selected.count < Self.maxReservoirSize, !remainingBySource.isEmpty {
            let keys = remainingBySource.keys.shuffled()
            var indices = Dictionary(uniqueKeysWithValues: keys.map { ($0, 0) })
            while selected.count < Self.maxReservoirSize {
                var added = false
                for key in keys {
                    guard let list = remainingBySource[key],
                          indices[key]! < list.count,
                          selected.count < Self.maxReservoirSize else { continue }
                    selected.append(list[indices[key]!])
                    indices[key]! += 1
                    added = true
                }
                if !added { break }
            }
        }
        reservoir = interleave(selected)
    }

    private func markAsSurfaced(_ items: [FeedItem]) {
        let now = Date()
        for item in items {
            if surfacedTimestamps[item.id] == nil {
                surfacedTimestamps[item.id] = now
            }
        }
        if surfacedTimestamps.count > 2000 {
            let cutoff = now.addingTimeInterval(-Self.surfacedCooldown)
            surfacedTimestamps = surfacedTimestamps.filter { $0.value > cutoff }
        }
    }
}
```

- [ ] **Step 2: Build verification**

Run: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add feedmine/Services/Reservoir.swift
git commit -m "feat: create Reservoir extracted from FeedLoader interleave engine

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: Create SourceScheduler

**Files:**
- Create: `feedmine/Services/SourceScheduler.swift`

**Interfaces:**
- Consumes: `FeedSource` model, `Reservoir` (for entropy analysis)
- Produces:
  - `final class SourceScheduler` with `func nextBatch(reservoir: [FeedItem], sourcesByRegion: [String: [FeedSource]], activeRegion: String?, activeCategory: String?) -> [FeedSource]`
  - `func recordFetch(sourceURL: String, success: Bool)`, `func recordConsumption()`
  - `func prioritize(region: String)`, `func remove(region: String)`

- [ ] **Step 1: Create SourceScheduler**

```swift
// feedmine/Services/SourceScheduler.swift
import Foundation

/// Selects which feed sources to fetch next based on reservoir entropy.
/// Uses √n fairness between regions, LRU ordering within regions,
/// and soft cooldown instead of hard timeouts.
final class SourceScheduler {
    private var lastFetchedAt: [String: Date] = [:]
    private var consecutiveFailures: [String: Int] = [:]
    private var consumptionTimestamps: [Date] = []

    // MARK: - Public API

    func nextBatch(
        reservoir: [FeedItem],
        sourcesByRegion: [String: [FeedSource]],
        activeRegion: String?,
        activeCategory: String?
    ) -> [FeedSource] {
        // 1. Determine scope
        let regions = activeRegion.map { [$0] } ?? Array(sourcesByRegion.keys)
        guard !regions.isEmpty else { return [] }

        // 2. Measure consumption — how much buffer do we need?
        let bufferNeeded = estimatedBufferNeeded()
        let currentBuffer = reservoir.count
        guard currentBuffer < bufferNeeded else { return [] }

        // 3. Measure entropy — distribution of regions/categories in reservoir
        let regionDistribution = distribution(of: reservoir, key: { item -> String in
            item.sourceURL // will be mapped to region by caller
        })
        let categoryDistribution = distribution(of: reservoir, key: \.category)

        // 4. Calculate ideal distribution (√n for regions, uniform for categories)
        let regionWeights = sqrtWeights(for: sourcesByRegion)
        let allCategories = Set(sourcesByRegion.values.flatMap { $0 }.map(\.category))
        let idealRegionDist = normalize(regionWeights)
        let idealCategoryDist = normalize(Dictionary(uniqueKeysWithValues: allCategories.map { ($0, 1.0) }))

        // 5. Calculate deficits
        let regionDeficits = deficits(ideal: idealRegionDist, actual: regionDistribution)
        let categoryDeficits = deficits(ideal: idealCategoryDist, actual: categoryDistribution)

        // 6. Select sources that compensate deficits
        var selected: [FeedSource] = []
        var selectedURLs = Set<String>()
        let deficitNeeded = Int(ceil(Double(bufferNeeded - currentBuffer) / 3.0)) // ~3 items per source

        for _ in 0..<max(deficitNeeded, 10) {
            guard let best = bestSource(
                regions: regions,
                sourcesByRegion: sourcesByRegion,
                regionDeficits: regionDeficits,
                categoryDeficits: categoryDeficits,
                selectedURLs: selectedURLs
            ) else { break }
            selected.append(best)
            selectedURLs.insert(best.url)
        }
        return selected
    }

    func recordConsumption() {
        consumptionTimestamps.append(Date())
        // Keep only last 5 minutes
        let cutoff = Date().addingTimeInterval(-300)
        consumptionTimestamps = consumptionTimestamps.filter { $0 > cutoff }
    }

    func recordFetch(sourceURL: String, success: Bool) {
        lastFetchedAt[sourceURL] = Date()
        if success {
            consecutiveFailures[sourceURL] = 0
        } else {
            consecutiveFailures[sourceURL, default: 0] += 1
        }
    }

    func prioritize(region: String) {
        // Will be used when toggling ON — all sources in region get nil lastFetchedAt
        // which puts them at the front of LRU. Handled by caller clearing entries.
    }

    func remove(region: String) {
        // Remove sources from tracking when region toggled OFF. Handled by caller.
    }

    // MARK: - Private

    private func estimatedBufferNeeded() -> Int {
        let recent = consumptionTimestamps.filter { $0 > Date().addingTimeInterval(-120) }
        let rate = Double(recent.count) / 2.0 // scrolls per second over last 2 min
        let target = Int(rate * 180) // 3 min buffer
        return max(50, min(500, target))
    }

    private func distribution<T: Hashable>(of items: [FeedItem], key: (FeedItem) -> T) -> [T: Double] {
        guard !items.isEmpty else { return [:] }
        var counts: [T: Int] = [:]
        for item in items { counts[key(item), default: 0] += 1 }
        let total = Double(items.count)
        return counts.mapValues { Double($0) / total }
    }

    private func sqrtWeights(for sourcesByRegion: [String: [FeedSource]]) -> [String: Double] {
        sourcesByRegion.mapValues { sqrt(Double($0.count)) }
    }

    private func normalize(_ weights: [String: Double]) -> [String: Double] {
        let total = weights.values.reduce(0, +)
        guard total > 0 else { return weights }
        return weights.mapValues { $0 / total }
    }

    private func deficits(ideal: [String: Double], actual: [String: Double]) -> [String: Double] {
        var result: [String: Double] = [:]
        for (key, idealVal) in ideal {
            let actualVal = actual[key] ?? 0
            result[key] = idealVal - actualVal
        }
        return result
    }

    private func bestSource(
        regions: [String],
        sourcesByRegion: [String: [FeedSource]],
        regionDeficits: [String: Double],
        categoryDeficits: [String: Double],
        selectedURLs: Set<String>
    ) -> FeedSource? {
        var best: FeedSource?
        var bestScore = -Double.infinity

        for region in regions {
            guard let sources = sourcesByRegion[region] else { continue }
            for source in sources {
                guard !selectedURLs.contains(source.url) else { continue }
                // Check failure backoff
                let failures = consecutiveFailures[source.url] ?? 0
                if failures >= 3 {
                    let backoff = pow(2.0, Double(failures - 2)) * 60
                    if let last = lastFetchedAt[source.url],
                       Date().timeIntervalSince(last) < backoff {
                        continue // in backoff
                    }
                }
                let regionDeficit = regionDeficits[region] ?? 0
                let catDeficit = categoryDeficits[source.category] ?? 0
                // Soft cooldown: applies 0→1 weight over 30 min
                let timeFactor: Double
                if let last = lastFetchedAt[source.url] {
                    timeFactor = min(1.0, Date().timeIntervalSince(last) / 1800)
                } else {
                    timeFactor = 1.0 // never fetched → full priority
                }
                let score = regionDeficit * catDeficit * timeFactor
                if score > bestScore {
                    bestScore = score
                    best = source
                }
            }
        }
        return best
    }
}
```

- [ ] **Step 2: Build verification**

Run: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add feedmine/Services/SourceScheduler.swift
git commit -m "feat: create SourceScheduler with entropy-based selection

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 6: Connect FeedStore — Wire Components Together

**Files:**
- Modify: `feedmine/Services/FeedStore.swift`
- Read for reference: `feedmine/Services/FeedLoader.swift:1072-1155` (start method), `:1218-1271` (fetchFreshContent), `:1510-1540` (refillReservoir), `:1158-1216` (fetchAllContent)

**Interfaces:**
- Consumes: `SourceRegistry`, `SourceScheduler`, `Reservoir`, `RSSFetcher`
- Produces: `func start() async`, `func loadMore() async`, `func refreshIfStale() async`, `func setFilter(region:, category:, type:)`, `func search(_: String)`, `func clearSearch()`

- [ ] **Step 1: Expand FeedStore with all components and coordination logic**

```swift
// Add to FeedStore class (replace the existing skeleton with full implementation)

import Foundation
import GRDB
import Observation

@MainActor
@Observable
final class FeedStore {
    // MARK: - Subcomponents
    let db: DatabaseQueue
    let registry = SourceRegistry()
    let scheduler = SourceScheduler()
    let reservoir = Reservoir()
    let fetcher = RSSFetcher()
    let networkMonitor = NetworkMonitor()

    // MARK: - Public state
    private(set) var visibleItems: [FeedItem] = []
    private(set) var reservoirCount: Int = 0
    private(set) var loadingState: FeedLoadingState = .idle
    private(set) var lastRefreshDate: Date?
    private(set) var totalFetched = 0
    private(set) var fetchErrorCount = 0
    private(set) var emptyFeedCount = 0

    // MARK: - Filter state (bidirectional)
    var activeRegion: String?
    var activeCategory: String?
    var activeContentType: FeedLoader.ContentType = .all
    var isSearching = false
    private var searchResults: [FeedItem] = []

    // MARK: - Read state
    private(set) var readItemIDs: Set<String> = []
    private var loadedIDs: Set<String> = []  // Bloom filter for dedup

    // MARK: - Init
    init() throws {
        self.db = try DatabaseQueue(path: Self.dbPath, configuration: Self.dbConfig)
        try Self.migrate(db)
        // Create default "Favorites" list if not exists
        try? db.write { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bookmark_list WHERE is_default = 1") ?? 0
            if count == 0 {
                try db.execute(sql: """
                    INSERT INTO bookmark_list (name, sort_order, created_at, is_default)
                    VALUES ('Favorites', 0, \(Int(Date().timeIntervalSince1970)), 1)
                """)
            }
        }
    }

    private static var dbPath: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("feedmine.sqlite").path
    }

    private static var dbConfig: Configuration {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        return config
    }

    // MARK: - Start (cold + warm)

    func start() async {
        loadingState = .initial
        networkMonitor.start()
        await registry.loadFromOPML()
        reservoir.sourceRegionMap = registry.regionMap

        // Warm start: hydrate from SQLite
        let cached = try? await loadReservoir()
        if let items = cached, !items.isEmpty {
            reservoir.seed(items: items)
            visibleItems = reservoir.visibleItems
            reservoirCount = reservoir.reservoirCount
            loadingState = .idle
        }

        guard !registry.enabledSources.isEmpty else {
            loadingState = .idle
            return
        }

        // Background: start fetching
        await fetchNextBatch()

        // If still empty, progressive fetch
        if visibleItems.isEmpty {
            await progressiveFetch()
        }
        loadingState = .idle
    }

    // MARK: - Scroll
    private var lastLoadedIndex = -1

    func loadMoreIfNeeded(currentItem: FeedItem) async {
        guard let itemIndex = visibleItems.firstIndex(where: { $0.id == currentItem.id }) else { return }
        guard itemIndex >= visibleItems.count - Reservoir.loadMoreThreshold else { return }
        guard itemIndex != lastLoadedIndex else { return }
        lastLoadedIndex = itemIndex

        scheduler.recordConsumption()
        reservoir.moveToVisible(count: Reservoir.pageSize)
        reservoir.trimBuffer(currentVisibleIndex: itemIndex)
        visibleItems = reservoir.visibleItems
        reservoirCount = reservoir.reservoirCount

        if reservoir.reservoirCount < Reservoir.reservoirLowWatermark {
            await fetchNextBatch()
        }
    }

    // MARK: - Stale refresh
    func refreshIfStale() async {
        guard !registry.enabledSources.isEmpty else { return }
        let shouldFetch: Bool
        if let last = lastRefreshDate {
            shouldFetch = Date().timeIntervalSince(last) > 900 || visibleItems.count < 10
        } else {
            shouldFetch = true
        }
        guard shouldFetch else { return }
        await fetchNextBatch()
    }

    // MARK: - Filter
    func setFilter(region: String?, category: String?, type: FeedLoader.ContentType) {
        activeRegion = region
        activeCategory = category
        activeContentType = type
        Task { await reloadFromSQLite() }
    }

    func clearAllFilters() {
        activeRegion = nil
        activeCategory = nil
        activeContentType = .all
        Task { await reloadFromSQLite() }
    }

    // MARK: - Search
    func search(_ query: String) {
        isSearching = true
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            searchResults = []
            visibleItems = []
            return
        }
        Task {
            let results: [FeedItemRecord] = try await db.read { db in
                try FeedItemRecord
                    .filter(Column("fetched_at") > Date().addingTimeInterval(-2592000))
                    .matching(FTS5Pattern(query: q))
                    .order(Column("published_at").desc)
                    .limit(100)
                    .fetchAll(db)
            }
            searchResults = results.map { $0.toFeedItem() }
            visibleItems = searchResults
        }
    }

    func clearSearch() {
        isSearching = false
        searchResults = []
        Task { await reloadFromSQLite() }
    }

    // MARK: - Read
    func markAsRead(_ itemID: String) {
        readItemIDs.insert(itemID)
        Task {
            try await db.write { db in
                try db.execute(sql: """
                    UPDATE feed_item SET is_read = 1, opened_at = \(Int(Date().timeIntervalSince1970))
                    WHERE id = ?
                """, arguments: [itemID])
            }
        }
    }

    // MARK: - Private: fetch

    private func fetchNextBatch() async {
        guard !isSearching else { return }
        let sourcesByRegion = Dictionary(grouping: registry.enabledSources, by: \.region)
        let batch = scheduler.nextBatch(
            reservoir: reservoir.reservoir,
            sourcesByRegion: sourcesByRegion,
            activeRegion: activeRegion,
            activeCategory: activeCategory
        )
        guard !batch.isEmpty else { return }

        let result = await fetcher.fetchAll(batch, maxConcurrent: 15)
        totalFetched += result.items.count
        fetchErrorCount += result.failedSourceCount
        emptyFeedCount += result.emptySourceCount

        for source in batch {
            scheduler.recordFetch(sourceURL: source.url, success: true)
        }

        let actualNew = result.items.filter { !loadedIDs.contains($0.id) }
        guard !actualNew.isEmpty else { return }
        for id in actualNew.map(\.id) { loadedIDs.insert(id) }

        // Write to SQLite
        do {
            for item in actualNew {
                let region = registry.regionFor(sourceURL: item.sourceURL)
                let record = FeedItemRecord(from: item, region: region)
                try await db.write { db in
                    try record.insert(db)
                }
            }
        } catch {
            print("[FeedStore] SQLite write error: \(error)")
        }

        // Append to reservoir
        reservoir.append(actualNew)
        // Only update visibleItems if no active search
        if !isSearching {
            visibleItems = reservoir.visibleItems
            reservoirCount = reservoir.reservoirCount
        }

        lastRefreshDate = .now

        // Check persistent searches
        await matchPersistentSearches(actualNew)
    }

    private func progressiveFetch() async {
        let allEnabled = registry.enabledSources
        let chunkSize = 20
        for chunkStart in stride(from: 0, to: min(allEnabled.count, 60), by: chunkSize) {
            let end = min(chunkStart + chunkSize, allEnabled.count)
            let chunk = Array(allEnabled[chunkStart..<end])
            let result = await fetcher.fetchAll(chunk, maxConcurrent: 15)
            totalFetched += result.items.count
            let actualNew = result.items.filter { !loadedIDs.contains($0.id) }
            for id in actualNew.map(\.id) { loadedIDs.insert(id) }
            reservoir.append(actualNew)
            if visibleItems.isEmpty && !reservoir.reservoir.isEmpty {
                reservoir.moveToVisible(count: Reservoir.pageSize)
                visibleItems = reservoir.visibleItems
                reservoirCount = reservoir.reservoirCount
            }
        }
        lastRefreshDate = .now
    }

    private func reloadFromSQLite() async {
        guard !isSearching else { return }
        let region = activeRegion
        let category = activeCategory
        let items: [FeedItemRecord] = (try? await db.read { db in
            var request = FeedItemRecord
                .filter(Column("fetched_at") > Date().addingTimeInterval(-2592000))
            if let r = region { request = request.filter(Column("region") == r) }
            if let c = category { request = request.filter(Column("category") == c) }
            return try request
                .order(Column("published_at").desc)
                .limit(200)
                .fetchAll(db)
        }) ?? []
        let feedItems = items.map { $0.toFeedItem() }
        reservoir.seed(items: feedItems)
        visibleItems = reservoir.visibleItems
        reservoirCount = reservoir.reservoirCount
    }

    private func loadReservoir() async throws -> [FeedItem]? {
        let records: [FeedItemRecord] = try await db.read { db in
            try FeedItemRecord
                .filter(Column("fetched_at") > Date().addingTimeInterval(-2592000))
                .order(Column("published_at").desc)
                .limit(200)
                .fetchAll(db)
        }
        guard !records.isEmpty else { return nil }
        return records.map { $0.toFeedItem() }
    }

    // MARK: - Region toggle

    func toggleRegion(_ region: String) {
        let wasDisabled = registry.disabledRegions.contains(region)
        registry.toggleRegion(region)
        if wasDisabled {
            reservoir.removeRegion(region)
            visibleItems = reservoir.visibleItems
            reservoirCount = reservoir.reservoirCount
            scheduler.prioritize(region: region)
            // Check if persistent searches depend on this region
            Task { await seedRegion(region) }
        } else {
            // Enabled — remove from scheduler, purge visible
            scheduler.remove(region: region)
            reservoir.removeRegion(region)
            visibleItems = reservoir.visibleItems
            reservoirCount = reservoir.reservoirCount
        }
    }

    private func seedRegion(_ region: String) async {
        let regionSources = registry.enabledSources
            .filter { $0.region == region }
            .prefix(10)
        guard !regionSources.isEmpty else { return }
        let batch = Array(regionSources)
        let result = await fetcher.fetchAll(batch, maxConcurrent: 10)
        let actualNew = result.items.filter { !loadedIDs.contains($0.id) }
        guard !actualNew.isEmpty else { return }
        for id in actualNew.map(\.id) { loadedIDs.insert(id) }
        for item in actualNew {
            let record = FeedItemRecord(from: item, region: region)
            try? await db.write { db in try record.insert(db) }
        }
        reservoir.append(actualNew)
        visibleItems = reservoir.visibleItems
        reservoirCount = reservoir.reservoirCount
    }

    // MARK: - Persistent search

    private func matchPersistentSearches(_ items: [FeedItem]) async {
        // Get all active persistent searches
        let searches: [BookmarkListRecord] = (try? await db.read { db in
            try BookmarkListRecord
                .filter(Column("search_active") == 1)
                .fetchAll(db)
        }) ?? []
        guard !searches.isEmpty else { return }

        for search in searches {
            guard let query = search.searchQuery else { continue }
            for item in items {
                var matches = true
                if let region = search.searchRegion, region != registry.regionFor(sourceURL: item.sourceURL) {
                    matches = false
                }
                if let cat = search.searchCategory, cat != item.category {
                    matches = false
                }
                if matches {
                    // FTS5 match
                    let ftsMatch: Bool = try! await db.read { db in
                        try FeedItemRecord
                            .filter(Column("id") == item.id)
                            .matching(FTS5Pattern(query: query))
                            .fetchCount(db) > 0
                    }
                    if ftsMatch {
                        try? await db.write { db in
                            try db.execute(sql: """
                                INSERT OR IGNORE INTO bookmark_item (list_id, item_id, added_at)
                                VALUES (?, ?, ?)
                            """, arguments: [search.id!, item.id, Int(Date().timeIntervalSince1970)])
                        }
                    }
                }
            }
        }
    }

    // MARK: - Emergency

    func emergencyTrim() {
        reservoir.emergencyTrim()
        visibleItems = reservoir.visibleItems
        reservoirCount = reservoir.reservoirCount
    }
}
```

- [ ] **Step 2: Remove duplicate schema code from Task 2 and consolidate**

Ensure the `FeedStore.swift` has `migrate` as a static method, not an instance method (since we already called it in init):

```swift
// Add this static method to FeedStore
static func migrate(_ db: DatabaseQueue) throws {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1") { db in
        // ... same schema as defined in Task 2 ...
    }
    try migrator.migrate(db)
}
```

- [ ] **Step 3: Build verification**

Run: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build`

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add feedmine/Services/FeedStore.swift
git commit -m "feat: wire FeedStore with all subcomponents and coordination

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 7: Refactor FeedLoader to ViewModel

**Files:**
- Modify: `feedmine/Services/FeedLoader.swift`
- Remove: `feedmine/Services/PersistenceManager.swift`

**Interfaces:**
- Consumes: `FeedStore`
- Produces: All existing FeedLoader public API, but delegated to FeedStore

- [ ] **Step 1: Rewrite FeedLoader as thin ViewModel**

```swift
// feedmine/Services/FeedLoader.swift
import Foundation
import Observation

@MainActor
@Observable
final class FeedLoader {
    private let store: FeedStore

    // MARK: - UI State (from store)

    var items: [FeedItem] { store.visibleItems }
    var loadingState: FeedLoadingState { store.loadingState }
    var totalFetched: Int { store.totalFetched }
    var fetchErrorCount: Int { store.fetchErrorCount }
    var sourceCount: Int { store.registry.sourceCount }
    var podcastSourceCount: Int { 0 }
    var podcastItemCount: Int { 0 }
    var totalDiscarded: Int { 0 }
    var emptyFeedCount: Int { store.emptyFeedCount }

    // Date sections (unchanged from current FeedLoader)
    struct DateSection: Identifiable {
        var id: String { title }
        let title: String
        let items: [FeedItem]
    }

    var dateSections: [DateSection] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredItems) { item -> String in
            if calendar.isDateInToday(item.publishedAt) { return "Today" }
            if calendar.isDateInYesterday(item.publishedAt) { return "Yesterday" }
            let days = calendar.dateComponents([.day], from: item.publishedAt, to: Date()).day ?? 0
            if days < 7 { return "This Week" }
            return "Earlier"
        }
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: Date()) ?? 0
        let remaining = ["Yesterday", "This Week", "Earlier"]
        let rotated = (0..<remaining.count).map { remaining[($0 + dayOfYear) % remaining.count] }
        let order = ["Today"] + rotated
        return order.compactMap { title in
            grouped[title].map { DateSection(title: title, items: $0) }
        }
    }

    // Layout
    enum FeedLayout { case card, list }
    var layout: FeedLayout = .card

    // Content type filter
    enum ContentType: String, CaseIterable, Identifiable {
        case all = "All"
        case text = "Articles"
        case video = "Videos"
        case audio = "Podcasts"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .all: return "circle.grid.3x3.fill"
            case .text: return "doc.text.fill"
            case .video: return "play.rectangle.fill"
            case .audio: return "headphones"
            }
        }
        func matches(_ item: FeedItem) -> Bool {
            switch self {
            case .all: return true
            case .text: return !item.isYouTube && !item.isPodcast
            case .video: return item.isYouTube
            case .audio: return item.isPodcast
            }
        }
    }
    var selectedContentType: ContentType = .all

    // Mood filter
    enum MoodFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case serious = "Serious"
        case fun = "Fun"
        case technical = "Technical"
        case inspiring = "Inspiring"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .all: return "circle.grid.3x3.fill"
            case .serious: return "newspaper.fill"
            case .fun: return "sparkles"
            case .technical: return "gearshape.2.fill"
            case .inspiring: return "sun.max.fill"
            }
        }
        // ... match logic unchanged ...
    }
    var selectedMood: MoodFilter = .all

    // Category filter
    var selectedCategory: String?

    // Search
    var searchQuery: String = ""
    var isSearching: Bool { store.isSearching }

    // Filters computed
    var filteredItems: [FeedItem] {
        var result = items
        if let cat = selectedCategory {
            result = result.filter { $0.category.lowercased() == cat.lowercased() }
        }
        if selectedContentType != .all {
            result = result.filter { selectedContentType.matches($0) }
        }
        if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let q = searchQuery.lowercased()
            result = result.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.excerpt.localizedCaseInsensitiveContains(q) }
        }
        return result
    }

    // Countries / Sources (delegated)
    var availableCountries: [Country] { store.registry.availableCountries }
    var availableCategories: [String] {
        Set(store.registry.enabledSources.map(\.category)).sorted()
    }
    var enabledSources: [FeedSource] { store.registry.enabledSources }
    var sources: [FeedSource] { store.registry.sources }
    var disabledSourceIDs: Set<String> { store.registry.disabledSourceIDs }

    // Read / Bookmark
    var readItemIDs: Set<String> { store.readItemIDs }
    var bookmarkedItems: [FeedItem] { [] } // Task 11 implements

    // Resources
    var networkMonitor: NetworkMonitor { store.networkMonitor }
    var currentVisibleIndex: Int = 0

    // Init
    init() {
        self.store = try! FeedStore()
    }

    // MARK: - Actions (delegate to store)

    func start() async { await store.start() }
    func loadMoreIfNeeded(currentItem: FeedItem) async {
        await store.loadMoreIfNeeded(currentItem: currentItem)
    }
    func refreshIfStale() async { await store.refreshIfStale() }

    func selectCategory(_ category: String?) {
        selectedCategory = (selectedCategory == category) ? nil : category
        store.setFilter(region: store.activeRegion, category: selectedCategory, type: selectedContentType)
    }
    func selectMood(_ mood: MoodFilter) {
        selectedMood = (selectedMood == mood) ? .all : mood
    }
    func selectContentType(_ type: ContentType) {
        selectedContentType = (selectedContentType == type) ? .all : type
        store.setFilter(region: store.activeRegion, category: selectedCategory, type: selectedContentType)
    }
    func clearAllFilters() {
        selectedCategory = nil
        selectedMood = .all
        selectedContentType = .all
        searchQuery = ""
        store.clearAllFilters()
    }

    func searchQueryChanged() {
        if searchQuery.isEmpty {
            store.clearSearch()
        } else {
            store.search(searchQuery)
        }
    }

    func toggleRegion(_ region: String) { store.toggleRegion(region) }
    func toggleAllCountries() { store.registry.toggleAllCountries() }
    func toggleGlobalFeeds() {
        if store.registry.disabledRegions.contains("global") {
            store.registry.disabledRegions.remove("global")
        } else {
            store.registry.disabledRegions.insert("global")
        }
        store.toggleRegion("global")
    }
    func toggleSource(_ sourceURL: String) { store.registry.toggleSource(sourceURL) }
    func isRegionEnabled(_ region: String) -> Bool { store.registry.isRegionEnabled(region) }
    func isSourceEnabled(_ url: String) -> Bool { store.registry.isSourceEnabled(url) }
    var isAnyCountryEnabled: Bool { store.registry.isAnyCountryEnabled }
    var isGlobalFeedsEnabled: Bool { store.registry.isRegionEnabled("global") }

    func markAsRead(_ itemID: String) { store.markAsRead(itemID) }

    func shakeToRefresh() {
        store.emergencyTrim()
        Task { await store.refreshIfStale() }
    }
    func emergencyTrim() { store.emergencyTrim() }
}
```

- [ ] **Step 2: Remove PersistenceManager.swift**

`PersistenceManager` is fully replaced by GRDB SQLite. Remove the file from the Xcode project.

- [ ] **Step 3: Build verification**

Run: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build`

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git rm feedmine/Services/PersistenceManager.swift
git add feedmine/Services/FeedLoader.swift
git commit -m "refactor: slim FeedLoader to ViewModel, remove PersistenceManager

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 8: Update Entry Point and Views

**Files:**
- Modify: `feedmine/feedmineApp.swift`
- Modify: `feedmine/Views/FeedScreen.swift`

- [ ] **Step 1: Update FeedmineApp entry point**

No changes needed — `FeedLoader` still works with `@State` and `.environment()`. The init is now `try! FeedStore()` internally.

- [ ] **Step 2: Update FeedScreen — remove direct PersistenceManager.save calls**

Replace the `scenePhase` change handler that calls `PersistenceManager.shared.saveNow(...)`:

```swift
// In FeedScreen.swift, onChange of scenePhase:
.onChange(of: scenePhase) { _, phase in
    if phase == .active {
        SessionTracker.shared.onForeground()
        engine.refresh()
    }
    if phase == .background {
        SessionTracker.shared.onBackground()
        loader.flushWhatsNewQueue()
        // Persistence is now automatic via SQLite WAL — no explicit save needed
    }
}
```

- [ ] **Step 3: Build verification**

Run: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build`

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add feedmine/feedmineApp.swift feedmine/Views/FeedScreen.swift
git commit -m "refactor: update entry point and views for FeedStore architecture

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 9: Create BookmarkList and ActiveSearch Models

**Files:**
- Create: `feedmine/Models/BookmarkList.swift`
- Create: `feedmine/Models/ActiveSearch.swift`

- [ ] **Step 1: Create models**

```swift
// feedmine/Models/BookmarkList.swift
import Foundation

struct BookmarkList: Identifiable, Hashable {
    let id: Int64
    var name: String
    var sortOrder: Int
    var createdAt: Date
    var isDefault: Bool
    var searchQuery: String?
    var searchRegion: String?
    var searchCategory: String?
    var searchActive: Bool
    var itemCount: Int

    var isPersistentSearch: Bool { searchQuery != nil }
}

// feedmine/Models/ActiveSearch.swift
import Foundation

/// Represents a persistent search that is currently active (search_active = 1).
/// Used to build the composite feed with multi-search scoring.
struct ActiveSearch: Identifiable, Hashable {
    let id: Int64
    let name: String
    let searchQuery: String
    let region: String?
    let category: String?

    /// How many dimensions this search contributes (1-3).
    /// Text = 1, region = 1, category = 1.
    var dimensionCount: Int {
        var count = 0
        if !searchQuery.isEmpty { count += 1 }
        if region != nil { count += 1 }
        if category != nil { count += 1 }
        return count
    }

    /// Returns the number of dimensions this search matches for a given item.
    func matches(_ item: FeedItem, itemRegion: String) -> Int {
        var score = 0
        if let r = region, itemRegion == r { score += 1 }
        if let c = category, item.category == c { score += 1 }
        // Text match is checked separately via FTS5 at query time
        return score
    }
}
```

- [ ] **Step 2: Build verification**

Run: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add feedmine/Models/BookmarkList.swift feedmine/Models/ActiveSearch.swift
git commit -m "feat: add BookmarkList and ActiveSearch models

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 10: Implement Bookmark CRUD and Persistent Search in FeedStore

**Files:**
- Modify: `feedmine/Services/FeedStore.swift`

- [ ] **Step 1: Add bookmark and search methods to FeedStore**

```swift
// Add these methods to FeedStore class

// MARK: - Bookmark Lists

func allBookmarkLists() async throws -> [BookmarkList] {
    let records: [BookmarkListRecord] = try await db.read { db in
        try BookmarkListRecord.order(Column("sort_order")).fetchAll(db)
    }
    return records.map { r in
        let count = (try? db.read { db in
            try BookmarkItemRecord.filter(Column("list_id") == r.id!).fetchCount(db)
        }) ?? 0
        return BookmarkList(
            id: r.id!, name: r.name, sortOrder: r.sortOrder,
            createdAt: r.createdAt, isDefault: r.isDefault,
            searchQuery: r.searchQuery, searchRegion: r.searchRegion,
            searchCategory: r.searchCategory, searchActive: r.searchActive,
            itemCount: count
        )
    }
}

func createBookmarkList(name: String, searchQuery: String? = nil,
                        region: String? = nil, category: String? = nil) async throws -> Int64 {
    try await db.write { db in
        var record = BookmarkListRecord(
            id: nil, name: name, sortOrder: 0,
            createdAt: Date(), isDefault: false,
            searchQuery: searchQuery, searchRegion: region,
            searchCategory: category, searchActive: searchQuery != nil
        )
        try record.insert(db)
        return record.id!
    }
}

func toggleBookmark(itemID: String, listID: Int64? = nil) async throws {
    let targetListID = listID ?? defaultListID()
    try await db.write { db in
        let existing = try BookmarkItemRecord
            .filter(Column("list_id") == targetListID && Column("item_id") == itemID)
            .fetchCount(db)
        if existing > 0 {
            try db.execute(sql: "DELETE FROM bookmark_item WHERE list_id = ? AND item_id = ?",
                          arguments: [targetListID, itemID])
        } else {
            try db.execute(sql: """
                INSERT INTO bookmark_item (list_id, item_id, added_at) VALUES (?, ?, ?)
            """, arguments: [targetListID, itemID, Int(Date().timeIntervalSince1970)])
        }
    }
}

func isBookmarked(itemID: String, listID: Int64? = nil) async throws -> Bool {
    let targetListID = listID ?? defaultListID()
    return try await db.read { db in
        try BookmarkItemRecord
            .filter(Column("list_id") == targetListID && Column("item_id") == itemID)
            .fetchCount(db) > 0
    }
}

func bookmarkedItems(listID: Int64? = nil) async throws -> [FeedItem] {
    let targetListID = listID ?? defaultListID()
    let records: [FeedItemRecord] = try await db.read { db in
        try FeedItemRecord
            .joining(required: FeedItemRecord.hasMany(BookmarkItemRecord.self)
                .filter(Column("list_id") == targetListID))
            .order(Column("published_at").desc)
            .fetchAll(db)
    }
    return records.map { $0.toFeedItem() }
}

func deleteBookmarkList(_ id: Int64) async throws {
    // Don't delete the default list
    try await db.write { db in
        let isDefault = try Bool.fetchOne(db, sql: "SELECT is_default FROM bookmark_list WHERE id = ?", arguments: [id]) ?? false
        guard !isDefault else { return }
        try db.execute(sql: "DELETE FROM bookmark_list WHERE id = ?", arguments: [id])
    }
}

private func defaultListID() -> Int64 {
    // Cache on first call
    if let cached = _defaultListID { return cached }
    let id: Int64 = (try? db.read { db in
        try Int64.fetchOne(db, sql: "SELECT id FROM bookmark_list WHERE is_default = 1 LIMIT 1")
    }) ?? 1
    _defaultListID = id
    return id
}
private var _defaultListID: Int64?

// MARK: - Persistent Search (Active)

func activeSearches() async throws -> [ActiveSearch] {
    let records: [BookmarkListRecord] = try await db.read { db in
        try BookmarkListRecord
            .filter(Column("search_active") == 1)
            .fetchAll(db)
    }
    return records.map { r in
        ActiveSearch(
            id: r.id!, name: r.name,
            searchQuery: r.searchQuery ?? "",
            region: r.searchRegion, category: r.searchCategory
        )
    }
}

/// Build composite feed from multiple active searches with tiered scoring.
func compositeSearchFeed() async throws -> [FeedItem] {
    let searches = try await activeSearches()
    guard !searches.isEmpty else { return [] }

    var scored: [(FeedItem, Int)] = []
    for search in searches {
        // Build query: FTS5 match + optional region/category filter
        let records: [FeedItemRecord] = try await db.read { db in
            var request = FeedItemRecord
                .filter(Column("fetched_at") > Date().addingTimeInterval(-2592000))
                .matching(FTS5Pattern(query: search.searchQuery))
            if let r = search.region {
                request = request.filter(Column("region") == r)
            }
            if let c = search.category {
                request = request.filter(Column("category") == c)
            }
            return try request.limit(50).fetchAll(db)
        }
        for record in records {
            let item = record.toFeedItem()
            let score = search.matches(item, itemRegion: registry.regionFor(sourceURL: item.sourceURL))
            // +1 for text match (FTS5 already filtered)
            scored.append((item, score + 1))
        }
    }

    // Deduplicate and sum scores
    var bestScore: [String: (FeedItem, Int)] = [:]
    for (item, score) in scored {
        if let existing = bestScore[item.id] {
            bestScore[item.id] = (item, existing.1 + score)
        } else {
            bestScore[item.id] = (item, score)
        }
    }

    // Sort: tier DESC, within tier: fetched_at DESC
    let sorted = bestScore.values.sorted { a, b in
        if a.1 != b.1 { return a.1 > b.1 }
        return true // preserve original order within tier
    }
    return sorted.map { $0.0 }
}
```

- [ ] **Step 2: Build verification**

Run: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add feedmine/Services/FeedStore.swift
git commit -m "feat: implement bookmark CRUD and persistent search

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 11: Implement Maintenance (Expurgo + VACUUM)

**Files:**
- Modify: `feedmine/Services/FeedStore.swift`

- [ ] **Step 1: Add maintenance methods to FeedStore**

```swift
// Add to FeedStore class

// MARK: - Maintenance

/// Lightweight cleanup on every launch — deletes up to 500 expired items.
func performLightExpurgo() async {
    let cutoff = Int(Date().addingTimeInterval(-2592000).timeIntervalSince1970) // 30 days
    do {
        try await db.write { db in
            try db.execute(sql: """
                DELETE FROM feed_item
                WHERE fetched_at < ?
                  AND is_read = 0
                  AND id NOT IN (SELECT item_id FROM bookmark_item)
                LIMIT 500
            """, arguments: [cutoff])
        }
    } catch {
        print("[FeedStore] Expurgo error: \(error)")
    }
}

/// Per-source cap: keep max 50 items per source within 30-day window.
func capSourceItems(sourceURL: String) async {
    do {
        try await db.write { db in
            let count = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM feed_item WHERE source_url = ?
            """, arguments: [sourceURL]) ?? 0
            guard count > 50 else { return }
            // Delete oldest exceeding 50
            try db.execute(sql: """
                DELETE FROM feed_item WHERE id IN (
                    SELECT id FROM feed_item WHERE source_url = ?
                    ORDER BY published_at ASC
                    LIMIT ?
                )
            """, arguments: [sourceURL, count - 50])
        }
    } catch {
        print("[FeedStore] Source cap error: \(error)")
    }
}

/// Heavy maintenance — VACUUM + REINDEX. Run once per week in background.
func performHeavyMaintenance() async {
    let lastKey = "lastHeavyMaintenance"
    let now = Date().timeIntervalSince1970
    let last = UserDefaults.standard.double(forKey: lastKey)
    guard now - last > 604800 else { return } // 7 days

    do {
        try await db.write { db in
            try db.execute(sql: "DELETE FROM feed_item WHERE fetched_at < ? AND is_read = 0 AND id NOT IN (SELECT item_id FROM bookmark_item)",
                          arguments: [Int(Date().addingTimeInterval(-2592000).timeIntervalSince1970)])
        }
        try await db.vacuum()
        UserDefaults.standard.set(now, forKey: lastKey)
        print("[FeedStore] Heavy maintenance complete")
    } catch {
        print("[FeedStore] Maintenance error: \(error)")
    }
}
```

- [ ] **Step 2: Wire into app lifecycle**

In `FeedStore.start()`, add after warm start:

```swift
// At end of start():
Task { await performLightExpurgo() }
Task.detached(priority: .background) { [weak self] in
    await self?.performHeavyMaintenance()
}
```

- [ ] **Step 3: Wire source cap into writeItems**

In `FeedStore.writeItems` (or the fetch batch handler), after inserting items for a source:

```swift
// After bulk insert
if items.count > 0 {
    let sourceURLs = Set(items.map(\.sourceURL))
    for url in sourceURLs {
        await capSourceItems(sourceURL: url)
    }
}
```

- [ ] **Step 4: Build verification**

Run: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build`

Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add feedmine/Services/FeedStore.swift
git commit -m "feat: implement maintenance — expurgo, source cap, VACUUM

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 12: Update Views for New Bindings

**Files:**
- Modify: `feedmine/Views/FilterSheetView.swift`
- Modify: `feedmine/Views/BookmarksSheetView.swift`
- Modify: `feedmine/Views/CountriesListScreen.swift`

- [ ] **Step 1: FilterSheetView — verify bindings still work**

The `FilterSheetView` already calls `loader.toggleGlobalFeeds()`, `loader.selectCategory()`, etc. These are now thin wrappers in the new `FeedLoader`. No changes needed unless the method signatures changed.

- [ ] **Step 2: BookmarksSheetView — add list support**

```swift
// In BookmarksSheetView.swift, add list picker
struct BookmarksSheetView: View {
    @Environment(FeedLoader.self) private var loader
    @State private var bookmarkLists: [BookmarkList] = []
    @State private var selectedListID: Int64?
    @State private var bookmarkedItems: [FeedItem] = []

    var body: some View {
        NavigationStack {
            List {
                if !bookmarkLists.isEmpty {
                    Picker("List", selection: $selectedListID) {
                        ForEach(bookmarkLists, id: \.id) { list in
                            Text(list.name).tag(Optional(list.id))
                        }
                    }
                }
                // ... existing bookmark items list ...
            }
            .task {
                // Load lists and items
            }
        }
    }
}
```

- [ ] **Step 3: CountriesListScreen — verify toggle bindings**

The toggle bindings use `loader.isRegionEnabled(region)` and `loader.toggleRegion(region)` — these delegate to `FeedStore` now. No changes needed.

- [ ] **Step 4: Build verification**

Run: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build`

Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add feedmine/Views/
git commit -m "refactor: update views for FeedStore bindings and add bookmark lists

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 13: Integration Testing — End-to-End Verification

**Files:**
- None (manual verification)

- [ ] **Step 1: Cold start — verify SQLite creates schema**

Launch app fresh. Verify in Xcode console:
- No crash
- SQLite file created at `Documents/feedmine.sqlite`
- "Favorites" list exists in bookmark_list

- [ ] **Step 2: Feed parsing — verify OPML loads**

- Check that sources are populated
- Check that countries appear in CountriesListScreen
- Check that global feeds are enabled by default, countries disabled

- [ ] **Step 3: Feed fetching — verify items appear**

- Wait for first batch to complete
- Verify items appear in the feed
- Verify items are persisted in SQLite: `SELECT COUNT(*) FROM feed_item` > 0

- [ ] **Step 4: Toggle — verify region ON/OFF**

- Enable Brazil → verify Brazilian items appear within seconds
- Disable Brazil → verify Brazilian items disappear from feed
- Verify items remain in SQLite after toggle OFF

- [ ] **Step 5: Filter — verify bidirectional**

- Select category "tech" → verify feed shows only tech
- Verify that scheduler only fetches tech sources (inspect logs)
- Clear filter → verify all content returns

- [ ] **Step 6: Search — verify FTS5**

- Type "Lula" in search → verify results appear from FTS5
- Clear search → verify feed returns to normal

- [ ] **Step 7: Bookmark — verify persistence**

- Bookmark an item → verify it appears in BookmarksSheetView
- Kill app, relaunch → verify bookmark still exists
- Verify bookmark survives 30-day expurgo (check `id NOT IN (SELECT item_id FROM bookmark_item)`)

- [ ] **Step 8: Commit final adjustments**

```bash
git add -A
git commit -m "test: end-to-end verification of FeedStore architecture

Co-Authored-By: Claude <noreply@anthropic.com>"
```
