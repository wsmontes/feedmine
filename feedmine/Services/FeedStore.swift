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
    let userRepo: UserStateStore
    let bookmarkStore: BookmarkStore
    let searchEngine: SearchEngine
    let whatsNewManager: WhatsNewManager

    // MARK: - Public state
    private(set) var visibleItems: [FeedItem] = []
    /// Monotonic generation counter — incremented on every visibleItems change.
    /// FeedLoader uses this for cache invalidation instead of item count.
    private(set) var visibleItemsGeneration: UInt64 = 0
    private(set) var reservoirCount: Int = 0
    var lastToggleMessage: String?
    private(set) var loadingState: FeedLoadingState = .idle
    private(set) var lastRefreshDate: Date?
    private(set) var totalFetched = 0
    private(set) var fetchErrorCount = 0
    private(set) var lastFetchSucceeded = false  // reset error banner on success
    private(set) var emptyFeedCount = 0
    private(set) var totalDiscarded = 0
    var emptyStateFetchedCount: Int = 0
    var emptyStateFetchTotal: Int = 0
    /// True while an urgent taxonomy fetch is in-flight — FeedScreen uses this
    /// to keep the empty state in .fetching mode until items actually arrive.
    private(set) var isUrgentFetching = false

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
    var activeNodeIDs: Set<String> = []
    var activeContentType: FeedLoader.ContentType = .all
    var activeMood: FeedLoader.MoodFilter = .all
    var activeLanguages: Set<String> = []

    /// Cached set of feed URLs that match the current taxonomy selection.
    /// Invalidated when activeNodeIDs changes. Makes applyFilters O(items) instead
    /// of O(items x selectedNodes).
    private var cachedTaxonomyFeedURLs: Set<String> = []
    private var cachedTaxonomyNodeIDs: Set<String> = []
    /// Monotonic counter incremented on every filter change. Async operations
    /// (urgent fetch, reloadFromSQLite pipeline) capture the generation at launch
    /// and discard results if a newer filter has been applied in the meantime.
    private var filterGeneration: Int64 = 0
    /// When set, the feed shows only items from this bookmark list.
    var selectedBookmarkListID: Int64?
    /// Preferred box for saving bookmarks. Defaults to the "Favorites" list.
    var preferredBookmarkListID: Int64?
    private(set) var isBookmarkFeed = false

    /// Load a fixed bookmark feed — all items from the box, ordered by save date.
    /// Pauses all background processes that would modify the screen.
    func loadBookmarkFeed(items: [FeedItem]) {
        isBookmarkFeed = true
        pipelineTask?.cancel()
        trimDebounceTask?.cancel()
        progressiveFetchTask?.cancel()
        backgroundRefreshTask?.cancel()
        setVisibleItems(items)
        reservoirCount = 0
        reservoir.clear()
    }

    /// Clear bookmark mode and reload the normal feed.
    func clearBookmarkFeed() {
        isBookmarkFeed = false
        startBackgroundRefresh()
        applyUpdate(.flush())
    }
    /// Single eligibility rule — used by fetch and in-memory filter paths.
    /// (The SQL path loads items from taxonomy URLs unconditionally; the
    /// in-memory applyFilters pass then applies this rule to cull individually
    /// disabled sources.)
    ///
    /// - When taxonomy is active AND the item's source URL is in the taxonomy
    ///   set: bypass category/region disables but still respect individual
    ///   per-source opt-outs. An explicit taxonomy selection acts as a temporary
    ///   query over the full catalogue.
    /// - Otherwise: delegate to the normal SourceRegistry enablement check.
    private func isSourceEligible(sourceURL: String, taxonomySelectionActive: Bool) -> Bool {
        if taxonomySelectionActive, cachedTaxonomyFeedURLs.contains(OPMLParser.normalizeURL(sourceURL)) {
            // Bypass inherited disables (category, region) but respect individual off
            return !registry.isSourceExplicitlyDisabled(sourceURL)
        }
        return registry.isSourceEnabled(sourceURL)
    }

    /// Safety filter: excludes items from disabled regions/categories/feeds.
    /// Respects taxonomy override — see isSourceEligible for semantics.
    private func isItemEnabled(_ item: FeedItem) -> Bool {
        isSourceEligible(sourceURL: item.sourceURL, taxonomySelectionActive: !cachedTaxonomyFeedURLs.isEmpty)
    }

    /// Prefetch images for items if enabled (default: true).
    private func prefetchImagesIfEnabled(for items: [FeedItem]) {
        guard Settings.prefetchImages else { return }
        let urls = items.compactMap { $0.bestImageURL ?? $0.imageURL }
        guard !urls.isEmpty else { return }
        Task { await prefetcher.prefetch(urls: urls, priorityURLs: urls) }
    }

    /// Aggressive prefetch: visible items first (user sees now), then deep
    /// reservoir batch (user scrolls to soon). Called after seed/moveToVisible
    /// so images are cached before they hit the screen.
    private func prefetchVisibleAndNext() {
        guard Settings.prefetchImages else { return }
        let visible = reservoir.visibleItems.compactMap { $0.bestImageURL ?? $0.imageURL }
        let upcoming = reservoir.upcomingItems(100).compactMap { $0.bestImageURL ?? $0.imageURL }
        let all = Array(Set(visible + upcoming))
        guard !all.isEmpty else { return }
        Task { await prefetcher.prefetch(urls: all, priorityURLs: visible) }
    }

    /// Normalize a set of language codes to ISO 639-1 base codes.
    /// Used to ensure selected languages, persisted settings, and any
    /// BCP 47 input from external sources all converge on the same keys.
    static func normalizedLanguageSet(_ languages: some Sequence<String>) -> Set<String> {
        Set(languages.compactMap(normalizedLanguageCode))
    }

    /// Fast-path language filter — assumes `selectedLanguages` and
    /// `deviceLanguage` are already normalized to ISO 639-1 base codes.
    /// Only `itemLanguage` is normalized (items may carry raw BCP 47 tags
    /// or unrecognized input from feeds).
    ///
    /// Used in hot paths (`applyFilters`) where the set and device language
    /// are normalized once before the per-item loop.
    nonisolated static func languageFilterMatchesNormalized(
        itemLanguage: String?,
        selectedLanguages: Set<String>,
        deviceLanguage: String?
    ) -> Bool {
        guard !selectedLanguages.isEmpty else { return true }
        if let lang = normalizedLanguageCode(itemLanguage) {
            return selectedLanguages.contains(lang)
        }
        if let device = deviceLanguage {
            return selectedLanguages.contains(device)
        }
        return false
    }

    /// Public defensive wrapper — normalizes all three inputs before
    /// delegating to the fast path. Safe for external callers, tests,
    /// and any code that may receive unnormalized BCP 47 input.
    static func languageFilterMatches(
        itemLanguage: String?,
        selectedLanguages: Set<String>,
        deviceLanguage: String?
    ) -> Bool {
        languageFilterMatchesNormalized(
            itemLanguage: itemLanguage,
            selectedLanguages: normalizedLanguageSet(selectedLanguages),
            deviceLanguage: normalizedLanguageCode(deviceLanguage)
        )
    }

    /// Normalize a language tag to its ISO 639-1 base code.
    /// - Trims whitespace, normalizes underscores to hyphens
    /// - Extracts the primary language subtag from BCP 47 / RFC 5646 tags
    ///   (e.g. "pt-BR" → "pt", "en_US" → "en", "zh-Hant" → "zh")
    /// - Returns lowercase code, or nil for empty/whitespace-only input
    nonisolated static func normalizedLanguageCode(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        guard !trimmed.isEmpty else { return nil }
        // Use Foundation's Locale.Language to extract the primary language
        // subtag — handles arbitrary BCP 47 complexity correctly.
        if let code = Locale.Language(identifier: trimmed).languageCode?.identifier {
            return code.lowercased()
        }
        // Fallback: split on first hyphen (covers codes Foundation may reject)
        return trimmed
            .split(separator: "-", maxSplits: 1)
            .first
            .map { String($0).lowercased() }
    }

    /// Lightweight, Sendable input for off‑main‑actor language detection.
    private struct LanguageDetectionInput: Sendable {
        let title: String
        let excerpt: String
        /// Explicit language from the source OPML (xml:lang or category directory).
        let explicitLanguage: String?
    }

    /// Run language detection for a batch of items off the main actor.
    /// Reuses a single NLLanguageRecognizer across the batch to avoid
    /// per‑item allocation overhead. Returns resolved language codes in the
    /// same order as the input array.
    nonisolated private static func detectLanguages(_ inputs: [LanguageDetectionInput]) -> [String?] {
        guard !inputs.isEmpty else { return [] }
        let recognizer = NLLanguageRecognizer()
        return inputs.map { input in
            // 1. Explicit source language (already resolved, just pass through)
            if let lang = input.explicitLanguage, !lang.isEmpty {
                return lang
            }
            // 2. On-device detection fallback
            let text = (input.title + " " + input.excerpt)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 12 else { return nil }
            recognizer.reset()
            recognizer.processString(text)
            // NLLanguageRecognizer may return BCP 47 tags — normalize to base code
            return normalizedLanguageCode(recognizer.dominantLanguage?.rawValue)
        }
    }

    /// Apply all active filters to a list of items — single source of truth.
    /// Hit recording is NOT performed here; it happens once at ingestion time
    /// in persistFetchedItems so each item is counted exactly once regardless
    /// of how many times applyFilters runs on the same items.
    func applyFilters(_ items: [FeedItem]) -> [FeedItem] {
        let region = activeRegion
        let contentType = filterContentType
        let languages = activeLanguages
        let mood = activeMood
        let contentFilters = ContentFilterStore.shared.isEnabled
            ? ContentFilterStore.shared.activeFilters : []
        let deviceLanguage = Self.normalizedLanguageCode(Locale.current.language.languageCode?.identifier)
        return items.filter { item in
            isItemEnabled(item)
            && (region == nil || item.region == region || item.region.hasPrefix(region! + "/"))
            && (cachedTaxonomyFeedURLs.isEmpty || cachedTaxonomyFeedURLs.contains(OPMLParser.normalizeURL(item.sourceURL)))
            && Self.languageFilterMatchesNormalized(itemLanguage: item.language, selectedLanguages: languages, deviceLanguage: deviceLanguage)
            && contentType(item)
            && (mood == .all || mood.matches(item.title))
            && !contentFilterExcludes(item, filters: contentFilters)
        }
    }

    /// Content filter matching engine: checks if an item's title+excerpt contains any
    /// keyword from the user's active content filters. Collects matching filter IDs
    /// in `hitIDs` for optional hit tracking by the caller. Pure matching — no
    /// side effects; callers decide whether to record hits via ContentFilterStore.
    ///
    /// Performance: uses plain contains() on pre-normalized strings instead of
    /// localizedStandardContains. Keywords are already lowercased + diacritic-folded
    /// by ContentFilterStore.activeFilters. Item text is computed once via
    /// FeedItem.searchableText.
    private func _contentFilterExcludes(_ item: FeedItem, filters: [(id: UUID, keywords: [String])], hitIDs: inout [UUID]) -> Bool {
        guard !filters.isEmpty else { return false }
        let text = item.searchableText
        for filter in filters {
            for keyword in filter.keywords {
                if text.contains(keyword) {
                    hitIDs.append(filter.id)
                    return true
                }
            }
        }
        return false
    }

    /// Pure predicate — no side effects. Used by applyFilters where hits are
    /// recorded once at ingestion time in persistFetchedItems instead of on
    /// every filter pass.
    private func contentFilterExcludes(_ item: FeedItem, filters: [(id: UUID, keywords: [String])]) -> Bool {
        var unused: [UUID] = []
        return _contentFilterExcludes(item, filters: filters, hitIDs: &unused)
    }

    /// Records a hit for each matching filter. Used at item ingestion time
    /// (persistFetchedItems) so each item is counted exactly once.
    private func contentFilterExcludesAndRecord(_ item: FeedItem, filters: [(id: UUID, keywords: [String])]) -> Bool {
        var hitIDs: [UUID] = []
        let excluded = _contentFilterExcludes(item, filters: filters, hitIDs: &hitIDs)
        for id in hitIDs {
            ContentFilterStore.shared.recordHit(id)
        }
        return excluded
    }

    private var filterContentType: (FeedItem) -> Bool {
        switch activeContentType {
        case .all: return { _ in true }
        case .text: return { !$0.isYouTube && !$0.isPodcast && !$0.isForum }
        case .video: return { $0.isYouTube }
        case .audio: return { $0.isPodcast }
        case .forum: return { $0.isForum }
        }
    }
    var isSearching = false
    private var searchResults: [FeedItem] = []

    // MARK: - Read & Seen state
    private(set) var readItemIDs: Set<String> = []
    /// Items that the user has bookmarked — loaded at startup and kept in sync
    /// with every toggle so `setVisibleItems` can stamp `isBookmarked` correctly.
    private(set) var bookmarkedItemIDs: Set<String> = []
    /// Items that have appeared in the main feed (surfaced). Tracked
    /// continuously so What's New can exclude already-seen content.
    private(set) var surfacedItemIDs: Set<String> = []
    private(set) var loadedIDsCount: Int = 0
    private var loadedIDs: Set<String> = []  // Bloom filter for dedup
    private static let lastWhatsNewSeenAtKey = "last_whats_new_seen_at"

    /// Computed forwarding for What's New items from the manager.
    var whatsNewItems: [FeedItem] { whatsNewManager.whatsNewItems }

    private var hasStarted = false             // guards one-time startup work
    private var progressiveFetchTask: Task<Void, Never>?
    private var backgroundRefreshTask: Task<Void, Never>?
    private var regionToggleTask: Task<Void, Never>?
    private var filterDebounceTask: Task<Void, Never>?
    private var urgentFetchTask: Task<Void, Never>?

    // MARK: - Throttled reservoir append
    // Accumulates items from progressive/background fetches and flushes them
    // to the reservoir in a single interleave pass every few seconds, reducing
    // 10+ interleave passes to 2-3 during startup.
    private var pendingReservoirItems: [FeedItem] = []
    private var reservoirFlushTask: Task<Void, Never>?
    private static let reservoirFlushInterval: Duration = .seconds(3)

    /// Queue items for eventual reservoir append. Flushes after a debounce
    /// interval or when the pending batch reaches a size threshold.
    func throttledReservoirAppend(_ items: [FeedItem]) {
        pendingReservoirItems.append(contentsOf: items)
        reservoirFlushTask?.cancel()
        // Flush immediately if large batch (user might be scrolling).
        // Schedule via reservoirFlushTask so that flushPendingReservoir()
        // can await it when a pipeline op needs ordering guarantees.
        if pendingReservoirItems.count >= 100 {
            reservoirFlushTask = Task { [weak self] in
                guard let self else { return }
                self.reservoirFlushTask = nil
                await self.flushPendingReservoir()
            }
            return
        }
        reservoirFlushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.reservoirFlushInterval)
            guard !Task.isCancelled, let self else { return }
            self.reservoirFlushTask = nil
            await self.flushPendingReservoir()
        }
    }

    /// Flush pending reservoir items — interleave + append — and return when
    /// the items are fully committed to the reservoir. Await this before any
    /// pipeline operation (.refresh, .append) that must see the new items.
    ///
    /// Drains any scheduled `reservoirFlushTask` before proceeding so that
    /// items batched by the throttled path are always committed before a
    /// refresh sees them. The task body clears its own reference before
    /// calling us, preventing a circular await.
    private func flushPendingReservoir() async {
        // Cancel and drain any scheduled flush task that hasn't started
        // executing yet so callers that need ordering guarantees do not wait
        // for the debounce interval before committing pending items.
        // (Tasks that already started clear reservoirFlushTask before calling us.)
        if let task = reservoirFlushTask {
            reservoirFlushTask = nil
            task.cancel()
            await task.value
        }

        guard !pendingReservoirItems.isEmpty else { return }
        let batch = pendingReservoirItems

        // Compute interleave off the main actor — this is the expensive part
        // (O(n × sources) with multiple spread passes). Only the final
        // assignment to reservoir arrays needs MainActor.
        let readIDs = reservoir.readItemIDs
        let surfacedTs = reservoir.surfacedTimestamps
        let regionMap = reservoir.sourceRegionMap
        let visibleIDs = Set(reservoir.visibleItems.map(\.id))
        let trulyNew = batch.filter { !visibleIDs.contains($0.id) }
        guard !trulyNew.isEmpty else {
            pendingReservoirItems = []
            return
        }

        let interleaved = await Task.detached(priority: .userInitiated) {
            Reservoir.interleaveOffMain(
                trulyNew, readItemIDs: readIDs,
                surfacedTimestamps: surfacedTs, sourceRegionMap: regionMap
            )
        }.value

        // Drain the batch only after the interleave completes — otherwise a
        // concurrent caller during the suspension would see an empty queue
        // and proceed without waiting for the in-flight items.
        let batchIDs = Set(batch.map(\.id))
        pendingReservoirItems.removeAll { batchIDs.contains($0.id) }

        self.reservoir.appendPreInterleaved(interleaved)
        if !self.isSearching && self.visibleItems.isEmpty && !self.reservoir.reservoir.isEmpty {
            self.reservoir.moveToVisible(count: Reservoir.pageSize)
            self.setVisibleItems(self.applyFilters(self.reservoir.visibleItems))
        }
        self.reservoirCount = self.reservoir.reservoirCount
    }

    #if DEBUG
    func flushPendingReservoirForTesting() async {
        await flushPendingReservoir()
    }
    #endif

    // MARK: - Init
    init(inMemory: Bool = false) throws {
        let endInitMetric = FeedMetrics.beginInterval("FeedStore.init")
        defer { endInitMetric() }
        if inMemory {
            self.db = try DatabaseQueue(configuration: Self.dbConfig)
        } else {
            self.db = try DatabaseQueue(path: Self.dbPath, configuration: Self.dbConfig)
        }
        try Self.migrate(db)
        // user.sqlite — owns bookmark identity, survives catalog rebuilds
        self.userRepo = try UserStateStore(inMemory: inMemory)
        self.bookmarkStore = BookmarkStore(userDB: userRepo.db, contentDB: db)
        self.searchEngine = SearchEngine(db: db)
        self.whatsNewManager = WhatsNewManager(db: db)
        // Migrate legacy bookmark data from feedmine.sqlite → user.sqlite
        // if this is the first launch after the split.
        if !inMemory {
            Task { [weak self] in
                guard let self else { return }
                do {
                    if try self.userRepo.needsLegacyMigration(legacyDB: self.db) {
                        try await self.userRepo.migrateFromLegacy(legacyDB: self.db)
                    }
                } catch {
                    Log.db.error("Bookmark migration to user.sqlite failed: \(error)")
                }
            }
        }
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

    /// Last-resort fallback: creates an in-memory store. Uses try! because if
    /// even an in-memory SQLite database cannot be created, the device is in a
    /// state where no app using SQLite can run (out of memory, broken OS
    /// libraries). This is the one acceptable crash point — the app literally
    /// cannot function without a database.
    static func empty() -> FeedStore {
        try! FeedStore(inMemory: true)
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
            Log.db.error("loadSourceHealth failed: \(error.localizedDescription)")
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
            Log.db.error("saveSourceHealthBatch error: \(error.localizedDescription)")
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
        FeedMetrics.event("Backend.start")
        networkMonitor.start()
        let endOPMLMetric = FeedMetrics.beginInterval("OPML.load")
        await registry.loadFromOPML()
        endOPMLMetric()
        FeedMetrics.event("OPML.sourceCount", "count=\(self.registry.sources.count)")
        FeedMetrics.memory("afterOPML")
        reservoir.sourceRegionMap = registry.regionMap

        // Build taxonomy tree from loaded sources — try cache first, build if needed
        let endTaxonomyMetric = FeedMetrics.beginInterval("Taxonomy.loadOrBuild")
        let taxonomyCacheHit = TaxonomyStore.shared.loadFromCache(sources: registry.sources)
        if !taxonomyCacheHit {
            await TaxonomyStore.shared.build(from: registry.sources)
        }
        endTaxonomyMetric()
        if taxonomyCacheHit {
            FeedMetrics.event("Taxonomy.cacheHit")
        } else {
            FeedMetrics.event("Taxonomy.cacheMiss")
        }
        FeedMetrics.event(
            "Taxonomy.objectCounts",
            "nodes=\(TaxonomyStore.shared.flatIndex.count) sources=\(self.registry.sources.count)"
        )
        FeedMetrics.memory("afterTaxonomy")

        // Invalidate taxonomy filter cache after rebuild
        cachedTaxonomyNodeIDs = []
        cachedTaxonomyFeedURLs = []

        // Restore persisted filters FIRST so the first render shows
        // correctly filtered content, not a flash of unfiltered items.
        restoreFilters()

        // Set language default on first launch — only applies when no
        // persisted language filter was restored above.
        if !Settings.hasInitializedLanguageDefault {
            let deviceLang = Locale.current.language.languageCode?.identifier
            if let lang = deviceLang {
                let availableLangs = Self.normalizedLanguageSet(registry.sources.compactMap(\.language))
                if availableLangs.contains(lang) {
                    activeLanguages = [lang]
                    persistFilters()
                }
            }
            Settings.hasInitializedLanguageDefault = true
        }

        let endReadStateMetric = FeedMetrics.beginInterval("ReadState.load")
        await loadReadState()
        endReadStateMetric()
        reservoir.readItemIDs = readItemIDs
        bookmarkedItemIDs = bookmarkStore.allBookmarkedItemIDs()

        // Warm start: hydrate from SQLite with filters already active
        let endReservoirLoadMetric = FeedMetrics.beginInterval("Reservoir.load")
        let cached = try? await loadReservoir()
        endReservoirLoadMetric()
        if let items = cached, !items.isEmpty {
            for item in items { loadedIDs.insert(item.id) }
            loadedIDsCount = loadedIDs.count
            // Pre-filter before seeding — same pattern as reloadFromSQLite.
            let filteredItems = applyFilters(items)
            let endReservoirSeedMetric = FeedMetrics.beginInterval("Reservoir.seed")
            await reservoir.seed(items: filteredItems)
            endReservoirSeedMetric()
            FeedMetrics.event("FirstVisibleItems", "count=\(self.reservoir.visibleItems.count)")
            FeedMetrics.memory("afterFirstVisible")
            markSurfaced(reservoir.visibleItems)
            setVisibleItems(reservoir.visibleItems)  // already filtered
            if visibleItems.count < Reservoir.pageSize && reservoir.reservoirCount > 0 {
                repeat {
                    reservoir.moveToVisible(count: Reservoir.pageSize)
                    setVisibleItems(applyFilters(reservoir.visibleItems))
                } while visibleItems.count < Reservoir.pageSize && reservoir.reservoirCount > 0
            }
            reservoirCount = reservoir.reservoirCount
            loadingState = .idle
            prefetchVisibleAndNext()
        }

        // Snapshot baseline for "What's New" — persisted so items don't vanish
        // just because the app restarted. Falls back to now on first launch.
        if let persisted = UserDefaults.standard.object(forKey: Self.lastWhatsNewSeenAtKey) as? Date {
            whatsNewManager.whatsNewBaselineDate = persisted
        } else {
            whatsNewManager.whatsNewBaselineDate = Date()
        }

        guard !registry.enabledSources.isEmpty else {
            loadingState = .idle
            return
        }

        // Unblock the UI immediately — the warm cache already provides content.
        // First batch and progressive fetch run as background Tasks so the view
        // finishes layout without waiting for network I/O.
        loadingState = .idle

        progressiveFetchTask = Task {
            // First batch: fill the visible feed quickly (scheduler picks ~17 sources).
            await fetchNextBatch()
            // Then process remaining enabled sources in the background.
            await progressiveFetch()
        }

        // Kick off What's New pipeline
        refreshWhatsNew()

        // Slow-drip background refresh — keeps the database and What's New
        // fed with fresh content continuously while the app is in foreground.
        startBackgroundRefresh()

        // Light maintenance on every launch
        Task { await performLightExpurgo() }
        Task.detached(priority: .background) { [weak self] in
            await self?.performHeavyMaintenance()
        }
    }

    // MARK: - UI Pipeline
    /// All visibleItems writes route through this single pipeline.
    /// Category‑A triggers (.flush) cancel everything; scroll/fetch/trim
    /// chain behind the current task so only one actor mutates the UI.
    private enum FeedUIUpdate {
        case flush(forceFetch: Bool = false, skipRead: Bool = false, generation: Int64 = 0)
        case append         // Move from reservoir → visible (scroll)
        case refresh(generation: Int64 = 0)  // Sync visible from reservoir (after fetch)
        case trim(Int, generation: Int64 = 0)      // Trim buffer with currentVisibleIndex
        case replace([FeedItem])  // Full replace (search, toggle)
    }
    private var pipelineTask: Task<Void, Never>?

    /// Single writer for `visibleItems`. Every mutation routes through here.
    /// Stamps each item with isRead/isBookmarked so views don't observe the
    /// global sets directly — reading one item won't invalidate all cards.
    /// Increments `visibleItemsGeneration` so FeedLoader caches invalidate reliably.
    private func setVisibleItems(_ items: [FeedItem]) {
        let stamped = items.map { $0.stamped(readItemIDs: readItemIDs, bookmarkItemIDs: bookmarkedItemIDs) }
        guard stamped != visibleItems else { return }
        visibleItems = stamped
        visibleItemsGeneration &+= 1
    }

    /// Single writer for `visibleItems`. Every mutation routes through here.
    /// - `.flush`: cancels all competing work, clears, then reloads from SQLite.
    /// - `.append` / `.refresh` / `.trim`: serialized behind the current pipeline.
    /// - `.replace`: immediate (search results, source toggle — caller owns the data).
    private func applyUpdate(_ update: FeedUIUpdate) {
        // Bookmark mode is a fixed snapshot — no screen mutations allowed
        guard !isBookmarkFeed else { return }
        switch update {
        case .flush(let forceFetch, let skipRead, let generation):
            pipelineTask?.cancel()
            progressiveFetchTask?.cancel()
            trimDebounceTask?.cancel()
            setVisibleItems([])
            reservoirCount = 0
            reservoir.clear()
            Log.feed.info("[TaxonomyTrace] flush gen=\(generation) clearing visible+reservoir, will reloadFromSQLite")
            pipelineTask = Task { [weak self] in
                guard let self else { return }
                await self.reloadFromSQLite(skipRead: skipRead, generation: generation)
                guard !Task.isCancelled else { return }
                // Drop stale pipeline results — only when generation is explicitly tracked
                if generation != 0, generation != self.filterGeneration {
                    Log.feed.info("[TaxonomyTrace] flush gen=\(generation) dropping stale (current=\(self.filterGeneration))")
                    return
                }
                if forceFetch || self.visibleItems.count < 20 { await self.fetchNextBatch() }
                self.loadingState = .idle
                Log.feed.info("[TaxonomyTrace] flush gen=\(generation) complete visibleItems=\(self.visibleItems.count)")
            }

        case .append:
            let prev = pipelineTask
            pipelineTask = Task { [weak self] in
                await prev?.value
                guard !Task.isCancelled, let self else { return }
                self.reservoir.moveToVisible(count: Reservoir.pageSize)
                self.markSurfaced(self.reservoir.visibleItems)
                self.setVisibleItems(self.applyFilters(self.reservoir.visibleItems))
                self.reservoirCount = self.reservoir.reservoirCount
                self.prefetchVisibleAndNext()
            }

        case .refresh(let generation):
            let prev = pipelineTask
            pipelineTask = Task { [weak self] in
                await prev?.value
                guard !Task.isCancelled, let self else { return }
                // Drop stale refresh — a newer filter may have been applied
                if generation != 0, generation != self.filterGeneration {
                    Log.feed.info("[TaxonomyTrace] refresh gen=\(generation) dropping stale (current=\(self.filterGeneration))")
                    return
                }
                // Move any new items from reservoir buffer to visible
                let oldCount = self.reservoir.visibleItems.count
                if self.reservoir.reservoirCount > 0 && oldCount < Reservoir.pageSize {
                    self.reservoir.moveToVisible(count: Reservoir.pageSize)
                }
                self.markSurfaced(self.reservoir.visibleItems)
                self.setVisibleItems(self.applyFilters(self.reservoir.visibleItems))
                self.reservoirCount = self.reservoir.reservoirCount
                Log.feed.info("[TaxonomyTrace] refresh gen=\(generation) visibleItems=\(self.visibleItems.count) (was \(oldCount))")
            }

        case .trim(let idx, let generation):
            let prev = pipelineTask
            pipelineTask = Task { [weak self] in
                await prev?.value
                guard !Task.isCancelled, let self else { return }
                // Drop stale trim — a newer filter may have triggered a more
                // recent pipeline that already seeded fresher data.
                if generation != 0, generation != self.filterGeneration { return }
                self.reservoir.trimBuffer(currentVisibleIndex: idx)
                self.setVisibleItems(self.applyFilters(self.reservoir.visibleItems))
                self.reservoirCount = self.reservoir.reservoirCount
            }

        case .replace(let items):
            pipelineTask?.cancel()
            setVisibleItems(items)
        }
    }

    // MARK: - Scroll
    private var lastLoadedIndex = -1
    private var trimDebounceTask: Task<Void, Never>?

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
        guard !isBookmarkFeed else { return }  // fixed feed, no pagination
        guard let itemIndex = visibleItems.firstIndex(where: { $0.id == currentItem.id }) else { return }
        guard itemIndex >= visibleItems.count - Reservoir.loadMoreThreshold else { return }
        guard itemIndex != lastLoadedIndex else { return }
        lastLoadedIndex = itemIndex

        scheduler.recordConsumption()
        applyUpdate(.append)
        // Defer trimming: cancel previous, schedule new after 1.5s pause.
        trimDebounceTask?.cancel()
        let idx = itemIndex
        trimDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self else { return }
            self.applyUpdate(.trim(idx, generation: self.filterGeneration))
        }

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

    /// Filters expire after 4 hours of inactivity so the user doesn't
    /// open the app to an empty or confusing feed. Cleared on restore if stale.
    private static let filterExpirySeconds: TimeInterval = 14400  // 4 hours

    private func persistFilters() {
        Settings.filterRegion = activeRegion
        Settings.filterTaxonomyNodes = Array(activeNodeIDs)
        Settings.filterContentType = activeContentType.rawValue
        Settings.filterLanguages = Array(activeLanguages)
        Settings.filterMood = activeMood.rawValue
        Settings.filterSetAt = Date().timeIntervalSince1970
    }

    func restoreFilters() {
        let hasActiveFilters = Settings.filterRegion != nil
            || !Settings.filterTaxonomyNodes.isEmpty
            || (FeedLoader.ContentType(rawValue: Settings.filterContentType) ?? .all) != .all
            || !Settings.filterLanguages.isEmpty
            || (FeedLoader.MoodFilter(rawValue: Settings.filterMood) ?? .all) != .all

        if hasActiveFilters && Settings.filterAutoExpire {
            let elapsed = Date().timeIntervalSince1970 - Settings.filterSetAt
            if Settings.filterSetAt > 0 && elapsed > Self.filterExpirySeconds {
                Settings.filterRegion = nil
                Settings.filterTaxonomyNodes = []
                Settings.filterContentType = "All"
                Settings.filterMood = "all"
                Settings.filterLanguages = []
                Settings.filterSetAt = 0
                return
            }
        }

        activeRegion = Settings.filterRegion
        // Migrate persisted taxonomy node IDs: old flat global IDs
        // ("global/acoustics") may no longer exist after the topic-directory
        // reorganization.  Filter to only valid IDs; if every saved ID is
        // stale, clear the selection so the user doesn't see a ghost filter.
        let savedIDs = Settings.filterTaxonomyNodes
        let validIDs = savedIDs.filter { TaxonomyStore.shared.node(id: $0) != nil }
        if validIDs.count != savedIDs.count {
            Settings.filterTaxonomyNodes = validIDs
            if validIDs.isEmpty && !savedIDs.isEmpty {
                // All previously-saved IDs are gone — clear selection entirely.
                activeNodeIDs = []
                TaxonomyStore.shared.clearSelection()
            } else {
                activeNodeIDs = Set(validIDs)
                TaxonomyStore.shared.selectedNodeIDs = activeNodeIDs
            }
        } else {
            activeNodeIDs = Set(savedIDs)
            TaxonomyStore.shared.selectedNodeIDs = activeNodeIDs
        }
        // Rebuild taxonomy URL cache so applyFilters actually enforces the
        // restored taxonomy selection (cache is empty on cold start).
        cachedTaxonomyNodeIDs = activeNodeIDs
        cachedTaxonomyFeedURLs = TaxonomyStore.shared.feedURLs(inSubtreesOf: activeNodeIDs)
        activeLanguages = Self.normalizedLanguageSet(Settings.filterLanguages)
        if let type = FeedLoader.ContentType(rawValue: Settings.filterContentType) {
            activeContentType = type
        }
        if let mood = FeedLoader.MoodFilter(rawValue: Settings.filterMood) {
            activeMood = mood
        }
    }

    func setFilter(region: String?, nodeIDs: Set<String>, type: FeedLoader.ContentType, mood: FeedLoader.MoodFilter = .all, languages: Set<String>? = nil) {
        // Increment generation BEFORE updating state — every async operation
        // captures this and discards results if a newer filter supersedes it.
        filterGeneration &+= 1
        let generation = filterGeneration

        // Update state immediately for UI responsiveness
        activeRegion = region
        activeNodeIDs = nodeIDs
        activeContentType = type
        activeMood = mood
        if let langs = languages {
            activeLanguages = Self.normalizedLanguageSet(langs)
        }

        // Rebuild taxonomy URL cache when selection changes (O(1) filter instead of O(n x m))
        if activeNodeIDs != cachedTaxonomyNodeIDs {
            cachedTaxonomyNodeIDs = activeNodeIDs
            cachedTaxonomyFeedURLs = TaxonomyStore.shared.feedURLs(inSubtreesOf: activeNodeIDs)
        }

        Log.feed.info("[TaxonomyTrace] setFilter gen=\(generation) region=\(region ?? "nil") nodeIDs=\(self.activeNodeIDs) taxonomyURLs=\(self.cachedTaxonomyFeedURLs.count)")

        persistFilters()

        // Cancel progressive fetch — waste of budget when user wants specific content
        progressiveFetchTask?.cancel()
        // Cancel any previous urgent fetch
        urgentFetchTask?.cancel()
        isUrgentFetching = false

        // Debounce the expensive flush+reload: if multiple filter changes
        // arrive within 300ms (e.g. user tapping category then mood quickly),
        // only the last one triggers the full reload pipeline.
        filterDebounceTask?.cancel()
        filterDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }

            // Kick off urgent fetch for taxonomy sources
            let priorityURLs = self.cachedTaxonomyFeedURLs
            if !priorityURLs.isEmpty {
                self.isUrgentFetching = true
                self.urgentFetchTask = Task { [weak self] in
                    guard let self else { return }
                    await self.fetchUrgentTaxonomyBatch(sourceURLs: priorityURLs, generation: generation)
                    self.isUrgentFetching = false
                    // Resume background refresh after urgent work completes
                    self.startBackgroundRefresh()
                }
            }

            self.loadingState = .refreshing
            self.refreshWhatsNew()
            self.applyUpdate(.flush(generation: generation))
        }
    }

    func clearAllFilters() {
        loadingState = .refreshing
        activeRegion = nil
        activeNodeIDs = []
        activeContentType = .all
        activeMood = .all
        activeLanguages = []
        cachedTaxonomyNodeIDs = []
        cachedTaxonomyFeedURLs = []
        persistFilters()
        // Content on screen is untouchable. Clear everything, reload fresh.
        refreshWhatsNew()
        applyUpdate(.flush())
    }

    // MARK: - Search
    func search(_ query: String) {
        isSearching = true
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            searchResults = []
            applyUpdate(.replace([]))
            return
        }
        Task {
            let results = await searchEngine.search(query, region: activeRegion, taxonomyNodeIDs: activeNodeIDs)
            guard isSearching else { return }
            searchResults = results
            applyUpdate(.replace(applyFilters(searchResults)))
        }
    }

    func clearSearch() {
        isSearching = false
        searchResults = []
        applyUpdate(.flush())
    }

    // MARK: - Read & Seen

    /// Mark items as surfaced (appeared on screen in feed or What's New carousel).
    /// Tracked continuously so we know what the user has already seen.
    func markSurfaced(_ items: [FeedItem]) {
        for item in items { surfacedItemIDs.insert(item.id) }
    }

    func markAsRead(_ itemID: String) {
        readItemIDs.insert(itemID)
        reservoir.readItemIDs = readItemIDs
        // Update stamped item in-place so only this card re-renders
        if let idx = visibleItems.firstIndex(where: { $0.id == itemID }) {
            visibleItems[idx].isRead = true
            visibleItemsGeneration &+= 1
        }
        Task {
            try await db.write { db in
                try db.execute(sql: """
                    UPDATE feed_item SET is_read = 1, opened_at = \(Int(Date().timeIntervalSince1970))
                    WHERE id = ?
                """, arguments: [itemID])
            }
        }
    }

    /// Bulk mark-as-read — single UPDATE with WHERE id IN (...) instead of
    /// N individual writes. Same pattern as shakeToRefresh.
    func markAllAsRead(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        for id in ids { readItemIDs.insert(id) }
        reservoir.readItemIDs = readItemIDs
        // Update stamped items in-place
        let idSet = Set(ids)
        for idx in visibleItems.indices where idSet.contains(visibleItems[idx].id) {
            visibleItems[idx].isRead = true
        }
        visibleItemsGeneration &+= 1
        let now = Int(Date().timeIntervalSince1970)
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        Task {
            try await db.write { db in
                try db.execute(sql: """
                    UPDATE feed_item SET is_read = 1, opened_at = \(now)
                    WHERE id IN (\(placeholders))
                """, arguments: StatementArguments(ids))
            }
        }
    }

    func markAsUnread(_ itemID: String) {
        readItemIDs.remove(itemID)
        reservoir.readItemIDs = readItemIDs
        // Update stamped item in-place
        if let idx = visibleItems.firstIndex(where: { $0.id == itemID }) {
            visibleItems[idx].isRead = false
            visibleItemsGeneration &+= 1
        }
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
        bookmarkStore.clearAllBookmarks()
        bookmarkedItemIDs.removeAll()
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
                    collectWhatsNewCandidates(actualNew)
                    // Prepend to visible feed
                    var combined = actualNew
                    combined.append(contentsOf: reservoir.visibleItems)
                    await reservoir.seed(items: combined)
                    applyUpdate(.replace(applyFilters(reservoir.visibleItems)))
                    reservoirCount = reservoir.reservoirCount
                }
            }
        } else {
            // Disabling — remove only this feed's items, not its whole region.
            reservoir.removeSource(sourceURL)
            applyUpdate(.replace(applyFilters(reservoir.visibleItems)))
            reservoirCount = reservoir.reservoirCount
        }
    }

    func isCategoryEnabled(_ category: String) -> Bool {
        registry.status(of: SourceRegistry.categoryKey(category)) != .off
    }

    func toggleCategory(_ category: String) {
        registry.toggleCategory(category)
        // Category toggle is structural — reload feed
        applyUpdate(.flush())
    }

    /// Consecutive failures for a source URL.
    func consecutiveFailures(for sourceURL: String) -> Int {
        scheduler.consecutiveFailures[sourceURL] ?? 0
    }

    // MARK: - What's New

    /// Items fetched since the baseline snapshot, respecting all active filters.
    /// Only items with images, unread, capped at 10, shuffled for variety.
    /// Called every time new items are persisted into the database.
    /// Feeds the What's New candidate pool — items accumulate in the
    /// background until the threshold is reached, then the carousel appears.
    func collectWhatsNewCandidates(_ newItems: [FeedItem]) {
        let visibleIDs = Set(reservoir.visibleItems.map(\.id))
        let readIDs = readItemIDs
        whatsNewManager.collectWhatsNewCandidates(
            newItems,
            visibleIDs: visibleIDs,
            readIDs: readIDs,
            isItemEnabled: { [self] in isItemEnabled($0) },
            filterContentType: filterContentType,
            contentFilterExcludes: { [self] in contentFilterExcludes($0, filters: ContentFilterStore.shared.activeFilters) },
            markSurfaced: { [self] in markSurfaced($0) }
        )
    }

    /// Promote candidates to the visible carousel when the pool is full.
    private func promoteWhatsNewIfReady() {
        whatsNewManager.promoteWhatsNewIfReady(markSurfaced: { [self] in markSurfaced($0) })
    }

    /// Advance the carousel: return shown (unclicked) items to the pool so
    /// they remain available for future selections, then promote next batch.
    func advanceWhatsNew() {
        whatsNewManager.advanceWhatsNew(markSurfaced: { [self] in markSurfaced($0) })
    }

    /// Kick off an aggressive fetch to fill the What's New pool quickly at
    /// cold start. Runs alongside the DB seed — if the database has nothing,
    /// this fetches fresh content from the network immediately.
    func fetchWhatsNewBooster() {
        whatsNewManager.fetchWhatsNewBooster(
            enabledSources: registry.enabledSources,
            fetcher: fetcher,
            persistFetchedItems: { [self] in await persistFetchedItems($0) },
            throttledReservoirAppend: { [self] in throttledReservoirAppend($0) },
            collectCandidates: { [self] in collectWhatsNewCandidates($0) },
            prefetchImages: { [self] in prefetchImagesIfEnabled(for: $0) },
            recordFetch: { [self] in scheduler.recordFetch(sourceURL: $0, success: $1) }
        )
    }

    /// Refresh What's New: clear the pool, re-seed from DB, and trigger
    /// a booster fetch. Called on any user-triggered update (startup, shake,
    /// filter change) so the carousel always reflects the current context.
    func refreshWhatsNew() {
        whatsNewManager.refreshWhatsNew(
            seedFromDB: { [self] in await seedWhatsNewFromDB() },
            booster: { [self] in fetchWhatsNewBooster() }
        )
    }

    /// Seed the pool from existing SQLite content — runs once at startup
    /// so the carousel isn't empty while waiting for the first fetch batch.
    private func seedWhatsNewFromDB() async {
        await whatsNewManager.seedWhatsNewFromDB(
            surfacedIDs: surfacedItemIDs,
            readIDs: readItemIDs,
            isItemEnabled: { [self] in isItemEnabled($0) },
            filterContentType: filterContentType,
            contentFilterExcludes: { [self] in contentFilterExcludes($0, filters: ContentFilterStore.shared.activeFilters) },
            markSurfaced: { [self] in markSurfaced($0) }
        )
    }

    /// Advance the baseline to now and persist it — so items already shown
    /// in the carousel aren't treated as "new" again next session.
    func advanceWhatsNewBaseline() {
        whatsNewManager.advanceWhatsNewBaseline()
    }

    /// Reset the What's New baseline to now so newly enabled content appears.
    /// Items fetched after this point (e.g. seedRegion) will be "new";
    /// weeks-old DB content won't be.
    func resetWhatsNewBaseline() {
        whatsNewManager.resetWhatsNewBaseline()
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
    func persistFetchedItems(_ items: [FeedItem], regionOverride: String? = nil) async -> [FeedItem] {
        var seen = Set<String>()
        let actualNew = items.filter { item in
            guard !loadedIDs.contains(item.id) else { return false }
            return seen.insert(item.id).inserted
        }
        guard !actualNew.isEmpty else { return [] }

        // Collect regions + explicit source languages on the main actor
        // (dictionary lookups are O(1) and cheap). Language detection via
        // NLLanguageRecognizer runs in a detached task to avoid blocking UI.
        let regions: [String] = actualNew.map { regionOverride ?? registry.regionFor(sourceURL: $0.sourceURL) }
        let detectionInputs: [LanguageDetectionInput] = actualNew.map { item in
            let itemLang = Self.normalizedLanguageCode(item.language)
            let sourceLang = Self.normalizedLanguageCode(registry.languageFor(sourceURL: item.sourceURL))
            return LanguageDetectionInput(
                title: item.title,
                excerpt: item.excerpt,
                explicitLanguage: itemLang ?? sourceLang
            )
        }
        let resolvedLanguages: [String?] = await Task.detached(priority: .utility) {
            Self.detectLanguages(detectionInputs)
        }.value

        // Safety: all three arrays must have identical counts before we merge.
        guard actualNew.count == regions.count,
              actualNew.count == resolvedLanguages.count else {
            Log.db.error("persistFetchedItems: count mismatch — items=\(actualNew.count) regions=\(regions.count) languages=\(resolvedLanguages.count)")
            return []
        }

        // Pre-compute section day offsets once so dateSections doesn't run
        // expensive Calendar operations on every scroll-driven cache miss.
        let now = Date()
        let todayStart = Calendar.current.startOfDay(for: now)
        let sectionOffsets: [Int] = actualNew.map { item in
            let itemStart = Calendar.current.startOfDay(for: item.publishedAt)
            let diff = todayStart.timeIntervalSince(itemStart)
            return Int(diff / 86400)  // days
        }

        // Enrich each item with the resolved region, language, normalized
        // sourceURL, and pre-computed section offset so the in-memory
        // representation matches exactly what is written to SQLite.
        let enriched: [FeedItem] = (0..<actualNew.count).map { i in
            actualNew[i]
                .replacingMetadata(region: regions[i], language: resolvedLanguages[i])
                .withNormalizedSourceURL
                .withSectionDayOffset(sectionOffsets[i])
        }
        do {
            // Single batch write. Items are deduplicated in memory before this
            // point (loadedIDs check + batch-internal dedup), so the only
            // possible conflict is a PRIMARY KEY collision from a concurrent
            // write — do/catch handles that without the 3x per-item SQL
            // overhead of SAVEPOINT/RELEASE/ROLLBACK.
            let succeeded: [FeedItem] = try await db.write { db -> [FeedItem] in
                var ok: [FeedItem] = []
                for item in enriched {
                    do {
                        let record = FeedItemRecord(from: item, region: item.region, language: item.language)
                        try record.insert(db)
                        ok.append(item)
                    } catch {
                        // Skip individual row failures. Items are deduplicated in
                        // memory (loadedIDs + batch-internal), so the only expected
                        // failure is a PRIMARY KEY collision from a concurrent write.
                        // One bad row does not roll back the batch.
                        Log.db.warning("persistFetchedItems: skip \(item.id): \(error)")
                    }
                }
                return ok
            }
            for item in succeeded { loadedIDs.insert(item.id) }
            loadedIDsCount = loadedIDs.count

            // Record content filter hits on first ingestion (idempotent)
            if ContentFilterStore.shared.isEnabled {
                let filters = ContentFilterStore.shared.activeFilters
                for item in succeeded {
                    _ = contentFilterExcludesAndRecord(item, filters: filters)
                }
            }

            return succeeded
        } catch {
            Log.db.error("persist error: \(error.localizedDescription)")
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
            activeCategory: nil,
            activeContentType: contentTypeStr,
            prioritySourceURLs: activeNodeIDs.isEmpty ? [] : cachedTaxonomyFeedURLs,
            activeLanguages: activeLanguages
        )
        guard !batch.isEmpty else { return }

        loadingState = .refreshing
        defer { loadingState = .idle }

        let result = await fetcher.fetchAll(batch, maxConcurrent: 15)
        // Yield to let pending UI work through after network I/O returns
        await Task.yield()

        totalFetched += result.items.count
        if result.failedSourceCount == 0 { fetchErrorCount = 0 }
        else { fetchErrorCount += result.failedSourceCount }
        lastFetchSucceeded = result.failedSourceCount == 0
        emptyFeedCount += result.emptySourceCount

        // Record per-source health in batch — count items once, look up O(1)
        let sourceItemCounts = Dictionary(grouping: result.items, by: \.sourceURL)
            .mapValues(\.count)
        var healthEntries: [(url: String, itemCount: Int?)] = []
        for source in batch {
            let failed = result.sourceStatuses[source.url] == .failed
            scheduler.recordFetch(sourceURL: source.url, success: !failed)
            let count = sourceItemCounts[source.url]
            healthEntries.append((source.url, count))
        }
        saveSourceHealthBatch(healthEntries)

        let actualNew = await persistFetchedItems(result.items)
        guard !actualNew.isEmpty else { return }

        // Yield again after heavy DB work before processing results
        await Task.yield()

        // Feed the What's New reactive pipeline
        collectWhatsNewCandidates(actualNew)

        // Diagnostic (opt-in via debug bar): surface non-English items so a
        // mis-languaged feed can be identified. See loop-focus-areas #5.
        if Settings.showDebugBar {
            logNonEnglishItems(actualNew)
        }

        // Cap items per source after bulk insert
        if !actualNew.isEmpty {
            let sourceURLs = Array(Set(actualNew.map(\.sourceURL)))
            await capSourceItemsBatch(sourceURLs)
        }

        // Append to reservoir via throttled path — interleave runs off MainActor
        throttledReservoirAppend(actualNew)
        prefetchImagesIfEnabled(for: actualNew)

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
            Log.feed.debug("[LangCheck] \(lang.rawValue) source=\"\(item.sourceTitle)\" region=\(region) url=\(item.url)")
        }
    }

    /// Urgent fetch for the current taxonomy selection. Runs immediately when
    /// the user changes filters so the taxonomy-curated feed populates quickly
    /// instead of waiting for the next progressive or background refresh cycle.
    private func fetchUrgentTaxonomyBatch(sourceURLs: Set<String>, generation: Int64) async {
        // Drop if a newer filter was applied while this task was queued
        guard generation == self.filterGeneration else {
            Log.feed.info("[TaxonomyTrace] urgentFetch gen=\(generation) dropping stale before start (current=\(self.filterGeneration))")
            return
        }

        // Resolve taxonomy URLs against ALL registered sources, not just
        // enabledSources. An explicit taxonomy selection acts as a temporary
        // catalogue query — category/region disables are bypassed, but
        // individual per-source opt-outs are respected.
        let allMatching = self.registry.sources.filter { sourceURLs.contains(OPMLParser.normalizeURL($0.url)) }
        let individuallyDisabled = allMatching.filter { self.registry.isSourceExplicitlyDisabled($0.url) }
        let eligible = allMatching.filter { !self.registry.isSourceExplicitlyDisabled($0.url) }

        // [TaxonomyTrace] — detailed diagnostic for the 4 Acoustics feeds
        Log.feed.info("""
            [TaxonomyTrace] urgentFetch gen=\(generation): \
            taxonomyURLs=\(sourceURLs.count) \
            allMatching=\(allMatching.count) \
            normallyEnabled=\(eligible.filter { self.registry.isSourceEnabled($0.url) }.count) \
            eligible=\(eligible.count) \
            individuallyDisabled=\(individuallyDisabled.count)
            """)
        for src in allMatching {
            Log.feed.info("[TaxonomyTrace] source: title=\"\(src.title)\" url=\(src.url) enabled=\(self.registry.isSourceEnabled(src.url)) explicitOff=\(self.registry.isSourceExplicitlyDisabled(src.url))")
        }

        // Always define both progress values together, before any early return,
        // so stale totals from a previous fetch can never leak into the UI.
        emptyStateFetchTotal = eligible.count
        emptyStateFetchedCount = 0
        guard !eligible.isEmpty else {
            Log.feed.warning("[TaxonomyTrace] urgentFetch gen=\(generation): \(sourceURLs.count) taxonomy URLs matched 0 eligible sources (allMatching=\(allMatching.count), individuallyDisabled=\(individuallyDisabled.count))")
            return
        }

        // Check again before expensive network work
        guard generation == self.filterGeneration else {
            Log.feed.info("[TaxonomyTrace] urgentFetch gen=\(generation) dropping stale before fetch (current=\(self.filterGeneration))")
            return
        }

        let result = await fetcher.fetchAll(eligible, maxConcurrent: 15)
        emptyStateFetchedCount = result.sourceStatuses.count

        // Log per-source fetch results
        for (url, status) in result.sourceStatuses {
            let itemCount = result.items.filter { OPMLParser.normalizeURL($0.sourceURL) == OPMLParser.normalizeURL(url) }.count
            Log.feed.info("[TaxonomyTrace] fetchResult url=\(url) status=\(String(describing: status)) items=\(itemCount)")
        }

        // Final generation check before mutating state
        guard generation == self.filterGeneration else {
            Log.feed.info("[TaxonomyTrace] urgentFetch gen=\(generation) dropping stale after fetch (current=\(self.filterGeneration))")
            return
        }

        let actualNew = await persistFetchedItems(result.items)
        let filteredCount = self.applyFilters(actualNew).count
        Log.feed.info("[TaxonomyTrace] urgentFetch gen=\(generation): fetched=\(result.items.count) persisted=\(actualNew.count) afterFilters=\(filteredCount)")

        // Bypass throttling: the user is waiting for taxonomy-filtered items.
        // Flush synchronously so items are committed to the reservoir BEFORE
        // the .refresh pipeline runs — the refresh must see the new items.
        pendingReservoirItems.append(contentsOf: actualNew)
        reservoirFlushTask?.cancel()
        await flushPendingReservoir()

        // Now that the flush is complete, refresh to move items into visible.
        // The refresh is serialized behind the pipeline task, and the flush
        // is already done, so items are guaranteed to be in the reservoir.
        if !actualNew.isEmpty {
            applyUpdate(.refresh(generation: generation))
        }

        collectWhatsNewCandidates(actualNew)
        prefetchImagesIfEnabled(for: actualNew)
        Log.feed.info("[TaxonomyTrace] urgentFetch gen=\(generation) DONE visibleItems=\(self.visibleItems.count)")
    }

    /// Fetch a budgeted batch of remaining enabled sources in the background.
    /// Capped per session to avoid hammering 800+ sources at every launch;
    /// the rest trickle in via normal refresh cycles. Shuffled for fair
    /// distribution across text/video/audio types.
    private func progressiveFetch() async {
        let allEnabled = registry.enabledSources.shuffled()
        let budget = min(allEnabled.count, 200)  // per-session cap
        let chunkSize = 20
        Log.feed.info("progressiveFetch starting: \(budget)/\(allEnabled.count) sources")
        for chunkStart in stride(from: 0, to: budget, by: chunkSize) {
            let end = min(chunkStart + chunkSize, budget)
            let chunk = Array(allEnabled[chunkStart..<end])
            // Gentle 1s inter-chunk delay (skip first) to avoid rate-limiting
            // from YouTube and other aggressive CDNs when processing 800+ sources.
            if chunkStart > 0 { try? await Task.sleep(for: .seconds(1)) }
            let result = await fetcher.fetchAll(chunk, maxConcurrent: 5)
            guard !Task.isCancelled else { break }
            await Task.yield()  // Let UI work run between chunks
            totalFetched += result.items.count
            fetchErrorCount += result.failedSourceCount
            emptyFeedCount += result.emptySourceCount
            // Batch-save source health with real item counts
            let sourceItemCounts = Dictionary(grouping: result.items, by: \.sourceURL)
                .mapValues(\.count)
            var healthEntries: [(url: String, itemCount: Int?)] = []
            for source in chunk {
                let failed = result.sourceStatuses[source.url] == .failed
                scheduler.recordFetch(sourceURL: source.url, success: !failed)
                let count = sourceItemCounts[source.url]
                healthEntries.append((source.url, count))
            }
            saveSourceHealthBatch(healthEntries)
            let actualNew = await persistFetchedItems(result.items)
            throttledReservoirAppend(actualNew)
            collectWhatsNewCandidates(actualNew)
            // Cap items per source so no single feed dominates (>50 items)
            if !actualNew.isEmpty {
                let sourceURLs = Array(Set(actualNew.map(\.sourceURL)))
                await capSourceItemsBatch(sourceURLs)
            }
            prefetchImagesIfEnabled(for: actualNew)
            await matchPersistentSearches(actualNew)
            if visibleItems.isEmpty {
                await flushPendingReservoir()
            }
        }
        Log.feed.info("progressiveFetch DONE — all \(allEnabled.count) sources processed")
        lastRefreshDate = .now
        await capAllSources()
    }

    /// Slow-drip background refresh — fetches a small batch of sources every
    /// few minutes to keep the database and What's New fed with fresh content.
    /// Complements progressiveFetch (bulk initial fill) with continuous renewal.
    private func startBackgroundRefresh() {
        backgroundRefreshTask?.cancel()
        backgroundRefreshTask = Task { [weak self] in
            guard let self else { return }
            let interval: TimeInterval = 150  // 2.5 minutes
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                guard self.loadingState == .idle, !self.isSearching else { continue }
                let batchSize = 5
                let allSources = self.registry.enabledSources.shuffled()
                let batch = Array(allSources.prefix(batchSize))
                guard !batch.isEmpty else { continue }
                let result = await self.fetcher.fetchAll(batch, maxConcurrent: 2)
                let actualNew = await self.persistFetchedItems(result.items)
                if !actualNew.isEmpty {
                    self.throttledReservoirAppend(actualNew)
                    self.collectWhatsNewCandidates(actualNew)
                    self.prefetchImagesIfEnabled(for: actualNew)
                    // Cap per source to prevent domination
                    await self.capSourceItemsBatch(Array(Set(actualNew.map(\.sourceURL))))
                }
                // Record fetch health for each source
                for source in batch {
                    let success = result.sourceStatuses[source.url] != .failed
                    self.scheduler.recordFetch(sourceURL: source.url, success: success)
                }
                self.lastRefreshDate = .now
            }
        }
    }

    func stopBackgroundRefresh() {
        backgroundRefreshTask?.cancel()
        backgroundRefreshTask = nil
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
            Log.db.info("capAllSources: capping \(offenders.count) sources (>50 items)")
            await capSourceItemsBatch(offenders)
        } catch {
            Log.db.error("capAllSources error: \(error.localizedDescription)")
        }
    }

    private func reloadFromSQLite(prepend: [FeedItem] = [], skipRead: Bool = false, generation: Int64 = 0) async {
        guard !isSearching else { return }
        let region = activeRegion
        let contentType = activeContentType
        let languages = activeLanguages
        // Capture taxonomy feed URLs before entering the read closure (which may
        // run off the main actor). When taxonomy is active we load matching
        // items via batched IN clause with per-chunk and global caps.
        let taxonomyURLs: Set<String>? = activeNodeIDs.isEmpty ? nil : cachedTaxonomyFeedURLs
        let deviceLanguage = Self.normalizedLanguageCode(Locale.current.language.languageCode?.identifier)
        // Always exclude read items — the feed should only show unseen content.
        // Read/opened items are tracked continuously and this information is
        // consumed by all feed-population paths (shake, filter, startup).
        let items: [FeedItemRecord] = (try? await db.read { db in
            var request = FeedItemRecord
                .filter(Column("fetched_at") > Self.thirtyDayCutoffEpoch)
                .filter(Column("is_read") == 0)
            if let r = region {
                // Exact match or descendant prefix (e.g. "countries/brazil/sao-paulo")
                // matches both the region itself and its sub-regions, matching the
                // in-memory filter behavior in applyFilters.
                request = request.filter(
                    sql: "region = ? OR region LIKE ?",
                    arguments: [r, "\(r)/%"]
                )
            }
            // Filter by content type at SQL level to avoid loading 200 items
            // only to discard 95% in-memory (e.g. "Podcasts" filter with few
            // podcast items in the DB).
            switch contentType {
            case .audio: request = request.filter(Column("audio_url") != nil)
            case .video: request = request.filter(Column("source_url").like("%youtube%"))
            case .text:  request = request.filter(Column("audio_url") == nil)
                            .filter(!Column("source_url").like("%youtube%"))
                            .filter(!Column("source_url").like("%reddit%"))
            case .forum: request = request.filter(Column("source_url").like("%reddit%"))
            case .all: break
            }

            // Language filter — shared rule with applyFilters via LanguageFilterMatches.
            // nil-language items pass provisionally only when the device language
            // is among the selected set (matching the in-memory filter behavior).
            if !languages.isEmpty {
                let langArray = Array(languages)
                let nilPasses = deviceLanguage.map { languages.contains($0) } ?? false
                let nilClause = nilPasses ? " OR language IS NULL" : ""
                if langArray.count <= 999 {
                    let langPlaceholders = langArray.map { _ in "?" }.joined(separator: ",")
                    request = request.filter(
                        sql: "(language IN (\(langPlaceholders))\(nilClause))",
                        arguments: StatementArguments(langArray)
                    )
                } else {
                    // Fallback: batch in chunks of 999 (unlikely with real language counts)
                    let batchSize = 999
                    var orParts: [String] = []
                    var allArgs: [String] = []
                    for chunkStart in stride(from: 0, to: langArray.count, by: batchSize) {
                        let chunk = Array(langArray[chunkStart..<min(chunkStart + batchSize, langArray.count)])
                        orParts.append("language IN (\(chunk.map { _ in "?" }.joined(separator: ",")))")
                        allArgs.append(contentsOf: chunk)
                    }
                    request = request.filter(
                        sql: "((\(orParts.joined(separator: " OR ")))\(nilClause))",
                        arguments: StatementArguments(allArgs)
                    )
                }
            }

            // Taxonomy filter — batched IN clause to stay within SQLite's
            // 999-parameter limit. When taxonomy is active, load matching items
            // items so the user sees the full curated feed rather than just
            // the 200 most recent items (which may not overlap at all with
            // the selected taxonomy nodes).
            if let urls = taxonomyURLs, !urls.isEmpty {
                let urlArray = Array(urls)
                let batchSize = 999
                let perChunkLimit = 400
                var allItems: [FeedItemRecord] = []
                for chunkStart in stride(from: 0, to: urlArray.count, by: batchSize) {
                    let chunk = Array(urlArray[chunkStart..<min(chunkStart + batchSize, urlArray.count)])
                    // Generate ALL URL variants that could appear in SQLite:
                    // - normalized URL (no trailing slash, no www, https)
                    // - normalized + trailing slash
                    // - www. variant (items stored with original OPML URL
                    //   may have www. that normalizeURL stripped)
                    // - www. variant + trailing slash
                    // - http:// variants for legacy rows stored before
                    //   normalizeURL began forcing https (v1-v5 era)
                    let chunkBoth = chunk.flatMap { url -> [String] in
                        var variants = [url, "\(url)/"]
                        // http:// variants — legacy rows may use http scheme
                        if let comps = URLComponents(string: url),
                           comps.scheme == "https" {
                            var httpComps = comps
                            httpComps.scheme = "http"
                            if let httpURL = httpComps.string {
                                variants.append(httpURL)
                                variants.append("\(httpURL)/")
                            }
                        }
                        // Add www.-prefixed variants if the normalized URL lacks www.
                        if let comps = URLComponents(string: url),
                           let host = comps.host, !host.hasPrefix("www.") {
                            var wwwComps = comps
                            wwwComps.host = "www.\(host)"
                            if let wwwURL = wwwComps.string {
                                variants.append(wwwURL)
                                variants.append("\(wwwURL)/")
                                // Also add http://www... for legacy rows
                                wwwComps.scheme = "http"
                                if let httpWWWURL = wwwComps.string {
                                    variants.append(httpWWWURL)
                                    variants.append("\(httpWWWURL)/")
                                }
                            }
                        }
                        return variants
                    }
                    let placeholders = chunkBoth.map { _ in "?" }.joined(separator: ",")
                    let chunkRequest = request.filter(
                        sql: "source_url IN (\(placeholders))",
                        arguments: StatementArguments(chunkBoth)
                    )
                    let batchItems = try chunkRequest
                        .order(Column("published_at").desc)
                        .limit(perChunkLimit)
                        .fetchAll(db)
                    allItems.append(contentsOf: batchItems)
                }
                // Sort merged batches by published_at desc so the most recent
                // items appear first regardless of which batch they came from.
                allItems.sort { $0.publishedAt > $1.publishedAt }
                // Global cap prevents memory runaway from very broad taxonomy nodes.
                let topN = min(allItems.count, 600)
                return Array(allItems.prefix(topN))
            }

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
        // Drop stale reload BEFORE mutating loadedIDs — a newer filter may have
        // triggered a more recent pipeline that already seeded fresher data.
        // Only check when generation is explicitly tracked (non-zero).
        if generation != 0, generation != self.filterGeneration {
            Log.feed.info("[TaxonomyTrace] reloadFromSQLite gen=\(generation) dropping stale seed (current=\(self.filterGeneration))")
            return
        }
        // Register all loaded IDs to prevent re-fetch duplicates.
        // Must happen AFTER the stale-generation guard so IDs are only
        // registered when the items are actually used.
        for item in feedItems { loadedIDs.insert(item.id) }
        loadedIDsCount = loadedIDs.count
        // Pre-filter before seeding so the reservoir never holds items that
        // would be filtered out. This prevents the reservoir from becoming a
        // trove of disabled-source items that leak through on .append/.trim
        // (even after Task 1-2 fixes, this avoids wasted memory and ensures
        // consistent reservoirCount).

        let filteredItems = applyFilters(feedItems)
        Log.feed.info("[TaxonomyTrace] reloadFromSQLite gen=\(generation) loaded=\(feedItems.count) filtered=\(filteredItems.count) taxonomyURLs=\(taxonomyURLs?.count ?? 0)")
        await reservoir.seed(items: filteredItems)
        // markSurfaced runs on reservoir.visibleItems AFTER seed, so only
        // items that actually appear on screen are recorded as surfaced.
        markSurfaced(reservoir.visibleItems)
        setVisibleItems(reservoir.visibleItems)  // already filtered — no double-filter needed)
        // If the active filter (e.g. Podcasts) removed all seeded items,
        // pull more from the reservoir so the screen isn't empty.
        // (This loop is now a safety net — the reservoir is pre-filtered,
        // but edge cases like very restrictive mood filters may still
        // produce an empty first page.)
        if visibleItems.count < Reservoir.pageSize && reservoir.reservoirCount > 0 {
            repeat {
                reservoir.moveToVisible(count: Reservoir.pageSize)
                setVisibleItems(applyFilters(reservoir.visibleItems))
            } while visibleItems.count < Reservoir.pageSize && reservoir.reservoirCount > 0
        }
        reservoirCount = reservoir.reservoirCount
        Log.feed.info("[TaxonomyTrace] reloadFromSQLite gen=\(generation) done visibleItems=\(self.visibleItems.count) reservoirCount=\(self.reservoirCount)")
    }

    private func loadReservoir() async throws -> [FeedItem]? {
        // Fetch a larger pool, then select with diversity: news items favor
        // recency; everything else is randomized. This prevents a single
        // prolific source from dominating the first 200 slots.
        let poolSize = 400
        let records: [FeedItemRecord] = try await db.read { db in
            try FeedItemRecord
                .filter(Column("fetched_at") > Self.thirtyDayCutoffEpoch)
                .filter(Column("is_read") == 0)
                .order(Column("published_at").desc)
                .limit(poolSize)
                .fetchAll(db)
        }
        guard !records.isEmpty else { return nil }
        let items = records.map { $0.toFeedItem() }

        // Split: news items (time-sensitive) keep recency order; everything
        // else gets shuffled for diversity. Then merge: all news first (most
        // recent at top), then random non-news, capped at 200.
        // Match category by keyword (case-insensitive). After taxonomy changes
        // category stores the original OPML outline text (e.g. "News", "Sports").
        let newsKeywords = ["news", "sports", "politics"]
        var news = items.filter { item in
            let lower = item.category.lowercased()
            return newsKeywords.contains(where: { lower.contains($0) })
        }
        var other = items.filter { item in
            let lower = item.category.lowercased()
            return !newsKeywords.contains(where: { lower.contains($0) })
        }.shuffled()
        // News already ordered by published_at DESC from the query
        var selected = news + other
        if selected.count > 200 { selected = Array(selected.prefix(200)) }
        return selected
    }

    private static let maxReadIDs = 5000

    private func loadReadState() async {
        do {
            let limit = Self.maxReadIDs
            let ids: [String] = try await db.read { db in
                try String.fetchAll(db, sql: """
                    SELECT id FROM feed_item WHERE is_read = 1
                    ORDER BY opened_at DESC LIMIT \(limit)
                """)
            }
            readItemIDs = Set(ids)

            // Purge old read rows beyond the cap
            try await db.write { db in
                try db.execute(sql: """
                    UPDATE feed_item SET is_read = 0, opened_at = NULL
                    WHERE is_read = 1 AND id NOT IN (
                        SELECT id FROM feed_item WHERE is_read = 1
                        ORDER BY opened_at DESC LIMIT \(limit)
                    )
                """)
            }
        } catch {
            Log.db.error("loadReadState error: \(error.localizedDescription)")
        }
    }

    // MARK: - Region toggle

    func toggleRegion(_ region: String) {
        let wasDisabled = registry.status(of: SourceRegistry.regionKey(region)) == .off
        // Match exact region + sub-regions (e.g. "countries/brazil/sao-paulo")
        let sourceURLs = registry.sources.filter {
            $0.region == region || $0.region.hasPrefix(region + "/")
        }.map(\.url)
        registry.toggleRegion(region)
        if wasDisabled {
            // Enabling: seed fresh content then reload.
            // Keep current content on screen (optimistic) — don't clear until
            // new content is ready, preventing empty-screen flashes.
            regionToggleTask?.cancel()
            scheduler.prioritize(sourceURLs: sourceURLs)
            resetWhatsNewBaseline()
            regionToggleTask = Task { [weak self] in
                guard let self else { return }
                let seedItems = await self.seedRegion(region)
                guard !Task.isCancelled else { return }
                if !seedItems.isEmpty {
                    let name: String
                    if region == "global" {
                        name = "Global feeds"
                    } else if region.hasPrefix("topic/") {
                        // Derive a human-readable name from the topic path
                        let topicPath = String(region.dropFirst(6))  // strip "topic/"
                        name = topicPath
                            .replacingOccurrences(of: "_", with: " ")
                            .capitalized
                    } else {
                        name = CountryStore.countryName(for: region.replacingOccurrences(of: "countries/", with: ""))
                    }
                    // Inform user about filter mismatch
                    let visibleCount = self.applyFilters(seedItems).count
                    if visibleCount == 0 && !seedItems.isEmpty {
                        self.lastToggleMessage = "\(name): \(seedItems.count) articles (0 match current filter)"
                    } else {
                        self.lastToggleMessage = "\(name): \(seedItems.count) new articles"
                    }
                }
                guard !Task.isCancelled else { return }
                await self.reloadFromSQLite(prepend: seedItems)
            }
        } else {
            // Disabling: remove from scheduler (incl. sub-regions), purge from reservoir
            regionToggleTask?.cancel()
            scheduler.remove(sourceURLs: sourceURLs)
            reservoir.removeRegion(region)
            applyUpdate(.replace(applyFilters(reservoir.visibleItems)))
            reservoirCount = reservoir.reservoirCount
        }
    }

    func toggleAllCountries() {
        let wasAnyOn = registry.isAnyCountryEnabled
        registry.toggleAllCountries()
        if wasAnyOn {
            // Disabling all countries — purge their items from the reservoir
            // and all visible items. Unlike individual toggleRegion, this
            // affects every country at once, so a full flush is appropriate.
            let countryRegions = registry.sources
                .filter { $0.isCountryFeed }
                .map { $0.region }
            for region in Set(countryRegions) {
                reservoir.removeRegion(region)
            }
            applyUpdate(.replace(applyFilters(reservoir.visibleItems)))
        } else {
            // Enabling all countries — flush and reload from SQLite so
            // country content appears immediately.
            resetWhatsNewBaseline()
            refreshWhatsNew()
            applyUpdate(.flush())
        }
        reservoirCount = reservoir.reservoirCount
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
        await bookmarkStore.matchPersistentSearches(items, regionResolver: { [self] in registry.regionFor(sourceURL: $0) })
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
            Log.db.warning("Expurgo error: \(error.localizedDescription)")
        }
    }

    /// Per-source cap: keep max 50 items per source within 30-day window.
    /// Cap a single source at 50 items. Prefer `capSourceItemsBatch` for multiple sources.
    func capSourceItems(sourceURL: String) async {
        await capSourceItemsBatch([sourceURL])
    }

    /// Batch cap: enforce 50-item-per-source limit for multiple sources in a
    /// single transaction. Replaces the previous 3×N round-trip approach with
    /// one read + one write, dramatically reducing SQLite churn on startup.
    func capSourceItemsBatch(_ sourceURLs: [String]) async {
        guard !sourceURLs.isEmpty else { return }
        do {
            let removedIDs: [String] = try await db.write { db in
                // Find all sources that exceed the cap and collect IDs to delete
                let placeholders = sourceURLs.map { _ in "?" }.joined(separator: ",")
                let args = StatementArguments(sourceURLs)

                // Identify items to delete: for each overflowing source, keep
                // the 50 newest by published_at, delete the rest (excluding
                // bookmarks and read items).
                let idsToDelete = try String.fetchAll(db, sql: """
                    DELETE FROM feed_item WHERE id IN (
                        SELECT fi.id FROM feed_item fi
                        LEFT JOIN bookmark_item bi ON bi.item_id = fi.id
                        WHERE fi.source_url IN (\(placeholders))
                          AND bi.item_id IS NULL
                          AND fi.is_read = 0
                          AND fi.id NOT IN (
                              SELECT id FROM feed_item fi2
                              WHERE fi2.source_url = fi.source_url
                              ORDER BY fi2.published_at DESC
                              LIMIT 50
                          )
                    ) RETURNING id
                """, arguments: args)
                return idsToDelete
            }
            // Sync loadedIDs
            if !removedIDs.isEmpty {
                for id in removedIDs { loadedIDs.remove(id) }
                loadedIDsCount = loadedIDs.count
            }
        } catch {
            Log.db.error("capSourceItemsBatch error: \(error.localizedDescription)")
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
            Log.db.info("Heavy maintenance complete")
        } catch {
            Log.db.error("Maintenance error: \(error.localizedDescription)")
        }
    }

    // MARK: - Bookmark CRUD

    func allBookmarkLists() async throws -> [BookmarkList] {
        try await bookmarkStore.allBookmarkLists()
    }

    func createBookmarkList(name: String, searchQuery: String? = nil,
                            region: String? = nil, category: String? = nil) async throws -> Int64 {
        try await bookmarkStore.createBookmarkList(name: name, searchQuery: searchQuery, region: region, category: category)
    }

    func toggleBookmark(itemID: String, listID: Int64? = nil) async throws {
        let wasBookmarked = try await bookmarkStore.isBookmarked(itemID: itemID, listID: listID)
        try await bookmarkStore.toggleBookmark(itemID: itemID, listID: listID)
        // Keep the in-memory set in sync so setVisibleItems stamps correctly.
        // Also re-stamp visible items in-place so the bookmark indicator
        // updates immediately without a full pipeline cycle.
        if wasBookmarked {
            bookmarkedItemIDs.remove(itemID)
        } else {
            bookmarkedItemIDs.insert(itemID)
        }
        if let idx = visibleItems.firstIndex(where: { $0.id == itemID }) {
            visibleItems[idx].isBookmarked = !wasBookmarked
            visibleItemsGeneration &+= 1
        }
    }

    func isBookmarked(itemID: String, listID: Int64? = nil) async throws -> Bool {
        try await bookmarkStore.isBookmarked(itemID: itemID, listID: listID)
    }

    func bookmarkedItems(listID: Int64? = nil) async throws -> [FeedItem] {
        try await bookmarkStore.bookmarkedItems(listID: listID)
    }

    func renameBookmarkList(_ id: Int64, name: String) async throws {
        try await bookmarkStore.renameBookmarkList(id, name: name)
    }

    func reorderBookmarkList(_ id: Int64, sortOrder: Int) async throws {
        try await bookmarkStore.reorderBookmarkList(id, sortOrder: sortOrder)
    }

    func deleteBookmarkList(_ id: Int64) async throws {
        try await bookmarkStore.deleteBookmarkList(id)
    }

    /// Toggle search_active on a persistent search bookmark list.
    /// When activated, retroactively adds matching existing items to the list.
    func toggleSearchActive(listID: Int64) async throws {
        try await bookmarkStore.toggleSearchActive(listID: listID)
    }

    // MARK: - Persistent Search (Active)

    func activeSearches() async throws -> [ActiveSearch] {
        try await bookmarkStore.activeSearches()
    }

    /// Build composite feed from multiple active searches with tiered scoring.
    func compositeSearchFeed() async throws -> [FeedItem] {
        try await bookmarkStore.compositeSearchFeed(regionResolver: { [self] in registry.regionFor(sourceURL: $0) })
    }

    // MARK: - Private helpers

    private func defaultListID() -> Int64 {
        bookmarkStore.defaultListID()
    }

    // MARK: - Emergency

    func emergencyTrim() {
        reservoir.emergencyTrim()
        setVisibleItems(applyFilters(reservoir.visibleItems))
        reservoirCount = reservoir.reservoirCount
    }

    /// Shake-to-refresh: mark visible as read, re-interleave reservoir,
    /// reload from SQLite, force fetch fresh content.
    func shakeToRefresh() {
        // Persist visible items as read so they don't reappear after reload.
        let ids = reservoir.visibleItems.map(\.id)
        for id in ids { readItemIDs.insert(id) }
        reservoir.readItemIDs = readItemIDs
        let now = Int(Date().timeIntervalSince1970)
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        Task {
            try await db.write { db in
                try db.execute(sql: """
                    UPDATE feed_item SET is_read = 1, opened_at = \(now)
                    WHERE id IN (\(placeholders))
                """, arguments: StatementArguments(ids))
            }
        }
        // Clear everything, then force-fetch NEW content. The SQLite reload
        // will skip read items so only unseen content appears.
        resetWhatsNewBaseline()
        lastRefreshDate = nil
        refreshWhatsNew()
        applyUpdate(.flush(forceFetch: true, skipRead: true))
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
        // v6: Convert any TEXT dates in bookmark columns to INTEGER epoch seconds,
        // matching the v2 migration for feed_item columns. Older builds (commit
        // 8cc2551 era) could write TEXT values via GRDB's default Date encoding.
        migrator.registerMigration("v6_bookmark_epoch_dates") { db in
            try db.execute(sql: """
                UPDATE bookmark_list
                SET created_at = CAST(strftime('%s', created_at) AS INTEGER)
                WHERE typeof(created_at) = 'text'
            """)
            try db.execute(sql: """
                UPDATE bookmark_item
                SET added_at = CAST(strftime('%s', added_at) AS INTEGER)
                WHERE typeof(added_at) = 'text'
            """)
        }
        migrator.registerMigration("v7_language") { db in
            try db.alter(table: "feed_item") { t in
                t.add(column: "language", .text)
            }
            try db.create(index: "idx_item_language", on: "feed_item", columns: ["language"])
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
    var language: String?

    static var databaseTableName: String { "feed_item" }

    // GRDB Associations
    static let bookmarkItems = hasMany(BookmarkItemRecord.self, using: ForeignKey(["item_id"], to: ["id"]))

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
        case language
    }

    init(from item: FeedItem, region: String, language: String? = nil) {
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
        self.language = language
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
            region: region,
            language: language
        )
    }
}

// MARK: - Bookmark Models

struct BookmarkListRecord: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var name: String
    var sortOrder: Int
    var createdAt: Int  // epoch seconds (matches SQL storage)
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
    var addedAt: Int  // epoch seconds
    var sortOrder: Int

    static var databaseTableName: String { "bookmark_item" }

    enum CodingKeys: String, CodingKey {
        case listId = "list_id"
        case itemId = "item_id"
        case addedAt = "added_at"
        case sortOrder = "sort_order"
    }
}
