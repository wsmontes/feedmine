import XCTest
@testable import feedmine

// MARK: - Stub Feed Engine

private final class StubFeedEngine: FeedEngineProtocol, @unchecked Sendable {
    var browseResponses: [CatalogPage] = []
    var searchResponses: [CatalogPage] = []
    var detailResponses: [SourceID: SourceDetails] = [:]
    var browseError: Error?
    var searchError: Error?
    var detailError: Error?

    private var browseCallCount = 0
    private var searchCallCount = 0

    func browseCatalog(
        query: CatalogBrowseQuery,
        cursor: CatalogCursor?,
        limit: Int
    ) async throws -> CatalogPage {
        if let error = browseError { throw error }
        defer { browseCallCount += 1 }
        guard browseCallCount < browseResponses.count else {
            return CatalogPage(nodes: [], sources: [], nextCursor: nil, estimatedTotalCount: nil)
        }
        return browseResponses[browseCallCount]
    }

    func searchCatalog(
        query: CatalogSearchQuery,
        cursor: CatalogCursor?,
        limit: Int
    ) async throws -> CatalogPage {
        if let error = searchError { throw error }
        defer { searchCallCount += 1 }
        guard searchCallCount < searchResponses.count else {
            return CatalogPage(nodes: [], sources: [], nextCursor: nil, estimatedTotalCount: nil)
        }
        return searchResponses[searchCallCount]
    }

    func loadSourceDetails(sourceID: SourceID) async throws -> SourceDetails {
        if let error = detailError { throw error }
        guard let details = detailResponses[sourceID] else {
            throw FeedEngineError.sourceNotFound(sourceID)
        }
        return details
    }

    func loadTimeline(
        query: ContentQuery,
        cursor: TimelineCursor?,
        limit: Int
    ) async throws -> TimelinePage {
        throw FeedEngineError.unsupportedTimelineRepository
    }
}

// MARK: - Tests

@MainActor
final class CatalogBrowserViewModelTests: XCTestCase {

    // MARK: - Factory Helpers

    private func makeNode(
        id: UInt32 = 1,
        name: String = "Node",
        kind: CatalogNodeKind = .topic,
        sourceCount: Int = 0,
        childCount: Int = 0,
        language: String? = nil
    ) -> CatalogNodeSummary {
        CatalogNodeSummary(
            id: CatalogNodeID(rawValue: id),
            name: name,
            kind: kind,
            sourceCount: sourceCount,
            childCount: childCount,
            language: language
        )
    }

    private func makeSource(
        id: UInt32 = 1,
        title: String = "Source",
        displayHost: String? = nil,
        mediaKind: MediaKind = .text,
        language: String? = nil
    ) -> SourceSummary {
        SourceSummary(
            id: SourceID(rawValue: id),
            title: title,
            displayHost: displayHost,
            mediaKind: mediaKind,
            language: language
        )
    }

    private func makeDetails(
        id: UInt32 = 1,
        title: String = "Detailed Source",
        urlString: String = "https://example.com/feed"
    ) -> SourceDetails {
        SourceDetails(
            id: SourceID(rawValue: id),
            title: title,
            declaredURL: URL(string: urlString)!,
            requestURL: URL(string: urlString)!,
            mediaKind: .text,
            language: nil,
            placements: []
        )
    }

    private func page(
        nodes: [CatalogNodeSummary] = [],
        sources: [SourceSummary] = [],
        cursor: CatalogCursor? = nil,
        estimatedTotalCount: Int? = nil
    ) -> CatalogPage {
        CatalogPage(
            nodes: nodes,
            sources: sources,
            nextCursor: cursor,
            estimatedTotalCount: estimatedTotalCount
        )
    }

    // MARK: - loadRoot()

