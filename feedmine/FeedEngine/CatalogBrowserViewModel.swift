import Foundation
import Observation

// MARK: - CatalogBrowserViewModel

/// Main-actor-bound observable ViewModel wrapping ``FeedEngineProtocol``.
///
/// This is the sole UI entry point for catalog browsing and search. It manages
/// a navigation stack of taxonomy nodes, paginated browse/source lists, and
/// full-text search — all backed by the active local ``catalog.sqlite``.
///
/// **Browse** operations (``loadRoot()``, ``navigate(to:)``, ``goBack()``,
/// ``goToRoot()``) are *synchronous-async*: they await the network/Database
/// fetch before returning and reset browse state on each call.
///
/// **Search** is debounced (~300 ms) via ``scheduleSearchIfNeeded()`` and
/// updates only ``searchResults``/``searchNextCursor``, leaving browse state
/// intact.
@MainActor
@Observable
final class CatalogBrowserViewModel {
    // MARK: - Dependencies

    private let engine: FeedEngineProtocol

    // MARK: - Browse State

    /// Current navigation stack of taxonomy nodes. Empty means root.
    private(set) var navigationPath: [CatalogNodeSummary] = []

    /// Child taxonomy nodes at the current level.
    private(set) var nodes: [CatalogNodeSummary] = []

    /// Feed sources at the current level.
    private(set) var sources: [SourceSummary] = []

    /// Feed sources matching the active search query.
    private(set) var searchResults: [SourceSummary] = []

    /// Full details for the source the user tapped.
    private(set) var selectedSourceDetails: SourceDetails?

    // MARK: - Loading Flags

    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var isSearching = false
    private(set) var isLoadingDetails = false
    private(set) var loadingDetailsSourceID: SourceID?
    private(set) var errorMessage: String?
    private(set) var estimatedTotalCount: Int?

    // MARK: - Search Text (triggers debounced search)

    var searchText = "" {
        didSet { scheduleSearchIfNeeded() }
    }

    // MARK: - Cursors (private — views use computed properties below)

    private var browseNextCursor: CatalogCursor?
    private var searchNextCursor: CatalogCursor?

    /// Cancellable search task. Marked `@ObservationIgnored` to avoid
    /// runtime observation of a non-Sendable `Task` value.
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    // MARK: - Init

    init(engine: FeedEngineProtocol) {
        self.engine = engine
    }

    // MARK: - Computed Properties

    /// The current node ID — root if navigation path is empty.
    var currentNodeID: CatalogNodeID {
        navigationPath.last?.id ?? .root
    }

    /// Display name for the current level.
    var currentNodeName: String {
        navigationPath.last?.name ?? "Catalog"
    }

    /// The source list the view should display.
    var displaySources: [SourceSummary] {
        isSearching ? searchResults : sources
    }

    /// Whether more browse pages can be loaded (not while searching).
    var canLoadMoreBrowse: Bool {
        browseNextCursor != nil && !isSearching
    }

    /// Whether more search pages can be loaded.
    var canLoadMoreSearch: Bool {
        searchNextCursor != nil && isSearching
    }

    /// Whether there is anything to display.
    var hasContent: Bool {
        !nodes.isEmpty || !displaySources.isEmpty
    }

    // MARK: - Browse Operations

