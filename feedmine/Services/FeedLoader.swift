import Foundation
import Observation

// MARK: - Shared types (file scope for module access by FeedStore)

enum FeedLoadingState {
    case idle
    case initial
    case refreshing
    case loadingMore
}

/// Minimal placeholder for migration compatibility.
/// Replaced by SQLite persistence — kept for stub API compliance.
struct FeedState: Codable {
    var schemaVersion: Int = 3
    var readItemIDs: [String] = []
    var bookmarkedIDs: [String] = []
    var disabledSourceIDs: [String] = []
    var disabledRegions: [String] = []
    var sources: [FeedSource] = []
    var lastRefreshDate: Date?
    var streakCount: Int = 0
    var lastOpenDate: TimeInterval = Date().timeIntervalSinceReferenceDate
    var readTimestamps: [String: Date] = [:]
    var cachedItems: [FeedItem] = []
    var clickedSourceURLs: [String] = []
}

// MARK: - ViewModel

@MainActor
@Observable
final class FeedLoader {
    private let store: FeedStore
    private let prefetcher = ImagePrefetcher()

    // MARK: - UI State (from store)

    var items: [FeedItem] { store.visibleItems }
    var loadingState: FeedLoadingState { store.loadingState }
    var totalFetched: Int { store.totalFetched }
    var fetchErrorCount: Int { store.fetchErrorCount }
    var sourceCount: Int { store.registry.sourceCount }
    var podcastSourceCount: Int { store.podcastSourceCount }
    var podcastItemCount: Int { store.podcastItemCount }
    var totalDiscarded: Int { store.totalDiscarded }
    var emptyFeedCount: Int { store.emptyFeedCount }

    // MARK: - Date Sections

    struct DateSection: Identifiable {
        var id: String { title }
        let title: String
        let items: [FeedItem]
    }

    // MARK: - Layout

    enum FeedLayout { case card, list }
    var layout: FeedLayout = .card

    // MARK: - Content Type Filter

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
    // Single source of truth: all filter state lives in FeedStore
    var selectedContentType: ContentType { store.activeContentType }
    var selectedMood: MoodFilter { store.activeMood }
    var selectedCategory: String? { store.activeCategory }

    // MARK: - Mood Filter

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

    // MARK: - Search

    var searchQuery: String = ""
    var isSearching: Bool { store.isSearching }

    // MARK: - Filtered Items (reads from FeedStore as single source)

    private var _cachedFiltered: [FeedItem] = []
    private var _cacheKey: Int = -1

