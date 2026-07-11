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
    private var _cachedFirst: String = ""
    private var _cachedLast: String = ""
    private var _cachedCount: Int = -1
    private var _cachedSearch: String = ""

    var filteredItems: [FeedItem] {
        let first = items.first?.id ?? ""
        let last  = items.last?.id ?? ""
        let count = items.count
        if first == _cachedFirst, last == _cachedLast, count == _cachedCount, searchQuery == _cachedSearch {
            return _cachedFiltered
        }
        _cachedFirst = first; _cachedLast = last; _cachedCount = count; _cachedSearch = searchQuery
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
    private var _sectionsFirst: String = ""
    private var _sectionsLast: String = ""
    private var _sectionsCount: Int = -1
    private var _sectionsSearch: String = ""

    var dateSections: [DateSection] {
        // Force filteredItems to refresh its cache before we read either —
        // without this, dateSections can return stale sections when accessed
        // before filteredItems in a SwiftUI body evaluation.
        let items = filteredItems
        if _cachedFirst == _sectionsFirst, _cachedLast == _sectionsLast,
           _cachedCount == _sectionsCount, _cachedSearch == _sectionsSearch,
           !_cachedSections.isEmpty { return _cachedSections }
        _sectionsFirst = _cachedFirst; _sectionsLast = _cachedLast
        _sectionsCount = _cachedCount; _sectionsSearch = _cachedSearch
        let calendar = Calendar.current; let now = Date()
        // Ordered grouping — Dictionary(grouping:) does not preserve array
        // order, which caused visible cards to reorder on every cache miss.
        var grouped: [String: [FeedItem]] = [:]
        for item in items {
            let section: String
            if calendar.isDateInToday(item.publishedAt) { section = "Today" }
            else if calendar.isDateInYesterday(item.publishedAt) { section = "Yesterday" }
            else {
                let days = calendar.dateComponents([.day], from: item.publishedAt, to: now).day ?? 0
                section = days < 7 ? "This Week" : "Earlier"
            }
            grouped[section, default: []].append(item)
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

    /// Currently selected bookmark box — when set, the feed becomes a fixed
    /// list of that box's contents, ordered by save date. Dismiss to clear.
    var selectedBookmarkListID: Int64? {
        get { store.selectedBookmarkListID }
        set {
            store.selectedBookmarkListID = newValue
            if let listID = newValue {
                // Bookmark mode: load all items from the box
                Task { @MainActor in
                    do {
                        let lists = try await store.allBookmarkLists()
                        selectedBookmarkListName = lists.first(where: { $0.id == listID })?.name
                        let items = try await store.bookmarkedItems(listID: listID)
                        store.loadBookmarkFeed(items: items)
                    } catch {
                        store.selectedBookmarkListID = nil
                        selectedBookmarkListName = nil
                    }
                }
            } else {
                selectedBookmarkListName = nil
                store.clearBookmarkFeed()
            }
        }
    }

    /// Name of the currently selected bookmark box, if any.
    private(set) var selectedBookmarkListName: String? = nil

    /// Reload bookmark state from FeedStore (call on appear and after toggle).
    func refreshBookmarkState() async {
        do {
            let lists = try await store.allBookmarkLists()
            bookmarkLists = lists
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

    /// Direct index setter — caller already knows the position from ForEach
    /// enumeration, so we skip the O(n) `firstIndex(where:)` scan.
    func noteVisibleIndex(_ index: Int) {
        currentVisibleIndex = index
    }

    /// O(n) fallback kept for any caller that only has an item reference.
    func noteVisibleIndex(for item: FeedItem) {
        noteVisibleIndex(filteredItems.firstIndex(where: { $0.id == item.id }) ?? 0)
    }
    var loadedIDsCount: Int { store.loadedIDsCount }

    // MARK: - What's New

    /// What's New items — driven by the reactive pipeline in FeedStore.
    /// Items accumulate as new content enters the database and are promoted
    /// to the carousel when the pool reaches the threshold (10).
    var whatIsNewItems: [FeedItem] { store.whatsNewItems }
    var whatsNewLabel: String { "What's New" }
    var whatsNewVisible = false

    /// Refresh What's New — clears pool, re-seeds from DB, triggers booster fetch.
    func loadWhatsNew() async {
        store.refreshWhatsNew()
    }

    /// User scrolled past the carousel — advance to the next batch.
    func advanceWhatsNewCarousel() {
        store.advanceWhatsNew()
    }

    func flushWhatsNewQueue() {
        store.advanceWhatsNew()
    }

    /// Mark a What's New item as read and remove it from the carousel immediately.
    func markWhatsNewAsRead(_ id: String) {
        store.markAsRead(id)
    }

    func prefetchWhatsNewImages() {
        let urls = whatIsNewItems.compactMap { $0.bestImageURL ?? $0.imageURL }
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
    init(feedID: UUID = FeedStore.mainID, defaults: UserDefaults = .standard, store: FeedStore? = nil) {
        self.store = store ?? (try! FeedStore(feedID: feedID, defaults: defaults))
    }

    // MARK: - Actions (delegate to store)

    func start() async {
        await store.start()
        await loadWhatsNew()
        await refreshBookmarkLists()
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

    /// Light refresh for inactive feeds — pulls new items to accumulate What's New,
    /// without heavy image prefetch or load-more. Delegates to the store's stale refresh.
    func backgroundRefresh() async {
        await store.refreshIfStale()
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

    func toggleRegion(_ region: String) {
        store.toggleRegion(region)
        Task { await loadWhatsNew() }
    }

    func clearToggleMessage() {
        store.lastToggleMessage = nil
    }
    func toggleAllCountries() {
        store.registry.toggleAllCountries()
        store.resetWhatsNewBaseline()
        Task { await loadWhatsNew() }
    }
    func toggleGlobalFeeds() {
        store.toggleRegion("global")
        store.resetWhatsNewBaseline()
        Task { await loadWhatsNew() }
    }
    func toggleSource(_ sourceURL: String) { store.toggleSource(sourceURL) }
    /// True if the region is not explicitly disabled. Partial (disabled but
    /// some sources overridden) still counts as disabled from the user's POV.
    func isRegionEnabled(_ region: String) -> Bool { store.registry.status(of: SourceRegistry.regionKey(region)) == .on }
    func isSourceEnabled(_ url: String) -> Bool { store.registry.isSourceEnabled(url) }
    func nodeStatus(for key: String) -> NodeStatus { store.registry.status(of: key) }
    func activeCount(for key: String) -> Int { store.registry.activeCount(for: key) }
    func toggleCategory(_ category: String) { store.toggleCategory(category) }
    /// True if the category is not explicitly disabled.
    func isCategoryEnabled(_ category: String) -> Bool { store.registry.status(of: SourceRegistry.categoryKey(category)) == .on }
    var isAnyCountryEnabled: Bool { store.registry.isAnyCountryEnabled }
    var isGlobalFeedsEnabled: Bool { store.registry.status(of: SourceRegistry.regionKey("global")) == .on }

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

    func toggleBookmark(_ itemID: String, listID: Int64? = nil) {
        let targetListID = listID ?? store.preferredBookmarkListID
        Task {
            try? await store.toggleBookmark(itemID: itemID, listID: targetListID)
            await refreshBookmarkState()
        }
    }

    var preferredBookmarkListID: Int64? {
        get { store.preferredBookmarkListID }
        set { store.preferredBookmarkListID = newValue }
    }

    /// Cached bookmark lists for context menus — loaded at startup, refreshed on changes.
    var bookmarkLists: [BookmarkList] = []

    func refreshBookmarkLists() async {
        do { bookmarkLists = try await store.allBookmarkLists() }
        catch {}
    }

    @discardableResult
    func createBookmarkList(name: String) async throws -> Int64 {
        try await store.createBookmarkList(name: name)
    }

    func renameBookmarkList(_ id: Int64, name: String) async throws {
        try await store.renameBookmarkList(id, name: name)
    }

    func reorderBookmarkList(_ id: Int64, sortOrder: Int) async throws {
        try await store.reorderBookmarkList(id, sortOrder: sortOrder)
    }

    func deleteBookmarkList(_ id: Int64) async throws {
        try await store.deleteBookmarkList(id)
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
        store.markAllAsRead(items.map(\.id))
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
