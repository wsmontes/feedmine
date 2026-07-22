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
    let sourceCollectionStore: SourceCollectionStore
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
    private(set) var hasPreviouslyLoadedContent = false
    private(set) var startupFetchedSourceCount = 0
    private(set) var startupTargetSourceCount = 100
    private(set) var startupTotalSourceCount = 0
    private(set) var startupRecentSourceNames: [String] = []
    private(set) var startupRunwayReady = false
    private(set) var isPreparingInitialRunway = false
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
    /// True when the user explicitly chose "all languages" (cleared filter).
    /// Reset when the user toggles a specific language. Not persisted — on
    /// next launch the device-language default is applied again.
    var hasUserClearedLanguageFilter = false

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
        coverageMiningTask?.cancel()
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
        let isExplicitCatalogueQuery = activeContentType != .all
            || (taxonomySelectionActive
                && cachedTaxonomyFeedURLs.contains(OPMLParser.normalizeURL(sourceURL)))
        if isExplicitCatalogueQuery {
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
    /// Also resolves article-page artwork for items with no feed image URL,
    /// so CachedAsyncImage finds cached data before the card renders.
    private func prefetchImagesIfEnabled(for items: [FeedItem]) {
        guard Settings.prefetchImages else { return }
        let urls = items.compactMap { $0.bestImageURL ?? $0.imageURL }
        let needsArticleResolution = items.filter {
            $0.bestImageURL == nil && $0.canResolveArticleImage
        }
        if !urls.isEmpty {
            Task { await prefetcher.prefetch(urls: urls, priorityURLs: urls) }
        }
        if !needsArticleResolution.isEmpty {
            let articleURLs = needsArticleResolution.compactMap { URL(string: $0.url) }
            Task {
                for url in articleURLs {
                    await prefetcher.prefetchArticleImage(for: url)
                }
            }
        }
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
        deviceLanguage _: String?
    ) -> Bool {
        guard !selectedLanguages.isEmpty else { return true }
        if let lang = normalizedLanguageCode(itemLanguage) {
            return selectedLanguages.contains(lang)
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
        /// Language declared by the item/feed or inherited from the catalogue.
        /// It is a fallback, not an authority: publishers often ship stale or
        /// incorrect language metadata.
        let explicitLanguage: String?
    }

    /// Scripts with a dependable one-language answer for Feedmine's supported
    /// language codes. This also handles short headlines that are too small for
    /// NLLanguageRecognizer and mixed feeds whose XML incorrectly declares en.
    nonisolated private static func distinctiveScriptLanguage(in text: String) -> String? {
        let scalars = text.unicodeScalars
        func count(in range: ClosedRange<UInt32>) -> Int {
            scalars.reduce(into: 0) { total, scalar in
                if range.contains(scalar.value) { total += 1 }
            }
        }

        if count(in: 0x0980...0x09FF) >= 2 { return "bn" } // Bengali
        if count(in: 0x0530...0x058F) >= 2 { return "hy" } // Armenian
        if count(in: 0x10A0...0x10FF) >= 2 { return "ka" } // Georgian
        if count(in: 0x0E00...0x0E7F) >= 2 { return "th" } // Thai
        if count(in: 0x1780...0x17FF) >= 2 { return "km" } // Khmer
        if count(in: 0xAC00...0xD7AF) >= 2 { return "ko" } // Hangul
        if count(in: 0x0590...0x05FF) >= 2 { return "he" } // Hebrew
        if count(in: 0x0370...0x03FF) >= 2 { return "el" } // Greek
        let kanaCount = count(in: 0x3040...0x30FF)
        if kanaCount >= 2 { return "ja" }
        // Han characters are not distinctive to Chinese: Japanese uses them
        // heavily, and an otherwise English article may quote a Chinese name.
        // Let NLLanguageRecognizer evaluate the complete text instead.
        return nil
    }

    /// Run language detection for a batch of items off the main actor.
    /// Reuses a single NLLanguageRecognizer across the batch to avoid
    /// per‑item allocation overhead. Returns resolved language codes in the
    /// same order as the input array.
    nonisolated private static func detectLanguages(_ inputs: [LanguageDetectionInput]) -> [String?] {
        guard !inputs.isEmpty else { return [] }
        let recognizer = NLLanguageRecognizer()
        let minimumTextForDetection = 12
        let minimumTextForSourceOverride = 48
        let minimumOverrideConfidence = 0.65
        let minimumOverrideMargin = 0.15
        return inputs.map { input in
            let text = (input.title + " " + input.excerpt)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // NaturalLanguage has no Azerbaijani model and commonly reports
            // Turkish instead. Schwa is distinctive in Azerbaijani Latin text.
            if text.rangeOfCharacter(from: CharacterSet(charactersIn: "Əə")) != nil {
                return "az"
            }
            if let scriptLanguage = distinctiveScriptLanguage(in: text) {
                return scriptLanguage
            }
            // Run detection when there's enough text. Source-level OPML tags
            // can be wrong for multilingual feeds (e.g. youtube.opml tagged
            // "en" with content in many languages).
            if text.count >= minimumTextForDetection {
                recognizer.reset()
                recognizer.processString(text)
                let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
                    .compactMap { language, confidence -> (language: String, confidence: Double)? in
                        guard let code = normalizedLanguageCode(language.rawValue) else { return nil }
                        return (code, confidence)
                    }
                    .sorted { $0.confidence > $1.confidence }
                if let best = hypotheses.first {
                    let detected = best.language
                    let runnerUp = hypotheses.dropFirst().first?.confidence ?? 0
                    if let explicit = input.explicitLanguage, !explicit.isEmpty {
                        if explicit == detected { return explicit }
                        let margin = best.confidence - runnerUp
                        if text.count >= minimumTextForSourceOverride,
                           best.confidence >= minimumOverrideConfidence,
                           margin >= minimumOverrideMargin {
                            return detected
                        }
                        return explicit
                    }
                    return detected
                }
            }
            // Fall back to explicit source language (OPML header)
            if let lang = input.explicitLanguage, !lang.isEmpty {
                return lang
            }
            return nil
        }
    }

    nonisolated static func resolvedLanguage(
        title: String,
        excerpt: String,
        explicitLanguage: String? = nil
    ) -> String? {
        detectLanguages([
            LanguageDetectionInput(
                title: title,
                excerpt: excerpt,
                explicitLanguage: normalizedLanguageCode(explicitLanguage)
            )
        ]).first ?? nil
    }

    nonisolated static func googleNewsPublisher(fromArticleTitle title: String) -> String? {
        guard let separator = title.range(of: " - ", options: .backwards) else { return nil }
        let publisher = title[separator.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard publisher.count >= 2, publisher.count <= 80 else { return nil }
        return publisher
    }

    /// Apply all active filters to a list of items — single source of truth.
    /// Hit recording is NOT performed here; it happens once at ingestion time
    /// in persistFetchedItems so each item is counted exactly once regardless
    /// of how many times applyFilters runs on the same items.
    func applyFilters(_ items: [FeedItem]) -> [FeedItem] {
        refreshCachedTaxonomyFeedURLsIfNeeded()
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
    private(set) var isSearchLoading = false
    private(set) var unifiedSearchResults = UnifiedSearchResults.empty
    private var searchGeneration: UInt64 = 0

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
    private static let hasPreviouslyLoadedContentKey = "has_previously_loaded_feed_content"

    /// Computed forwarding for What's New items from the manager.
    var whatsNewItems: [FeedItem] { whatsNewManager.whatsNewItems }

    private var hasStarted = false             // guards one-time startup work
    private let usesPersistentStorage: Bool
    nonisolated private static let coldStartMinimumSourceCount = 100
    nonisolated private static let coldStartCatalogSourceCount = 240
    nonisolated private static let coldStartFetchChunkSize = 240
    nonisolated static let sourceCoverageTarget = 100
    nonisolated static let immediateFilteredSourceTarget = 20
    private var coldStartPendingItems: [FeedItem] = []
    @ObservationIgnored private var startupSuccessfulSourceURLs: Set<String> = []
    private var firstLaunchBootstrapTask: Task<Void, Never>?
    private var progressiveFetchTask: Task<Void, Never>?
    private var coverageMiningTask: Task<Void, Never>?
    private var backgroundRefreshTask: Task<Void, Never>?
    private var regionToggleTask: Task<Void, Never>?
    private var filterDebounceTask: Task<Void, Never>?
    private var filterPersistenceTask: Task<Void, Never>?
    private var isEditingFilters = false
    private var pendingFilterReloadGeneration: Int64?
    private var sourceEnablementRefreshTask: Task<Void, Never>?
    private var urgentFetchTask: Task<Void, Never>?
    private var taxonomyCoverageCursor = 0
    private var backgroundCoverageCursor = 0

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

        // Keep background collection off the main feed while a filter sheet is
        // open. The pending items stay in memory and are published as soon as
        // editing ends, so a local toggle never competes with an interleave.
        guard !isEditingFilters, !pendingReservoirItems.isEmpty else { return }
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
        self.usesPersistentStorage = !inMemory
        self.hasPreviouslyLoadedContent = !inMemory
            && UserDefaults.standard.bool(forKey: Self.hasPreviouslyLoadedContentKey)
        if inMemory {
            self.db = try DatabaseQueue(configuration: Self.dbConfig)
        } else {
            self.db = try DatabaseQueue(path: Self.dbPath, configuration: Self.dbConfig)
        }
        try Self.migrate(db)
        // user.sqlite — owns bookmark identity, survives catalog rebuilds
        self.userRepo = try UserStateStore(inMemory: inMemory)
        self.bookmarkStore = BookmarkStore(userDB: userRepo.db, contentDB: db)
        self.sourceCollectionStore = SourceCollectionStore(db: userRepo.db)
        self.searchEngine = SearchEngine(
            db: db,
            userDB: userRepo.db,
            catalogURL: CatalogRuntime.activeCatalogURL()
        )
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
                    try await self.bookmarkStore.synchronizeRetentionPins()
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

    /// Read a small, varied starter set from the active local catalog. This is
    /// intentionally not a replacement for SourceRegistry:
    /// it only overlaps first-install network latency with the authoritative
    /// OPML/taxonomy reconstruction.
    nonisolated static func activeStarterSources(
        language: String,
        limit: Int = coldStartCatalogSourceCount
    ) async -> [FeedSource] {
        guard limit > 0,
              let catalogURL = CatalogRuntime.activeCatalogURL() else { return [] }

        let normalizedLanguage = normalizedLanguageCode(language) ?? "en"
        return await Task.detached(priority: .userInitiated) {
            do {
                var configuration = Configuration()
                configuration.readonly = true
                let catalog = try DatabaseQueue(path: catalogURL.path, configuration: configuration)
                let candidateLimit = max(limit * 6, 180)
                let rows = try catalog.read { db in
                    try Row.fetchAll(db, sql: """
                        SELECT
                            s.title AS title,
                            s.request_url AS url,
                            s.media_kind AS media_kind,
                            s.language AS language,
                            MIN(n.name) AS category
                        FROM catalog_source s
                        JOIN catalog_placement p ON p.source_id = s.id
                        JOIN catalog_node n ON n.id = p.node_id
                        WHERE s.language = ?
                          AND s.request_url LIKE 'https://%'
                          AND s.default_enabled = 1
                          AND n.kind = 3
                          AND n.key NOT LIKE 'countries/%'
                          AND n.key NOT LIKE '90_countries/%'
                          AND n.key NOT LIKE 'languages/%'
                        GROUP BY s.id, s.title, s.request_url, s.media_kind, s.language
                        ORDER BY RANDOM()
                        LIMIT ?
                        """, arguments: [normalizedLanguage, candidateLimit])
                }
                let candidates: [FeedSource] = rows.compactMap { row in
                    guard let title: String = row["title"],
                          let url: String = row["url"],
                          let kindValue: String = row["media_kind"],
                          let kind = MediaKind(rawValue: kindValue) else { return nil }
                    let category: String = row["category"] ?? "General"
                    let rowLanguage: String? = row["language"]
                    return FeedSource(
                        title: title,
                        url: url,
                        category: category,
                        region: "global",
                        mediaKind: kind,
                        language: rowLanguage
                    )
                }
                let scored = candidates.map {
                    (source: $0, score: Double.random(in: 0.9...1.1))
                }
                return SourceScheduler.diverseSources(from: scored, limit: limit)
            } catch {
                Log.feed.error("Active starter catalog failed: \(error.localizedDescription)")
                return []
            }
        }.value
    }

    /// Compatibility entry point retained for tests and older callers. The
    /// returned data now comes from the active local snapshot, which may be the
    /// bundled bootstrap or a verified managed update.
    nonisolated static func bundledStarterSources(
        language: String,
        limit: Int = coldStartCatalogSourceCount
    ) async -> [FeedSource] {
        await activeStarterSources(language: language, limit: limit)
    }

    nonisolated static func coldStartRunwayIsUseful(
        _ items: [FeedItem],
        targetSourceCount: Int = coldStartMinimumSourceCount
    ) -> Bool {
        let target = max(1, min(coldStartMinimumSourceCount, targetSourceCount))
        return items.count >= target && Set(items.map(\.sourceURL)).count >= target
    }

    nonisolated private static func activeCatalogSourceCount() -> Int {
        if let count = CatalogRuntime.activeManifest()?.sourceCount {
            return count
        }
        guard let url = Bundle.main.url(
            forResource: "catalog-manifest",
            withExtension: "json",
            subdirectory: "FeedEngine"
        ),
        let data = try? Data(contentsOf: url),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let count = object["source_count"] as? Int else { return 0 }
        return count
    }

    func configureStartupProgress(targetSourceCount: Int) {
        startupTargetSourceCount = max(1, min(Self.coldStartMinimumSourceCount, targetSourceCount))
        startupFetchedSourceCount = min(startupTargetSourceCount, startupSuccessfulSourceURLs.count)
        startupRunwayReady = startupFetchedSourceCount >= startupTargetSourceCount
    }

    func recordStartupFetchProgress(_ result: FeedFetchResult) {
        guard result.status == .success else { return }
        let normalizedURL = OPMLParser.normalizeURL(result.source.url)
        guard startupSuccessfulSourceURLs.insert(normalizedURL).inserted else { return }

        startupFetchedSourceCount = min(startupTargetSourceCount, startupSuccessfulSourceURLs.count)
        startupRecentSourceNames.append(result.source.title)
        startupRunwayReady = startupFetchedSourceCount >= startupTargetSourceCount
    }

    /// Build a useful first-session runway instead of returning as soon as a
    /// handful of prolific feeds produce many items. Distinct sources are the
    /// release criterion; item count is only the secondary buffer criterion.
    private func fetchColdStartRunway(from sources: [FeedSource]) async -> FeedFetchBatch {
        let targetSourceCount = max(
            1,
            min(Self.coldStartMinimumSourceCount, Set(sources.map(\.url)).count)
        )
        configureStartupProgress(targetSourceCount: targetSourceCount)
        var items: [FeedItem] = []
        var fetchedSourceCount = 0
        var failedSourceCount = 0
        var emptySourceCount = 0
        var statuses: [String: FeedFetchStatus] = [:]

        for start in stride(from: 0, to: sources.count, by: Self.coldStartFetchChunkSize) {
            let end = min(start + Self.coldStartFetchChunkSize, sources.count)
            let chunk = Array(sources[start..<end])
            let usefulSourceCount = Set(items.map(\.sourceURL)).count
            let remainingSources = max(1, targetSourceCount - usefulSourceCount)
            let remainingItems = max(1, targetSourceCount - items.count)
            let result = await fetcher.fetchStarter(
                chunk,
                maxConcurrent: min(48, chunk.count),
                minimumSuccessfulSources: remainingSources,
                minimumItemCount: remainingItems,
                deadline: .seconds(10),
                onProgress: { [weak self] result in
                    self?.recordStartupFetchProgress(result)
                }
            )
            items.append(contentsOf: result.items)
            fetchedSourceCount += result.fetchedSourceCount
            failedSourceCount += result.failedSourceCount
            emptySourceCount += result.emptySourceCount
            statuses.merge(result.sourceStatuses) { _, newest in newest }

            if Self.coldStartRunwayIsUseful(items, targetSourceCount: targetSourceCount) {
                break
            }
        }

        return FeedFetchBatch(
            items: items,
            fetchedSourceCount: fetchedSourceCount,
            failedSourceCount: failedSourceCount,
            emptySourceCount: emptySourceCount,
            sourceStatuses: statuses
        )
    }

    private func startFirstLaunchBootstrapIfNeeded() -> Task<Void, Never>? {
        guard !Settings.hasInitializedLanguageDefault else { return nil }
        let storedItemCount = (try? db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM feed_item") ?? 0
        }) ?? 0
        guard storedItemCount == 0 else { return nil }

        let language = Self.normalizedLanguageCode(
            Locale.current.language.languageCode?.identifier
        ) ?? "en"
        activeLanguages = [language]
        Settings.filterLanguages = [language]
        Settings.hasInitializedLanguageDefault = true
        let generation = filterGeneration
        let startedAt = Date()

        return Task { [weak self] in
            guard let self else { return }
            let sources = await Self.activeStarterSources(language: language)
            guard !Task.isCancelled, !sources.isEmpty else { return }

            // Keep bootstrap items eligible until the full registry replaces
            // this temporary source set a few moments later.
            if self.registry.sources.isEmpty {
                self.registry.sources = sources
                self.reservoir.sourceRegionMap = self.registry.regionMap
            }

            let result = await self.fetchColdStartRunway(from: sources)
            guard !Task.isCancelled, generation == self.filterGeneration else { return }

            let targetSourceCount = min(Self.coldStartMinimumSourceCount, sources.count)
            let usefulSourceCount = Set(result.items.map(\.sourceURL)).count
            guard Self.coldStartRunwayIsUseful(
                result.items,
                targetSourceCount: targetSourceCount
            ) else {
                self.coldStartPendingItems = result.items
                Log.feed.info(
                    "firstLaunchBootstrap withheld: sources=\(usefulSourceCount)/\(targetSourceCount) items=\(result.items.count)/\(targetSourceCount)"
                )
                return
            }

            for (url, status) in result.sourceStatuses {
                self.scheduler.recordFetch(sourceURL: url, success: status != .failed)
            }
            let actualNew = await self.persistFetchedItems(result.items)
            guard !Task.isCancelled, !actualNew.isEmpty else { return }

            self.collectWhatsNewCandidates(actualNew)
            self.throttledReservoirAppend(actualNew)
            await self.flushPendingReservoir()
            self.prefetchImagesIfEnabled(for: actualNew)
            if !self.visibleItems.isEmpty {
                self.isPreparingInitialRunway = false
                self.loadingState = .idle
            }
            Log.feed.info(
                "firstLaunchBootstrap published: sources=\(result.fetchedSourceCount) items=\(actualNew.count) visible=\(self.visibleItems.count) elapsed=\(Date().timeIntervalSince(startedAt), format: .fixed(precision: 3))s"
            )
        }
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
        isPreparingInitialRunway = true
        startupFetchedSourceCount = 0
        startupTargetSourceCount = Self.coldStartMinimumSourceCount
        startupTotalSourceCount = Self.activeCatalogSourceCount()
        startupRecentSourceNames = []
        startupRunwayReady = false
        startupSuccessfulSourceURLs.removeAll(keepingCapacity: true)
        FeedMetrics.event("Backend.start")
        networkMonitor.start()

        // On the first installation the full OPML registry and taxonomy still
        // need to be reconstructed. Start a small, language-matched network
        // race from the bundled compiled catalog while that CPU work runs so
        // first content is not serialized behind thousands of OPML files.
        firstLaunchBootstrapTask = startFirstLaunchBootstrapIfNeeded()

        let endOPMLMetric = FeedMetrics.beginInterval("OPML.load")
        await registry.loadFromOPML()
        startupTotalSourceCount = registry.sourceCount
        endOPMLMetric()
        FeedMetrics.event("OPML.sourceCount", "count=\(self.registry.sources.count)")
        FeedMetrics.memory("afterOPML")
        reservoir.sourceRegionMap = registry.regionMap

        // Build taxonomy tree from loaded sources — try cache first, build if needed
        let endTaxonomyMetric = FeedMetrics.beginInterval("Taxonomy.loadOrBuild")
        let taxonomyCacheHit = TaxonomyStore.shared.loadFromCache(
            sources: registry.sources,
            sharedCountrySourceURLs: registry.sharedCountrySourceURLs
        )
        if !taxonomyCacheHit {
            await TaxonomyStore.shared.build(
                from: registry.sources,
                sharedCountrySourceURLs: registry.sharedCountrySourceURLs
            )
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

        // Warm start: hydrate from SQLite with filters already active. Reuse
        // the same filtered path as filter changes so startup never samples a
        // small unfiltered window and then throws most of it away.
        let endReservoirLoadMetric = FeedMetrics.beginInterval("Reservoir.load")
        if visibleItems.isEmpty {
            await reloadFromSQLite()
        } else {
            // The parallel first-launch bootstrap may already have published a
            // page. Keep its stable IDs/order and only apply the now-complete
            // registry plus read/bookmark state.
            setVisibleItems(applyFilters(visibleItems))
            reservoirCount = reservoir.reservoirCount
        }
        endReservoirLoadMetric()
        if !visibleItems.isEmpty {
            isPreparingInitialRunway = false
            FeedMetrics.event("FirstVisibleItems", "count=\(visibleItems.count)")
            FeedMetrics.memory("afterFirstVisible")
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
            isPreparingInitialRunway = false
            loadingState = .idle
            return
        }

        // A warm cache can render immediately. A gated cold start stays in its
        // preparation state until the 100-source runway is actually ready;
        // showing "no articles" while useful collection is in flight is false.
        loadingState = visibleItems.isEmpty ? .initial : .idle

        // Seed What's New from local data now. Fresh network candidates arrive
        // through the starter/progressive pipeline, so a second 30-source
        // booster would only compete with first paint for bandwidth.
        refreshWhatsNew(shouldBoost: false)

        progressiveFetchTask = Task {
            await self.firstLaunchBootstrapTask?.value
            self.firstLaunchBootstrapTask = nil

            // A populated warm cache or the first-launch bootstrap already
            // owns first paint. Otherwise keep collecting distinct providers;
            // never fall through to the normal progressive path with a thin
            // four- or five-source sample.
            var coldStartAttempts = 0
            while self.visibleItems.isEmpty,
                  self.reservoir.reservoirCount == 0,
                  coldStartAttempts < 3 {
                coldStartAttempts += 1
                await self.fetchNextBatch()
            }
            guard !self.visibleItems.isEmpty || self.reservoir.reservoirCount > 0 else {
                self.isPreparingInitialRunway = false
                self.loadingState = .idle
                Log.feed.info("cold start still withheld after \(coldStartAttempts) registry attempts")
                return
            }
            // Bulk-fill only when the local runway is genuinely shallow. A
            // warm reservoir should stay quiet while the user starts reading.
            if self.reservoir.reservoirCount < Reservoir.progressiveFillTarget {
                await progressiveFetch()
            } else {
                Log.feed.info("progressiveFetch skipped: runway=\(self.reservoir.reservoirCount)")
            }
            guard !Task.isCancelled else { return }
            self.startCoverageMining(generation: self.filterGeneration)
        }

        // Slow-drip background refresh — keeps the database and What's New
        // fed with fresh content continuously while the app is in foreground.
        startBackgroundRefresh()

        // Maintenance is deliberately outside the startup runway. On a fresh
        // database even VACUUM can contend with ingestion and delay first paint.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            await self?.performLightExpurgo()
        }
        Task.detached(priority: .background) { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            await self?.performHeavyMaintenance()
        }
    }

    /// Rebind runtime consumers after a verified managed snapshot is activated.
    /// Feed items, bookmarks, history, collections, and user-imported sources
    /// live outside the managed catalog and are deliberately preserved.
    func reloadActiveCatalogAfterUpdate() async {
        let importedSources = registry.sources.filter { $0.region == "imported" }
        await registry.loadFromOPML()
        if !importedSources.isEmpty {
            registry.sources = OPMLParser.deduplicateSources(
                registry.sources + importedSources
            )
            registry.prepareFilterCaches()
        }

        reservoir.sourceRegionMap = registry.regionMap
        await TaxonomyStore.shared.build(
            from: registry.sources,
            sharedCountrySourceURLs: registry.sharedCountrySourceURLs
        )
        cachedTaxonomyNodeIDs = []
        cachedTaxonomyFeedURLs = []
        startupTotalSourceCount = registry.sourceCount
        searchEngine.replaceCatalog(at: CatalogRuntime.activeCatalogURL())

        setFilter(
            region: activeRegion,
            nodeIDs: activeNodeIDs,
            type: activeContentType,
            mood: activeMood,
            languages: activeLanguages
        )
        FeedMetrics.event(
            "CatalogUpdate.reloaded",
            "sources=\(registry.sourceCount) revision=\(CatalogRuntime.activeManifest()?.revision ?? 0)"
        )
    }

    // MARK: - UI Pipeline
    /// All visibleItems writes route through this single pipeline.
    /// Category‑A triggers (.flush) cancel everything; scroll/fetch/trim
    /// chain behind the current task so only one actor mutates the UI.
    private enum FeedUIUpdate {
        case flush(
            forceFetch: Bool = false,
            skipRead: Bool = false,
            skipNetworkFetch: Bool = false,
            generation: Int64 = 0
        )
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
        guard stamped != visibleItems else {
            markPreviouslyLoadedContentIfNeeded(stamped)
            return
        }
        visibleItems = stamped
        visibleItemsGeneration &+= 1
        markPreviouslyLoadedContentIfNeeded(stamped)
    }

    private func markPreviouslyLoadedContentIfNeeded(_ items: [FeedItem]) {
        guard !items.isEmpty, !hasPreviouslyLoadedContent else { return }
        hasPreviouslyLoadedContent = true
        if usesPersistentStorage {
            UserDefaults.standard.set(true, forKey: Self.hasPreviouslyLoadedContentKey)
        }
    }

    /// Single writer for `visibleItems`. Every mutation routes through here.
    /// - `.flush`: cancels all competing work, clears, then reloads from SQLite.
    /// - `.append` / `.refresh` / `.trim`: serialized behind the current pipeline.
    /// - `.replace`: immediate (search results, source toggle — caller owns the data).
    private func applyUpdate(_ update: FeedUIUpdate) {
        // Bookmark mode is a fixed snapshot — no screen mutations allowed
        guard !isBookmarkFeed else { return }
        switch update {
        case .flush(let forceFetch, let skipRead, let skipNetworkFetch, let generation):
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
                let needsFilteredBreadth = self.activeContentType != .all
                    && Set(self.visibleItems.map(\.sourceURL)).count < Self.immediateFilteredSourceTarget
                if !skipNetworkFetch,
                   (forceFetch || self.visibleItems.count < Reservoir.pageSize || needsFilteredBreadth) {
                    await self.fetchNextBatch()
                }
                // A filtered fetch may add providers after the cached page was
                // seeded. Rebuild once so those providers are interleaved into
                // the first page instead of waiting behind a prolific channel.
                if needsFilteredBreadth,
                   !Task.isCancelled,
                   (generation == 0 || generation == self.filterGeneration) {
                    await self.reloadFromSQLite(skipRead: skipRead, generation: generation)
                }
                if self.usesPersistentStorage,
                   !Task.isCancelled,
                   generation == self.filterGeneration {
                    self.startCoverageMining(generation: generation)
                }
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

    private func scheduleFilterPersistence(generation: Int64) {
        filterPersistenceTask?.cancel()
        filterPersistenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self, generation == self.filterGeneration else { return }
            self.persistFilters()
        }
    }

    private func refreshCachedTaxonomyFeedURLsIfNeeded() {
        guard activeNodeIDs != cachedTaxonomyNodeIDs else { return }
        cachedTaxonomyNodeIDs = activeNodeIDs
        cachedTaxonomyFeedURLs = TaxonomyStore.shared.feedURLs(inSubtreesOf: activeNodeIDs)
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

        // Never leave visibly incompatible cards on screen during the debounce.
        // This is a bounded in-memory cull only; database reads, taxonomy
        // expansion, rebalancing, and network work remain in the async pipeline.
        immediatelyCullVisibleItemsForActiveFilter()

        Log.feed.info("[TaxonomyTrace] setFilter gen=\(generation) region=\(region ?? "nil") nodeIDs=\(self.activeNodeIDs)")

        scheduleFilterPersistence(generation: generation)

        // Cancel progressive fetch — waste of budget when user wants specific content
        progressiveFetchTask?.cancel()
        coverageMiningTask?.cancel()
        // Cancel any previous urgent fetch
        urgentFetchTask?.cancel()
        isUrgentFetching = false

        if isEditingFilters {
            // The sheet owns only selection state. Feed/DB/network work begins
            // once, after dismissal, so rapid taps remain purely interactive.
            filterDebounceTask?.cancel()
            pendingFilterReloadGeneration = generation
        } else {
            scheduleFilterReload(generation: generation, delay: .milliseconds(300))
        }
    }

    private func immediatelyCullVisibleItemsForActiveFilter() {
        guard !visibleItems.isEmpty else { return }
        let region = activeRegion
        let languages = activeLanguages
        let contentType = filterContentType
        let mood = activeMood
        let deviceLanguage = Self.normalizedLanguageCode(
            Locale.current.language.languageCode?.identifier
        )
        setVisibleItems(visibleItems.filter { item in
            (region == nil || item.region == region || item.region.hasPrefix(region! + "/"))
            && Self.languageFilterMatchesNormalized(
                itemLanguage: item.language,
                selectedLanguages: languages,
                deviceLanguage: deviceLanguage
            )
            && contentType(item)
            && (mood == .all || mood.matches(item.title))
        })
    }

    func beginFilterEditing() {
        isEditingFilters = true
    }

    func endFilterEditing() {
        isEditingFilters = false
        if let generation = pendingFilterReloadGeneration {
            pendingFilterReloadGeneration = nil
            scheduleFilterReload(generation: generation, delay: .milliseconds(80))
        } else if !pendingReservoirItems.isEmpty {
            Task { [weak self] in
                await self?.flushPendingReservoir()
            }
        }
    }

    private func scheduleFilterReload(generation: Int64, delay: Duration) {
        filterDebounceTask?.cancel()
        filterDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self,
                  generation == self.filterGeneration else { return }

            self.refreshCachedTaxonomyFeedURLsIfNeeded()
            let priorityURLs = self.cachedTaxonomyFeedURLs
            self.loadingState = .refreshing
            // Render the matching local cache before dispatching network work.
            // Besides making a saved feed react immediately, this prevents a
            // slow source probe from competing with the first filtered frame.
            self.refreshWhatsNew(shouldBoost: false)
            let reloadFromCacheBeforeUrgentFetch = !priorityURLs.isEmpty
            self.applyUpdate(.flush(
                skipNetworkFetch: reloadFromCacheBeforeUrgentFetch,
                generation: generation
            ))
            let reloadTask = self.pipelineTask

            // In-memory stores are test/preview sandboxes. Their filtered
            // pipeline must stay local and deterministic instead of leaving
            // network tasks alive after an XCTest has released the store.
            if !priorityURLs.isEmpty, self.usesPersistentStorage {
                self.isUrgentFetching = true
                self.urgentFetchTask = Task { [weak self] in
                    await reloadTask?.value
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    await self.fetchUrgentTaxonomyBatch(sourceURLs: priorityURLs, generation: generation)
                    self.isUrgentFetching = false
                    self.startBackgroundRefresh()
                }
            }
        }
    }

    func clearAllFilters() {
        filterGeneration &+= 1
        let generation = filterGeneration

        activeRegion = nil
        activeNodeIDs = []
        activeContentType = .all
        activeMood = .all
        activeLanguages = []
        hasUserClearedLanguageFilter = true
        cachedTaxonomyNodeIDs = []
        cachedTaxonomyFeedURLs = []
        scheduleFilterPersistence(generation: generation)

        progressiveFetchTask?.cancel()
        coverageMiningTask?.cancel()
        urgentFetchTask?.cancel()
        isUrgentFetching = false

        if isEditingFilters {
            filterDebounceTask?.cancel()
            pendingFilterReloadGeneration = generation
        } else {
            scheduleFilterReload(generation: generation, delay: .milliseconds(100))
        }
    }

    // MARK: - Search
    func search(_ query: String) {
        isSearching = true
        isSearchLoading = true
        searchGeneration &+= 1
        let generation = searchGeneration
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            unifiedSearchResults = .empty
            isSearchLoading = false
            return
        }
        Task {
            let results = await searchEngine.unifiedSearch(q)
            guard isSearching, generation == searchGeneration else { return }
            unifiedSearchResults = results
            isSearchLoading = false
        }
    }

    func clearSearch() {
        isSearching = false
        isSearchLoading = false
        searchGeneration &+= 1
        unifiedSearchResults = .empty
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
        setCategoryEnabled(category, enabled: registry.status(of: SourceRegistry.categoryKey(category)) == .off)
    }

    func setCategoryEnabled(_ category: String, enabled: Bool) {
        registry.setCategoryEnabled(category, enabled: enabled)
        // Category toggle is structural — reload feed
        scheduleSourceEnablementRefresh()
    }

    func setTopicRegionsEnabled(_ enabled: Bool) {
        registry.setTopicRegionsEnabled(enabled)
        resetWhatsNewBaseline()
        scheduleSourceEnablementRefresh()
    }

    func scheduleSourceEnablementRefresh() {
        sourceEnablementRefreshTask?.cancel()
        sourceEnablementRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.loadingState = .refreshing
            self.refreshWhatsNew(shouldBoost: false)
            self.applyUpdate(.flush())
        }
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
            matchesActiveFilters: { [self] in !applyFilters([$0]).isEmpty },
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

    /// Refresh What's New from the local DB. The network booster is reserved
    /// for startup so filter edits never cancel a write already in progress.
    func refreshWhatsNew(shouldBoost: Bool = false) {
        whatsNewManager.refreshWhatsNew(
            seedFromDB: { [self] in await seedWhatsNewFromDB() },
            booster: { [self] in
                if shouldBoost { fetchWhatsNewBooster() }
            }
        )
    }

    /// Seed the pool from existing SQLite content — runs once at startup
    /// so the carousel isn't empty while waiting for the first fetch batch.
    private func seedWhatsNewFromDB() async {
        await whatsNewManager.seedWhatsNewFromDB(
            surfacedIDs: surfacedItemIDs,
            readIDs: readItemIDs,
            matchesActiveFilters: { [self] in !applyFilters([$0]).isEmpty },
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
        // Existing IDs are normally skipped, but a newer parser may recover
        // artwork that an older build missed. Repair only empty image fields so
        // read state, bookmarks, and other persisted metadata stay untouched.
        let imageRepairs = items.compactMap { item -> (id: String, imageURL: String)? in
            guard loadedIDs.contains(item.id),
                  let imageURL = item.bestImageURL else { return nil }
            return (item.id, imageURL)
        }
        var seen = Set<String>()
        let actualNew = items.filter { item in
            guard !loadedIDs.contains(item.id) else { return false }
            return seen.insert(item.id).inserted
        }
        guard !actualNew.isEmpty else {
            guard !imageRepairs.isEmpty else { return [] }
            do {
                try await db.write { db in
                    for repair in imageRepairs {
                        try db.execute(
                            sql: "UPDATE feed_item SET image_url = ? WHERE id = ? AND image_url IS NULL",
                            arguments: [repair.imageURL, repair.id]
                        )
                    }
                }
            } catch {
                Log.db.warning("persistFetchedItems: image repair failed: \(error.localizedDescription)")
            }
            return []
        }

        // Collect regions + explicit source languages on the main actor
        // (dictionary lookups are O(1) and cheap). Language detection via
        // NLLanguageRecognizer runs in a detached task to avoid blocking UI.
        let regions: [String] = actualNew.map { regionOverride ?? registry.regionFor(sourceURL: $0.sourceURL) }
        let detectionInputs: [LanguageDetectionInput] = actualNew.map { item in
            let itemLang = Self.normalizedLanguageCode(item.language)
            let sourceLang = Self.normalizedLanguageCode(registry.languageFor(sourceURL: item.sourceURL))
            // Item-level language is authoritative; source-level (OPML) can
            // be overridden by detection when content text disagrees.
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
                for repair in imageRepairs {
                    try db.execute(
                        sql: "UPDATE feed_item SET image_url = ? WHERE id = ? AND image_url IS NULL",
                        arguments: [repair.imageURL, repair.id]
                    )
                }
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
        let needsStarter = visibleItems.isEmpty && reservoir.reservoirCount == 0
        // The 100-source runway protects the first impression on a fresh app.
        // An empty result after a user changes filters is a different state: it
        // should fetch only compatible sources and publish their first batch.
        let needsInitialRunway = needsStarter && isPreparingInitialRunway
        let visibleSourceCount = Set(visibleItems.map(\.sourceURL)).count
        let needsFilteredRunway = !needsInitialRunway
            && activeContentType != .all
            && visibleSourceCount < Self.immediateFilteredSourceTarget
        refreshCachedTaxonomyFeedURLsIfNeeded()
        let sourcePool: [FeedSource]
        if activeContentType == .all {
            sourcePool = registry.enabledSources
        } else {
            // A top-level type is an explicit catalogue query, not a request
            // limited to the small default global-source subset.
            sourcePool = await coverageSources(
                for: activeContentType,
                languages: activeLanguages,
                region: nil,
                taxonomyURLs: nil
            )
        }
        let sourcesByRegion = await Task.detached(priority: .userInitiated) {
            Dictionary(grouping: sourcePool, by: \.region)
        }.value
        let contentTypeStr: String? = switch activeContentType {
        case .video: "video"; case .audio: "audio"; case .text: "text"
        case .forum: "forum"; default: nil
        }
        let batch = scheduler.nextBatch(
            reservoir: reservoir.reservoir,
            sourcesByRegion: sourcesByRegion,
            activeRegion: activeRegion,
            activeCategory: nil,
            activeContentType: contentTypeStr,
            prioritySourceURLs: activeNodeIDs.isEmpty ? [] : cachedTaxonomyFeedURLs,
            activeLanguages: activeLanguages,
            minimumBatchSize: needsInitialRunway
                ? Self.coldStartCatalogSourceCount
                : (needsFilteredRunway ? 120 : 24)
        )
        guard !batch.isEmpty else { return }
        let coldStartTargetSourceCount = min(
            Self.coldStartMinimumSourceCount,
            Set(batch.map(\.url)).count
        )

        loadingState = needsInitialRunway ? .initial : .refreshing
        defer {
            loadingState = isPreparingInitialRunway && visibleItems.isEmpty ? .initial : .idle
        }

        let result: FeedFetchBatch
        if needsInitialRunway {
            result = await fetchColdStartRunway(from: batch)
            Log.feed.info("starterFetch completed: sources=\(result.fetchedSourceCount) items=\(result.items.count) attempted=\(result.sourceStatuses.count)")
        } else if needsFilteredRunway {
            let neededSources = max(1, Self.immediateFilteredSourceTarget - visibleSourceCount)
            result = await fetcher.fetchStarter(
                batch,
                maxConcurrent: min(30, batch.count),
                minimumSuccessfulSources: min(neededSources, batch.count),
                minimumItemCount: neededSources,
                deadline: .seconds(8)
            )
        } else {
            result = await fetcher.fetchAll(batch, maxConcurrent: 15)
        }
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
            guard let status = result.sourceStatuses[source.url] else { continue }
            let failed = status == .failed
            scheduler.recordFetch(sourceURL: source.url, success: !failed)
            let count = sourceItemCounts[source.url]
            healthEntries.append((source.url, count))
        }
        saveSourceHealthBatch(healthEntries)

        let itemsToPersist: [FeedItem]
        if needsInitialRunway {
            coldStartPendingItems.append(contentsOf: result.items)
            let usefulSourceCount = Set(coldStartPendingItems.map(\.sourceURL)).count
            guard Self.coldStartRunwayIsUseful(
                coldStartPendingItems,
                targetSourceCount: coldStartTargetSourceCount
            ) else {
                Log.feed.info(
                    "starterIngest withheld: sources=\(usefulSourceCount)/\(coldStartTargetSourceCount) items=\(self.coldStartPendingItems.count)/\(coldStartTargetSourceCount)"
                )
                return
            }
            itemsToPersist = coldStartPendingItems
            coldStartPendingItems = []
        } else {
            itemsToPersist = result.items
        }

        let ingestStartedAt = Date()
        let actualNew = await persistFetchedItems(itemsToPersist)
        if needsInitialRunway {
            Log.feed.info("starterIngest persisted: items=\(actualNew.count) elapsed=\(Date().timeIntervalSince(ingestStartedAt), format: .fixed(precision: 3))s")
        }
        guard !actualNew.isEmpty else { return }

        if needsInitialRunway {
            isPreparingInitialRunway = false
            startupRunwayReady = true
        }

        // Yield again after heavy DB work before processing results
        await Task.yield()

        // Feed the What's New reactive pipeline
        collectWhatsNewCandidates(actualNew)

        // Diagnostic (opt-in via debug bar): surface non-English items so a
        // mis-languaged feed can be identified. See loop-focus-areas #5.
        if Settings.showDebugBar {
            logNonEnglishItems(actualNew)
        }

        // Prefetch images before items enter the reservoir so downloads
        // race ahead of LazyVStack card rendering (50-200ms head start).
        prefetchImagesIfEnabled(for: actualNew)

        // Append to the reservoir via the batched off-main interleave path.
        throttledReservoirAppend(actualNew)
        // A cold feed or a nearly depleted runway cannot wait for the normal
        // three-second coalescing interval. Commit this batch now so the first
        // page appears immediately and fast scrolling always has content ahead.
        if visibleItems.isEmpty || reservoir.reservoirCount < Reservoir.reservoirLowWatermark {
            await flushPendingReservoir()
        }
        if needsInitialRunway {
            Log.feed.info("starterIngest published: visible=\(self.visibleItems.count) reservoir=\(self.reservoir.reservoirCount) elapsed=\(Date().timeIntervalSince(ingestStartedAt), format: .fixed(precision: 3))s")
        }

        // Database retention is maintenance, not a prerequisite for showing
        // content. Run it after publication so it never extends first paint.
        let sourceURLs = Array(Set(actualNew.map(\.sourceURL)))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            await self?.capSourceItemsBatch(sourceURLs)
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
        let lookup = registry.lookupSnapshot()
        let languages = activeLanguages
        let typeRawValue = activeContentType.rawValue
        let region = activeRegion
        let allMatching = await Task.detached(priority: .userInitiated) {
            sourceURLs.compactMap { lookup.sourcesByNormalizedURL[$0] }
        }.value
        let individuallyDisabled = await Task.detached(priority: .utility) {
            allMatching.filter {
                lookup.explicitlyDisabledURLs.contains(OPMLParser.normalizeURL($0.url))
            }
        }.value
        let eligible = await Task.detached(priority: .userInitiated) {
            allMatching.filter { source in
                let normalizedURL = OPMLParser.normalizeURL(source.url)
                return !lookup.explicitlyDisabledURLs.contains(normalizedURL)
                    && Self.coverageSourceMatches(
                        source,
                        typeRawValue: typeRawValue,
                        languages: languages,
                        region: region
                    )
            }
        }.value
        let enabledSnapshot = registry.enabledSources
        let normallyEnabledCount = await Task.detached(priority: .utility) {
            let enabledURLs = Set(enabledSnapshot.map { OPMLParser.normalizeURL($0.url) })
            return eligible.reduce(into: 0) { count, source in
                if enabledURLs.contains(OPMLParser.normalizeURL(source.url)) { count += 1 }
            }
        }.value

        // [TaxonomyTrace] — detailed diagnostic for the 4 Acoustics feeds
        Log.feed.info("""
            [TaxonomyTrace] urgentFetch gen=\(generation): \
            taxonomyURLs=\(sourceURLs.count) \
            allMatching=\(allMatching.count) \
            normallyEnabled=\(normallyEnabledCount) \
            eligible=\(eligible.count) \
            individuallyDisabled=\(individuallyDisabled.count)
            """)
        for src in allMatching.prefix(20) {
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

    // MARK: - Source coverage

    private struct CoveragePlan: Sendable {
        let target: Int
        let representedCount: Int
        let deficit: Int
        let candidates: [FeedSource]
    }

    /// The screen can publish after 20 providers, but collection continues until
    /// a filter has 100 providers that have actually produced persisted items.
    /// A successful HTTP response with zero usable items does not count.
    private func startCoverageMining(generation: Int64) {
        coverageMiningTask?.cancel()
        let preferredType = activeContentType
        let languages = activeLanguages
        coverageMiningTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, generation == self.filterGeneration else { return }

            while self.isUrgentFetching, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled, generation == self.filterGeneration else { return }

            if preferredType != .all {
                let activeSources = await self.coverageSources(
                    for: preferredType,
                    languages: languages,
                    region: self.activeRegion,
                    taxonomyURLs: self.activeNodeIDs.isEmpty ? nil : self.cachedTaxonomyFeedURLs
                )
                // The active filter owns the runway. Keep taking bounded passes
                // until 100 useful providers are represented; switching filters
                // cancels this task immediately through the generation guard.
                for pass in 1...6 {
                    guard !Task.isCancelled, generation == self.filterGeneration else { return }
                    let started = await self.mineCoverage(
                        sources: activeSources,
                        label: "active-\(preferredType.rawValue)-p\(pass)",
                        deadline: .seconds(20),
                        publish: true
                    )
                    guard started else { break }
                    try? await Task.sleep(for: .milliseconds(350))
                }
            }

            let topTypes: [FeedLoader.ContentType] = [.video, .audio, .forum, .text]
            for type in topTypes where type != preferredType {
                guard !Task.isCancelled, generation == self.filterGeneration else { return }
                let sources = await self.coverageSources(
                    for: type,
                    languages: languages,
                    region: nil,
                    taxonomyURLs: nil
                )
                _ = await self.mineCoverage(
                    sources: sources,
                    label: "top-\(type.rawValue)",
                    deadline: .seconds(12),
                    publish: false
                )
                try? await Task.sleep(for: .milliseconds(750))
            }

            // Make visible progress across the catalogue on every session. The
            // slow refresh continues rotating through the remaining categories.
            for _ in 0..<6 {
                guard !Task.isCancelled, generation == self.filterGeneration else { return }
                guard await self.mineNextTaxonomyCoverage(languages: languages) else { break }
                try? await Task.sleep(for: .milliseconds(750))
            }
        }
    }

    private func coverageSources(
        for type: FeedLoader.ContentType,
        languages: Set<String>,
        region: String?,
        taxonomyURLs: Set<String>?
    ) async -> [FeedSource] {
        let typeRawValue = type.rawValue
        let sourceSnapshot: [FeedSource]
        if let taxonomyURLs {
            let lookup = registry.lookupSnapshot()
            sourceSnapshot = await Task.detached(priority: .utility) {
                taxonomyURLs.compactMap { url in
                    guard !lookup.explicitlyDisabledURLs.contains(url) else { return nil }
                    return lookup.sourcesByNormalizedURL[url]
                }
            }.value
        } else if type == .all {
            sourceSnapshot = registry.enabledSources
        } else {
            // Top-level media filters query the complete catalogue. Inherited
            // category/region disables are bypassed, while an explicit source
            // opt-out remains absolute.
            let lookup = registry.lookupSnapshot()
            sourceSnapshot = await Task.detached(priority: .utility) {
                lookup.sourcesByNormalizedURL.compactMap { url, source in
                    lookup.explicitlyDisabledURLs.contains(url) ? nil : source
                }
            }.value
        }
        return await Task.detached(priority: .utility) {
            sourceSnapshot.filter { source in
                Self.coverageSourceMatches(
                    source,
                    typeRawValue: typeRawValue,
                    languages: languages,
                    region: region
                )
            }
        }.value
    }

    nonisolated private static func coverageSourceMatches(
        _ source: FeedSource,
        typeRawValue: String,
        languages: Set<String>,
        region: String?
    ) -> Bool {
        if let region,
           source.region != region,
           !source.region.hasPrefix(region + "/") { return false }
        if !languages.isEmpty,
           let language = normalizedLanguageCode(source.language),
           !languages.contains(language) { return false }
        switch typeRawValue {
        case "Videos":
            return source.isYouTube || source.mediaKind == .video
        case "Podcasts":
            return source.mediaKind == .audio
        case "Forums":
            return source.mediaKind == .forum
        case "Articles":
            return !source.isYouTube && source.mediaKind == .text
        default:
            return true
        }
    }

    private func storedSourceURLs() async -> Set<String> {
        let urls = (try? await db.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT source_url FROM feed_item")
        }) ?? []
        return Set(urls.map(OPMLParser.normalizeURL))
    }

    /// Returns true when a network coverage pass was started.
    @discardableResult
    private func mineCoverage(
        sources: [FeedSource],
        label: String,
        deadline: Duration,
        publish: Bool
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        let stored = await storedSourceURLs()
        let plan = await Task.detached(priority: .utility) {
            Self.makeCoveragePlan(sources: sources, stored: stored)
        }.value
        guard plan.target > 0 else { return false }
        guard plan.deficit > 0 else {
            Log.feed.info("coverage \(label): ready \(plan.representedCount)/\(plan.target) useful sources")
            return false
        }
        let candidates = plan.candidates
        guard !candidates.isEmpty else { return false }

        Log.feed.info(
            "coverage \(label): mining \(plan.representedCount)/\(plan.target), candidates=\(candidates.count)"
        )
        let result = await fetcher.fetchStarter(
            candidates,
            maxConcurrent: min(36, candidates.count),
            minimumSuccessfulSources: min(plan.deficit, candidates.count),
            minimumItemCount: min(plan.deficit, candidates.count),
            deadline: deadline
        )
        guard !Task.isCancelled else { return true }

        let sourceItemCounts = await Task.detached(priority: .utility) {
            Dictionary(grouping: result.items, by: \.sourceURL).mapValues(\.count)
        }.value
        var healthEntries: [(url: String, itemCount: Int?)] = []
        for source in candidates {
            guard let status = result.sourceStatuses[source.url] else { continue }
            scheduler.recordFetch(sourceURL: source.url, success: status != .failed)
            healthEntries.append((source.url, sourceItemCounts[source.url]))
        }
        saveSourceHealthBatch(healthEntries)

        totalFetched += result.items.count
        fetchErrorCount += result.failedSourceCount
        emptyFeedCount += result.emptySourceCount
        let actualNew = await persistFetchedItems(result.items)
        if publish {
            let visibleNew = await presentationItems(from: actualNew)
            if !visibleNew.isEmpty {
                throttledReservoirAppend(visibleNew)
                collectWhatsNewCandidates(visibleNew)
                prefetchImagesIfEnabled(for: visibleNew)
            }
        }
        if !actualNew.isEmpty {
            await capSourceItemsBatch(Array(Set(actualNew.map(\.sourceURL))))
            await matchPersistentSearches(actualNew)
        }

        let newlyUsefulCount = await Task.detached(priority: .utility) {
            Set(result.items.map { OPMLParser.normalizeURL($0.sourceURL) })
                .subtracting(stored).count
        }.value
        let usefulAfter = plan.representedCount + newlyUsefulCount
        Log.feed.info(
            "coverage \(label): \(min(usefulAfter, plan.target))/\(plan.target) useful sources after pass"
        )
        return true
    }

    nonisolated private static func makeCoveragePlan(
        sources: [FeedSource],
        stored: Set<String>
    ) -> CoveragePlan {
        var uniqueSources: [String: FeedSource] = [:]
        uniqueSources.reserveCapacity(sources.count)
        for source in sources {
            let key = OPMLParser.normalizeURL(source.url)
            if uniqueSources[key] == nil { uniqueSources[key] = source }
        }
        let target = min(sourceCoverageTarget, uniqueSources.count)
        let represented = uniqueSources.keys.reduce(into: 0) { count, url in
            if stored.contains(url) { count += 1 }
        }
        let deficit = max(0, target - represented)
        let unfetched = uniqueSources.compactMap { url, source in
            stored.contains(url) ? nil : source
        }
        let limit = min(unfetched.count, max(120, deficit * 4))
        return CoveragePlan(
            target: target,
            representedCount: represented,
            deficit: deficit,
            candidates: Array(unfetched.shuffled().prefix(limit))
        )
    }

    private func presentationItems(from items: [FeedItem]) async -> [FeedItem] {
        guard !items.isEmpty else { return [] }
        var filtered: [FeedItem] = []
        filtered.reserveCapacity(items.count)
        for start in stride(from: 0, to: items.count, by: 80) {
            let end = min(start + 80, items.count)
            filtered.append(contentsOf: applyFilters(Array(items[start..<end])))
            await Task.yield()
        }
        return filtered
    }

    /// Rotates through leaf taxonomy categories. A category with fewer than 100
    /// catalogued feeds is complete when every available feed has produced items.
    private func mineNextTaxonomyCoverage(languages: Set<String>) async -> Bool {
        let groups = TaxonomyStore.shared.coverageGroups
        guard !groups.isEmpty else { return false }
        let lookup = registry.lookupSnapshot()
        let stored = await storedSourceURLs()
        let cursor = taxonomyCoverageCursor
        let next = await Task.detached(priority: .utility) { () -> (Int, String, [FeedSource])? in
            for offset in 0..<groups.count {
                let index = (cursor + offset) % groups.count
                let group = groups[index]
                let sources = group.feedURLs.compactMap { url -> FeedSource? in
                    guard !lookup.explicitlyDisabledURLs.contains(url),
                          let source = lookup.sourcesByNormalizedURL[url] else { return nil }
                    if !languages.isEmpty,
                       let language = Self.normalizedLanguageCode(source.language),
                       !languages.contains(language) { return nil }
                    return source
                }
                let uniqueURLs = Set(sources.map { OPMLParser.normalizeURL($0.url) })
                let target = min(Self.sourceCoverageTarget, uniqueURLs.count)
                guard target > 0, uniqueURLs.intersection(stored).count < target else { continue }
                return (index, group.id, sources)
            }
            return nil
        }.value
        guard let (index, nodeID, sources) = next else { return false }
        taxonomyCoverageCursor = (index + 1) % groups.count
        return await mineCoverage(
            sources: sources,
            label: "category-\(nodeID)",
            deadline: .seconds(10),
            publish: false
        )
    }

    /// Fetch a budgeted batch of remaining enabled sources in the background.
    /// Capped per session to avoid hammering 800+ sources at every launch;
    /// the rest trickle in via normal refresh cycles. Shuffled for fair
    /// distribution across text/video/audio types.
    private func progressiveFetch() async {
        let allEnabled = progressiveFetchSources()
        let budget = allEnabled.count
        let chunkSize = 20
        var processed = 0
        Log.feed.info("progressiveFetch starting: \(budget) filtered/diverse sources")
        for chunkStart in stride(from: 0, to: budget, by: chunkSize) {
            let end = min(chunkStart + chunkSize, budget)
            let chunk = Array(allEnabled[chunkStart..<end])
            processed += chunk.count
            // Gentle 1s inter-chunk delay (skip first) to avoid rate-limiting
            // from YouTube and other aggressive CDNs when processing 800+ sources.
            if chunkStart > 0 { try? await Task.sleep(for: .seconds(1)) }
            let result: FeedFetchBatch
            if chunkStart == 0 && reservoir.reservoirCount < Reservoir.reservoirLowWatermark {
                result = await fetcher.fetchStarter(chunk, maxConcurrent: 10)
            } else {
                result = await fetcher.fetchAll(chunk, maxConcurrent: 5)
            }
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
            if reservoir.reservoirCount < Reservoir.progressiveFillTarget {
                await flushPendingReservoir()
            }
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
            if reservoir.reservoirCount >= Reservoir.progressiveFillTarget {
                Log.feed.info("progressiveFetch runway ready: reservoir=\(self.reservoir.reservoirCount)")
                break
            }
        }
        Log.feed.info("progressiveFetch DONE — \(processed)/\(allEnabled.count) sources processed")
        lastRefreshDate = .now
        await capAllSources()
    }

    private func progressiveFetchSources() -> [FeedSource] {
        let activeLangs = activeLanguages
        let activeType = activeContentType
        let recentCutoff = Date().addingTimeInterval(-300)
        let candidates = registry.enabledSources.filter { source in
            sourceMatches(source, languages: activeLangs)
                && sourceMatches(source, contentType: activeType)
                && (scheduler.lastFetchedAt[source.url] ?? .distantPast) < recentCutoff
        }
        let budget = min(candidates.count, 200)  // per-session cap
        let scored = candidates.map { source in
            (source: source, score: Double.random(in: 0.95...1.05))
        }
        return SourceScheduler.diverseSources(from: scored, limit: budget)
    }

    private func sourceMatches(_ source: FeedSource, languages: Set<String>) -> Bool {
        guard !languages.isEmpty else { return true }
        let sourceLang = Self.normalizedLanguageCode(
            source.language.flatMap { $0.isEmpty ? nil : $0 }
        )
        guard let sourceLang else { return true }
        return languages.contains(sourceLang)
    }

    private func sourceMatches(_ source: FeedSource, contentType: FeedLoader.ContentType) -> Bool {
        switch contentType {
        case .all:
            return true
        case .text:
            return !source.isYouTube && source.mediaKind != .video
                && source.mediaKind != .audio && source.mediaKind != .forum
        case .video:
            return source.isYouTube || source.mediaKind == .video
        case .audio:
            return source.mediaKind == .audio
        case .forum:
            return source.mediaKind == .forum
        }
    }

    /// Slow-drip background refresh — fetches a small batch of sources every
    /// few minutes to keep the database and What's New fed with fresh content.
    /// Complements progressiveFetch (bulk initial fill) with continuous renewal.
    private func startBackgroundRefresh() {
        backgroundRefreshTask?.cancel()
        backgroundRefreshTask = Task(priority: .background) { [weak self] in
            guard let self else { return }
            let interval: TimeInterval = 150  // 2.5 minutes
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                guard self.loadingState == .idle, !self.isSearching else { continue }

                let coverageStep = self.backgroundCoverageCursor
                self.backgroundCoverageCursor &+= 1
                let didMineCoverage: Bool
                if coverageStep.isMultiple(of: 2) {
                    let types: [FeedLoader.ContentType] = [.video, .audio, .forum, .text]
                    let type = types[(coverageStep / 2) % types.count]
                    let sources = await self.coverageSources(
                        for: type,
                        languages: self.activeLanguages,
                        region: nil,
                        taxonomyURLs: nil
                    )
                    didMineCoverage = await self.mineCoverage(
                        sources: sources,
                        label: "refresh-\(type.rawValue)",
                        deadline: .seconds(10),
                        publish: type == self.activeContentType
                    )
                } else {
                    didMineCoverage = await self.mineNextTaxonomyCoverage(
                        languages: self.activeLanguages
                    )
                }
                if didMineCoverage { continue }

                let batchSize = 5
                let sourceSnapshot = self.registry.enabledSources
                let batch = await Task.detached(priority: .utility) {
                    Array(sourceSnapshot.shuffled().prefix(batchSize))
                }.value
                guard !batch.isEmpty else { continue }
                let result = await self.fetcher.fetchAll(batch, maxConcurrent: 2)
                let actualNew = await self.persistFetchedItems(result.items)
                let visibleNew = await self.presentationItems(from: actualNew)
                if !visibleNew.isEmpty {
                    self.throttledReservoirAppend(visibleNew)
                    self.collectWhatsNewCandidates(visibleNew)
                    self.prefetchImagesIfEnabled(for: visibleNew)
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
        refreshCachedTaxonomyFeedURLsIfNeeded()
        let region = activeRegion
        let contentType = activeContentType
        let languages = activeLanguages
        // Capture taxonomy feed URLs before entering the read closure (which may
        // run off the main actor). When taxonomy is active we load matching
        // items via batched IN clause with per-chunk and global caps.
        let taxonomyURLs: Set<String>? = activeNodeIDs.isEmpty ? nil : cachedTaxonomyFeedURLs
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

            // Language filter — shared rule with applyFilters.
            // Unknown-language rows do not pass while a language filter is active.
            if !languages.isEmpty {
                let langArray = Array(languages)
                if langArray.count <= 999 {
                    let langPlaceholders = langArray.map { _ in "?" }.joined(separator: ",")
                    request = request.filter(
                        sql: "language IN (\(langPlaceholders))",
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
                        sql: "(\(orParts.joined(separator: " OR ")))",
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

            if contentType == .all {
                // A timestamp-only window can be entirely consumed by prolific
                // article sources. Read bounded media slices independently so
                // a mixed, language-only feed can still surface its videos and
                // podcasts while preserving a large pool of recent articles.
                let illustratedTextItems = try request
                    .filter(Column("audio_url") == nil)
                    .filter(!Column("source_url").like("%youtube%"))
                    .filter(!Column("source_url").like("%reddit%"))
                    .filter(Column("image_url") != nil)
                    .order(Column("published_at").desc)
                    .limit(Self.illustratedTextCandidateReadLimit)
                    .fetchAll(db)
                let textItems = try request
                    .filter(Column("audio_url") == nil)
                    .filter(!Column("source_url").like("%youtube%"))
                    .filter(!Column("source_url").like("%reddit%"))
                    .filter(Column("image_url") == nil)
                    .order(Column("published_at").desc)
                    .limit(Self.textCandidateReadLimit - Self.illustratedTextCandidateReadLimit)
                    .fetchAll(db)
                let videoItems = try request
                    .filter(Column("source_url").like("%youtube%"))
                    .order(Column("published_at").desc)
                    .limit(Self.mediaCandidateReadLimit)
                    .fetchAll(db)
                let audioItems = try request
                    .filter(Column("audio_url") != nil)
                    .order(Column("published_at").desc)
                    .limit(Self.mediaCandidateReadLimit)
                    .fetchAll(db)
                let forumItems = try request
                    .filter(Column("source_url").like("%reddit%"))
                    .order(Column("published_at").desc)
                    .limit(Self.forumCandidateReadLimit)
                    .fetchAll(db)
                return illustratedTextItems + textItems + videoItems + audioItems + forumItems
            }

            return try request
                .order(Column("published_at").desc)
                .limit(Self.candidateReadLimit)
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
        let balancedItems = Self.balancedCandidatePool(filteredItems)
        Log.feed.info("[TaxonomyTrace] reloadFromSQLite gen=\(generation) loaded=\(feedItems.count) filtered=\(filteredItems.count) balanced=\(balancedItems.count) taxonomyURLs=\(taxonomyURLs?.count ?? 0)")
        await reservoir.seed(items: balancedItems)
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

    /// Build a broad startup pool without letting the newest prolific feeds
    /// consume every slot. The first pass admits only a small number per
    /// provider; a second pass fills unused capacity so narrow filters still
    /// retain all available content.
    // Persistence caps each feed at 50 rows. Reading 5,000 candidates therefore
    // reaches at least 100 feeds even when prolific, fresh aggregator queries
    // occupy the entire leading edge of a language or category selection.
    nonisolated static let candidateReadLimit = 5_000
    nonisolated static let textCandidateReadLimit = 4_000
    nonisolated static let illustratedTextCandidateReadLimit = 300
    nonisolated static let mediaCandidateReadLimit = 500
    nonisolated static let forumCandidateReadLimit = 100

    nonisolated static func balancedCandidatePool(
        _ items: [FeedItem],
        limit: Int = 500,
        initialPerSource: Int = 8
    ) -> [FeedItem] {
        guard limit > 0, !items.isEmpty else { return [] }

        var uniqueItems: [FeedItem] = []
        var seenIDs = Set<String>()
        for item in items where seenIDs.insert(item.id).inserted {
            uniqueItems.append(item)
        }

        var selected: [FeedItem] = []
        var overflowByProvider: [String: [FeedItem]] = [:]
        var providerOrder: [String] = []
        var providerCounts: [String: Int] = [:]
        var selectedIDs = Set<String>()
        selected.reserveCapacity(min(limit, items.count))

        func registerProvider(for item: FeedItem) -> String {
            let provider = Reservoir.providerKey(item)
            if providerCounts[provider] == nil {
                providerOrder.append(provider)
            }
            return provider
        }

        // Reserve a bounded first pass for each non-text medium. The usual
        // source round-robin still applies, so one podcast or channel cannot
        // spend the reservation by itself.
        let perMediumReservation = max(1, limit / 5)
        for predicate in [
            { (item: FeedItem) in item.isPodcast },
            { (item: FeedItem) in item.isYouTube },
            { (item: FeedItem) in item.isForum },
        ] {
            var admitted = 0
            for item in uniqueItems where admitted < perMediumReservation {
                guard predicate(item) else { continue }
                let provider = registerProvider(for: item)
                guard providerCounts[provider, default: 0] < initialPerSource,
                      selected.count < limit else { continue }
                selected.append(item)
                selectedIDs.insert(item.id)
                providerCounts[provider, default: 0] += 1
                admitted += 1
            }
        }

        for item in uniqueItems where !selectedIDs.contains(item.id) {
            let provider = registerProvider(for: item)
            if providerCounts[provider, default: 0] < initialPerSource,
               selected.count < limit {
                selected.append(item)
                selectedIDs.insert(item.id)
                providerCounts[provider, default: 0] += 1
            } else {
                overflowByProvider[provider, default: []].append(item)
            }
        }

        // Source URLs originate in remote feeds and can repeat in malformed or
        // partially merged data. Build the index incrementally so a repeated
        // provider never turns a recoverable refresh into a duplicate-key trap.
        var overflowIndices: [String: Int] = [:]
        overflowIndices.reserveCapacity(providerOrder.count)
        for provider in providerOrder {
            overflowIndices[provider] = 0
        }
        while selected.count < limit {
            var appended = false
            for provider in providerOrder where selected.count < limit {
                let index = overflowIndices[provider, default: 0]
                guard let overflow = overflowByProvider[provider], index < overflow.count else { continue }
                selected.append(overflow[index])
                overflowIndices[provider] = index + 1
                appended = true
            }
            if !appended { break }
        }
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
        setRegionEnabled(
            region,
            enabled: registry.status(of: SourceRegistry.regionKey(region)) != .on
        )
    }

    func setRegionEnabled(_ region: String, enabled: Bool) {
        // Match exact region + sub-regions (e.g. "countries/brazil/sao-paulo")
        let sourceURLs = registry.sourceURLs(inRegionTree: region)
        registry.setRegionEnabled(region, enabled: enabled)
        if enabled {
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
        setAllCountriesEnabled(!registry.isAnyCountryEnabled)
    }

    func setAllCountriesEnabled(_ enabled: Bool) {
        registry.setAllCountriesEnabled(enabled)
        if !enabled {
            // Disabling all countries — purge their items from the reservoir
            // and all visible items. Unlike individual toggleRegion, this
            // affects every country at once, so a full flush is appropriate.
            let countryRegions = Set(registry.sources
                .filter { $0.isCountryFeed }
                .map(\.region))
            reservoir.removeRegions(countryRegions)
            applyUpdate(.replace(applyFilters(reservoir.visibleItems)))
        } else {
            // Enabling all countries — flush and reload from SQLite so
            // country content appears immediately.
            resetWhatsNewBaseline()
            scheduleSourceEnablementRefresh()
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

    // MARK: - Source view and personal source collections

    func sourceReference(for item: FeedItem) -> SourceReference {
        if let source = registry.source(forURL: item.sourceURL) {
            return SourceReference(source: source)
        }
        let kind: MediaKind = item.isYouTube ? .video : (item.isPodcast ? .audio : (item.isForum ? .forum : .text))
        return SourceReference(
            title: item.sourceTitle,
            feedURL: item.sourceURL,
            category: item.category,
            region: item.region,
            mediaKind: kind,
            language: item.language
        )
    }

    func sourceReference(for member: SourceCollectionMember) -> SourceReference {
        if let source = registry.source(forURL: member.sourceURL) {
            return SourceReference(source: source)
        }
        return SourceReference(
            title: member.title,
            feedURL: member.sourceURL,
            mediaKind: member.mediaKind
        )
    }

    /// All locally retained posts for a source, without date, read-state,
    /// enablement, or normal-feed filters.
    func sourceContentFromCache(_ source: SourceReference) async -> [FeedItem] {
        await cachedSourceItems(sourceURLs: [source.feedURL], limit: nil)
    }

    /// Explicit source intent overrides default dormancy for this request only.
    /// It does not subscribe/enable the source. The endpoint's complete current
    /// payload is persisted and merged with any older local history.
    func loadSourceContent(_ source: SourceReference) async -> SourceContentResult {
        await recordExplicitSourceAccess(source.feedURL)
        let resolved = registry.source(forURL: source.feedURL) ?? source.feedSource
        let fetchResult = await fetcher.fetch(resolved)
        if !fetchResult.items.isEmpty {
            _ = await persistFetchedItems(fetchResult.items)
        }
        let items = await sourceContentFromCache(source)
        return SourceContentResult(
            items: items,
            fetchStatus: fetchResult.status,
            fetchedItemCount: fetchResult.items.count
        )
    }

    func allSourceCollections() async throws -> [SourceCollection] {
        try await sourceCollectionStore.allCollections()
    }

    @discardableResult
    func createSourceCollection(name: String) async throws -> Int64 {
        try await sourceCollectionStore.createCollection(name: name)
    }

    func renameSourceCollection(id: Int64, name: String) async throws {
        try await sourceCollectionStore.renameCollection(id: id, name: name)
    }

    func deleteSourceCollection(id: Int64) async throws {
        try await sourceCollectionStore.deleteCollection(id: id)
    }

    func reorderSourceCollections(ids: [Int64]) async throws {
        try await sourceCollectionStore.reorderCollections(ids: ids)
    }

    func sourceCollectionMembers(collectionID: Int64) async throws -> [SourceCollectionMember] {
        try await sourceCollectionStore.members(collectionID: collectionID)
    }

    func addSource(_ source: SourceReference, toCollectionID id: Int64) async throws {
        try await sourceCollectionStore.add(source, to: id)
    }

    @discardableResult
    func addSourceURLs(_ sourceURLs: [String], toCollectionID id: Int64) async throws -> Int {
        var seen = Set<String>()
        var references: [SourceReference] = []
        for sourceURL in sourceURLs {
            let normalized = OPMLParser.normalizeURL(sourceURL)
            guard seen.insert(normalized).inserted else { continue }
            guard let source = registry.source(forURL: normalized) else {
                Log.import_.info("Skipping URL not found in registry: \(sourceURL)")
                continue
            }
            references.append(SourceReference(source: source))
        }
        try await sourceCollectionStore.add(references, to: id)
        return references.count
    }

    @discardableResult
    func migrateImportedSourceCollections() async throws -> Int {
        let importedSources = registry.sources.filter { $0.region == "imported" }
        return try await sourceCollectionStore.migrateImportedCategoriesToCollections(importedSources)
    }

    func removeSource(_ sourceURL: String, fromCollectionID id: Int64) async throws {
        try await sourceCollectionStore.remove(sourceURL: sourceURL, from: id)
    }

    func reorderSourceCollectionMembers(collectionID: Int64, sourceURLs: [String]) async throws {
        try await sourceCollectionStore.reorderMembers(collectionID: collectionID, sourceURLs: sourceURLs)
    }

    func sourceCollectionIDs(containing sourceURL: String) async throws -> Set<Int64> {
        try await sourceCollectionStore.collectionIDs(containing: sourceURL)
    }

    /// A collection is a reusable live filter over source identities. Opening
    /// it refreshes every member, then merges current endpoint payloads with
    /// locally retained history. Unlike a single-source inspection it does not
    /// grant every member extended retention, preventing large playlists from
    /// silently pinning an unbounded database.
    func loadSourceCollectionContent(collectionID: Int64) async throws -> SourceCollectionContentResult {
        let members = try await sourceCollectionStore.members(collectionID: collectionID)
        let sources = members.map { member in
            registry.source(forURL: member.sourceURL) ?? sourceReference(for: member).feedSource
        }
        guard !sources.isEmpty else {
            return SourceCollectionContentResult(items: [], sourceCount: 0, failedSourceCount: 0, emptySourceCount: 0)
        }
        let batch = await fetcher.fetchAll(sources, maxConcurrent: min(8, sources.count))
        if !batch.items.isEmpty {
            _ = await persistFetchedItems(batch.items)
        }
        let items = await cachedSourceItems(sourceURLs: members.map(\.sourceURL), limit: 1_000)
        return SourceCollectionContentResult(
            items: items,
            sourceCount: sources.count,
            failedSourceCount: batch.failedSourceCount,
            emptySourceCount: batch.emptySourceCount
        )
    }

    func recordExplicitSourceAccess(_ sourceURL: String) async {
        do {
            try await db.write { db in
                try db.execute(sql: """
                    INSERT INTO source_history_access (source_url, last_accessed_at)
                    VALUES (?, ?)
                    ON CONFLICT(source_url) DO UPDATE SET
                        last_accessed_at = excluded.last_accessed_at
                    """, arguments: [
                        OPMLParser.normalizeURL(sourceURL),
                        Int(Date().timeIntervalSince1970),
                    ])
            }
        } catch {
            Log.db.warning("Could not retain explicit source history: \(error.localizedDescription)")
        }
    }

    private func cachedSourceItems(sourceURLs: [String], limit: Int?) async -> [FeedItem] {
        let normalized = Array(Set(sourceURLs.map(OPMLParser.normalizeURL)))
        guard !normalized.isEmpty else { return [] }
        let records: [FeedItemRecord] = (try? await db.read { db in
            var result: [FeedItemRecord] = []
            for start in stride(from: 0, to: normalized.count, by: 400) {
                let chunk = Array(normalized[start..<min(start + 400, normalized.count)])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                result.append(contentsOf: try FeedItemRecord.fetchAll(db, sql: """
                    SELECT * FROM feed_item
                    WHERE source_url IN (\(placeholders))
                    ORDER BY published_at DESC
                    """, arguments: StatementArguments(chunk)))
            }
            let sorted = result.sorted { $0.publishedAt > $1.publishedAt }
            if let limit { return Array(sorted.prefix(limit)) }
            return sorted
        }) ?? []
        let bookmarked = userRepo.allBookmarkedItemIDs()
        return records.map { record in
            record.toFeedItem().stamped(
                readItemIDs: record.isRead ? [record.id] : [],
                bookmarkItemIDs: bookmarked.contains(record.id) ? [record.id] : []
            )
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
                          AND NOT EXISTS (
                              SELECT 1 FROM source_history_access sha
                              WHERE sha.source_url = feed_item.source_url
                                AND sha.last_accessed_at >= ?
                          )
                        LIMIT 500
                    )
                """, arguments: [cutoff, cutoff])
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
        let normalizedURLs = Array(Set(sourceURLs.map(OPMLParser.normalizeURL)))
        guard !normalizedURLs.isEmpty else { return }
        do {
            let removedIDs: [String] = try await db.write { db in
                // Find all sources that exceed the cap and collect IDs to delete
                let placeholders = normalizedURLs.map { _ in "?" }.joined(separator: ",")
                let retentionCutoff = Int(Date().addingTimeInterval(-2_592_000).timeIntervalSince1970)
                let args = StatementArguments(normalizedURLs)

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
                          AND NOT EXISTS (
                              SELECT 1 FROM source_history_access sha
                              WHERE sha.source_url = fi.source_url
                                AND sha.last_accessed_at >= \(retentionCutoff)
                          )
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
                      AND NOT EXISTS (
                          SELECT 1 FROM source_history_access sha
                          WHERE sha.source_url = feed_item.source_url
                            AND sha.last_accessed_at >= ?
                      )
                """, arguments: [
                    Int(Date().addingTimeInterval(-2592000).timeIntervalSince1970),
                    Int(Date().addingTimeInterval(-2592000).timeIntervalSince1970),
                ])
                try db.execute(sql: "DELETE FROM source_history_access WHERE last_accessed_at < ?",
                               arguments: [Int(Date().addingTimeInterval(-2592000).timeIntervalSince1970)])
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
        refreshWhatsNew(shouldBoost: false)
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
        // Older RSSFetcher builds copied the OPML source language into every
        // item. That made FeedStore treat inherited metadata as authoritative,
        // so clearly non-English content could remain tagged "en". Clear the
        // obvious script mismatches; nil languages are excluded by an active
        // language filter and will be detected correctly when fetched again.
        migrator.registerMigration("v8_clear_mislabeled_english_items") { db in
            let scriptRanges = [
                "А-Яа-яЁёІіЇїЄєҐґ", // Cyrillic
                "؀-ۿ",             // Arabic
                "֐-׿",             // Hebrew
                "Ͱ-Ͽ",             // Greek
                "一-龿",            // Han
                "ぁ-ゟ",             // Hiragana
                "゠-ヿ",             // Katakana
                "가-힣",            // Hangul
                "ऀ-ॿ",             // Devanagari
                "ก-๿",             // Thai
                "က-႟",             // Myanmar
                "԰-֏",             // Armenian
                "ሀ-፼",             // Ethiopic
            ]
            let scriptClauses = scriptRanges.map { range in
                "(title || ' ' || excerpt) GLOB '*[\(range)]*[\(range)]*'"
            }.joined(separator: " OR ")
            try db.execute(sql: """
                UPDATE feed_item
                SET language = NULL
                WHERE language = 'en'
                  AND (\(scriptClauses))
            """)
        }
        // Remove values that older media extraction treated as images even
        // though ImageIO cannot render them. A later fetch can repair these
        // rows through persistFetchedItems without disturbing user state.
        migrator.registerMigration("v9_clear_invalid_image_urls") { db in
            try db.execute(sql: """
                UPDATE feed_item
                SET image_url = NULL
                WHERE image_url IS NOT NULL
                  AND (
                    lower(image_url) LIKE 'data:image/svg%'
                    OR lower(image_url) LIKE '%.svg%'
                    OR lower(image_url) LIKE '%.mp3%'
                    OR lower(image_url) LIKE '%.m4a%'
                    OR lower(image_url) LIKE '%youtube.com/embed/%'
                    OR lower(image_url) LIKE '%/tracker/%'
                    OR lower(image_url) LIKE '%count.gif%'
                    OR lower(image_url) LIKE '%track-rss-story%'
                  )
            """)
        }
        migrator.registerMigration("v10_fix_azerbaijani_language") { db in
            try db.execute(sql: """
                UPDATE feed_item
                SET language = 'az'
                WHERE language = 'en'
                  AND (title || ' ' || excerpt) GLOB '*[Əə]*'
            """)
        }
        migrator.registerMigration("v11_fix_distinctive_script_languages") { db in
            let scripts: [(language: String, ranges: [String])] = [
                ("bn", ["ঀ-৿"]),
                ("hy", ["԰-֏"]),
                ("ka", ["Ⴀ-ჿ"]),
                ("th", ["ก-๿"]),
                ("ko", ["가-힣"]),
                ("he", ["֐-׿"]),
                ("el", ["Ͱ-Ͽ"]),
                ("ja", ["ぁ-ゟ", "゠-ヿ"]),
                ("zh", ["㐀-䶿", "一-鿿"]),
            ]
            for script in scripts {
                let clauses = script.ranges.map { range in
                    "(title || ' ' || excerpt) GLOB '*[\(range)]*[\(range)]*'"
                }.joined(separator: " OR ")
                try db.execute(sql: """
                    UPDATE feed_item
                    SET language = ?
                    WHERE (language IS NULL OR language = 'en')
                      AND (\(clauses))
                """, arguments: [script.language])
            }
        }
        // v11 treated any two Han characters as Chinese. Re-evaluate those
        // rows from the full title and excerpt so English text quoting a name
        // such as "金萱", and Japanese text using kanji, leave the ZH feed.
        migrator.registerMigration("v12_reclassify_han_language") { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, title, excerpt FROM feed_item WHERE language = 'zh'"
            )
            let inputs = rows.map { row in
                LanguageDetectionInput(
                    title: row["title"],
                    excerpt: row["excerpt"],
                    explicitLanguage: nil
                )
            }
            let resolved = Self.detectLanguages(inputs)
            for (row, language) in zip(rows, resolved) {
                guard let language, language != "zh" else { continue }
                let id: String = row["id"]
                try db.execute(
                    sql: "UPDATE feed_item SET language = ? WHERE id = ?",
                    arguments: [language, id]
                )
            }
        }
        // Google News search feeds are collection endpoints, not publishers.
        // Older rows discarded the item-level <source>, but Google also appends
        // the publisher to article titles, so recover it for display/fairness.
        migrator.registerMigration("v13_recover_google_news_publishers") { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, title
                    FROM feed_item
                    WHERE source_url LIKE '%news.google.com%'
                      AND source_title LIKE 'Candidate:%'
                """
            )
            for row in rows {
                let title: String = row["title"]
                guard let publisher = Self.googleNewsPublisher(fromArticleTitle: title) else { continue }
                let id: String = row["id"]
                try db.execute(
                    sql: "UPDATE feed_item SET source_title = ? WHERE id = ?",
                    arguments: [publisher, id]
                )
            }
        }
        migrator.registerMigration("v14_clear_google_news_channel_artwork") { db in
            try db.execute(sql: """
                UPDATE feed_item
                SET image_url = NULL
                WHERE source_url LIKE '%news.google.com%'
                  AND image_url = 'https://lh3.googleusercontent.com/-DR60l-K8vnyi99NZovm9HlXyZwQ85GMDxiwJWzoasZYCUrPuUM_P_4Rb7ei03j-0nRs0c4F=w256'
            """)
        }
        migrator.registerMigration("v15_remove_candidate_display_names") { db in
            try db.execute(sql: """
                UPDATE feed_item
                SET source_title = 'Google News'
                WHERE source_url LIKE '%news.google.com%'
                  AND source_title LIKE 'Candidate:%'
            """)
        }
        // Earlier builds turned escaped CDATA titles into the literal
        // placeholder "Untitled". Remove only unsaved cache rows; bookmarks
        // remain intact and the corrected parser will refill fresh cards.
        migrator.registerMigration("v16_remove_unsaved_placeholder_titles") { db in
            try db.execute(sql: """
                DELETE FROM feed_item
                WHERE lower(trim(title)) = 'untitled'
                  AND id NOT IN (SELECT item_id FROM bookmark_item)
            """)
        }
        // YouTube channel metadata can claim English even when the item title
        // is clearly Khmer. Reclassify cached rows so an English-only filter
        // cannot surface them before the channel is fetched again.
        migrator.registerMigration("v17_fix_khmer_language") { db in
            try db.execute(sql: """
                UPDATE feed_item
                SET language = 'km'
                WHERE language = 'en'
                  AND (title || ' ' || excerpt) GLOB '*[ក-៙]*[ក-៙]*'
            """)
        }
        migrator.registerMigration("v18_source_history_access") { db in
            try db.create(table: "source_history_access") { t in
                t.primaryKey("source_url", .text)
                t.column("last_accessed_at", .integer).notNull()
            }
            try db.create(index: "idx_source_history_access_date",
                          on: "source_history_access", columns: ["last_accessed_at"])
        }
        try migrator.migrate(db)
    }
}

struct SourceContentResult: Equatable, Sendable {
    let items: [FeedItem]
    let fetchStatus: FeedFetchStatus
    let fetchedItemCount: Int
}

struct SourceCollectionContentResult: Equatable, Sendable {
    let items: [FeedItem]
    let sourceCount: Int
    let failedSourceCount: Int
    let emptySourceCount: Int
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
        let cleanedSourceTitle = FeedTextSanitizer.sanitizedHTMLText(sourceTitle)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedTitle = FeedTextSanitizer.sanitizedHTMLText(title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedExcerpt = FeedTextSanitizer.sanitizedHTMLText(excerpt)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return FeedItem(
            id: id,
            sourceTitle: cleanedSourceTitle.isEmpty ? sourceTitle : cleanedSourceTitle,
            sourceURL: sourceURL,
            category: category,
            title: cleanedTitle.isEmpty ? title : cleanedTitle,
            excerpt: cleanedExcerpt,
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