    func test_loadRoot_populatesNodesAndSourcesAndClearsNavigation() async {
        let engine = StubFeedEngine()
        let node = makeNode(id: 1, name: "Countries", childCount: 5)
        let source = makeSource(id: 100, title: "Test Source")
        engine.browseResponses = [page(nodes: [node], sources: [source])]

        let viewModel = CatalogBrowserViewModel(engine: engine)

        XCTAssertTrue(viewModel.navigationPath.isEmpty)
        XCTAssertTrue(viewModel.nodes.isEmpty)
        XCTAssertTrue(viewModel.sources.isEmpty)
        XCTAssertNil(viewModel.errorMessage)

        await viewModel.loadRoot()

        XCTAssertTrue(viewModel.navigationPath.isEmpty, "navigationPath should remain empty at root")
        XCTAssertEqual(viewModel.nodes.count, 1)
        XCTAssertEqual(viewModel.nodes.first?.name, "Countries")
        XCTAssertEqual(viewModel.sources.count, 1)
        XCTAssertEqual(viewModel.sources.first?.title, "Test Source")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isLoading)
    }

    // MARK: - navigate(to:)

    func test_navigate_pushesNodeAndLoadsPage() async {
        let engine = StubFeedEngine()
        let rootNode = makeNode(id: 1, name: "Countries", childCount: 5)
        let childSource = makeSource(id: 100, title: "Brazil Source")
        engine.browseResponses = [
            page(nodes: [rootNode]),
            page(sources: [childSource]),
        ]

        let viewModel = CatalogBrowserViewModel(engine: engine)
        await viewModel.loadRoot()
        XCTAssertTrue(viewModel.nodes.isEmpty == false)

        let childNode = CatalogNodeSummary(
            id: CatalogNodeID(rawValue: 2),
            name: "Brazil",
            kind: .country,
            sourceCount: 10,
            childCount: 0,
            language: "pt"
        )
        await viewModel.navigate(to: childNode)

        XCTAssertEqual(viewModel.navigationPath.count, 1)
        XCTAssertEqual(viewModel.navigationPath.first?.name, "Brazil")
        XCTAssertTrue(viewModel.nodes.isEmpty, "child page should have no sub-nodes")
        XCTAssertEqual(viewModel.sources.count, 1)
        XCTAssertEqual(viewModel.sources.first?.title, "Brazil Source")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isLoading)
    }

    // MARK: - goBack()

    func test_goBack_popsAndReloadsPreviousLevel() async {
        let engine = StubFeedEngine()
        let rootNode = makeNode(id: 1, name: "Countries")
        engine.browseResponses = [
            page(nodes: [rootNode]),
            page(sources: [makeSource(id: 100, title: "Brazil Source")]),
            page(nodes: [rootNode]),
        ]

        let viewModel = CatalogBrowserViewModel(engine: engine)
        await viewModel.loadRoot()

        let childNode = CatalogNodeSummary(
            id: CatalogNodeID(rawValue: 2),
            name: "Brazil",
            kind: .country,
            sourceCount: 10,
            childCount: 0,
            language: nil
        )
        await viewModel.navigate(to: childNode)
        XCTAssertEqual(viewModel.navigationPath.count, 1)

        await viewModel.goBack()

        XCTAssertTrue(viewModel.navigationPath.isEmpty, "should return to root after goBack")
        XCTAssertEqual(viewModel.nodes.first?.name, "Countries")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isLoading)
    }

    // MARK: - goToRoot()

    func test_goToRoot_clearsFullNavigationPath() async {
        let engine = StubFeedEngine()
        let rootNode = makeNode(id: 1, name: "Countries")
        engine.browseResponses = [
            page(nodes: [rootNode]),
            page(sources: [makeSource(id: 100, title: "Brazil Source")]),
            page(nodes: [rootNode]),
        ]

        let viewModel = CatalogBrowserViewModel(engine: engine)
        await viewModel.loadRoot()

        let childNode = CatalogNodeSummary(
            id: CatalogNodeID(rawValue: 2),
            name: "Brazil",
            kind: .country,
            sourceCount: 5,
            childCount: 0,
            language: nil
        )
        await viewModel.navigate(to: childNode)
        XCTAssertEqual(viewModel.navigationPath.count, 1)

        await viewModel.goToRoot()

        XCTAssertTrue(viewModel.navigationPath.isEmpty, "path should be cleared")
        XCTAssertEqual(viewModel.nodes.first?.name, "Countries")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isLoading)
    }

    // MARK: - Search debounce

    func test_searchText_debouncesAndPopulatesSearchResults() async {
        let engine = StubFeedEngine()
        let source = makeSource(id: 100, title: "Found Source")
        engine.searchResponses = [page(sources: [source])]

        let viewModel = CatalogBrowserViewModel(engine: engine)

        XCTAssertTrue(viewModel.searchResults.isEmpty)
        XCTAssertFalse(viewModel.isSearching)

        viewModel.searchText = "test query"

        // Poll for the debounced search with a generous timeout.
        // Task.sleep-based approaches are unreliable on the MainActor because
        // the debounce task and the test task both run on it.
        let deadline = CFAbsoluteTimeGetCurrent() + 5.0
        while CFAbsoluteTimeGetCurrent() < deadline {
            if viewModel.isSearching { break }
            try? await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertTrue(viewModel.isSearching, "search should be active after debounce")
        XCTAssertEqual(viewModel.searchResults.count, 1)
        XCTAssertEqual(viewModel.searchResults.first?.title, "Found Source")
        XCTAssertFalse(viewModel.isLoading)
    }

    // MARK: - clearSearch()

    func test_clearSearch_restoresBrowseState() async {
        let engine = StubFeedEngine()
        engine.searchResponses = [page(sources: [makeSource(id: 100, title: "Found")])]

        let viewModel = CatalogBrowserViewModel(engine: engine)

        // Directly run search (avoids debounce timing dependency)
        viewModel.searchText = "test"
        await viewModel.runSearch()
        XCTAssertTrue(viewModel.isSearching)
        XCTAssertFalse(viewModel.searchResults.isEmpty)

        viewModel.clearSearch()

        XCTAssertFalse(viewModel.isSearching, "search should be inactive after clear")
        XCTAssertTrue(viewModel.searchResults.isEmpty, "searchResults should be cleared")
        XCTAssertTrue(viewModel.searchText.isEmpty, "searchText should be cleared")
        XCTAssertNil(viewModel.errorMessage)
    }

    // MARK: - loadNextPage()

    func test_loadNextPage_appendsBrowseNodesAndSources() async {
        let engine = StubFeedEngine()
        let cursor1 = CatalogCursor(catalogVersion: 1, sortKey: "a", entityID: 1)
        let cursor2 = CatalogCursor(catalogVersion: 1, sortKey: "b", entityID: 2)
        engine.browseResponses = [
            page(
                nodes: [makeNode(id: 1, name: "Node1")],
                cursor: cursor1,
                estimatedTotalCount: 10
            ),
            page(
                nodes: [makeNode(id: 2, name: "Node2")],
                sources: [makeSource(id: 100, title: "More Source")],
                cursor: cursor2,
                estimatedTotalCount: 10
            ),
        ]

        let viewModel = CatalogBrowserViewModel(engine: engine)
        await viewModel.loadRoot()

        XCTAssertEqual(viewModel.nodes.count, 1)
        XCTAssertEqual(viewModel.nodes.first?.name, "Node1")
        XCTAssertEqual(viewModel.estimatedTotalCount, 10)

        await viewModel.loadNextPage()

        XCTAssertEqual(viewModel.nodes.count, 2, "nodes should be appended")
        XCTAssertEqual(viewModel.nodes.last?.name, "Node2")
        XCTAssertEqual(viewModel.sources.count, 1)
        XCTAssertEqual(viewModel.sources.first?.title, "More Source")
        XCTAssertEqual(viewModel.estimatedTotalCount, 10)
        XCTAssertFalse(viewModel.isLoadingMore)
    }

    // MARK: - loadNextSearchPage()

    func test_loadNextSearchPage_appendsSearchResultsOnly() async {
        let engine = StubFeedEngine()

        // Configure two search responses: first with cursor, second without
        let cursor = CatalogCursor(catalogVersion: 1, sortKey: "a", entityID: 1)
        engine.searchResponses = [
            page(sources: [makeSource(id: 100, title: "First")], cursor: cursor),
            page(sources: [makeSource(id: 101, title: "Second")]),
        ]

        let viewModel = CatalogBrowserViewModel(engine: engine)

        // Get the first search page (avoids debounce timing dependency)
        viewModel.searchText = "test"
        await viewModel.runSearch()
        XCTAssertEqual(viewModel.searchResults.count, 1)
        XCTAssertEqual(viewModel.searchResults.first?.title, "First")

        await viewModel.loadNextSearchPage()

        XCTAssertEqual(viewModel.searchResults.count, 2, "search results should be appended")
        XCTAssertEqual(viewModel.searchResults.last?.title, "Second")

        // Browse state must remain untouched
        XCTAssertTrue(viewModel.nodes.isEmpty, "browse nodes must not change")
        XCTAssertTrue(viewModel.sources.isEmpty, "browse sources must not change")
        XCTAssertFalse(viewModel.isLoadingMore)
    }

    // MARK: - loadSourceDetails(for:)

    func test_loadSourceDetails_setsSelectedSourceDetails() async {
        let engine = StubFeedEngine()
        let sourceID = SourceID(rawValue: 42)
        let details = makeDetails(id: 42, title: "Detailed Source")
        engine.detailResponses[sourceID] = details

        let viewModel = CatalogBrowserViewModel(engine: engine)

        XCTAssertNil(viewModel.selectedSourceDetails)
        XCTAssertFalse(viewModel.isLoadingDetails)
        XCTAssertNil(viewModel.loadingDetailsSourceID)

        await viewModel.loadSourceDetails(for: sourceID)

        XCTAssertNotNil(viewModel.selectedSourceDetails)
        XCTAssertEqual(viewModel.selectedSourceDetails?.title, "Detailed Source")
        XCTAssertEqual(viewModel.selectedSourceDetails?.id, sourceID)
        XCTAssertFalse(viewModel.isLoadingDetails, "isLoadingDetails should clear after loading")
        XCTAssertNil(
            viewModel.loadingDetailsSourceID,
            "loadingDetailsSourceID should clear after loading"
        )
    }

    // MARK: - Error handling

    func test_browseError_setsErrorMessage() async {
        let engine = StubFeedEngine()
        engine.browseError = NSError(
            domain: "test", code: 0,
            userInfo: [NSLocalizedDescriptionKey: "Browse failed"]
        )

        let viewModel = CatalogBrowserViewModel(engine: engine)
        await viewModel.loadRoot()

        XCTAssertEqual(viewModel.errorMessage, "Browse failed")
        XCTAssertFalse(viewModel.isLoading)
    }

    func test_searchError_setsErrorMessage() async {
        let engine = StubFeedEngine()
        engine.searchError = NSError(
            domain: "test", code: 0,
            userInfo: [NSLocalizedDescriptionKey: "Search failed"]
        )

        let viewModel = CatalogBrowserViewModel(engine: engine)
        viewModel.searchText = "test"
        await viewModel.runSearch()

        XCTAssertEqual(viewModel.errorMessage, "Search failed")
        XCTAssertFalse(viewModel.isLoading)
    }

    func test_detailError_setsErrorMessage() async {
        let engine = StubFeedEngine()
        engine.detailError = NSError(
            domain: "test", code: 0,
            userInfo: [NSLocalizedDescriptionKey: "Detail failed"]
        )

        let viewModel = CatalogBrowserViewModel(engine: engine)
        await viewModel.loadSourceDetails(for: SourceID(rawValue: 1))

        XCTAssertEqual(viewModel.errorMessage, "Detail failed")
        XCTAssertFalse(viewModel.isLoadingDetails)
        XCTAssertNil(viewModel.loadingDetailsSourceID)
    }

    // MARK: - clearError()

    func test_clearError_clearsErrorMessage() async {
        let engine = StubFeedEngine()
        engine.browseError = NSError(
            domain: "test", code: 0,
            userInfo: [NSLocalizedDescriptionKey: "Browse failed"]
        )

        let viewModel = CatalogBrowserViewModel(engine: engine)
        await viewModel.loadRoot()
        XCTAssertNotNil(viewModel.errorMessage)

        viewModel.clearError()

        XCTAssertNil(viewModel.errorMessage, "errorMessage should be nil after clearError")
    }
}
