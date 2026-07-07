import Foundation
import Observation

enum FeedLoadingState {
    case idle
    case initial
    case refreshing
    case loadingMore
}

@MainActor
@Observable
final class FeedLoader {
    // MARK: - Public state (observed by views)
    private(set) var items: [FeedItem] = []
    private(set) var loadingState: FeedLoadingState = .idle
    private(set) var selectedCategory: String? = nil

    /// Group items into date-based sections for section headers
    struct DateSection: Identifiable {
        var id: String { title }  // stable across recomputes — prevents flicker
        let title: String
        let items: [FeedItem]
    }

    private var cachedDateSections: [DateSection] = []
    private var cachedDateSectionVersion = -1
    private var itemVersion = 0  // bumped only when visible items[] change
    private var whatsNewVersion = 0  // bumped when reservoir gets new content (background fetch)
    private var filterVersion = 0  // bumped whenever filters/search change

    var dateSections: [DateSection] {
        if itemVersion != cachedDateSectionVersion {
            cachedDateSections = computeDateSections()
            cachedDateSectionVersion = itemVersion
        }
        return cachedDateSections
    }

    private func computeDateSections() -> [DateSection] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredItems) { item -> String in
            if calendar.isDateInToday(item.publishedAt) { return "Today" }
            if calendar.isDateInYesterday(item.publishedAt) { return "Yesterday" }
            let days = calendar.dateComponents([.day], from: item.publishedAt, to: Date()).day ?? 0
            if days < 7 { return "This Week" }
            return "Earlier"
        }
        // Today always first; remaining sections shuffled so "Earlier" content
        // occasionally appears higher instead of always buried at the bottom.
        let order = ["Today"] + ["Yesterday", "This Week", "Earlier"].shuffled()
        return order.compactMap { title in
            grouped[title].map { DateSection(title: title, items: $0) }
        }
    }

    /// Layout mode: card or compact list
    enum FeedLayout { case card, list }
    var layout: FeedLayout = .card

    /// Content type filter
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

    func selectContentType(_ type: ContentType) {
        selectedContentType = (selectedContentType == type) ? .all : type
        UserDefaults.standard.set(selectedContentType.rawValue, forKey: "filterContentType")
        rebuildForFilter()
    }

    /// Mood filter
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

        func matches(_ title: String) -> Bool {
            let lower = title.lowercased()
            switch self {
            case .all: return true
            case .serious:
                return lower.contains("crisis") || lower.contains("war") || lower.contains("death") ||
                       lower.contains("killed") || lower.contains("attack") || lower.contains("emergency") ||
                       lower.contains("ban") || lower.contains("ruling") || lower.contains("court")
            case .fun:
                return lower.contains("fun") || lower.contains("amazing") || lower.contains("incredible") ||
                       lower.contains("wow") || lower.contains("hilarious") || lower.contains("funny") ||
                       lower.contains("adorable") || lower.contains("genius") || lower.contains("brilliant")
            case .technical:
                return lower.contains("ai") || lower.contains("code") || lower.contains("data") ||
                       lower.contains("algorithm") || lower.contains("startup") || lower.contains("tech") ||
                       lower.contains("software") || lower.contains("hardware") || lower.contains("api") ||
                       lower.contains("quantum") || lower.contains("robot") || lower.contains("chip")
            case .inspiring:
                return lower.contains("discovered") || lower.contains("breakthrough") || lower.contains("solved") ||
                       lower.contains("cure") || lower.contains("hope") || lower.contains("inspiring") ||
                       lower.contains("hero") || lower.contains("changed") || lower.contains("revolutionary")
            }
        }
    }

    var selectedMood: MoodFilter = .all

    func selectMood(_ mood: MoodFilter) {
        selectedMood = (selectedMood == mood) ? .all : mood
        UserDefaults.standard.set(selectedMood.rawValue, forKey: "filterMood")
        rebuildForFilter()
    }

    /// Search query for filtering by title and excerpt
    var searchQuery = ""

    /// Called by the view when searchQuery changes — triggers filter rebuild
    func searchQueryChanged() {
        filterVersion &+= 1
        rebuildForFilter()
    }

    /// Items filtered by selected mood, category, AND search query — CACHED
    private var cachedFilteredItems: [FeedItem] = []
    private var cachedFilteredItemsVersion = -1
    private var cachedFilteredItemsFilterVersion = -1

    var filteredItems: [FeedItem] {
        if itemVersion != cachedFilteredItemsVersion || filterVersion != cachedFilteredItemsFilterVersion {
            cachedFilteredItems = computeFilteredItems()
            cachedFilteredItemsVersion = itemVersion
            cachedFilteredItemsFilterVersion = filterVersion
        }
        return cachedFilteredItems
    }

    private func computeFilteredItems() -> [FeedItem] {
        var result = items
        if selectedMood != .all {
            result = result.filter { selectedMood.matches($0.title) }
        }
        if let category = selectedCategory {
            result = result.filter { $0.category.lowercased() == category.lowercased() }
        }
        if selectedContentType != .all {
            result = result.filter { selectedContentType.matches($0) }
        }
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(query) ||
                $0.excerpt.localizedCaseInsensitiveContains(query)
            }
            let q = query.lowercased()
            result.sort { a, b in
                let scoreA = searchScore(a, q); let scoreB = searchScore(b, q)
                return scoreA > scoreB
            }
        }
        return result
    }

    private func searchScore(_ item: FeedItem, _ q: String) -> Int {
        let t = item.title.lowercased(); let e = item.excerpt.lowercased()
        if t == q { return 100 }; if t.hasPrefix(q) { return 80 }
        if t.contains(q) { return 60 }; if e.contains(q) { return 30 }
        return 10
    }

    /// Number of unique item IDs tracked (dedup count)
    var loadedIDsCount: Int { loadedIDs.count }

    /// When the feed was last refreshed (nil = never)
    private(set) var lastRefreshDate: Date?

    // MARK: - Persistence

    func buildState() -> FeedState {
        FeedState(
            readItemIDs: Array(readItemIDs),
            bookmarkedIDs: Array(bookmarkedIDs),
            disabledSourceIDs: Array(disabledSourceIDs),
            disabledRegions: Array(disabledRegions),
            sources: sources,
            lastRefreshDate: lastRefreshDate,
            streakCount: UserDefaults.standard.integer(forKey: "streakCount"),
            lastOpenDate: UserDefaults.standard.double(forKey: "lastOpenDate"),
            readTimestamps: readTimestamps,
            clickedSourceURLs: Array(clickedSourceURLs)
        )
    }

    func restoreState(from state: FeedState) {
        readItemIDs = Set(state.readItemIDs)
        readTimestamps = state.readTimestamps
        bookmarkedIDs = Set(state.bookmarkedIDs)
        disabledSourceIDs = Set(state.disabledSourceIDs)
        disabledRegions = Set(state.disabledRegions)
        if !state.sources.isEmpty {
            sources = state.sources
            sourceCount = sources.count
        }
        lastRefreshDate = state.lastRefreshDate
        clickedSourceURLs = Set(state.clickedSourceURLs)
    }

    /// Build a FeedState that INCLUDES cached articles for instant cold launch
    func buildStateWithItems() -> FeedState {
        var state = buildState()
        let allItems = (items + reservoir).sorted { $0.publishedAt > $1.publishedAt }
        state.cachedItems = Array(allItems.prefix(200))  // cap at 200 most recent
        return state
    }

    func saveNow() {
        PersistenceManager.shared.save(buildState())
    }

    /// Per-source health tracking
    struct SourceHealth {
        var lastFetchDate: Date?
        var consecutiveFailures: Int = 0
        var lastArticleCount: Int = 0
        var isStale: Bool { consecutiveFailures >= 3 }
    }
    private(set) var sourceHealth: [String: SourceHealth] = [:]

    func healthFor(_ source: FeedSource) -> SourceHealth {
        sourceHealth[source.url] ?? SourceHealth()
    }

    private func updateSourceHealth(failedSources: Int, totalSources: Int, totalItems: Int) {
        let now = Date()
        for source in enabledSources {
            var health = sourceHealth[source.url] ?? SourceHealth()
            health.lastFetchDate = now
            health.lastArticleCount = totalItems / max(totalSources, 1)
            if failedSources > 0 && totalItems == 0 {
                health.consecutiveFailures += 1
            } else {
                health.consecutiveFailures = 0
            }
            sourceHealth[source.url] = health
        }
    }

    /// Available categories from global (non-country) sources only.
    /// Country categories must not mix with global topic categories.
    var availableCategories: [String] {
        let cats = Set(sources
            .filter { $0.region == "global" }
            .map(\.category))
            .sorted()
        return cats
    }

    // MARK: - Country feeds

    var availableCountries: [Country] {
        let grouped = Dictionary(grouping: sources, by: \.region)
        return grouped
            .filter { $0.key.hasPrefix("countries/") }
            .compactMap { region, feeds -> Country? in
                let slug = region.replacingOccurrences(of: "countries/", with: "")
                let categories = Array(Set(feeds.map(\.category))).sorted()
                return Country(
                    region: region,
                    name: CountryStore.countryName(for: slug),
                    flag: CountryStore.countryFlag(for: slug),
                    feedCount: feeds.count,
                    categories: categories
                )
            }
            .sorted { $0.name < $1.name }
    }

    func countryFeeds(for region: String) -> [FeedSource] {
        sources
            .filter { $0.region == region }
            .sorted { $0.category < $1.category || ($0.category == $1.category && $0.title < $1.title) }
    }

    func toggleRegion(_ region: String) {
        if disabledRegions.contains(region) {
            disabledRegions.remove(region)
        } else {
            disabledRegions.insert(region)
        }
        rebuildAfterRegionToggle()
        PersistenceManager.shared.save(buildState())
    }

    func isRegionEnabled(_ region: String) -> Bool {
        !disabledRegions.contains(region)
    }

    func toggleAllCountries() {
        let allCountryRegions = Set(sources
            .filter { $0.isCountryFeed }
            .map(\.region))
        let anyEnabled = allCountryRegions.contains { !disabledRegions.contains($0) }
        if anyEnabled {
            disabledRegions.formUnion(allCountryRegions)
        } else {
            disabledRegions.subtract(allCountryRegions)
        }
        rebuildAfterRegionToggle()
        PersistenceManager.shared.save(buildState())
    }

    var isAnyCountryEnabled: Bool {
        sources.contains { $0.isCountryFeed && !disabledRegions.contains($0.region) }
    }

    // MARK: - Global feeds toggle

    var isGlobalFeedsEnabled: Bool {
        !disabledRegions.contains("global")
    }

    func toggleGlobalFeeds() {
        if disabledRegions.contains("global") {
            disabledRegions.remove("global")
        } else {
            disabledRegions.insert("global")
        }
        rebuildAfterRegionToggle()
        PersistenceManager.shared.save(buildState())
    }

    /// Track which items have been opened, with timestamps for cleanup
    var readItemIDs: Set<String> = []
    var readTimestamps: [String: Date] = [:]

    func markAsRead(_ itemID: String) {
        readItemIDs.insert(itemID)
        readTimestamps[itemID] = Date()
        // Track clicked source for "What's New"
        if let item = (items + reservoir).first(where: { $0.id == itemID }) {
            clickedSourceURLs.insert(item.sourceURL)
        }
        capReadIDsIfNeeded()
        PersistenceManager.shared.save(buildState())
    }

    /// Source URLs the user has clicked at least once
    var clickedSourceURLs: Set<String> = []

    /// Item IDs already known at launch — "What's New" only shows items arriving AFTER this snapshot
    private var whatsNewBaselineIDs: Set<String> = []

    /// "What's New" — only items with images, not in memory at launch, unread, deduped. CACHED.
    private var cachedWhatsNew: [FeedItem] = []
    private var cachedWhatsNewVersion = -1
    private var cachedWhatsNewReadVersion = -1
    private var whatsNewPendingQueue: [FeedItem] = []

    /// Set by WhatsNewCarousel to prevent visible reordering while user is watching.
    var whatsNewVisible = false

    var whatIsNewItems: [FeedItem] {
        let readVersion = readItemIDs.count
        let effectiveVersion = itemVersion &+ whatsNewVersion  // either visible or reservoir changed
        if effectiveVersion != cachedWhatsNewVersion || readVersion != cachedWhatsNewReadVersion {
            let fresh = computeWhatsNewItems()
            if whatsNewVisible && !cachedWhatsNew.isEmpty {
                // User is watching — queue new items, keep showing current content
                let newIDs = Set(fresh.map(\.id))
                let currentIDs = Set(cachedWhatsNew.map(\.id))
                let added = fresh.filter { !currentIDs.contains($0.id) }
                if !added.isEmpty {
                    whatsNewPendingQueue.append(contentsOf: added)
                }
                // Remove items that disappeared from fresh (read, filtered out)
                cachedWhatsNew = cachedWhatsNew.filter { newIDs.contains($0.id) }
            } else {
                // Not visible — apply pending queue immediately
                if !whatsNewPendingQueue.isEmpty {
                    var merged = fresh
                    merged.append(contentsOf: whatsNewPendingQueue)
                    whatsNewPendingQueue.removeAll()
                    var seen = Set<String>()
                    cachedWhatsNew = merged.filter { seen.insert($0.id).inserted }.shuffled()
                } else {
                    cachedWhatsNew = fresh
                }
            }
            cachedWhatsNewVersion = effectiveVersion
            cachedWhatsNewReadVersion = readVersion
        }
        return cachedWhatsNew
    }

    /// Flush pending items into the carousel — call when user stops watching.
    func flushWhatsNewQueue() {
        guard !whatsNewPendingQueue.isEmpty else { return }
        whatsNewPendingQueue.removeAll()
        cachedWhatsNewVersion = -1  // force recompute on next access
        cachedWhatsNewReadVersion = -1
    }

    private func computeWhatsNewItems() -> [FeedItem] {
        let pool = (items + reservoir)
            .filter { item in
                !readItemIDs.contains(item.id)
                && !whatsNewBaselineIDs.contains(item.id)
                && item.bestImageURL != nil
            }
        var seen = Set<String>()
        let unique = pool.filter { seen.insert($0.id).inserted }
        let sorted = unique.sorted { $0.publishedAt > $1.publishedAt }

        if !clickedSourceURLs.isEmpty {
            let fromClicked = sorted.filter { clickedSourceURLs.contains($0.sourceURL) }
            if !fromClicked.isEmpty { return fromClicked.shuffled() }
        }
        return Array(sorted.prefix(10)).shuffled()
    }

    func markAllAsRead() {
        readItemIDs.formUnion(items.map(\.id))
        capReadIDsIfNeeded()
        PersistenceManager.shared.save(buildState())
    }

    private func capReadIDsIfNeeded() {
        // Note: Set has no order. For a prototype, just trim to a cap.
        // Items exceeding the cap are oldest (by insertion order approximation via Array conversion).
        if readItemIDs.count > Self.maxLoadedIDs {
            let keep = Array(readItemIDs).suffix(Self.maxLoadedIDs)
            readItemIDs = Set(keep)
        }
        if bookmarkedIDs.count > Self.maxLoadedIDs {
            let keep = Array(bookmarkedIDs).suffix(Self.maxLoadedIDs)
            bookmarkedIDs = Set(keep)
        }
    }

    func isRead(_ itemID: String) -> Bool {
        readItemIDs.contains(itemID)
    }

    /// Bookmarked item IDs
    var bookmarkedIDs: Set<String> = []

    /// Disabled source URLs — persisted concept (in-memory for prototype)
    var disabledSourceIDs: Set<String> = []

    /// Disabled country regions — persisted. When a region is disabled, all its feeds
    /// are excluded from enabledSources regardless of per-source toggles.
    var disabledRegions: Set<String> = []

    /// Only enabled sources (respects both per-source and per-region toggles)
    var enabledSources: [FeedSource] {
        sources.filter { source in
            if disabledSourceIDs.contains(source.url) { return false }
            if disabledRegions.contains(source.region) { return false }
            return true
        }
    }

    func toggleSource(_ sourceURL: String) {
        if disabledSourceIDs.contains(sourceURL) {
            disabledSourceIDs.remove(sourceURL)
        } else {
            disabledSourceIDs.insert(sourceURL)
        }
        PersistenceManager.shared.save(buildState())
    }

    func isSourceEnabled(_ sourceURL: String) -> Bool {
        !disabledSourceIDs.contains(sourceURL)
    }

    func addSources(_ newSources: [FeedSource]) {
        sources = OPMLParser.deduplicateSources(sources + newSources)
        sourceCount = sources.count
    }

    func toggleBookmark(_ itemID: String) {
        if bookmarkedIDs.contains(itemID) {
            bookmarkedIDs.remove(itemID)
        } else {
            bookmarkedIDs.insert(itemID)
            capReadIDsIfNeeded()
        }
        PersistenceManager.shared.save(buildState())
    }

    func isBookmarked(_ itemID: String) -> Bool {
        bookmarkedIDs.contains(itemID)
    }

    /// Bookmarked items sorted by date
    var bookmarkedItems: [FeedItem] {
        items.filter { bookmarkedIDs.contains($0.id) }
            .sorted { $0.publishedAt > $1.publishedAt }
    }

    // Debug counters
    private(set) var opmlFileCount = 0
    private(set) var sourceCount = 0
    private(set) var invalidSourceCount = 0
    private(set) var opmlErrorCount = 0
    private(set) var duplicateSourceCount = 0
    private(set) var reservoirCount = 0
    private(set) var totalFetched = 0
    private(set) var totalDiscarded = 0
    private(set) var fetchErrorCount = 0
    private(set) var emptyFeedCount = 0
    private(set) var podcastSourceCount = 0
    private(set) var podcastItemCount = 0

    // MARK: - Internal state
    private let fetcher = RSSFetcher()
    private let prefetcher = ImagePrefetcher()
    let networkMonitor = NetworkMonitor()
    /// Whether to pre-download images before cards appear (default: true)
    var prefetchImages: Bool {
        get { UserDefaults.standard.object(forKey: "prefetchImages") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "prefetchImages") }
    }
    private(set) var sources: [FeedSource] = []
    private var reservoir: [FeedItem] = []
    private var loadedIDs: Set<String> = []
    private var loadedIDsInsertionOrder: [String] = []  // FIFO for precise trimming
    private(set) var currentVisibleIndex: Int = 0
    private var hasStarted = false
    private var retryCount = 0
    private var retryTask: Task<Void, Never>?
    private var filteredOutItems: [FeedItem] = []  // items excluded by active filter; restored when filter clears
    /// Items that have appeared on screen — used to deprioritize recently-seen content.
    /// Key = item ID, Value = when it first appeared in the visible window.
    private var surfacedItemTimestamps: [String: Date] = [:]
    /// Items surfaced within this window are pushed to the back of their bucket.
    private static let surfacedCooldown: TimeInterval = 1800  // 30 minutes
    /// Number of visible-window moves since last reservoir reshuffle.
    private var moveCountSinceReshuffle = 0
    /// Re-interleave the reservoir after this many moves to keep buried items rotating.
    private static let reshuffleInterval = 5
    private var hasActiveFilter: Bool {
        selectedCategory != nil || selectedMood != .all || selectedContentType != .all || !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Helpers

    /// Source-first interleave with type/category variety baked in.
    ///
    /// Algorithm (scalable to hundreds of sources):
    /// 1. Group items by source URL
    /// 2. Within each source: recency tiers → spread by type+category (inner interleave)
    /// 3. Assign per-source weights (more items → more round-robin slots, capped at 5)
    /// 4. Build weighted slot array, spread to avoid adjacent same-source slots
    /// 5. Round-robin through slots, 1 item per turn → no consecutive same-source items
    ///
    /// Result: source alternates every card, types and categories vary within each source's turn.
    private func interleave(_ items: [FeedItem]) -> [FeedItem] {
        guard items.count > 1 else { return items }

        // Step 1: Group by source
        var bySource: [String: [FeedItem]] = [:]
        for item in items {
            bySource[item.sourceURL, default: []].append(item)
        }

        // Single source: spread by type+category within it
        guard bySource.count > 1 else {
            return interleaveByTypeCategory(items)
        }

        // Step 2: Within each source — recency tiers, then spread by type+category
        let surfacedCutoff = Date().addingTimeInterval(-Self.surfacedCooldown)
        let staleCutoff = Date().addingTimeInterval(-86400)
        for key in bySource.keys {
            let bucket = bySource[key]!
            let surfacedIDs = Set(bucket.filter { item in
                guard let ts = surfacedItemTimestamps[item.id] else { return false }
                return ts > surfacedCutoff
            }.map(\.id))
            let staleIDs = Set(bucket.filter { item in
                !surfacedIDs.contains(item.id) && item.publishedAt < staleCutoff
            }.map(\.id))
            let recent = interleaveByTypeCategory(bucket.filter { !surfacedIDs.contains($0.id) && !staleIDs.contains($0.id) }.shuffled())
            let stale = interleaveByTypeCategory(bucket.filter { staleIDs.contains($0.id) }.shuffled())
            let surfaced = interleaveByTypeCategory(bucket.filter { surfacedIDs.contains($0.id) }.shuffled())
            bySource[key] = recent + stale + surfaced
        }

        // Step 3: Per-source weights — proportional to item count, capped at 5
        let minCount = max(1, bySource.values.map(\.count).min() ?? 1)
        let weights: [String: Int] = bySource.mapValues { min(5, max(1, $0.count / minCount)) }

        // Step 4: Build weighted slot array — each source appears `weight` times
        var slots: [String] = []
        for (sourceURL, srcItems) in bySource where !srcItems.isEmpty {
            let w = weights[sourceURL] ?? 1
            for _ in 0..<w { slots.append(sourceURL) }
        }
        // Spread identical slots so no same-source adjacency in the order
        slots = spreadSlots(slots)

        // Step 5: Round-robin through slots, 1 item per turn
        var result: [FeedItem] = []
        result.reserveCapacity(items.count)
        var indices: [String: Int] = Dictionary(uniqueKeysWithValues: bySource.keys.map { ($0, 0) })
        var added = true
        while added {
            added = false
            for sourceURL in slots {
                guard let list = bySource[sourceURL],
                      indices[sourceURL]! < list.count else { continue }
                result.append(list[indices[sourceURL]!])
                indices[sourceURL]! += 1
                added = true
            }
        }
        return result
    }

    /// Interleave items by type+category (inner diversity within a source).
    /// Groups by "type:category", shuffles each bucket, round-robins 1 item per turn.
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

    /// Spread slot entries so no two adjacent slots share the same value.
    /// Groups identical values, round-robins across groups.
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

    /// Rebuild items + reservoir when filters change so the feed shows matching content
    /// from the full dataset (not just the visible buffer).
    private func rebuildForFilter() {
        filterVersion &+= 1
        // Pool everything we have: visible items + reservoir + previously filtered-out
        let allItems = items + reservoir + filteredOutItems

        if hasActiveFilter {
            // Build filter predicate
            let predicate: (FeedItem) -> Bool = { item in
                let moodMatch = self.selectedMood == .all || self.selectedMood.matches(item.title)
                let catMatch: Bool
                if let cat = self.selectedCategory {
                    catMatch = item.category.lowercased() == cat.lowercased()
                } else {
                    catMatch = true
                }
                let q = self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                let searchMatch: Bool
                if q.isEmpty {
                    searchMatch = true
                } else {
                    searchMatch = item.title.localizedCaseInsensitiveContains(q)
                        || item.excerpt.localizedCaseInsensitiveContains(q)
                }
                let typeMatch = self.selectedContentType == .all || self.selectedContentType.matches(item)
                return moodMatch && catMatch && searchMatch && typeMatch
            }

            var matching: [FeedItem] = []
            var nonMatching: [FeedItem] = []
            for item in allItems {
                if predicate(item) { matching.append(item) } else { nonMatching.append(item) }
            }

            // Show first pageSize matches, rest go to reservoir
            let w = min(Self.pageSize, matching.count)
            items = Array(matching.prefix(w))
            reservoir = Array(matching.dropFirst(w))
            capReservoir()
            filteredOutItems = nonMatching
        } else {
            // Filter cleared: merge everything back, re-interleave for category variety
            let merged = interleave(allItems)
            let w = min(Self.pageSize, merged.count)
            items = Array(merged.prefix(w))
            reservoir = Array(merged.dropFirst(w))
            capReservoir()
            filteredOutItems = []
        }

        reservoirCount = reservoir.count
        itemVersion += 1
        markAsSurfaced(items)
    }

    /// Rebuild the visible feed immediately when regions are toggled.
    /// Items from disabled regions move to filteredOutItems and come back
    /// when the region is re-enabled — same as other filters.
    private func rebuildAfterRegionToggle() {
        // Map source URLs to their region for quick lookup
        let sourceRegionMap: [String: String] = Dictionary(
            sources.map { ($0.url, $0.region) },
            uniquingKeysWith: { first, _ in first }
        )

        // Pool everything
        let allItems = items + reservoir + filteredOutItems
        var enabled: [FeedItem] = []
        var disabled: [FeedItem] = []

        for item in allItems {
            let region = sourceRegionMap[item.sourceURL] ?? "global"
            if disabledRegions.contains(region) {
                disabled.append(item)
            } else {
                enabled.append(item)
            }
        }

        let interleaved = interleave(enabled)
        let w = min(Self.pageSize, interleaved.count)
        items = Array(interleaved.prefix(w))
        reservoir = Array(interleaved.dropFirst(w))
        capReservoir()
        filteredOutItems = disabled
        reservoirCount = reservoir.count
        itemVersion += 1
        markAsSurfaced(items)
    }

    // MARK: - Constants
    static let maxBuffer = 300
    static let pageSize = 20            // how many to show/move at a time
    static let loadMoreThreshold = 5    // when only N items remain visible, load more
    static let discardBatchSize = 50
    static let reservoirLowWatermark = 30  // fetch more when reserve drops below this
    static let safetyZoneRadius = 50
    static let maxLoadedIDs = 5000        // prevent unbounded memory growth
    static let maxReservoirSize = 500     // cap reservoir to avoid memory pressure

    // MARK: - Public methods

    func selectCategory(_ category: String?) {
        selectedCategory = (selectedCategory == category) ? nil : category
        UserDefaults.standard.set(selectedCategory, forKey: "filterCategory")
        rebuildForFilter()
    }

    /// Aggressive trim on memory warning — keep only visible + safety zone
    func emergencyTrim() {
        let safeCount = Self.safetyZoneRadius * 2
        if items.count > safeCount {
            let removed = items.count - safeCount
            items = Array(items.suffix(safeCount))
            totalDiscarded += removed
            itemVersion += 1
            print("[FeedLoader] Memory warning: trimmed \(removed) items, kept \(items.count)")
        }
        reservoir.removeAll()
        reservoirCount = 0
        filteredOutItems.removeAll()
        URLCache.shared.removeAllCachedResponses()
    }

    /// Shake-to-refresh: dump visible items, clear search, re-interleave reservoir, fetch new
    func shakeToRefresh() {
        // Clear search query
        searchQuery = ""
        guard !items.isEmpty || !reservoir.isEmpty else { return }
        // Mark all visible items as seen so they never come back
        readItemIDs.formUnion(items.map(\.id))
        reservoir.append(contentsOf: items)
        items.removeAll()
        currentVisibleIndex = 0
        reservoir = interleave(reservoir)
        let w = min(Self.pageSize, reservoir.count)
        items = Array(reservoir.prefix(w))
        reservoir.removeFirst(w)
        reservoirCount = reservoir.count
        itemVersion += 1
        markAsSurfaced(items)
        Task { await self.fetchFreshContent() }
    }

    /// Re-interleave all content for fresh variety — no network call.
    /// On app reopen: fetch new content in background WITHOUT disturbing visible items.
    /// The user left the app reading something — we must not reorder or replace their view.
    func refreshIfStale() async {
        guard !sources.isEmpty else { return }

        // Only re-interleave reservoir (not visible items!) for variety when user loads more
        if !reservoir.isEmpty {
            reservoir = interleave(reservoir)
            capReservoir()
            reservoirCount = reservoir.count
        }

        // Fetch new content in background
        let shouldFetch: Bool
        if let last = lastRefreshDate {
            shouldFetch = Date().timeIntervalSince(last) > 900 || items.count < 10
        } else {
            shouldFetch = true
        }
        guard shouldFetch else { return }
        await fetchFreshContent()
        PersistenceManager.shared.save(buildStateWithItems())
    }

    func clearAllFilters() {
        selectedCategory = nil
        selectedMood = .all
        selectedContentType = .all
        searchQuery = ""
        rebuildForFilter()
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        // Step 1: Restore persisted state off main thread — skeleton visible during I/O
        var cachedItems: [FeedItem] = []
        let saved = await Task.detached(priority: .userInitiated) {
            loadPersistedState()
        }.value
        if let saved {
            restoreState(from: saved)
            cachedItems = saved.cachedItems
        }

        networkMonitor.start()

        // Restore persisted filter selections
        if let cat = UserDefaults.standard.string(forKey: "filterCategory") { selectedCategory = cat }
        if let moodRaw = UserDefaults.standard.string(forKey: "filterMood"),
           let mood = MoodFilter(rawValue: moodRaw) { selectedMood = mood }
        if let typeRaw = UserDefaults.standard.string(forKey: "filterContentType"),
           let type = ContentType(rawValue: typeRaw) { selectedContentType = type }

        // Fetch weather in background (non-blocking)
        Task { await WeatherService.shared.fetch() }

        // Show cached content BEFORE any I/O — UI must be instant
        if !cachedItems.isEmpty {
            registerLoadedIDs(cachedItems.map(\.id))
            let interleaved = interleave(cachedItems)
            let w = min(Self.pageSize, interleaved.count)
            items = Array(interleaved.prefix(w))
            reservoir = Array(interleaved.dropFirst(w))
            capReservoir()
            reservoirCount = reservoir.count
            itemVersion += 1
            totalFetched = cachedItems.count
            loadingState = .idle  // content is visible — no skeleton!
            markAsSurfaced(items)
            // Prefetch images for visible + near-visible cached items
            let visibleCount = min(Self.pageSize, items.count)
            prefetchImagesIfNeeded(for: Array(items.prefix(visibleCount)))
        } else {
            loadingState = .initial
        }

        // Snapshot current IDs — "What's New" only shows items arriving AFTER this
        whatsNewBaselineIDs = loadedIDs

        // Step 2: Parse OPML (non-blocking for cached path — UI already live)
        let parseResult = await OPMLParser.parseAll()
        sources = parseResult.sources
        opmlFileCount = parseResult.fileCount
        print("[FeedLoader] Sources loaded: \(sources.count) total, \(availableCountries.count) countries")
        opmlErrorCount = parseResult.failedFileCount
        invalidSourceCount = parseResult.invalidSourceCount
        duplicateSourceCount = parseResult.duplicateSourceCount
        sourceCount = sources.count

        guard !sources.isEmpty else {
            loadingState = .idle
            return
        }

        // Step 3: Fetch fresh content
        if !cachedItems.isEmpty {
            // UI already live with cache → fetch in background, merge into reservoir
            Task { await self.fetchFreshContent() }
        } else {
            // No cache → progressive fetch, show content as it arrives
            await fetchAllContent()
            loadingState = .idle
            PersistenceManager.shared.save(buildStateWithItems())
            if items.isEmpty && fetchErrorCount > 0 {
                scheduleRetryIfAllFailed()
            }
        }
    }

    /// Fetch all enabled sources in chunks — used when there's NO cached content.
    private func fetchAllContent() async {
        let activeSources = interleaveSourcesByType(enabledSources)  // mixed types in early chunks
        let chunkSize = 20
        var allFetched = 0
        var allFailed = 0

        for chunkStart in stride(from: 0, to: activeSources.count, by: chunkSize) {
            let end = min(chunkStart + chunkSize, activeSources.count)
            let chunk = Array(activeSources[chunkStart..<end])
            let batch = await fetcher.fetchAll(chunk, maxConcurrent: 15)

            allFetched += batch.items.count
            allFailed += batch.failedSourceCount
            totalFetched = allFetched
            fetchErrorCount = allFailed
            emptyFeedCount += batch.emptySourceCount

            updateSourceHealth(failedSources: batch.failedSourceCount, totalSources: chunk.count, totalItems: batch.items.count)

            let actualNew = batch.items.filter { !loadedIDs.contains($0.id) }
            registerLoadedIDs(actualNew.map(\.id))

            // Track podcast items
            let newPodcastItems = actualNew.filter { $0.isPodcast }
            if !newPodcastItems.isEmpty { podcastItemCount += newPodcastItems.count }

            prefetchImagesIfNeeded(for: actualNew)

            // Just append date-sorted during loading — interleave once at the end
            reservoir.append(contentsOf: actualNew.sorted { $0.publishedAt > $1.publishedAt })
            capReservoir()

            // Show content immediately after first batch
            if items.isEmpty && !reservoir.isEmpty {
                let w = min(Self.pageSize, reservoir.count)
                items = Array(reservoir.prefix(w))
                reservoir.removeFirst(w)
                reservoirCount = reservoir.count
                itemVersion += 1
                markAsSurfaced(items)
            }
        }

        // Interleave once + top up visible window
        reservoir = interleave(reservoir)
        reservoirCount = reservoir.count
        if items.count < Self.pageSize && !reservoir.isEmpty {
            let needed = Self.pageSize - items.count
            let toMove = min(needed, reservoir.count)
            items.append(contentsOf: reservoir.prefix(toMove))
            reservoir.removeFirst(toMove)
            reservoirCount = reservoir.count
            itemVersion += 1
        }

        lastRefreshDate = .now
    }

    /// Fetch fresh content in background while cached items are already displayed.
    /// New items are merged into the reservoir so they appear as the user scrolls.
    private func fetchFreshContent() async {
        loadingState = .refreshing

        let activeSources = enabledSources.shuffled()
        let chunkSize = 20
        var allFetched = 0
        var allFailed = 0

        for chunkStart in stride(from: 0, to: activeSources.count, by: chunkSize) {
            let end = min(chunkStart + chunkSize, activeSources.count)
            let chunk = Array(activeSources[chunkStart..<end])
            let batch = await fetcher.fetchAll(chunk, maxConcurrent: 15)

            allFetched += batch.items.count
            allFailed += batch.failedSourceCount
            totalFetched = allFetched
            fetchErrorCount = allFailed
            emptyFeedCount += batch.emptySourceCount

            updateSourceHealth(failedSources: batch.failedSourceCount, totalSources: chunk.count, totalItems: batch.items.count)

            let actualNew = batch.items.filter { !loadedIDs.contains($0.id) }
            registerLoadedIDs(actualNew.map(\.id))

            prefetchImagesIfNeeded(for: actualNew)

            // Merge new items into reservoir (interleaved), don't touch visible items
            reservoir.append(contentsOf: actualNew)
            reservoir = interleave(reservoir)
            capReservoir()
            reservoirCount = reservoir.count
            whatsNewVersion &+= 1  // invalidate whatIsNewItems without touching date sections
        }

        lastRefreshDate = .now
        loadingState = .idle

        PersistenceManager.shared.save(buildStateWithItems())

        // Auto-retry with backoff if nothing loaded
        if items.isEmpty && fetchErrorCount > 0 {
            scheduleRetryIfAllFailed()
        }
    }

    func refresh() async {
        loadingState = .refreshing

        // Clear all state
        loadedIDs.removeAll()
        loadedIDsInsertionOrder.removeAll()
        reservoir.removeAll()
        items.removeAll()
        filteredOutItems.removeAll()
        totalDiscarded = 0

        guard !sources.isEmpty else {
            loadingState = .idle
            return
        }

        let batch = await fetcher.fetchAll(enabledSources.shuffled())
        totalFetched = batch.items.count
        fetchErrorCount = batch.failedSourceCount

        updateSourceHealth(failedSources: batch.failedSourceCount, totalSources: enabledSources.count, totalItems: batch.items.count)
        emptyFeedCount = batch.emptySourceCount

        let actualNew = batch.items.filter { !loadedIDs.contains($0.id) }
        registerLoadedIDs(actualNew.map(\.id))

        reservoir = interleave(actualNew)
        capReservoir()

        let windowSize = min(Self.pageSize, reservoir.count)
        items = Array(reservoir.prefix(windowSize))
        reservoir.removeFirst(windowSize)
        reservoirCount = reservoir.count
        itemVersion += 1
        markAsSurfaced(items)

        lastRefreshDate = .now
        loadingState = .idle

        PersistenceManager.shared.save(buildStateWithItems())
    }

    private var lastLoadedIndex: Int = -1

    func loadMoreIfNeeded(currentItem: FeedItem) async {
        // Single O(n) scan for both position tracking and guard
        guard let itemIndex = items.firstIndex(where: { $0.id == currentItem.id }) else {
            return
        }
        currentVisibleIndex = itemIndex

        // Only trigger when near the bottom
        guard itemIndex >= items.count - Self.loadMoreThreshold else { return }

        // Debounce: skip if we already loaded at this position (SwiftUI onAppear can refire during scroll)
        guard itemIndex != lastLoadedIndex else { return }
        lastLoadedIndex = itemIndex

        // Step 1: ALWAYS move from reservoir to visible (works even during background fetch)
        moveFromReservoirToVisible(count: Self.pageSize)

        // Step 2: Always trim after adding items
        trimBufferIfNeeded()

        // Step 3: Refill reservoir — only when idle (don't compete with fetchFreshContent)
        guard loadingState == .idle else { return }

        if reservoir.isEmpty || reservoir.count < Self.reservoirLowWatermark {
            loadingState = .loadingMore
            await refillReservoir()
            loadingState = .idle
        }
    }

    func trimBufferIfNeeded() {
        guard items.count > Self.maxBuffer else { return }

        let excess = items.count - Self.maxBuffer
        let toDiscard = min(Self.discardBatchSize, excess)

        // Priority 1: discard items above current position (already scrolled past)
        let safeStart = max(0, currentVisibleIndex - Self.safetyZoneRadius)
        let aboveCandidates = items[0..<safeStart]
        let aboveToDiscard = min(toDiscard, aboveCandidates.count)

        if aboveToDiscard > 0 {
            items.removeFirst(aboveToDiscard)
            currentVisibleIndex -= aboveToDiscard
            totalDiscarded += aboveToDiscard
        }

        // Priority 2: if still over, discard from far below
        let remaining = toDiscard - aboveToDiscard
        if remaining > 0 && items.count > Self.maxBuffer {
            let safeEnd = min(items.count, currentVisibleIndex + Self.safetyZoneRadius)
            if safeEnd < items.count {
                let belowToDiscard = min(remaining, items.count - safeEnd)
                if belowToDiscard > 0 {
                    items.removeLast(belowToDiscard)
                    totalDiscarded += belowToDiscard
                }
            }
        }
        // Note: callers bump itemVersion once after all mutations complete
    }

    // MARK: - Private

    /// Trim reservoir to maxReservoirSize while preserving source diversity.
    /// Every source gets at least 1 slot; remaining slots are proportional to item count.
    /// This ensures 200+ sources all have a presence instead of 20 sources dominating.
    private func capReservoir() {
        guard reservoir.count > Self.maxReservoirSize else { return }

        // Group by source — each source is a separate voice
        var bySource: [String: [FeedItem]] = [:]
        for item in reservoir {
            bySource[item.sourceURL, default: []].append(item)
        }
        let sourceCount = bySource.count
        guard sourceCount > 1 else {
            reservoir = Array(reservoir.prefix(Self.maxReservoirSize))
            reservoirCount = reservoir.count
            return
        }

        // Floor: 1 item per source guarantees every source is represented
        let floorPerSource = 1
        let floorSlots = min(sourceCount * floorPerSource, Self.maxReservoirSize)
        let proportionalSlots = Self.maxReservoirSize - floorSlots

        var selected: [FeedItem] = []
        var remainingBySource: [String: [FeedItem]] = [:]

        for (sourceURL, items) in bySource {
            let take = min(floorPerSource, items.count)
            selected.append(contentsOf: items.prefix(take))
            if items.count > take {
                remainingBySource[sourceURL] = Array(items.dropFirst(take))
            }
        }

        // Distribute remaining slots proportionally to how many items each source has
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

        // Fill any leftover slots round-robin
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
        reservoirCount = reservoir.count
    }

    /// Register new item IDs, tracking insertion order for precise FIFO trimming.
    private func registerLoadedIDs(_ ids: [String]) {
        for id in ids {
            if loadedIDs.insert(id).inserted {
                loadedIDsInsertionOrder.append(id)
            }
        }
        // Trim oldest IDs when over cap
        while loadedIDsInsertionOrder.count > Self.maxLoadedIDs {
            loadedIDs.remove(loadedIDsInsertionOrder.removeFirst())
        }
    }

    /// Record items as "surfaced on screen" so interleave deprioritizes them for 30 min.
    private func markAsSurfaced(_ items: [FeedItem]) {
        let now = Date()
        for item in items {
            if surfacedItemTimestamps[item.id] == nil {
                surfacedItemTimestamps[item.id] = now
            }
        }
        // Periodic cleanup of expired timestamps
        if surfacedItemTimestamps.count > 2000 {
            let cutoff = now.addingTimeInterval(-Self.surfacedCooldown)
            surfacedItemTimestamps = surfacedItemTimestamps.filter { $0.value > cutoff }
        }
    }

    private func moveFromReservoirToVisible(count: Int) {
        guard !reservoir.isEmpty else { return }

        // Periodic reshuffle: re-interleave reservoir so items buried at the back
        // get a chance to surface in a different order.
        moveCountSinceReshuffle += 1
        if moveCountSinceReshuffle >= Self.reshuffleInterval && reservoir.count > count {
            reservoir = interleave(reservoir)
            moveCountSinceReshuffle = 0
        }

        let toMove = min(count, reservoir.count)
        let batch = Array(reservoir.prefix(toMove))
        items.append(contentsOf: batch)
        reservoir.removeFirst(toMove)
        reservoirCount = reservoir.count
        itemVersion += 1
        markAsSurfaced(batch)
    }

    private func refillReservoir() async {
        guard !enabledSources.isEmpty else { return }

        let batch = await fetcher.fetchAll(enabledSources.shuffled())
        totalFetched += batch.items.count
        fetchErrorCount += batch.failedSourceCount
        emptyFeedCount += batch.emptySourceCount

        let actualNew = batch.items.filter { !loadedIDs.contains($0.id) }
        registerLoadedIDs(actualNew.map(\.id))

        prefetchImagesIfNeeded(for: actualNew)

        reservoir.append(contentsOf: actualNew)
        reservoir = interleave(reservoir)
        capReservoir()
        reservoirCount = reservoir.count

        PersistenceManager.shared.save(buildStateWithItems())
    }

    /// Interleave YouTube + non-YouTube sources so early chunks have video variety.
    /// Podcast vs text classification happens at the item level via FeedItem.isPodcast
    /// (detected from enclosure MIME type, Media RSS, and iTunes namespace — all standards).
    private func interleaveSourcesByType(_ sources: [FeedSource]) -> [FeedSource] {
        let videos = sources.filter { $0.isYouTube }.shuffled()
        let nonVideos = sources.filter { !$0.isYouTube }.shuffled()
        var result: [FeedSource] = []
        result.reserveCapacity(sources.count)
        let maxCount = max(videos.count, nonVideos.count)
        for i in 0..<maxCount {
            if i < nonVideos.count { result.append(nonVideos[i]) }
            if i < videos.count { result.append(videos[i]) }
        }
        return result
    }

    /// Prefetch What's New carousel images — called when carousel appears.
    /// Uses the shared prefetcher so in-flight requests are deduplicated.
    func prefetchWhatsNewImages() {
        let carouselItems = whatIsNewItems
        let urls = carouselItems.compactMap { $0.bestImageURL ?? $0.imageURL }
        guard !urls.isEmpty else { return }
        Task { await prefetcher.prefetch(urls: urls, priorityURLs: urls) }
    }

    /// Prefetch images for items if the setting is enabled
    private func prefetchImagesIfNeeded(for items: [FeedItem], priorityItems: [FeedItem] = []) {
        guard prefetchImages else { return }
        let urls = items.compactMap { $0.bestImageURL }
        let priority = priorityItems.compactMap { $0.bestImageURL }
        guard !urls.isEmpty else { return }
        Task { await prefetcher.prefetch(urls: urls, priorityURLs: priority) }
    }

    /// Schedule an automatic retry with exponential backoff when all sources fail
    func scheduleRetryIfAllFailed() {
        guard totalFetched == 0, fetchErrorCount > 0 else {
            retryCount = 0
            return
        }

        let delay = min(Double(1 << min(retryCount, 4)), 60.0)  // 1, 2, 4, 8, 16, 32, 60, 60... seconds
        retryCount += 1
        retryTask?.cancel()
        retryTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            print("[FeedLoader] Auto-retry #\(retryCount) after \(Int(delay))s")
            await refresh()
        }
    }
}
