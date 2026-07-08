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
    private var filterContentType: (FeedItem) -> Bool {
        switch activeContentType {
        case .all: return { _ in true }
        case .text: return { !$0.isYouTube && !$0.isPodcast }
        case .video: return { $0.isYouTube }
        case .audio: return { $0.isPodcast }
        }
    }
    var isSearching = false
    private var searchResults: [FeedItem] = []

    // MARK: - Read state
    private(set) var readItemIDs: Set<String> = []
    private var loadedIDs: Set<String> = []  // Bloom filter for dedup
    private var _defaultListID: Int64?

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
            visibleItems = reservoir.visibleItems.filter(filterContentType)
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
        loadingState = .refreshing
        await fetchNextBatch()
        loadingState = .idle
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
            guard let pattern = FTS5Pattern(matchingAllTokensIn: q) else {
                searchResults = []
                visibleItems = []
                return
            }
            let results: [FeedItemRecord] = try await db.read { db in
                try FeedItemRecord
                    .filter(Column("fetched_at") > Date().addingTimeInterval(-2592000))
                    .matching(pattern)
                    .order(Column("published_at").desc)
                    .limit(100)
                    .fetchAll(db)
            }
            guard isSearching else { return }
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

        loadingState = .refreshing
        defer { loadingState = .idle }

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
            // Compute regions in @MainActor context before entering the write closure
            let itemsWithRegions: [(item: FeedItem, region: String)] = actualNew.map { item in
                (item, registry.regionFor(sourceURL: item.sourceURL))
            }
            try await db.write { db in
                for (item, region) in itemsWithRegions {
                    let record = FeedItemRecord(from: item, region: region)
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
            visibleItems = reservoir.visibleItems.filter(filterContentType)
            reservoirCount = reservoir.reservoirCount
        }

        lastRefreshDate = .now

        // Check persistent searches
        await matchPersistentSearches(actualNew)
    }

    private func progressiveFetch() async {
        loadingState = .refreshing
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
                visibleItems = reservoir.visibleItems.filter(filterContentType)
                reservoirCount = reservoir.reservoirCount
            }
        }
        lastRefreshDate = .now
        loadingState = .idle
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
        visibleItems = reservoir.visibleItems.filter(filterContentType)
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
            guard let pattern = FTS5Pattern(matchingAllTokensIn: query) else { continue }
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
                    let ftsMatch: Bool = (try? await db.read { db in
                        try FeedItemRecord
                            .filter(Column("id") == item.id)
                            .matching(pattern)
                            .fetchCount(db) > 0
                    }) ?? false
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

    // MARK: - Bookmark CRUD

    func allBookmarkLists() async throws -> [BookmarkList] {
        try await db.read { db in
            let records = try BookmarkListRecord.order(Column("sort_order")).fetchAll(db)
            return try records.map { r in
                let count = try BookmarkItemRecord.filter(Column("list_id") == r.id!).fetchCount(db)
                return BookmarkList(
                    id: r.id!, name: r.name, sortOrder: r.sortOrder,
                    createdAt: r.createdAt, isDefault: r.isDefault,
                    searchQuery: r.searchQuery, searchRegion: r.searchRegion,
                    searchCategory: r.searchCategory, searchActive: r.searchActive,
                    itemCount: count
                )
            }
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
        try await db.write { db in
            let isDefault = try Bool.fetchOne(db, sql: "SELECT is_default FROM bookmark_list WHERE id = ?", arguments: [id]) ?? false
            guard !isDefault else { return }
            try db.execute(sql: "DELETE FROM bookmark_list WHERE id = ?", arguments: [id])
        }
    }

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
            guard let pattern = FTS5Pattern(matchingAllTokensIn: search.searchQuery) else { continue }
            let records: [FeedItemRecord] = try await db.read { db in
                var request = FeedItemRecord
                    .filter(Column("fetched_at") > Date().addingTimeInterval(-2592000))
                    .matching(pattern)
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

        // Sort: score DESC, within score preserve order
        let sorted = bestScore.values.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            return true
        }
        return sorted.map { $0.0 }
    }

    // MARK: - Private helpers

    private func defaultListID() -> Int64 {
        if let cached = _defaultListID { return cached }
        let id: Int64 = (try? db.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM bookmark_list WHERE is_default = 1 LIMIT 1")
        }) ?? 1
        _defaultListID = id
        return id
    }

    // MARK: - Emergency

    func emergencyTrim() {
        reservoir.emergencyTrim()
        visibleItems = reservoir.visibleItems
        reservoirCount = reservoir.reservoirCount
    }

    // MARK: - Migration

    static func migrate(_ db: DatabaseQueue) throws {
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

// MARK: - FeedItem GRDB Record

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

// MARK: - Bookmark Models

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
