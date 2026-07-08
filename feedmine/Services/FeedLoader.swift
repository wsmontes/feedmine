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
    var selectedContentType: ContentType = .all

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
    var selectedMood: MoodFilter = .all

    // MARK: - Category Filter

    var selectedCategory: String?

    // MARK: - Search

    var searchQuery: String = ""
    var isSearching: Bool { store.isSearching }

    // MARK: - Filtered Items

    var filteredItems: [FeedItem] {
        var result = items
        if selectedMood != .all {
            result = result.filter { selectedMood.matches($0.title) }
        }
        if let cat = selectedCategory {
            result = result.filter { $0.category.lowercased() == cat.lowercased() }
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

    // MARK: - Countries / Sources

    var availableCountries: [Country] { store.registry.availableCountries }
    var availableCategories: [String] {
        Set(store.registry.enabledSources.map(\.category)).sorted()
    }
    var enabledSources: [FeedSource] { store.registry.enabledSources }
    var sources: [FeedSource] { store.registry.sources }
    var disabledSourceIDs: Set<String> { store.registry.disabledSourceIDs }

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
    var loadedIDsCount: Int { items.count }  // approximates unique loaded count

    // MARK: - What's New

    private var cachedWhatsNew: [FeedItem] = []
    var whatIsNewItems: [FeedItem] { cachedWhatsNew }
    var whatsNewVisible = false

    func loadWhatsNew() async {
        cachedWhatsNew = await store.loadWhatsNewItems()
    }

    func flushWhatsNewQueue() {
        // Refresh what's new items — called when user dismisses carousel
        Task { await loadWhatsNew() }
    }

    func prefetchWhatsNewImages() {
        let urls = cachedWhatsNew.compactMap { $0.bestImageURL ?? $0.imageURL }
        guard !urls.isEmpty else { return }
        Task {
            for urlString in urls {
                guard let url = URL(string: urlString) else { continue }
                _ = try? await URLSession.shared.data(from: url)
            }
        }
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

    init() {
        self.store = try! FeedStore()
    }

    // MARK: - Actions (delegate to store)

    func start() async {
        await store.start()
        await loadWhatsNew()
    }
    func loadMoreIfNeeded(currentItem: FeedItem) async {
        await store.loadMoreIfNeeded(currentItem: currentItem)
    }
    func refreshIfStale() async { await store.refreshIfStale() }
    func refresh() async { await store.start() }

    func selectCategory(_ category: String?) {
        selectedCategory = (selectedCategory == category) ? nil : category
        store.setFilter(
            region: store.activeRegion,
            category: selectedCategory,
            type: selectedContentType
        )
    }

    func selectMood(_ mood: MoodFilter) {
        selectedMood = (selectedMood == mood) ? .all : mood
    }

    func selectContentType(_ type: ContentType) {
        selectedContentType = (selectedContentType == type) ? .all : type
        store.setFilter(
            region: store.activeRegion,
            category: selectedCategory,
            type: selectedContentType
        )
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
        store.toggleRegion("global")
    }
    func toggleSource(_ sourceURL: String) { store.registry.toggleSource(sourceURL) }
    func isRegionEnabled(_ region: String) -> Bool { store.registry.isRegionEnabled(region) }
    func isSourceEnabled(_ url: String) -> Bool { store.registry.isSourceEnabled(url) }
    var isAnyCountryEnabled: Bool { store.registry.isAnyCountryEnabled }
    var isGlobalFeedsEnabled: Bool { store.registry.isRegionEnabled("global") }

    func markAsRead(_ itemID: String) { store.markAsRead(itemID) }
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
    }

    /// Whether any persistent search is currently active — main feed should use composite mode.
    var hasActiveSearches: Bool {
        // Inferred: checked each time bookmark views need to know.
        // For now, main feed checks via loadActiveSearches() on appear.
        false
    }

    func isBookmarked(_ itemID: String) -> Bool { false }

    func markAllAsRead() {
        for id in items.map(\.id) { store.markAsRead(id) }
        // Also mark reservoir items
        // (visibleItems covers everything the user sees — reservoir is pre-fetch)
    }

    func shakeToRefresh() {
        store.emergencyTrim()
        Task { await store.refreshIfStale() }
    }

    func emergencyTrim() { store.emergencyTrim() }

    var reservoirCount: Int { store.reservoirCount }
    var lastRefreshDate: Date? { store.lastRefreshDate }

    // MARK: - Source helpers

    func addSources(_ newSources: [FeedSource]) {
        store.registry.sources = OPMLParser.deduplicateSources(
            store.registry.sources + newSources
        )
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
