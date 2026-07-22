import Foundation
import Observation

// MARK: - Shared types (file scope for module access by FeedStore)

enum FeedLoadingState {
    case idle
    case initial
    case refreshing
    case loadingMore
}

enum DeferredToggleState: Equatable {
    case none
    case enabled
    case disabled
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
    private var pendingRegionToggleStates: [String: DeferredToggleState] = [:]

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
    var emptyStateFetchedCount: Int { store.emptyStateFetchedCount }
    var emptyStateFetchTotal: Int { store.emptyStateFetchTotal }
    var hasPreviouslyLoadedContent: Bool { store.hasPreviouslyLoadedContent }
    var isUrgentFetching: Bool { store.isUrgentFetching }
    var startupFetchedSourceCount: Int { store.startupFetchedSourceCount }
    var startupTargetSourceCount: Int { store.startupTargetSourceCount }
    var startupTotalSourceCount: Int { store.startupTotalSourceCount }
    var startupRecentSourceNames: [String] { store.startupRecentSourceNames }
    var startupRunwayReady: Bool { store.startupRunwayReady }
    var isPreparingInitialRunway: Bool { store.isPreparingInitialRunway }
    var catalogDiagnosticsStatus = FeedEngineCatalogDiagnosticsStatus.idle
    private var catalogDiagnosticsTask: Task<Void, Never>?
    private var catalogUpdateTask: Task<Void, Never>?

    // MARK: - Date Sections

    struct DateSection: Identifiable {
        let id: String
        let title: String
        let items: [FeedItem]
        let showsHeader: Bool