    var filteredItems: [FeedItem] {
        let key = items.count ^ (items.first?.id.hashValue ?? 0) ^ (items.last?.id.hashValue ?? 0) ^ searchQuery.hashValue
        if key == _cacheKey { return _cachedFiltered }
        _cacheKey = key
        var result = items
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            let q = query.lowercased()
            if !isSearching {
                result = result.filter {
                    $0.title.localizedCaseInsensitiveContains(q) ||
                    $0.excerpt.localizedCaseInsensitiveContains(q) ||
                    $0.sourceTitle.localizedCaseInsensitiveContains(q)
                }
            }
            result = result
                .map { (item: $0, score: searchScore($0, q)) }
                .sorted { $0.score > $1.score }
                .map(\.item)
        }
        _cachedFiltered = result
        return result
    }

    private var _cachedSections: [DateSection] = []
    private var _sectionsCacheKey: Int = -1

    var dateSections: [DateSection] {
        let key = _cacheKey
        if key == _sectionsCacheKey, !_cachedSections.isEmpty { return _cachedSections }
        _sectionsCacheKey = key
        let calendar = Calendar.current; let now = Date()
        let grouped = Dictionary(grouping: _cachedFiltered) { item -> String in
            if calendar.isDateInToday(item.publishedAt) { return "Today" }
            if calendar.isDateInYesterday(item.publishedAt) { return "Yesterday" }
            let days = calendar.dateComponents([.day], from: item.publishedAt, to: now).day ?? 0
            if days < 7 { return "This Week" }
            return "Earlier"
        }
        _cachedSections = ["Today", "Yesterday", "This Week", "Earlier"].compactMap { t in
            grouped[t].map { DateSection(title: t, items: $0) }
        }
        return _cachedSections
    }

    private func searchScore(_ item: FeedItem, _ q: String) -> Int {
        let t = item.title.lowercased(); let e = item.excerpt.lowercased()
        if t == q { return 100 }; if t.hasPrefix(q) { return 80 }
        if t.contains(q) { return 60 }; if e.contains(q) { return 30 }
        return 10
    }

    // MARK: - Countries / Sources

    var availableCountries: [Country] { store.registry.availableCountries }
    var availableCategories: [String] {
        Set(store.registry.enabledSources.map(\.category)).sorted()
    }
    var enabledSources: [FeedSource] { store.registry.enabledSources }
    var sources: [FeedSource] { store.registry.sources }
    var disabledSourceIDs: Set<String> {
        Set(store.registry.sources.filter { !store.registry.isSourceEnabled($0.url) }.map(\.url))
    }

    // MARK: - OPML debug counters

    var opmlErrorCount: Int { store.registry.opmlErrorCount }
    var duplicateSourceCount: Int { store.registry.duplicateSourceCount }
    var opmlFileCount: Int { store.registry.opmlFileCount }

    // MARK: - Read / Bookmark

    var readItemIDs: Set<String> { store.readItemIDs }

    /// Cached bookmark item IDs — refreshed on load and on toggle.
    private var bookmarkItemIDs: Set<String> = []

    var bookmarkedItems: [FeedItem] {
        items.filter { bookmarkItemIDs.contains($0.id) }
    }

    var bookmarkedIDs: Set<String> { bookmarkItemIDs }

    /// Reload bookmark state from FeedStore (call on appear and after toggle).
    func refreshBookmarkState() async {
        do {
            let lists = try await store.allBookmarkLists()
            guard let defaultID = lists.first(where: { $0.isDefault })?.id ?? lists.first?.id else {
                bookmarkItemIDs = []
                return
            }
            let items = try await store.bookmarkedItems(listID: defaultID)
            bookmarkItemIDs = Set(items.map(\.id))
        } catch {
            print("[FeedLoader] refreshBookmarkState error: \(error)")
        }
    }

    // MARK: - Resources

    var networkMonitor: NetworkMonitor { store.networkMonitor }
    var currentVisibleIndex: Int = 0

    /// Keep `currentVisibleIndex` in sync as rows appear. Nothing updated it
    /// before, so it was stuck at 0 and the scroll-to-top heuristic never fired.
    /// Gated by the caller (every Nth appear), so the O(n) lookup over the
    /// bounded visible buffer is cheap.
    func noteVisibleIndex(for item: FeedItem) {
        if let idx = filteredItems.firstIndex(where: { $0.id == item.id }) {
            currentVisibleIndex = idx
        }
    }
    var loadedIDsCount: Int { store.loadedIDsCount }

    // MARK: - What's New

    private var cachedWhatsNew: [FeedItem] = []
    /// What's New items — separate from active search results (#40).
    var whatIsNewItems: [FeedItem] { cachedWhatsNew }
    var whatsNewLabel: String { "What's New" }
    var whatsNewVisible = false

    func loadWhatsNew() async {
        cachedWhatsNew = await store.loadWhatsNewItems()
    }

    func flushWhatsNewQueue() {
        // Advance baseline so shown items aren't "new" next session,
        // then refresh — called when carousel dismisses or app backgrounds.
        store.advanceWhatsNewBaseline()
        Task { await loadWhatsNew() }
    }

    /// Mark a What's New item as read and remove it from the carousel immediately.
    /// This gives instant visual feedback — the card disappears without waiting
    /// for a full reload cycle.
    func markWhatsNewAsRead(_ id: String) {
        store.markAsRead(id)
        cachedWhatsNew.removeAll { $0.id == id }
    }

    func prefetchWhatsNewImages() {
        let urls = cachedWhatsNew.compactMap { $0.bestImageURL ?? $0.imageURL }
        guard !urls.isEmpty else { return }
        Task { await prefetcher.prefetch(urls: urls, priorityURLs: urls) }
    }

    // MARK: - Source health (stub)

    struct SourceHealth {
        var lastFetchDate: Date?
        var consecutiveFailures: Int = 0
        var lastArticleCount: Int = 0
        var isStale: Bool { consecutiveFailures >= 3 }
    }
    private var sourceHealth: [String: SourceHealth] = [:]

    func healthFor(_ source: FeedSource) -> SourceHealth {
        SourceHealth(
            lastFetchDate: store.lastFetchDate(for: source.url),
            consecutiveFailures: store.consecutiveFailures(for: source.url)
        )
    }

    // MARK: - Persistence stubs (migrated to SQLite / Task 11)

    func buildState() -> FeedState { FeedState() }
    func buildStateWithItems() -> FeedState { FeedState() }

    // MARK: - Init

    /// Creates a FeedLoader. Pass a custom FeedStore for testing; uses SQLite-backed
    /// store by default.
    init(store: FeedStore? = nil) {
        self.store = store ?? (try! FeedStore())
    }

    // MARK: - Actions (delegate to store)

    func start() async {
        await store.start()
        await loadWhatsNew()
        await refreshBookmarkState()
        await refreshActiveSearchState()
    }
    func loadMoreIfNeeded(currentItem: FeedItem) async {
        await store.loadMoreIfNeeded(currentItem: currentItem)
    }
    func refreshIfStale() async {
        await store.refreshIfStale()
        await loadWhatsNew()
    }
    func refresh() async {
        await store.refreshNow()
        await loadWhatsNew()
    }

    func selectCategory(_ category: String?) {
        let newValue = (store.activeCategory == category) ? nil : category
        store.setFilter(region: store.activeRegion, category: newValue,
                        type: store.activeContentType, mood: store.activeMood)
        Task { await loadWhatsNew() }
    }

    func selectMood(_ mood: MoodFilter) {
        let newValue = (store.activeMood == mood) ? .all : mood
        store.setFilter(region: store.activeRegion, category: store.activeCategory,
                        type: store.activeContentType, mood: newValue)
        Task { await loadWhatsNew() }
    }

    func selectContentType(_ type: ContentType) {
        let newValue = (store.activeContentType == type) ? .all : type
        store.setFilter(region: store.activeRegion, category: store.activeCategory,
                        type: newValue, mood: store.activeMood)
        Task { await loadWhatsNew() }
    }

    func clearAllFilters() {
        searchQuery = ""
        store.clearAllFilters()
        Task { await loadWhatsNew() }
    }

    func clearReadHistory() {
        store.clearReadHistory()
    }

    func clearAllBookmarks() {
        bookmarkItemIDs.removeAll()
        store.clearAllBookmarks()
        Task { await refreshBookmarkState() }
    }

    private var searchDebounceTask: Task<Void, Never>?

    func searchQueryChanged() {
        searchDebounceTask?.cancel()
        let query = searchQuery
        if query.isEmpty {
            store.clearSearch()
        } else {
            // Debounce 250ms — cancel previous task on each keystroke (#45)
            searchDebounceTask = Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                store.search(query)
            }
        }
    }

    var lastToggleMessage: String? { store.lastToggleMessage }

    /// Bumped on every toggle to notify SwiftUI of deep state changes in
    /// SourceRegistry (which isn't directly observable through FeedStore).
    var toggleGeneration = 0

    func toggleRegion(_ region: String) {
        store.toggleRegion(region)
        toggleGeneration &+= 1
        Task { await loadWhatsNew() }
    }

    func clearToggleMessage() {
        store.lastToggleMessage = nil
    }
    func toggleAllCountries() {
        store.registry.toggleAllCountries()
        toggleGeneration &+= 1
        store.resetWhatsNewBaseline()
        Task { await loadWhatsNew() }
    }
    func toggleGlobalFeeds() {
        store.toggleRegion("global")
        toggleGeneration &+= 1
        store.resetWhatsNewBaseline()
        Task { await loadWhatsNew() }
    }
    func toggleSource(_ sourceURL: String) { store.toggleSource(sourceURL); toggleGeneration &+= 1 }
    func isRegionEnabled(_ region: String) -> Bool { _ = toggleGeneration; return store.registry.status(of: SourceRegistry.regionKey(region)) != .off }
    func isSourceEnabled(_ url: String) -> Bool { store.registry.isSourceEnabled(url) }
    func nodeStatus(for key: String) -> NodeStatus { _ = toggleGeneration; return store.registry.status(of: key) }
    func activeCount(for key: String) -> Int { store.registry.activeCount(for: key) }
    func toggleCategory(_ category: String) { store.toggleCategory(category); toggleGeneration &+= 1 }
    func isCategoryEnabled(_ category: String) -> Bool { _ = toggleGeneration; return store.registry.status(of: SourceRegistry.categoryKey(category)) != .off }
    var isAnyCountryEnabled: Bool { _ = toggleGeneration; return store.registry.isAnyCountryEnabled }
    var isGlobalFeedsEnabled: Bool { _ = toggleGeneration; return store.registry.status(of: SourceRegistry.regionKey("global")) != .off }

    func markAsRead(_ itemID: String) { store.markAsRead(itemID) }
    func markAsUnread(_ itemID: String) { store.markAsUnread(itemID) }
    func isRead(_ itemID: String) -> Bool { store.readItemIDs.contains(itemID) }

    // MARK: - Bookmark Lists

    func loadBookmarkLists() async throws -> [BookmarkList] {
        try await store.allBookmarkLists()
    }

    func loadBookmarkedItems(listID: Int64) async throws -> [FeedItem] {
        try await store.bookmarkedItems(listID: listID)
    }

    func toggleBookmark(_ itemID: String) {
        Task {
            try? await store.toggleBookmark(itemID: itemID)
            await refreshBookmarkState()
        }
    }

    func loadActiveSearches() async throws -> [ActiveSearch] {
        try await store.activeSearches()
    }

    func toggleSearchActive(listID: Int64) async throws {
        try await store.toggleSearchActive(listID: listID)
        await refreshActiveSearchState()
    }

    /// Whether any persistent search is currently active.
    private(set) var hasActiveSearches = false

    /// Items from active saved searches — displayed separately from What's New
    /// so the two features don't compete for the same state.
    private(set) var activeSearchItems: [FeedItem] = []

    private func refreshActiveSearchState() async {
        do {
            let searches = try await store.activeSearches()
            hasActiveSearches = !searches.isEmpty
            if hasActiveSearches {
                activeSearchItems = try await store.compositeSearchFeed()
            } else {
                activeSearchItems = []
            }
        } catch {
            hasActiveSearches = false
            activeSearchItems = []
        }
    }

    func isBookmarked(_ itemID: String) -> Bool {
        bookmarkItemIDs.contains(itemID)
    }

    func markAllAsRead() {
        for id in items.map(\.id) { store.markAsRead(id) }
        // Also mark reservoir items
        // (visibleItems covers everything the user sees — reservoir is pre-fetch)
    }

    func shakeToRefresh() {
        searchQuery = ""
        store.shakeToRefresh()
    }

    func emergencyTrim() { store.emergencyTrim() }

    var reservoirCount: Int { store.reservoirCount }
    var lastRefreshDate: Date? { store.lastRefreshDate }

    // MARK: - Source helpers

    func addSources(_ newSources: [FeedSource]) {
        store.registry.sources = OPMLParser.deduplicateSources(
            store.registry.sources + newSources
        )
        // Persist imported sources so they survive app restart.
        // Saved to a simple JSON file in the app's documents directory.
        persistImportedSources()
    }

    private func persistImportedSources() {
        let imported = store.registry.sources.filter { $0.region == "imported" }
        guard !imported.isEmpty else { return }
        do {
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("imported_sources.json")
            let data = try JSONEncoder().encode(imported)
            try data.write(to: url)
        } catch {
            print("[FeedLoader] Failed to persist imported sources: \(error)")
        }
    }

    func regionFeeds(for regionPath: String) -> [FeedSource] {
        store.registry.sources
            .filter { $0.region == regionPath }
            .sorted { $0.category < $1.category || ($0.category == $1.category && $0.title < $1.title) }
    }

    func countryFeeds(for region: String) -> [FeedSource] {
        regionFeeds(for: region)
    }

    func subRegions(for countryRegion: String) -> [String] {
        let prefix = "\(countryRegion)/"
        return store.registry.sources
            .map(\.region)
            .filter { $0.hasPrefix(prefix) }
            .reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
            .sorted()
    }
}
