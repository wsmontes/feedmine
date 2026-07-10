import Foundation
import GRDB
import NaturalLanguage
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
    let prefetcher = ImagePrefetcher()
    let networkMonitor = NetworkMonitor()

    // MARK: - Public state
    private(set) var visibleItems: [FeedItem] = []
    private(set) var reservoirCount: Int = 0
    var lastToggleMessage: String?
    private(set) var loadingState: FeedLoadingState = .idle
    private(set) var lastRefreshDate: Date?
    private(set) var totalFetched = 0
    private(set) var fetchErrorCount = 0
    private(set) var lastFetchSucceeded = false  // reset error banner on success
    private(set) var emptyFeedCount = 0
    private(set) var totalDiscarded = 0

    /// Cached podcast counts — updated after fetch batches, not on every access (#24)
    private(set) var podcastItemCount = 0
    private(set) var podcastSourceCount = 0

    private func refreshPodcastCounts() {
        Task {
            do {
                let (items, sources) = try await db.read { db -> (Int, Int) in
                    let items = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM feed_item WHERE audio_url IS NOT NULL") ?? 0
                    let sources = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT source_url) FROM feed_item WHERE audio_url IS NOT NULL") ?? 0
                    return (items, sources)
                }
                podcastItemCount = items
                podcastSourceCount = sources
            } catch {}
        }
    }

    // MARK: - Filter state (bidirectional)
    var activeRegion: String?
    var activeCategory: String?
    var activeContentType: FeedLoader.ContentType = .all
    var activeMood: FeedLoader.MoodFilter = .all
    /// Safety filter: excludes items from disabled regions/categories/feeds.
    private func isItemEnabled(_ item: FeedItem) -> Bool {
        registry.isSourceEnabled(item.sourceURL)
    }

    /// Prefetch images for items if enabled (default: true).
    private func prefetchImagesIfEnabled(for items: [FeedItem]) {
        guard UserDefaults.standard.object(forKey: "prefetchImages") as? Bool ?? true else { return }
        let urls = items.compactMap { $0.bestImageURL ?? $0.imageURL }
        guard !urls.isEmpty else { return }
        Task { await prefetcher.prefetch(urls: urls, priorityURLs: urls) }
    }

    /// Aggressive prefetch: visible items first (user sees now), then deep
    /// reservoir batch (user scrolls to soon). Called after seed/moveToVisible
    /// so images are cached before they hit the screen.
    private func prefetchVisibleAndNext() {
        guard UserDefaults.standard.object(forKey: "prefetchImages") as? Bool ?? true else { return }
        let visible = reservoir.visibleItems.compactMap { $0.bestImageURL ?? $0.imageURL }
        let upcoming = reservoir.upcomingItems(100).compactMap { $0.bestImageURL ?? $0.imageURL }
        let all = Array(Set(visible + upcoming))
        guard !all.isEmpty else { return }
        Task { await prefetcher.prefetch(urls: all, priorityURLs: visible) }
    }

    /// Apply all active filters to a list of items — single source of truth.
    /// Every visibleItems assignment must pass through here so pagination
    /// (loadMoreIfNeeded) and the UI (FeedLoader.filteredItems) agree on count.
    /// Single-pass to avoid intermediate array allocations.
    private func applyFilters(_ items: [FeedItem]) -> [FeedItem] {
        let category = activeCategory
        let mood = activeMood
        let contentType = filterContentType
        return items.filter { item in
            isItemEnabled(item)
            && (category == nil || item.category == category)
            && contentType(item)
            && (mood == .all || mood.matches(item.title))
        }
    }

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
    private(set) var loadedIDsCount: Int = 0
    private var loadedIDs: Set<String> = []  // Bloom filter for dedup
    private static let lastWhatsNewSeenAtKey = "last_whats_new_seen_at"
    private var whatsNewBaselineDate: Date?    // persisted across sessions; advanced on dismiss
    private var _defaultListID: Int64?
    private var hasStarted = false             // guards one-time startup work
    private var progressiveFetchTask: Task<Void, Never>?

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
        loadSourceHealth()
    }

    // MARK: - Source Health Persistence

    private func loadSourceHealth() {
        do {
            let records = try db.read { db in try SourceHealthRecord.loadAll(db) }
            for r in records {
                scheduler.loadHealth(
                    url: r.url,
                    lastFetchAt: Date(timeIntervalSince1970: TimeInterval(r.lastFetchAt)),
                    consecutiveFailures: r.consecutiveFailures
                )
            }
        } catch {
            print("[FeedStore] loadSourceHealth failed: \(error)")
        }
    }

    private func saveSourceHealth(for sourceURL: String) {
        // Single-source write — used for one-off toggles. Bulk paths use
        // saveSourceHealthBatch for efficiency.
        saveSourceHealthBatch([(sourceURL, nil)])
    }

    /// Batch-save source health for multiple URLs in a single transaction.
    /// Dramatically faster than N individual writes for 800+ sources.
    private func saveSourceHealthBatch(_ entries: [(url: String, itemCount: Int?)]) {
        guard !entries.isEmpty else { return }
        do {
            try db.write { db in
                for (sourceURL, itemCount) in entries {
                    let health = scheduler.healthSnapshot(for: sourceURL, itemCount: itemCount)
                    try db.execute(sql: """
                        INSERT INTO source_health (url, last_fetch_at, consecutive_failures, last_status, last_item_count)
                        VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(url) DO UPDATE SET
                            last_fetch_at = excluded.last_fetch_at,
                            consecutive_failures = excluded.consecutive_failures,
                            last_status = excluded.last_status,
                            last_item_count = excluded.last_item_count
                        """, arguments: [
                            sourceURL,
                            Int(health.lastFetchAt.timeIntervalSince1970),
                            health.consecutiveFailures,
                            health.lastStatus,
                            health.lastItemCount
                        ])
                }
            }
        } catch {
            print("[FeedStore] saveSourceHealthBatch error: \(error)")
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

    /// Epoch-seconds cutoff for the 30-day retention window. All feed_item date
    /// columns are stored as epoch-second integers, so every comparison uses
    /// integers too — mixing GRDB's default TEXT date encoding with integer
    /// cutoffs produced always-true/always-false comparisons (dead expurgo,
    /// broken What's New).
    nonisolated private static var thirtyDayCutoffEpoch: Int {
        Int(Date().addingTimeInterval(-2592000).timeIntervalSince1970)
    }

    // MARK: - Start (cold + warm)

    /// One-time startup: parse OPML, start the network monitor, hydrate from
    /// SQLite, snapshot the What's New baseline, and kick off the first fetch.
    /// Idempotent — calling it again (e.g. the view reappearing) is a no-op;
    /// use `refreshNow()` to pull fresh content after startup.
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        loadingState = .initial
        networkMonitor.start()
        await registry.loadFromOPML()
        reservoir.sourceRegionMap = registry.regionMap

        // Restore persisted filters FIRST so the first render shows
        // correctly filtered content, not a flash of unfiltered items.
        restoreFilters()
        await loadReadState()
        reservoir.readItemIDs = readItemIDs

        // Warm start: hydrate from SQLite with filters already active
        let cached = try? await loadReservoir()
        if let items = cached, !items.isEmpty {
            for item in items { loadedIDs.insert(item.id) }
            loadedIDsCount = loadedIDs.count
            reservoir.seed(items: items)
            visibleItems = applyFilters(reservoir.visibleItems)
            reservoirCount = reservoir.reservoirCount
            loadingState = .idle
            prefetchVisibleAndNext()
        }

        // Snapshot baseline for "What's New" — persisted so items don't vanish
        // just because the app restarted. Falls back to now on first launch.
        if let persisted = UserDefaults.standard.object(forKey: Self.lastWhatsNewSeenAtKey) as? Date {
            whatsNewBaselineDate = persisted
        } else {
            whatsNewBaselineDate = Date()
        }

        guard !registry.enabledSources.isEmpty else {
            loadingState = .idle
            return
        }

        // First batch: fill the visible feed quickly so the user sees content
        // immediately. The scheduler picks ~17 top-scoring sources.
        await fetchNextBatch()

        // Background: process ALL remaining enabled sources so YouTube,
        // podcasts, and other non-text sources don't wait hours for their
        // turn in the scheduler lottery. Runs as a main-actor Task so
        // FeedStore state access is safe; each await suspension point
        // yields the actor for UI work.
        if !registry.enabledSources.isEmpty {
            progressiveFetchTask = Task { await progressiveFetch() }
        }
        loadingState = .idle

        // Light maintenance on every launch
        Task { await performLightExpurgo() }
        Task.detached(priority: .background) { [weak self] in
            await self?.performHeavyMaintenance()
        }
    }

    // MARK: - Scroll
    private var lastLoadedIndex = -1

    /// User-initiated refresh (pull-to-refresh, retry, empty-state button).
    /// Forces a fresh fetch WITHOUT re-running one-time startup — no re-parsing
    /// OPML, no restarting the network monitor, no re-hydrating SQLite, no
    /// baseline reset. Falls back to full startup if the store never started.
    func refreshNow() async {
        guard hasStarted else { await start(); return }
        guard !registry.enabledSources.isEmpty else { return }
        loadingState = .refreshing
        lastRefreshDate = nil   // bypass the staleness gate
        await fetchNextBatch()
        loadingState = .idle
    }

    func loadMoreIfNeeded(currentItem: FeedItem) async {
        guard !isSearching else { return }
        guard let itemIndex = visibleItems.firstIndex(where: { $0.id == currentItem.id }) else { return }
        guard itemIndex >= visibleItems.count - Reservoir.loadMoreThreshold else { return }
        guard itemIndex != lastLoadedIndex else { return }
        lastLoadedIndex = itemIndex

        scheduler.recordConsumption()
        reservoir.moveToVisible(count: Reservoir.pageSize)
        reservoir.trimBuffer(currentVisibleIndex: itemIndex)
        visibleItems = reservoir.visibleItems
        reservoirCount = reservoir.reservoirCount
        prefetchVisibleAndNext()

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

    private func persistFilters() {
        let d = UserDefaults.standard
        d.set(activeRegion, forKey: "filterRegion")
        d.set(activeCategory, forKey: "filterCategory")
        d.set(activeContentType.rawValue, forKey: "filterContentType")
        d.set(activeMood.rawValue, forKey: "filterMood")
    }

    private func restoreFilters() {
        let d = UserDefaults.standard
        activeRegion = d.string(forKey: "filterRegion")
        activeCategory = d.string(forKey: "filterCategory")
        if let raw = d.string(forKey: "filterContentType"),
           let type = FeedLoader.ContentType(rawValue: raw) {
            activeContentType = type
        }
        if let raw = d.string(forKey: "filterMood"),
           let mood = FeedLoader.MoodFilter(rawValue: raw) {
            activeMood = mood
        }
    }

    func setFilter(region: String?, category: String?, type: FeedLoader.ContentType, mood: FeedLoader.MoodFilter = .all) {
        progressiveFetchTask?.cancel()
        let regionChanged = activeRegion != region
        let categoryChanged = activeCategory != category
        activeRegion = region
        activeCategory = category
        activeContentType = type
        activeMood = mood
        persistFilters()
        if regionChanged || categoryChanged {
            // Clear visible items synchronously so the UI reflects the filter
            // change immediately — no stale content flash, no reordering.
            visibleItems = []
            reservoirCount = 0
            Task {
                await reloadFromSQLite()
                if visibleItems.count < 20 { await fetchNextBatch() }
            }
        } else {
            visibleItems = applyFilters(reservoir.visibleItems)
            if visibleItems.count < 20 { Task { await fetchNextBatch() } }
        }
    }

    func clearAllFilters() {
        let hadStructuralFilter = activeRegion != nil || activeCategory != nil
        activeRegion = nil
        activeCategory = nil
        activeContentType = .all
        activeMood = .all
        persistFilters()
        if hadStructuralFilter {
            visibleItems = []
            reservoirCount = 0
            Task {
                await reloadFromSQLite()
                if visibleItems.count < 20 { await fetchNextBatch() }
            }
        } else {
            visibleItems = applyFilters(reservoir.visibleItems)
            if visibleItems.count < 20 { Task { await fetchNextBatch() } }
        }
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
            let region = activeRegion
            let category = activeCategory
            // disabledRegions filtering now handled in-memory by isItemEnabled
            let results: [FeedItemRecord] = try await db.read { db in
                var request = FeedItemRecord
                    .filter(Column("fetched_at") > Self.thirtyDayCutoffEpoch)
                    .matching(pattern)
                if let r = region { request = request.filter(Column("region") == r) }
                if let c = category { request = request.filter(Column("category") == c) }
                return try request
                    .order(Column("published_at").desc)
                    .limit(100)
                    .fetchAll(db)
            }
            guard isSearching else { return }
            searchResults = results.map { $0.toFeedItem() }
            visibleItems = searchResults.filter(isItemEnabled).filter(filterContentType)
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
        reservoir.readItemIDs = readItemIDs
        Task {
            try await db.write { db in
                try db.execute(sql: """
                    UPDATE feed_item SET is_read = 1, opened_at = \(Int(Date().timeIntervalSince1970))
                    WHERE id = ?
                """, arguments: [itemID])
            }
        }
    }

    func markAsUnread(_ itemID: String) {
        readItemIDs.remove(itemID)
        reservoir.readItemIDs = readItemIDs
        Task {
            try await db.write { db in
                try db.execute(sql: "UPDATE feed_item SET is_read = 0, opened_at = NULL WHERE id = ?", arguments: [itemID])
            }
        }
    }

    func clearReadHistory() {
        readItemIDs.removeAll()
        reservoir.readItemIDs = []
        Task {
            try await db.write { db in
                try db.execute(sql: "UPDATE feed_item SET is_read = 0, opened_at = NULL")
            }
        }
    }

    func clearAllBookmarks() {
        Task {
            try await db.write { db in
                try db.execute(sql: "DELETE FROM bookmark_item")
            }
        }
    }

    // MARK: - Source health

    /// Last fetch date for a source URL.
    func lastFetchDate(for sourceURL: String) -> Date? {
        scheduler.lastFetchedAt[sourceURL]
    }

    func toggleSource(_ sourceURL: String) {
        let wasEnabled = registry.isSourceEnabled(sourceURL)
        registry.toggleSource(sourceURL)
        if !wasEnabled {
            // Enabling a single feed — fetch it immediately
            if let source = registry.sources.first(where: { $0.url == sourceURL }) {
                Task {
                    let result = await fetcher.fetchAll([source], maxConcurrent: 1)
                    let actualNew = await persistFetchedItems(result.items)
                    guard !actualNew.isEmpty else { return }
                    // Prepend to visible feed
                    var combined = actualNew
                    combined.append(contentsOf: reservoir.visibleItems)
                    reservoir.seed(items: combined)
                    visibleItems = applyFilters(reservoir.visibleItems)
                    reservoirCount = reservoir.reservoirCount
                }
            }
        } else {
            // Disabling — remove only this feed's items, not its whole region.
            reservoir.removeSource(sourceURL)
            visibleItems = applyFilters(reservoir.visibleItems)
            reservoirCount = reservoir.reservoirCount
        }
    }

    func isCategoryEnabled(_ category: String) -> Bool {
        registry.status(of: SourceRegistry.categoryKey(category)) != .off
    }

    func toggleCategory(_ category: String) {
        registry.toggleCategory(category)
        // Category toggle is structural — reload feed
        Task { await reloadFromSQLite() }
    }

    /// Consecutive failures for a source URL.
    func consecutiveFailures(for sourceURL: String) -> Int {
        scheduler.consecutiveFailures[sourceURL] ?? 0
    }

    // MARK: - What's New

    /// Items fetched since the baseline snapshot, respecting all active filters.
    /// Only items with images, unread, capped at 10, shuffled for variety.
    func loadWhatsNewItems() async -> [FeedItem] {
        guard let baseline = whatsNewBaselineDate else { return [] }
        let cutoff = Int(baseline.timeIntervalSince1970)
        let region = activeRegion
        let category = activeCategory

        /// Run the What's New query with a given cutoff. Extracted so we can try
        /// the baseline first, then fall back to a 7-day window if nothing is fresh.
        func query(cutoff: Int) async throws -> [FeedItem] {
            let records: [FeedItemRecord] = try await db.read { db in
                var request = FeedItemRecord
                    .filter(Column("fetched_at") > cutoff)
                    .filter(Column("is_read") == 0)
                if let r = region { request = request.filter(Column("region") == r) }
                if let c = category { request = request.filter(Column("category") == c) }
                return try request
                    .order(Column("fetched_at").desc)
                    .limit(10)
                    .fetchAll(db)
            }
            return records.map { $0.toFeedItem() }.filter(isItemEnabled).shuffled()
        }

        do {
            // 1) Baseline window — items fetched since the user last dismissed
            let fresh = try await query(cutoff: cutoff)
            if !fresh.isEmpty { return fresh }

            // 2) Fallback cooldown: if the baseline was advanced recently
            //    (e.g. user just dismissed the carousel), skip the 7-day
            //    fallback to respect the dismiss intent. (#37)
            let cooldownWindow: TimeInterval = 3600 // 1 hour
            if Date().timeIntervalSince(baseline) < cooldownWindow { return [] }

            // 3) Fallback: 7-day sliding window — prevents an eternally empty
            //    carousel when no new fetches have landed (e.g. staleness gate,
            //    offline, already-up-to-date feeds).
            let fallbackCutoff = Int(Date().addingTimeInterval(-604800).timeIntervalSince1970)
            let fallback = try await query(cutoff: fallbackCutoff)
            return fallback
        } catch {
            return []
        }
    }

    /// Advance the baseline to now and persist it — so items already shown
    /// in the carousel aren't treated as "new" again next session.
    func advanceWhatsNewBaseline() {
        let now = Date()
        whatsNewBaselineDate = now
        UserDefaults.standard.set(now, forKey: Self.lastWhatsNewSeenAtKey)
    }

    /// Reset the What's New baseline to now so newly enabled content appears.
    /// Items fetched after this point (e.g. seedRegion) will be "new";
    /// weeks-old DB content won't be.
    func resetWhatsNewBaseline() {
        let now = Date()
        whatsNewBaselineDate = now
        UserDefaults.standard.set(now, forKey: Self.lastWhatsNewSeenAtKey)
    }

    // MARK: - Private: fetch

    /// Persist freshly fetched items to SQLite and register them in the
    /// in-memory dedup set, atomically and consistently. Shared by every fetch
    /// path so none can diverge:
    /// - Deduplicates within the batch AND against already-loaded IDs, so two
    ///   feeds returning the same item in one batch can't collide on insert.
    /// - Writes in a single transaction, tolerating individual row failures, so
    ///   one bad/duplicate row can't roll back the whole batch.
    /// - Registers `loadedIDs` only after the write is attempted, so memory
    ///   reflects what was actually stored (no desync on write failure).
    ///
    /// Returns the deduplicated new items for the reservoir / prefetch / search.
    @discardableResult
    private func persistFetchedItems(_ items: [FeedItem], regionOverride: String? = nil) async -> [FeedItem] {
        var seen = Set<String>()
        let actualNew = items.filter { item in
            guard !loadedIDs.contains(item.id) else { return false }
            return seen.insert(item.id).inserted
        }
        guard !actualNew.isEmpty else { return [] }

        // Compute regions on the main actor before entering the write closure.
        let itemsWithRegions: [(item: FeedItem, region: String)] = actualNew.map { item in
            (item, regionOverride ?? registry.regionFor(sourceURL: item.sourceURL))
        }
        do {
            // Single batch write with SAVEPOINT per item. One bad row
            // rolls back to its savepoint without killing the whole batch. (#2)
            let succeeded: [FeedItem] = try await db.write { db -> [FeedItem] in
                var ok: [FeedItem] = []
                for (item, region) in itemsWithRegions {
                    do {
                        try db.execute(sql: "SAVEPOINT item_insert")
                        try FeedItemRecord(from: item, region: region).insert(db)
                        try db.execute(sql: "RELEASE SAVEPOINT item_insert")
                        ok.append(item)
                    } catch {
                        try? db.execute(sql: "ROLLBACK TO SAVEPOINT item_insert")
                    }
                }
                return ok
            }
            for item in succeeded { loadedIDs.insert(item.id) }
            loadedIDsCount = loadedIDs.count
            return succeeded
        } catch {
            print("[FeedStore] persist error: \(error)")
            return []
        }
    }

    private func fetchNextBatch() async {
        guard !isSearching else { return }
        let sourcesByRegion = Dictionary(grouping: registry.enabledSources, by: \.region)
        let contentTypeStr: String? = switch activeContentType {
        case .video: "video"; case .audio: "audio"; case .text: "text"; default: nil
        }
        let batch = scheduler.nextBatch(
            reservoir: reservoir.reservoir,
            sourcesByRegion: sourcesByRegion,
            activeRegion: activeRegion,
            activeCategory: activeCategory,
            activeContentType: contentTypeStr
        )
        guard !batch.isEmpty else { return }

        loadingState = .refreshing
        defer { loadingState = .idle }

        let result = await fetcher.fetchAll(batch, maxConcurrent: 15)
        totalFetched += result.items.count
        if result.failedSourceCount == 0 { fetchErrorCount = 0 }  // reset on clean batch
        else { fetchErrorCount += result.failedSourceCount }
        lastFetchSucceeded = result.failedSourceCount == 0
        emptyFeedCount += result.emptySourceCount

        // Record per-source health in batch
        var healthEntries: [(url: String, itemCount: Int?)] = []
        for source in batch {
            let failed = result.sourceStatuses[source.url] == .failed
            scheduler.recordFetch(sourceURL: source.url, success: !failed)
            let count = result.items.filter { $0.sourceURL == source.url }.count
            healthEntries.append((source.url, count))
        }
        saveSourceHealthBatch(healthEntries)

        let actualNew = await persistFetchedItems(result.items)
        guard !actualNew.isEmpty else { return }

        // Diagnostic (opt-in via debug bar): surface non-English items so a
        // mis-languaged feed can be identified. See loop-focus-areas #5.
        if UserDefaults.standard.bool(forKey: "showDebugBar") {
            logNonEnglishItems(actualNew)
        }

        // Cap items per source after bulk insert
        if !actualNew.isEmpty {
            let sourceURLs = Set(actualNew.map(\.sourceURL))
            for url in sourceURLs {
                await capSourceItems(sourceURL: url)
            }
        }

        // Append to reservoir
        reservoir.append(actualNew)
        prefetchImagesIfEnabled(for: actualNew)
        // Only update visibleItems if no active search
        if !isSearching {
            visibleItems = applyFilters(reservoir.visibleItems)
            reservoirCount = reservoir.reservoirCount
        }

        lastRefreshDate = .now

        // Check persistent searches
        await matchPersistentSearches(actualNew)
    }

    /// Debug diagnostic: logs items whose detected language isn't English,
    /// with source/region/url, so a mis-languaged feed can be spotted at
    /// runtime (loop-focus-areas #5). Gated behind the debug bar — no effect on
    /// the feed itself.
    private func logNonEnglishItems(_ items: [FeedItem]) {
        let recognizer = NLLanguageRecognizer()
        for item in items {
            let text = (item.title + " " + item.excerpt)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 12 else { continue }  // too short to detect reliably
            recognizer.reset()
            recognizer.processString(text)
            guard let lang = recognizer.dominantLanguage, lang != .english else { continue }
            let region = registry.regionFor(sourceURL: item.sourceURL)
            print("[LangCheck] \(lang.rawValue) source=\"\(item.sourceTitle)\" region=\(region) url=\(item.url)")
        }
    }

    /// Fetch a budgeted batch of remaining enabled sources in the background.
    /// Capped per session to avoid hammering 800+ sources at every launch;
    /// the rest trickle in via normal refresh cycles. Shuffled for fair
    /// distribution across text/video/audio types.
    private func progressiveFetch() async {
        let allEnabled = registry.enabledSources.shuffled()
        let budget = min(allEnabled.count, 200)  // per-session cap
        let chunkSize = 20
        print("[progressiveFetch] Starting: \(budget)/\(allEnabled.count) sources")
        for chunkStart in stride(from: 0, to: budget, by: chunkSize) {
            let end = min(chunkStart + chunkSize, budget)
            let chunk = Array(allEnabled[chunkStart..<end])
            // Gentle 1s inter-chunk delay (skip first) to avoid rate-limiting
            // from YouTube and other aggressive CDNs when processing 800+ sources.
            if chunkStart > 0 { try? await Task.sleep(for: .seconds(1)) }
            let result = await fetcher.fetchAll(chunk, maxConcurrent: 5)
            totalFetched += result.items.count
            fetchErrorCount += result.failedSourceCount
            emptyFeedCount += result.emptySourceCount
            // Batch-save source health with real item counts
            var healthEntries: [(url: String, itemCount: Int?)] = []
            for source in chunk {
                let failed = result.sourceStatuses[source.url] == .failed
                scheduler.recordFetch(sourceURL: source.url, success: !failed)
                let count = result.items.filter { $0.sourceURL == source.url }.count
                healthEntries.append((source.url, count))
            }
            saveSourceHealthBatch(healthEntries)
            let actualNew = await persistFetchedItems(result.items)
            reservoir.append(actualNew)
            // Cap items per source so no single feed dominates (>50 items)
            if !actualNew.isEmpty {
                let sourceURLs = Set(actualNew.map(\.sourceURL))
                for url in sourceURLs { await capSourceItems(sourceURL: url) }
            }
            prefetchImagesIfEnabled(for: actualNew)
            await matchPersistentSearches(actualNew)
            if visibleItems.isEmpty && !reservoir.reservoir.isEmpty {
                reservoir.moveToVisible(count: Reservoir.pageSize)
                visibleItems = applyFilters(reservoir.visibleItems)
                reservoirCount = reservoir.reservoirCount
            }
        }
        print("[progressiveFetch] DONE — all \(allEnabled.count) sources processed")
        lastRefreshDate = .now

        // Retroactive cap: sources that accumulated >50 items before the cap
        // existed (e.g. OpenAI Blog at 1000+) get trimmed once after the
        // initial bulk fetch completes.
        await capAllSources()
    }

    /// Cap ALL sources in the database at 50 items each. Runs once after
    /// progressiveFetch completes the initial bulk fetch. Uses a single
    /// query to find offenders so we don't scan 855 sources one-by-one.
    private func capAllSources() async {
        do {
            let offenders: [String] = try await db.read { db in
                try String.fetchAll(db, sql: """
                    SELECT source_url FROM feed_item
                    GROUP BY source_url HAVING COUNT(*) > 50
                """)
            }
            guard !offenders.isEmpty else { return }
            print("[capAllSources] Capping \(offenders.count) sources (>50 items)")
            for url in offenders {
                await capSourceItems(sourceURL: url)
            }
        } catch {
            print("[capAllSources] Error: \(error)")
        }
    }

    private func reloadFromSQLite(prepend: [FeedItem] = []) async {
        guard !isSearching else { return }
        let region = activeRegion
        let category = activeCategory
        // disabledRegions filtering now handled in-memory by isItemEnabled
        let items: [FeedItemRecord] = (try? await db.read { db in
            var request = FeedItemRecord
                .filter(Column("fetched_at") > Self.thirtyDayCutoffEpoch)
            if let r = region {
                request = request.filter(Column("region") == r)
            }
            if let c = category { request = request.filter(Column("category") == c) }
            return try request
                .order(Column("published_at").desc)
                .limit(200)
                .fetchAll(db)
        }) ?? []
        var feedItems = items.map { $0.toFeedItem() }
        // Prepend seed items at the top so newly enabled region appears first
        if !prepend.isEmpty {
            feedItems = prepend + feedItems
        }
        // Register all loaded IDs to prevent re-fetch duplicates
        for item in feedItems { loadedIDs.insert(item.id) }
        reservoir.seed(items: feedItems)
        visibleItems = applyFilters(reservoir.visibleItems)
        reservoirCount = reservoir.reservoirCount
    }

    private func loadReservoir() async throws -> [FeedItem]? {
        // Fetch a larger pool, then select with diversity: news items favor
        // recency; everything else is randomized. This prevents a single
        // prolific source from dominating the first 200 slots.
        let poolSize = 400
        let records: [FeedItemRecord] = try await db.read { db in
            try FeedItemRecord
                .filter(Column("fetched_at") > Self.thirtyDayCutoffEpoch)
                .order(Column("published_at").desc)
                .limit(poolSize)
                .fetchAll(db)
        }
        guard !records.isEmpty else { return nil }
        let items = records.map { $0.toFeedItem() }

        // Split: news items (time-sensitive) keep recency order; everything
        // else gets shuffled for diversity. Then merge: all news first (most
        // recent at top), then random non-news, capped at 200.
        let newsCategories = Set(["news", "News & Politics", "Sports"])
        var news = items.filter { newsCategories.contains($0.category) }
        var other = items.filter { !newsCategories.contains($0.category) }.shuffled()
        // News already ordered by published_at DESC from the query
        var selected = news + other
        if selected.count > 200 { selected = Array(selected.prefix(200)) }
        return selected
    }

    private func loadReadState() async {
        do {
            let ids: [String] = try await db.read { db in
                try String.fetchAll(db, sql: "SELECT id FROM feed_item WHERE is_read = 1")
            }
            readItemIDs = Set(ids)
        } catch {
            print("[FeedStore] loadReadState error: \(error)")
        }
    }

    // MARK: - Region toggle

    func toggleRegion(_ region: String) {
        let wasDisabled = registry.status(of: SourceRegistry.regionKey(region)) == .off
        let sourceURLs = registry.sources.filter { $0.region == region }.map(\.url)
        registry.toggleRegion(region)
        if wasDisabled {
            // Enabling: clear memory, seed fresh content, reload from SQLite
            scheduler.prioritize(sourceURLs: sourceURLs)
            resetWhatsNewBaseline()
            reservoir.clear()
            visibleItems = []
            reservoirCount = 0
            Task {
                let seedItems = await seedRegion(region)
                if !seedItems.isEmpty {
                    let name: String
                    if region == "global" {
                        name = "Global feeds"
                    } else {
                        name = CountryStore.countryName(for: region.replacingOccurrences(of: "countries/", with: ""))
                    }
                    lastToggleMessage = "\(name): \(seedItems.count) new articles"
                }
                await reloadFromSQLite(prepend: seedItems)
            }
        } else {
            // Disabling: remove from scheduler, purge from reservoir
            scheduler.remove(sourceURLs: sourceURLs)
            reservoir.removeRegion(region)
            visibleItems = applyFilters(reservoir.visibleItems)
            reservoirCount = reservoir.reservoirCount
        }
    }

    /// Fetch a seed batch from a newly enabled region. Returns items to prepend.
    private func seedRegion(_ region: String) async -> [FeedItem] {
        let regionSources = registry.enabledSources
            .filter { $0.region == region }
            .prefix(10)
        guard !regionSources.isEmpty else { return [] }
        let batch = Array(regionSources)
        let result = await fetcher.fetchAll(batch, maxConcurrent: 10)
        // Record fetch health first — reachability is independent of whether the
        // items turn out to be new.
        for source in batch {
            let failed = result.sourceStatuses[source.url] == .failed
            scheduler.recordFetch(sourceURL: source.url, success: !failed)
            saveSourceHealth(for: source.url)
        }
        let actualNew = await persistFetchedItems(result.items, regionOverride: region)
        guard !actualNew.isEmpty else { return [] }
        await matchPersistentSearches(actualNew)
        prefetchImagesIfEnabled(for: actualNew)
        return actualNew
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
            // Pre-filter by region/category in memory, then run ONE FTS query
            // for all candidate ids at once. The previous code issued a separate
            // FTS read (and write) per item, i.e. O(searches × items) round-trips
            // on every fetched batch.
            let candidateIDs = items.filter { item in
                if let region = search.searchRegion,
                   region != registry.regionFor(sourceURL: item.sourceURL) { return false }
                if let cat = search.searchCategory, cat != item.category { return false }
                return true
            }.map(\.id)
            guard !candidateIDs.isEmpty else { continue }

            let matchedIDs: [String] = (try? await db.read { db in
                try FeedItemRecord
                    .filter(candidateIDs.contains(Column("id")))
                    .matching(pattern)
                    .fetchAll(db)
                    .map(\.id)
            }) ?? []
            guard !matchedIDs.isEmpty else { continue }

            let now = Int(Date().timeIntervalSince1970)
            try? await db.write { db in
                for id in matchedIDs {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO bookmark_item (list_id, item_id, added_at)
                        VALUES (?, ?, ?)
                    """, arguments: [search.id!, id, now])
                }
            }
        }
    }

    // MARK: - Maintenance

    /// Lightweight cleanup on every launch — deletes up to 500 expired items.
    func performLightExpurgo() async {
        let cutoff = Int(Date().addingTimeInterval(-2592000).timeIntervalSince1970) // 30 days
        do {
            try await db.write { db in
                // Use subquery instead of DELETE LIMIT for SQLite compatibility (#22)
                try db.execute(sql: """
                    DELETE FROM feed_item WHERE id IN (
                        SELECT id FROM feed_item
                        WHERE fetched_at < ?
                          AND is_read = 0
                          AND id NOT IN (SELECT item_id FROM bookmark_item)
                        LIMIT 500
                    )
                """, arguments: [cutoff])
            }
        } catch {
            print("[FeedStore] Expurgo error: \(error)")
        }
    }

    /// Per-source cap: keep max 50 items per source within 30-day window.
    func capSourceItems(sourceURL: String) async {
        do {
            // Snapshot IDs before deletions so we know what existed
            let before = Set(try await db.read { db in
                try String.fetchAll(db, sql: "SELECT id FROM feed_item WHERE source_url = ?", arguments: [sourceURL])
            })
            try await db.write { db in
                let count = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM feed_item WHERE source_url = ?
                """, arguments: [sourceURL]) ?? 0
                guard count > 50 else { return }
                try db.execute(sql: """
                    DELETE FROM feed_item WHERE id IN (
                        SELECT id FROM feed_item WHERE source_url = ?
                        AND id NOT IN (SELECT item_id FROM bookmark_item)
                        AND is_read = 0
                        ORDER BY published_at ASC
                        LIMIT ?
                    )
                """, arguments: [sourceURL, count - 50])
            }
            // Sync loadedIDs: remove IDs that no longer exist in DB (#19)
            let after = Set(try await db.read { db in
                try String.fetchAll(db, sql: "SELECT id FROM feed_item WHERE source_url = ?", arguments: [sourceURL])
            })
            let removed = before.subtracting(after)
            for id in removed { loadedIDs.remove(id) }
            if !removed.isEmpty { loadedIDsCount = loadedIDs.count }
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
                try db.execute(sql: """
                    DELETE FROM feed_item
                    WHERE fetched_at < ?
                      AND is_read = 0
                      AND id NOT IN (SELECT item_id FROM bookmark_item)
                """, arguments: [Int(Date().addingTimeInterval(-2592000).timeIntervalSince1970)])
            }
            try await db.vacuum()
            UserDefaults.standard.set(now, forKey: lastKey)
            print("[FeedStore] Heavy maintenance complete")
        } catch {
            print("[FeedStore] Maintenance error: \(error)")
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

    /// Toggle search_active on a persistent search bookmark list.
    /// When activated, retroactively adds matching existing items to the list.
    func toggleSearchActive(listID: Int64) async throws {
        let wasActive: Bool = try await db.read { db in
            try Bool.fetchOne(db, sql: "SELECT search_active FROM bookmark_list WHERE id = ?", arguments: [listID]) ?? false
        }
        let newState = !wasActive
        try await db.write { db in
            try db.execute(sql: "UPDATE bookmark_list SET search_active = ? WHERE id = ?",
                          arguments: [newState, listID])
        }
        // If activating, retroactively match existing items in SQLite
        if newState {
            try await retroMatchSearch(listID: listID)
        }
    }

    /// Retroactively add all existing items in SQLite that match a persistent search.
    private func retroMatchSearch(listID: Int64) async throws {
        let search: BookmarkListRecord? = try await db.read { db in
            try BookmarkListRecord.fetchOne(db, key: listID)
        }
        guard let search, let query = search.searchQuery,
              let pattern = FTS5Pattern(matchingAllTokensIn: query) else { return }

        let records: [FeedItemRecord] = try await db.read { db in
            var request = FeedItemRecord
                .filter(Column("fetched_at") > Self.thirtyDayCutoffEpoch)
                .matching(pattern)
            if let region = search.searchRegion {
                request = request.filter(Column("region") == region)
            }
            if let cat = search.searchCategory {
                request = request.filter(Column("category") == cat)
            }
            return try request.fetchAll(db)
        }

        guard !records.isEmpty else { return }
        let now = Int(Date().timeIntervalSince1970)
        try await db.write { db in
            for record in records {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO bookmark_item (list_id, item_id, added_at)
                    VALUES (?, ?, ?)
                """, arguments: [listID, record.id, now])
            }
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
                    .filter(Column("fetched_at") > Self.thirtyDayCutoffEpoch)
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

        // Sort: score DESC. Must be a strict weak ordering — returning true for
        // equal scores (the old `return true`) violates sorted(by:)'s contract
        // and can crash or yield a garbage order. `a.1 > b.1` returns false on
        // ties, and sorted(by:) is stable, so equal scores keep their order.
        let sorted = bestScore.values.sorted { a, b in
            a.1 > b.1
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

    /// Shake-to-refresh: mark visible as read, re-interleave reservoir,
    /// reload from SQLite, force fetch fresh content.
    func shakeToRefresh() {
        // Mark visible items as surfaced so they deprecate below unseen content
        for item in reservoir.visibleItems {
            readItemIDs.insert(item.id)
        }
        // Clear everything, then force-fetch NEW content from the internet.
        // Reset What's New baseline so fresh items appear in the carousel.
        resetWhatsNewBaseline()
        visibleItems = []
        reservoirCount = 0
        reservoir.clear()
        lastRefreshDate = nil   // bypass staleness check
        Task {
            await reloadFromSQLite()
            await fetchNextBatch()  // always fetch, not just when <20
        }
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
        // v2: earlier builds stored feed_item dates using GRDB's default TEXT
        // encoding ("yyyy-MM-dd HH:mm:ss.SSS") even though the columns are
        // INTEGER. That made integer-epoch comparisons (expurgo, What's New)
        // always-true/always-false. Convert any lingering TEXT timestamps to
        // epoch seconds in place — we can't drop the cache because bookmark_item
        // cascades from feed_item and dropping rows would delete users' saves.
        migrator.registerMigration("v2_epoch_dates") { db in
            for col in ["published_at", "fetched_at", "opened_at"] {
                try db.execute(sql: """
                    UPDATE feed_item
                    SET \(col) = CAST(strftime('%s', \(col)) AS INTEGER)
                    WHERE typeof(\(col)) = 'text'
                """)
            }
        }
        migrator.registerMigration("v3_source_health") { db in
            try db.create(table: "source_health") { t in
                t.column("url", .text).primaryKey()
                t.column("last_fetch_at", .integer).notNull()
                t.column("consecutive_failures", .integer).notNull().defaults(to: 0)
                t.column("last_status", .text)
                t.column("last_item_count", .integer)
            }
        }
        migrator.registerMigration("v4_indexes") { db in
            try db.create(index: "idx_item_source_pub",
                          on: "feed_item", columns: ["source_url", "published_at"])
            try db.create(index: "idx_item_category_fetched",
                          on: "feed_item", columns: ["category", "fetched_at"])
        }
        migrator.registerMigration("v5_source_toggle") { db in
            try db.create(table: "source_toggle") { t in
                t.column("key", .text).primaryKey()
                t.column("state", .integer).notNull()  // 0=disabled, 1=enabled_override
            }
            // Migrate existing UserDefaults data
            if let disabled = UserDefaults.standard.array(forKey: "toggleDisabled") as? [String] {
                for key in disabled {
                    try db.execute(sql: "INSERT OR IGNORE INTO source_toggle (key, state) VALUES (?, 0)", arguments: [key])
                }
            }
            if let overrides = UserDefaults.standard.array(forKey: "toggleEnabledOverrides") as? [String] {
                for key in overrides {
                    try db.execute(sql: "INSERT OR REPLACE INTO source_toggle (key, state) VALUES (?, 1)", arguments: [key])
                }
            }
        }
        try migrator.migrate(db)
    }
}

// MARK: - Source Health Record

struct SourceHealthRecord: Codable, PersistableRecord, FetchableRecord {
    var url: String
    var lastFetchAt: Int
    var consecutiveFailures: Int
    var lastStatus: String?
    var lastItemCount: Int?

    enum CodingKeys: String, CodingKey {
        case url
        case lastFetchAt = "last_fetch_at"
        case consecutiveFailures = "consecutive_failures"
        case lastStatus = "last_status"
        case lastItemCount = "last_item_count"
    }

    static let databaseTableName = "source_health"

    static func loadAll(_ db: Database) throws -> [SourceHealthRecord] {
        try fetchAll(db)
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
    var publishedAt: Int   // epoch seconds
    var fetchedAt: Int     // epoch seconds
    var isRead: Bool
    var openedAt: Int?     // epoch seconds

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
        self.imageURL = item.bestImageURL  // YouTube thumbnail or RSS image
        self.audioURL = item.audioURL
        self.duration = item.duration
        self.publishedAt = Int(item.publishedAt.timeIntervalSince1970)
        self.fetchedAt = Int(Date().timeIntervalSince1970)
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
            publishedAt: Date(timeIntervalSince1970: TimeInterval(publishedAt)),
            audioURL: audioURL,
            duration: duration,
            region: region
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