        init(id: String? = nil, title: String, items: [FeedItem], showsHeader: Bool = true) {
            self.id = id ?? title
            self.title = title
            self.items = items
            self.showsHeader = showsHeader
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
        case forum = "Forums"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .all: return "circle.grid.3x3.fill"
            case .text: return "doc.text.fill"
            case .video: return "play.rectangle.fill"
            case .audio: return "headphones"
            case .forum: return "bubble.left.and.bubble.right.fill"
            }
        }
        func matches(_ item: FeedItem) -> Bool {
            switch self {
            case .all: return true
            case .text: return !item.isYouTube && !item.isPodcast && !item.isForum
            case .video: return item.isYouTube
            case .audio: return item.isPodcast
            case .forum: return item.isForum
            }
        }
    }
    // Single source of truth: all filter state lives in FeedStore
    var selectedContentType: ContentType { store.activeContentType }
    var selectedMood: MoodFilter { store.activeMood }
    var selectedNodeIDs: Set<String> { store.activeNodeIDs }
    var selectedNodeNames: [String] { TaxonomyStore.shared.selectedNodeNames }
    var selectedLanguages: Set<String> { store.activeLanguages }
    var selectedRegion: String? { store.activeRegion }
    var hasLanguageSelection: Bool { !store.activeLanguages.isEmpty }
    var hasTaxonomySelection: Bool { !selectedNodeIDs.isEmpty }
    var hasRegionSelection: Bool { selectedRegion != nil }
    var hasActiveFilters: Bool {
        hasRegionSelection || hasTaxonomySelection || selectedMood != .all || selectedContentType != .all || hasLanguageSelection
    }
    var activeFilterCount: Int {
        var count = 0
        if hasRegionSelection { count += 1 }
        count += selectedNodeIDs.count
        count += selectedLanguages.count
        if selectedContentType != .all { count += 1 }
        if selectedMood != .all { count += 1 }
        if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { count += 1 }
        return count
    }
    var availableTaxonomyRoot: TaxonomyNode? { TaxonomyStore.shared.root }

    /// Backward-compat: returns name of first selected node, or nil.
    var selectedCategory: String? {
        selectedNodeIDs.first.flatMap { TaxonomyStore.shared.flatIndex[$0]?.name }
    }

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

    // MARK: - Language Filter

    struct LanguageInfo: Identifiable {
        var id: String { code }
        let code: String       // ISO 639-1
        let name: String       // localized display name
        let flag: String       // emoji flag
        let feedCount: Int     // enabled sources matching this language
        let totalFeedCount: Int
    }

    @ObservationIgnored private var _cachedAvailableLanguages: [LanguageInfo] = []
    @ObservationIgnored private var _cachedAvailableLanguagesSourceRevision: UInt64?
    @ObservationIgnored private var _cachedAvailableLanguagesEnablementRevision: UInt64?
    @ObservationIgnored private var _cachedAvailableLanguagesLocaleIdentifier: String?

    // MARK: - Search

    var searchQuery: String = ""
    var isSearching: Bool { store.isSearching }
    var isSearchLoading: Bool { store.isSearchLoading }
    var unifiedSearchResults: UnifiedSearchResults { store.unifiedSearchResults }

    // MARK: - Filtered Items (reads from FeedStore as single source)

    private var _cachedFiltered: [FeedItem] = []
    private var _cachedGeneration: UInt64?
    private var _cachedSearchQuery: String?

    var filteredItems: [FeedItem] {
        let generation = store.visibleItemsGeneration
        if _cachedGeneration == generation, _cachedSearchQuery == searchQuery {
            return _cachedFiltered
        }
        _cachedGeneration = generation
        _cachedSearchQuery = searchQuery
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
    private var _cachedDateSectionsGen: UInt64?
    private var _cachedDateSectionsQuery: String?

    var dateSections: [DateSection] {
        let items = filteredItems
        if _cachedDateSectionsGen == _cachedGeneration, _cachedDateSectionsQuery == _cachedSearchQuery {
            return _cachedSections
        }
        _cachedDateSectionsGen = _cachedGeneration
        _cachedDateSectionsQuery = _cachedSearchQuery
        // A filtered feed already has an intentional provider/category/media
        // order. Regrouping it by date would move all fresh aggregator cards
        // ahead of older independent publishers and undo that diversity.
        if hasActiveFilters || !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _cachedSections = items.isEmpty
                ? []
                : [DateSection(id: "ordered-results", title: "", items: items, showsHeader: false)]
            return _cachedSections
        }
        // Use pre-computed sectionDayOffset when available (new items);
        // fall back to Calendar for older items loaded from SQLite.
        let calendar = Calendar.current; let now = Date()
        var grouped: [String: [FeedItem]] = [:]
        for item in items {
            let section: String
            let offset = item.sectionDayOffset
            if offset > 0 {
                // Pre-computed offset — fast path, no Calendar needed
                if offset == 1 { section = "Yesterday" }
                else if offset < 7 { section = "This Week" }
                else { section = "Earlier" }
            } else {
                // Legacy item or explicit today — use Calendar for accuracy
                if calendar.isDateInToday(item.publishedAt) { section = "Today" }
                else if calendar.isDateInYesterday(item.publishedAt) { section = "Yesterday" }
                else {
                    let days = calendar.dateComponents([.day], from: item.publishedAt, to: now).day ?? 0
                    section = days < 7 ? "This Week" : "Earlier"
                }
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
    var availableCategories: [String] { store.registry.availableCategories }
    var availableLanguages: [LanguageInfo] {
        let counts = store.registry.languageCountSnapshot()
        let localeIdentifier = Locale.current.identifier
        if _cachedAvailableLanguagesSourceRevision == counts.sourceRevision,
           _cachedAvailableLanguagesEnablementRevision == counts.enablementRevision,
           _cachedAvailableLanguagesLocaleIdentifier == localeIdentifier {
            return _cachedAvailableLanguages
        }

        // Use enabled sources so counts reflect what the user can actually see.
        // Normalize to ISO 639-1 base codes so "pt-BR" and "pt" merge into one entry.
        let languages = counts.enabled.map { code, count in
            LanguageInfo(
                code: code,
                name: Locale.current.localizedString(forLanguageCode: code) ?? code,
                flag: Self.flagEmoji(for: code),
                feedCount: count,
                totalFeedCount: counts.total[code] ?? count
            )
        }.sorted { $0.feedCount > $1.feedCount }

        _cachedAvailableLanguages = languages
        _cachedAvailableLanguagesSourceRevision = counts.sourceRevision
        _cachedAvailableLanguagesEnablementRevision = counts.enablementRevision
        _cachedAvailableLanguagesLocaleIdentifier = localeIdentifier
        return languages
    }

    private static let flagEmojiMapping: [String: String] = [
        "pt": "BR", "en": "US", "es": "ES", "fr": "FR", "de": "DE",
        "it": "IT", "ja": "JP", "ko": "KR", "zh": "CN", "ru": "RU",
        "ar": "SA", "hi": "IN", "nl": "NL", "sv": "SE", "no": "NO",
        "da": "DK", "fi": "FI", "pl": "PL", "tr": "TR", "th": "TH",
        "vi": "VN", "id": "ID", "ms": "MY", "fil": "PH", "he": "IL",
        "el": "GR", "cs": "CZ", "ro": "RO", "hu": "HU", "uk": "UA",
        "ca": "ES", "eu": "ES", "gl": "ES",
        "sw": "TZ", "ur": "PK", "fa": "IR", "bn": "BD", "km": "KH",
        "my": "MM", "ne": "NP", "si": "LK", "af": "ZA", "ha": "NG",
        "yo": "NG", "zu": "ZA", "so": "SO", "st": "LS", "tl": "PH",
        "am": "ET", "az": "AZ", "bg": "BG", "bs": "BA", "hr": "HR",
        "et": "EE", "ka": "GE", "is": "IS", "lv": "LV", "lt": "LT",
        "mk": "MK", "mt": "MT", "sk": "SK", "sl": "SI", "sr": "RS",
        "sq": "AL", "hy": "AM", "mn": "MN", "lo": "LA", "kk": "KZ",
        "ky": "KG", "tg": "TJ", "uz": "UZ", "ps": "AF", "ku": "IQ",
        "be": "BY", "ga": "IE", "cy": "GB", "fy": "NL", "lb": "LU",
        "jv": "ID", "su": "ID", "xh": "ZA", "ny": "MW", "mg": "MG",
        "om": "ET", "rw": "RW", "sn": "ZW", "ig": "NG", "ml": "IN",
        "kn": "IN", "ta": "IN", "te": "IN", "mr": "IN", "gu": "IN",
        "pa": "IN", "or": "IN", "as": "IN", "sd": "PK", "bo": "CN",
        "ug": "CN", "yi": "IL", "gd": "GB", "eo": "EU", "la": "VA",
    ]

    private static let flagEmojiBase: UInt32 = 127397

    private static func flagEmoji(for languageCode: String) -> String {
        guard let country = flagEmojiMapping[languageCode] else { return "🌐" }
        return country.unicodeScalars.map { scalar in
            String(UnicodeScalar(flagEmojiBase + scalar.value) ?? "�")
        }.joined()
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
            Log.feed.error("refreshBookmarkState error: \(error)")
        }
    }

    // MARK: - Resources

    var networkMonitor: NetworkMonitor { store.networkMonitor }
    var currentVisibleIndex: Int = 0

    /// Direct index setter — caller already knows the position from ForEach
    /// enumeration, so we skip the O(n) firstIndex(where:) scan.
    func noteVisibleIndex(_ index: Int) {
        currentVisibleIndex = index
    }

    /// O(n) fallback kept for any caller that only has an item reference.
    func noteVisibleIndex(for item: FeedItem) {
        noteVisibleIndex(filteredItems.firstIndex(where: { $0.id == item.id }) ?? 0)
    }
    var loadedIDsCount: Int { store.loadedIDsCount }

    // MARK: - What's New

    var whatsNewLabel: String { "What's New" }
    var whatsNewVisible = false

    /// Refresh What's New once after startup and request a fresh booster batch.
    func loadWhatsNew() async {
        store.refreshWhatsNew(shouldBoost: true)
    }

    /// Mark a What's New item as read and remove it from the carousel immediately.
    func markWhatsNewAsRead(_ id: String) {
        store.markAsRead(id)
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

    /// Non-nil if the default FeedStore failed to initialize.
    private(set) var initError: Error?

    /// Creates a FeedLoader. Pass a custom FeedStore for testing; uses SQLite-backed
    /// store by default. If store creation fails, captures the error for UI display.
    init(store: FeedStore? = nil) {
        if let store {
            self.store = store
        } else {
            do {
                self.store = try FeedStore()
            } catch {
                self.initError = error
                Log.db.error("FeedStore init failed: \(error.localizedDescription). Using in-memory fallback.")
                // FeedStore.empty() creates an in-memory store as a last resort.
                // Uses try! — if even an in-memory store fails, SQLite is
                // fundamentally broken and the app cannot function.
                self.store = FeedStore.empty()
            }
        }
    }

    // MARK: - Actions (delegate to store)

    func start() async {
        await store.start()
        if restoreImportedSources() {
            await TaxonomyStore.shared.build(
                from: store.registry.sources,
                sharedCountrySourceURLs: store.registry.sharedCountrySourceURLs
            )
        }
        do {
            let migratedCount = try await store.migrateImportedSourceCollections()
            if migratedCount > 0 {
                Log.import_.info("Recovered \(migratedCount) imported sources into personal collections")
            }
        } catch {
            Log.import_.error("Failed to recover imported source collections: \(error)")
        }
        await loadWhatsNew()
        await refreshBookmarkLists()
        await refreshBookmarkState()
        await refreshActiveSearchState()
        #if DEBUG || INSTRUMENTATION
        scheduleCatalogDiagnosticsIfNeeded()
        #endif
        scheduleCatalogUpdateIfNeeded()
    }

    /// Local startup is never gated on GitHub. Once the local registry is
    /// usable, check for a newer revision in the background and hot-reload only
    /// after the complete staged snapshot has passed validation.
    private func scheduleCatalogUpdateIfNeeded() {
        guard catalogUpdateTask == nil,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              !ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("-UITest") }) else {
            return
        }

        // This is deliberately the lowest scheduling class: opening and using
        // the local catalog must always win over a remote catalog check.
        // The update service is an independent actor, so its network, staging,
        // checksum and compilation work never runs on the main actor.
        catalogUpdateTask = Task(priority: .background) { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await CatalogUpdateService.shared.updateIfAvailable()
                switch outcome {
                case .current(let revision):
                    FeedMetrics.event("CatalogUpdate.current", "revision=\(revision)")
                case .updated(let from, let to, let changed, let deleted):
                    FeedMetrics.event(
                        "CatalogUpdate.activated",
                        "from=\(from) to=\(to) changed=\(changed) deleted=\(deleted)"
                    )
                    await store.reloadActiveCatalogAfterUpdate()
                }
            } catch {
                // The previous local snapshot stays active for every failure:
                // offline, bad manifest, checksum mismatch, or compile error.
                Log.feed.error("Catalog update kept local snapshot: \(error.localizedDescription)")
            }
            catalogUpdateTask = nil
        }
    }

    #if DEBUG || INSTRUMENTATION
    private func scheduleCatalogDiagnosticsIfNeeded() {
        guard catalogDiagnosticsTask == nil else { return }
        let sources = store.registry.sources

        catalogDiagnosticsStatus = .opening
        let diagnostics = FeedEngineCatalogDiagnostics()
        catalogDiagnosticsTask = Task(priority: .utility) {
            do {
                let status = try await diagnostics.openActiveCatalog()
                catalogDiagnosticsStatus = status
            } catch {
                guard !sources.isEmpty else {
                    FeedMetrics.event("CatalogDiagnostics.failed", error.localizedDescription)
                    catalogDiagnosticsStatus = .failed(error)
                    catalogDiagnosticsTask = nil
                    return
                }
                do {
                    catalogDiagnosticsStatus = .compiling(sourceCount: sources.count)
                    let status = try await diagnostics.compileLegacyCatalog(sources: sources)
                    catalogDiagnosticsStatus = status
                } catch {
                    FeedMetrics.event("CatalogDiagnostics.failed", error.localizedDescription)
                    catalogDiagnosticsStatus = .failed(error)
                }
            }
            catalogDiagnosticsTask = nil
        }
    }
    #endif
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

    func toggleNode(_ nodeID: String) {
        TaxonomyStore.shared.toggle(nodeID)
        let languages = resolvedLanguagesForFilter(store.activeLanguages)
        store.setFilter(region: store.activeRegion,
                        nodeIDs: TaxonomyStore.shared.selectedNodeIDs,
                        type: store.activeContentType, mood: store.activeMood,
                        languages: languages)
    }

    /// Seeds the first reading lens from onboarding in one atomic update.
    /// Keeping the selection local until the final button avoids launching a
    /// filter reload (and an urgent network batch) for every tapped interest.
    func applyOnboardingTopics(_ nodeIDs: Set<String>) {
        let validNodeIDs = nodeIDs.filter { TaxonomyStore.shared.node(id: $0) != nil }
        guard !validNodeIDs.isEmpty else { return }

        TaxonomyStore.shared.selectedNodeIDs = Set(validNodeIDs)
        let languages = resolvedLanguagesForFilter(store.activeLanguages)
        store.setFilter(
            region: store.activeRegion,
            nodeIDs: Set(validNodeIDs),
            type: store.activeContentType,
            mood: store.activeMood,
            languages: languages
        )
    }

    func toggleLanguage(_ code: String) {
        var langs = store.activeLanguages
        if langs.contains(code) {
            langs.remove(code)
        } else {
            langs.insert(code)
        }
        // Removing the last selected language is an explicit "all languages" choice.
        store.hasUserClearedLanguageFilter = langs.isEmpty
        store.setFilter(region: store.activeRegion,
                        nodeIDs: store.activeNodeIDs,
                        type: store.activeContentType, mood: store.activeMood,
                        languages: langs)
    }

    func clearTaxonomySelection() {
        TaxonomyStore.shared.clearSelection()
        let languages = resolvedLanguagesForFilter(store.activeLanguages)
        store.setFilter(region: store.activeRegion,
                        nodeIDs: [],
                        type: store.activeContentType, mood: store.activeMood,
                        languages: languages)
    }

    func clearRegionFilter() {
        let languages = resolvedLanguagesForFilter(store.activeLanguages)
        store.setFilter(region: nil,
                        nodeIDs: store.activeNodeIDs,
                        type: store.activeContentType, mood: store.activeMood,
                        languages: languages)
    }

    /// Backward-compat shim for single-category selection.
    func selectCategory(_ category: String?) {
        if let cat = category {
            if let node = TaxonomyStore.shared.flatIndex.values.first(where: { $0.name == cat }) {
                toggleNode(node.id)
            }
        } else {
            clearTaxonomySelection()
        }
    }

    func selectMood(_ mood: MoodFilter) {
        let newValue = (store.activeMood == mood) ? .all : mood
        let languages = resolvedLanguagesForFilter(store.activeLanguages)
        store.setFilter(region: store.activeRegion, nodeIDs: store.activeNodeIDs,
                        type: store.activeContentType, mood: newValue,
                        languages: languages)
    }

    func selectContentType(_ type: ContentType) {
        let newValue = (store.activeContentType == type) ? .all : type
        let languages = resolvedLanguagesForFilter(store.activeLanguages)
        store.setFilter(region: store.activeRegion, nodeIDs: store.activeNodeIDs,
                        type: newValue, mood: store.activeMood,
                        languages: languages)
    }

    /// Return the user's effective language filter. When no explicit choice
    /// has been made and the user hasn't opted into "all languages," default
    /// to the device language so that content-type-only filters don't show
    /// videos/articles from every language.
    private func resolvedLanguagesForFilter(_ selected: Set<String>) -> Set<String> {
        if !selected.isEmpty { return selected }
        if store.hasUserClearedLanguageFilter { return [] }
        guard let deviceLang = FeedStore.normalizedLanguageCode(
            Locale.current.language.languageCode?.identifier
        ) else { return [] }
        return store.registry.availableLanguageCodes.contains(deviceLang) ? [deviceLang] : []
    }

    func clearAllFilters() {
        searchQuery = ""
        TaxonomyStore.shared.clearSelection()
        store.clearAllFilters()
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
    }
    func setRegionEnabled(_ region: String, enabled: Bool) {
        store.setRegionEnabled(region, enabled: enabled)
    }
    func regionToggleState(for region: String) -> DeferredToggleState {
        pendingRegionToggleStates[region] ?? .none
    }
    func requestRegionEnabled(_ region: String, enabled: Bool) {
        let requested: DeferredToggleState = enabled ? .enabled : .disabled
        pendingRegionToggleStates[region] = requested
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingRegionToggleStates[region] == requested else { return }
            self.store.setRegionEnabled(region, enabled: enabled)
            if self.pendingRegionToggleStates[region] == requested {
                self.pendingRegionToggleStates.removeValue(forKey: region)
            }
        }
    }

    func clearToggleMessage() {
        store.lastToggleMessage = nil
    }
    func beginFilterEditing() { store.beginFilterEditing() }
    func endFilterEditing() { store.endFilterEditing() }
    func applyFilterDraft(type: ContentType, mood: MoodFilter, languages: Set<String>) {
        store.hasUserClearedLanguageFilter = languages.isEmpty
        store.setFilter(
            region: store.activeRegion,
            nodeIDs: store.activeNodeIDs,
            type: type,
            mood: mood,
            languages: languages
        )
    }
    func toggleAllCountries() {
        store.toggleAllCountries()
    }
    func setAllCountriesEnabled(_ enabled: Bool) {
        store.setAllCountriesEnabled(enabled)
    }
    // MARK: - Feed Presets

    /// The active feed preset. Drives scoring multipliers across the fetch pipeline.
    var activePreset: PresetSelector {
        get { store.activePreset }
    }

    /// Change the active preset and trigger a feed reload with new scoring.
    func setActivePreset(_ preset: PresetSelector) {
        store.setPreset(preset)
    }

    // MARK: - Legacy Global Feeds (kept for backward compat)

    func toggleGlobalFeeds() {
        setGlobalFeedsEnabled(!isGlobalFeedsEnabled)
    }
    func setGlobalFeedsEnabled(_ enabled: Bool) {
        store.setTopicRegionsEnabled(enabled)
    }
    func toggleSource(_ sourceURL: String) { store.toggleSource(sourceURL) }
    /// True if the region is not explicitly disabled. Partial (disabled but
    /// some sources overridden) still counts as disabled from the user's POV.
    func isRegionEnabled(_ region: String) -> Bool { store.registry.status(of: SourceRegistry.regionKey(region)) == .on }
    func isSourceEnabled(_ url: String) -> Bool { store.registry.isSourceEnabled(url) }
    func nodeStatus(for key: String) -> NodeStatus { store.registry.status(of: key) }
    func activeCount(for key: String) -> Int { store.registry.activeCount(for: key) }
    func toggleCategory(_ category: String) { store.toggleCategory(category) }
    func setCategoryEnabled(_ category: String, enabled: Bool) {
        store.setCategoryEnabled(category, enabled: enabled)
    }
    /// True if the category is not explicitly disabled.
    func isCategoryEnabled(_ category: String) -> Bool { store.registry.status(of: SourceRegistry.categoryKey(category)) == .on }
    var isAnyCountryEnabled: Bool { store.registry.isAnyCountryEnabled }
    /// True when at least one topic region (or legacy global) is enabled.
    /// A partial state (some on, some off) still returns true — the toggle
    /// will turn everything off.  Use `globalFeedsStatus` for the three-way
    /// ON / OFF / PARTIAL distinction in UI.
    var isGlobalFeedsEnabled: Bool {
        let topicRegions = store.registry.allTopicRegions
        if !topicRegions.isEmpty {
            return topicRegions.contains { store.registry.status(of: SourceRegistry.regionKey($0)) == .on }
        }
        return store.registry.status(of: SourceRegistry.regionKey("global")) == .on
    }

    /// Three-way status for the Global Feeds toggle: ON (all topic groups
    /// enabled), OFF (none enabled), or PARTIAL (some enabled).
    var globalFeedsStatus: NodeStatus {
        let topicRegions = store.registry.allTopicRegions
        let keys = topicRegions.isEmpty
            ? [SourceRegistry.regionKey("global")]
            : topicRegions.map { SourceRegistry.regionKey($0) }
        let statuses = keys.map { store.registry.status(of: $0) }
        let onCount = statuses.filter { $0 == .on }.count
        if onCount == keys.count { return .on }
        if onCount == 0 { return .off }
        return .partial(activeCount: store.registry.sources
            .filter { $0.region.hasPrefix("topic/") || $0.region == "global" }
            .filter { store.registry.isSourceEnabled($0.url) }
            .count)
    }

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

    func sourceReference(for item: FeedItem) -> SourceReference {
        store.sourceReference(for: item)
    }

    func sourceReference(for member: SourceCollectionMember) -> SourceReference {
        store.sourceReference(for: member)
    }

    func sourceContentFromCache(_ source: SourceReference) async -> [FeedItem] {
        await store.sourceContentFromCache(source)
    }

    func loadSourceContent(_ source: SourceReference) async -> SourceContentResult {
        await store.loadSourceContent(source)
    }

    func loadSourceCollections() async throws -> [SourceCollection] {
        try await store.allSourceCollections()
    }

    @discardableResult
    func createSourceCollection(name: String) async throws -> Int64 {
        try await store.createSourceCollection(name: name)
    }

    func renameSourceCollection(id: Int64, name: String) async throws {
        try await store.renameSourceCollection(id: id, name: name)
    }

    func deleteSourceCollection(id: Int64) async throws {
        try await store.deleteSourceCollection(id: id)
    }

    func reorderSourceCollections(ids: [Int64]) async throws {
        try await store.reorderSourceCollections(ids: ids)
    }

    func sourceCollectionMembers(collectionID: Int64) async throws -> [SourceCollectionMember] {
        try await store.sourceCollectionMembers(collectionID: collectionID)
    }

    func addSource(_ source: SourceReference, toCollectionID id: Int64) async throws {
        try await store.addSource(source, toCollectionID: id)
    }

    @discardableResult
    func addSourceURLs(_ sourceURLs: [String], toCollectionID id: Int64) async throws -> Int {
        try await store.addSourceURLs(sourceURLs, toCollectionID: id)
    }

    func removeSource(_ sourceURL: String, fromCollectionID id: Int64) async throws {
        try await store.removeSource(sourceURL, fromCollectionID: id)
    }

    func reorderSourceCollectionMembers(collectionID: Int64, sourceURLs: [String]) async throws {
        try await store.reorderSourceCollectionMembers(collectionID: collectionID, sourceURLs: sourceURLs)
    }

    func sourceCollectionIDs(containing sourceURL: String) async throws -> Set<Int64> {
        try await store.sourceCollectionIDs(containing: sourceURL)
    }

    func loadSourceCollectionContent(collectionID: Int64) async throws -> SourceCollectionContentResult {
        try await store.loadSourceCollectionContent(collectionID: collectionID)
    }

    // MARK: - Import Pipeline

    private let importPipeline = ImportPipeline()

    /// Legacy addSources — still works but prefer importFeeds for new code.
    func addSources(_ newSources: [FeedSource]) {
        store.registry.sources = OPMLParser.deduplicateSources(
            store.registry.sources + newSources
        )
        persistImportedSources()
        Task {
            await TaxonomyStore.shared.build(
                from: store.registry.sources,
                sharedCountrySourceURLs: store.registry.sharedCountrySourceURLs
            )
        }
        // Trigger fetch for new sources + reload feed
        Task { await fetchAndReloadAfterImport(newSources) }
    }

    /// Replace the entire source list (used by collection management: rename, delete, move).
    func replaceAllSources(_ sources: [FeedSource]) {
        store.registry.sources = sources
        persistImportedSources()
        Task {
            await TaxonomyStore.shared.build(
                from: store.registry.sources,
                sharedCountrySourceURLs: store.registry.sharedCountrySourceURLs
            )
        }
    }

    /// Import feed URLs (paste, share sheet, etc.) with full validation.
    /// Pass `skipValidation: true` when URLs come from URLResolver (already probed).
    /// Returns ImportResult for UI feedback.
    func importFeeds(urls: [String], category: String = "Imported", skipValidation: Bool = false) async -> ImportResult {
        let existingURLs = Set(store.registry.sources.map { OPMLParser.normalizeURL($0.url) })

        if skipValidation {
            // URLs already validated by URLResolver — skip probe, just dedup + register
            var results: [ImportItemResult] = []
            var newSources: [FeedSource] = []
            for rawURL in urls {
                let normalized = OPMLParser.normalizeURL(rawURL)
                if existingURLs.contains(normalized) {
                    results.append(ImportItemResult(url: rawURL, title: nil, status: .duplicate))
                } else {
                    let kind = ImportPipeline.detectMediaKind(url: normalized, title: nil)
                    let source = FeedSource(
                        title: ImportPipeline.titleFromURL(normalized),
                        url: normalized, category: category, region: "imported", mediaKind: kind
                    )
                    newSources.append(source)
                    results.append(ImportItemResult(url: normalized, title: source.title, status: .imported))
                }
            }
            if !newSources.isEmpty {
                store.registry.sources = OPMLParser.deduplicateSources(
                    store.registry.sources + newSources
                )
                persistImportedSources()
                await TaxonomyStore.shared.build(
                    from: store.registry.sources,
                    sharedCountrySourceURLs: store.registry.sharedCountrySourceURLs
                )
                await fetchAndReloadAfterImport(newSources)
            }
            return ImportResult(items: results)
        }

        let (result, sources) = await importPipeline.ingest(
            urls: urls, category: category, existingURLs: existingURLs
        )
        if !sources.isEmpty {
            store.registry.sources = OPMLParser.deduplicateSources(
                store.registry.sources + sources
            )
            persistImportedSources()
            await TaxonomyStore.shared.build(
                from: store.registry.sources,
                sharedCountrySourceURLs: store.registry.sharedCountrySourceURLs
            )
            await fetchAndReloadAfterImport(sources)
        }
        return result
    }

    /// Import from OPML file data (file picker, AirDrop).
    func importOPML(data: Data, fileName: String, validate: Bool = false) async -> ImportResult {
        let existingURLs = Set(store.registry.sources.map { OPMLParser.normalizeURL($0.url) })
        let (result, sources) = await importPipeline.ingest(
            opmlData: data, fileName: fileName, existingURLs: existingURLs, validate: validate
        )
        if !sources.isEmpty {
            store.registry.sources = OPMLParser.deduplicateSources(
                store.registry.sources + sources
            )
            persistImportedSources()
            await TaxonomyStore.shared.build(
                from: store.registry.sources,
                sharedCountrySourceURLs: store.registry.sharedCountrySourceURLs
            )
            await fetchAndReloadAfterImport(sources)
        }
        return result
    }

    /// Import from a remote OPML URL.
    func importOPML(url: URL, validate: Bool = false) async -> ImportResult? {
        let existingURLs = Set(store.registry.sources.map { OPMLParser.normalizeURL($0.url) })
        guard let (result, sources) = await importPipeline.ingest(
            opmlURL: url, existingURLs: existingURLs, validate: validate
        ) else { return nil }
        if !sources.isEmpty {
            store.registry.sources = OPMLParser.deduplicateSources(
                store.registry.sources + sources
            )
            persistImportedSources()
            await TaxonomyStore.shared.build(
                from: store.registry.sources,
                sharedCountrySourceURLs: store.registry.sharedCountrySourceURLs
            )
            await fetchAndReloadAfterImport(sources)
        }
        return result
    }

    /// After importing new sources: fetch their content immediately and reload the feed.
    private func fetchAndReloadAfterImport(_ sources: [FeedSource]) async {
        let batch = Array(sources.prefix(20))  // Cap first fetch to 20 sources
        let result = await store.fetcher.fetchAll(batch, maxConcurrent: 5)
        let actualNew = await store.persistFetchedItems(result.items)
        if !actualNew.isEmpty {
            store.throttledReservoirAppend(actualNew)
            store.collectWhatsNewCandidates(actualNew)
        }
        // Force reload to show new content
        store.setFilter(
            region: store.activeRegion,
            nodeIDs: store.activeNodeIDs,
            type: store.activeContentType,
            mood: store.activeMood,
            languages: store.activeLanguages
        )
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
            Log.import_.error("Failed to persist imported sources: \(error)")
        }
    }

    /// Restore previously imported sources from disk on app launch.
    /// Merges them into the registry without duplicating bundled sources.
    @discardableResult
    private func restoreImportedSources() -> Bool {
        let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("imported_sources.json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return false }
        do {
            let data = try Data(contentsOf: fileURL)
            let imported = try JSONDecoder().decode([FeedSource].self, from: data)
            guard !imported.isEmpty else { return false }
            let sourceCountBeforeRestore = store.registry.sources.count
            store.registry.sources = OPMLParser.deduplicateSources(
                store.registry.sources + imported
            )
            store.registry.prepareFilterCaches()
            Log.import_.info("Restored \(imported.count) imported sources")
            return store.registry.sources.count > sourceCountBeforeRestore
        } catch {
            Log.import_.error("Failed to restore imported sources: \(error)")
            return false
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