    /// Load the root catalog level.
    ///
    /// Resets all browse state and awaits the fetch before returning.
    func loadRoot() async {
        isLoading = true
        errorMessage = nil
        resetBrowseState()

        defer { isLoading = false }

        do {
            let query = CatalogBrowseQuery(parentID: nil)
            let page = try await engine.browseCatalog(
                query: query,
                cursor: nil,
                limit: FeedEnginePageLimit.defaultLimit
            )
            applyBrowsePage(page)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Navigate into a child taxonomy node.
    ///
    /// Appends the node to ``navigationPath``, resets browse state, and
    /// awaits the fetch before returning.
    func navigate(to node: CatalogNodeSummary) async {
        navigationPath.append(node)
        isLoading = true
        errorMessage = nil
        resetBrowseState()

        defer { isLoading = false }

        do {
            let query = CatalogBrowseQuery(parentID: node.id)
            let page = try await engine.browseCatalog(
                query: query,
                cursor: nil,
                limit: FeedEnginePageLimit.defaultLimit
            )
            applyBrowsePage(page)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Pop one level in the navigation stack and reload.
    ///
    /// No-op when already at root. Awaits the fetch before returning.
    func goBack() async {
        guard !navigationPath.isEmpty else { return }
        navigationPath.removeLast()

        isLoading = true
        errorMessage = nil
        resetBrowseState()

        defer { isLoading = false }

        do {
            let query = CatalogBrowseQuery(parentID: currentNodeID)
            let page = try await engine.browseCatalog(
                query: query,
                cursor: nil,
                limit: FeedEnginePageLimit.defaultLimit
            )
            applyBrowsePage(page)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Pop the entire navigation stack and reload the root.
    func goToRoot() async {
        navigationPath.removeAll()
        await loadRoot()
    }

    /// Load the next browse page, appending results to existing arrays.
    ///
    /// No-ops while a search is active to avoid polluting browse state.
    func loadNextPage() async {
        guard !isSearching, let cursor = browseNextCursor else { return }
        isLoadingMore = true
        errorMessage = nil

        defer { isLoadingMore = false }

        do {
            let query = CatalogBrowseQuery(parentID: currentNodeID)
            let page = try await engine.browseCatalog(
                query: query,
                cursor: cursor,
                limit: FeedEnginePageLimit.defaultLimit
            )
            nodes.append(contentsOf: page.nodes)
            sources.append(contentsOf: page.sources)
            browseNextCursor = page.nextCursor
            if let total = page.estimatedTotalCount {
                estimatedTotalCount = total
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Search Operations

    /// Execute a search against the catalog.
    ///
    /// If ``searchText`` is empty the search state is silently reset without
    /// calling ``clearSearch()`` (avoids re-triggering the debounce from
    /// ``searchText.didSet``).
    func runSearch() async {
        guard !searchText.isEmpty else {
            // searchText was cleared — state is already reset by clearSearch()
            // so just return early to avoid re-entering clearSearch().
            return
        }

        isSearching = true
        isLoading = true
        errorMessage = nil
        searchResults = []
        searchNextCursor = nil

        defer { isLoading = false }

        do {
            let query = CatalogSearchQuery(text: searchText)
            let page = try await engine.searchCatalog(
                query: query,
                cursor: nil,
                limit: FeedEnginePageLimit.defaultLimit
            )
            searchResults = page.sources
            searchNextCursor = page.nextCursor
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Load the next search results page.
    ///
    /// No-ops when not currently searching.
    func loadNextSearchPage() async {
        guard isSearching, let cursor = searchNextCursor else { return }
        isLoadingMore = true
        errorMessage = nil

        defer { isLoadingMore = false }

        do {
            let query = CatalogSearchQuery(text: searchText)
            let page = try await engine.searchCatalog(
                query: query,
                cursor: cursor,
                limit: FeedEnginePageLimit.defaultLimit
            )
            searchResults.append(contentsOf: page.sources)
            searchNextCursor = page.nextCursor
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Cancel any in-flight search, reset search text, and clear search state.
    func clearSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchText = ""
        isSearching = false
        searchResults = []
        searchNextCursor = nil
        errorMessage = nil
    }

    /// Debounced search scheduler.
    ///
    /// Cancels any previous search task and starts a new one that waits ~300 ms
    /// before calling ``runSearch()``. The new task is stored so it can be
    /// cancelled if ``searchText`` changes again before the delay elapses.
    private func scheduleSearchIfNeeded() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000) // 300 ms
            guard !Task.isCancelled else { return }
            await self?.runSearch()
        }
    }

    // MARK: - Source Details

    /// Load full details for a given source.
    ///
    /// Sets ``loadingDetailsSourceID`` before the fetch and clears it in
    /// `defer` — always, even on cancellation or error.
    func loadSourceDetails(for sourceID: SourceID) async {
        isLoadingDetails = true
        loadingDetailsSourceID = sourceID

        defer {
            isLoadingDetails = false
            loadingDetailsSourceID = nil
        }

        do {
            let details = try await engine.loadSourceDetails(sourceID: sourceID)
            selectedSourceDetails = details
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Dismiss the currently displayed source details.
    func clearSourceDetails() {
        selectedSourceDetails = nil
    }

    /// Dismiss the current error message.
    func clearError() {
        errorMessage = nil
    }

    // MARK: - Helpers

    /// Reset all browse-related state (nodes, sources, cursor, count).
    private func resetBrowseState() {
        nodes = []
        sources = []
        browseNextCursor = nil
        estimatedTotalCount = nil
    }

    /// Apply a ``CatalogPage`` to the current browse state.
    private func applyBrowsePage(_ page: CatalogPage) {
        nodes = page.nodes
        sources = page.sources
        browseNextCursor = page.nextCursor
        estimatedTotalCount = page.estimatedTotalCount
    }
}
