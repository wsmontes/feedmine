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

    /// Layout mode: card or compact list
    enum FeedLayout { case card, list }
    var layout: FeedLayout = .card

    /// Search query for filtering by title and excerpt
    var searchQuery = ""

    /// Items filtered by selected category AND search query
    var filteredItems: [FeedItem] {
        var result = items
        if let category = selectedCategory {
            result = result.filter { $0.category.lowercased() == category.lowercased() }
        }
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(query) ||
                $0.excerpt.localizedCaseInsensitiveContains(query)
            }
        }
        return result
    }

    /// Available categories from loaded sources
    var availableCategories: [String] {
        let cats = Set(sources.map { $0.category }).sorted()
        return cats
    }

    /// Track which items have been opened
    var readItemIDs: Set<String> = []

    func markAsRead(_ itemID: String) {
        readItemIDs.insert(itemID)
    }

    func isRead(_ itemID: String) -> Bool {
        readItemIDs.contains(itemID)
    }

    /// Bookmarked item IDs
    var bookmarkedIDs: Set<String> = []

    func toggleBookmark(_ itemID: String) {
        if bookmarkedIDs.contains(itemID) {
            bookmarkedIDs.remove(itemID)
        } else {
            bookmarkedIDs.insert(itemID)
        }
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

    // MARK: - Internal state
    private let fetcher = RSSFetcher()
    private var sources: [FeedSource] = []
    private var reservoir: [FeedItem] = []
    private var loadedIDs: Set<String> = []
    private var currentVisibleIndex: Int = 0
    private var hasStarted = false

    // MARK: - Constants
    static let maxBuffer = 300
    static let loadMoreThreshold = 15
    static let discardBatchSize = 50
    static let initialWindowSize = 50
    static let reservoirLowWatermark = 20
    static let safetyZoneRadius = 50

    // MARK: - Public methods

    func selectCategory(_ category: String?) {
        selectedCategory = (selectedCategory == category) ? nil : category
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        loadingState = .initial

        // Step 1: Parse OPML
        let parseResult = OPMLParser.parseAll()
        sources = parseResult.sources
        opmlFileCount = parseResult.fileCount
        opmlErrorCount = parseResult.failedFileCount
        invalidSourceCount = parseResult.invalidSourceCount
        duplicateSourceCount = parseResult.duplicateSourceCount
        sourceCount = sources.count

        guard !sources.isEmpty else {
            loadingState = .idle
            return
        }

        // Step 2: Fetch from all sources
        let batch = await fetcher.fetchAll(sources)
        totalFetched = batch.items.count
        fetchErrorCount = batch.failedSourceCount
        emptyFeedCount = batch.emptySourceCount

        // Step 3: Deduplicate and register ALL accepted item IDs
        let actualNew = batch.items.filter { !loadedIDs.contains($0.id) }
        loadedIDs.formUnion(actualNew.map(\.id))

        // Step 4: Sort by publish date descending, fill reservoir
        reservoir = actualNew.sorted { $0.publishedAt > $1.publishedAt }

        // Step 5: Move initial window from reservoir to visible items
        let windowSize = min(Self.initialWindowSize, reservoir.count)
        items = Array(reservoir.prefix(windowSize))
        reservoir.removeFirst(windowSize)
        reservoirCount = reservoir.count

        loadingState = .idle
    }

    func refresh() async {
        loadingState = .refreshing

        // Clear all state
        loadedIDs.removeAll()
        reservoir.removeAll()
        items.removeAll()
        totalDiscarded = 0

        guard !sources.isEmpty else {
            loadingState = .idle
            return
        }

        let batch = await fetcher.fetchAll(sources)
        totalFetched = batch.items.count
        fetchErrorCount = batch.failedSourceCount
        emptyFeedCount = batch.emptySourceCount

        let actualNew = batch.items.filter { !loadedIDs.contains($0.id) }
        loadedIDs.formUnion(actualNew.map(\.id))

        reservoir = actualNew.sorted { $0.publishedAt > $1.publishedAt }

        let windowSize = min(Self.initialWindowSize, reservoir.count)
        items = Array(reservoir.prefix(windowSize))
        reservoir.removeFirst(windowSize)
        reservoirCount = reservoir.count

        loadingState = .idle
    }

    func loadMoreIfNeeded(currentItem: FeedItem) async {
        // Track visible position
        if let index = items.firstIndex(where: { $0.id == currentItem.id }) {
            currentVisibleIndex = index
        }

        guard loadingState == .idle else { return }

        // Only trigger when near the bottom
        guard let itemIndex = items.firstIndex(where: { $0.id == currentItem.id }),
              itemIndex >= items.count - Self.loadMoreThreshold else {
            return
        }

        // Step 1: If reservoir is empty, fetch first
        var didFetch = false
        if reservoir.isEmpty {
            loadingState = .loadingMore
            await refillReservoir()
            loadingState = .idle
            didFetch = true
        }

        // Step 2: Move from reservoir to visible (show content we already have)
        moveFromReservoirToVisible(count: Self.loadMoreThreshold)

        // Step 3: Always trim after adding items (regardless of network fetch)
        trimBufferIfNeeded()

        // Step 4: Refill reservoir in background if low (skip if Step 1 already fetched)
        if !didFetch && reservoir.count < Self.reservoirLowWatermark {
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
            currentVisibleIndex -= aboveToDiscard  // adjust index after removal
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
    }

    // MARK: - Private

    private func moveFromReservoirToVisible(count: Int) {
        guard !reservoir.isEmpty else { return }
        let toMove = min(count, reservoir.count)
        let batch = Array(reservoir.prefix(toMove))
        items.append(contentsOf: batch)
        reservoir.removeFirst(toMove)
        reservoirCount = reservoir.count
    }

    private func refillReservoir() async {
        guard !sources.isEmpty else { return }

        let batch = await fetcher.fetchAll(sources)
        totalFetched += batch.items.count
        fetchErrorCount += batch.failedSourceCount
        emptyFeedCount += batch.emptySourceCount

        let actualNew = batch.items.filter { !loadedIDs.contains($0.id) }
        loadedIDs.formUnion(actualNew.map(\.id))

        let sorted = actualNew.sorted { $0.publishedAt > $1.publishedAt }
        reservoir.append(contentsOf: sorted)
        reservoir.sort { $0.publishedAt > $1.publishedAt }
        reservoirCount = reservoir.count
    }
}
