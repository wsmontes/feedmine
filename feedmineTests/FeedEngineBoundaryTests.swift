import XCTest
@testable import feedmine

final class FeedEngineBoundaryTests: XCTestCase {
    func testSourceIDsAreStableNumericValues() {
        let first = SourceID(rawValue: 42)
        let same = SourceID(rawValue: 42)
        let different = SourceID(rawValue: 43)

        XCTAssertEqual(first, same)
        XCTAssertNotEqual(first, different)
        XCTAssertEqual(first.rawValue, 42)
        XCTAssertEqual(CatalogNodeID.root.rawValue, 0)
    }

    func testCatalogCursorRoundTripsAsOpaqueTokenPayload() throws {
        let cursor = CatalogCursor(catalogVersion: 7, sortKey: "global/science", entityID: 99)

        let data = try JSONEncoder().encode(cursor)
        let decoded = try JSONDecoder().decode(CatalogCursor.self, from: data)

        XCTAssertEqual(decoded, cursor)
    }

    func testPageLimitBoundsUnlimitedRequests() {
        XCTAssertEqual(FeedEnginePageLimit.bounded(0), 1)
        XCTAssertEqual(FeedEnginePageLimit.bounded(50), 50)
        XCTAssertEqual(FeedEnginePageLimit.bounded(10_000), FeedEnginePageLimit.maximumLimit)
    }

    func testQueriesRepresentEmptyAndCompoundInputs() {
        let emptyBrowse = CatalogBrowseQuery()
        XCTAssertNil(emptyBrowse.parentID)
        XCTAssertTrue(emptyBrowse.includeSources)

        let compoundSearch = CatalogSearchQuery(
            text: "acoustics",
            filters: CatalogSearchFilters(kind: .subcategory, language: "en", region: "global/science")
        )
        XCTAssertEqual(compoundSearch.text, "acoustics")
        XCTAssertEqual(compoundSearch.filters.kind, .subcategory)
        XCTAssertEqual(compoundSearch.filters.language, "en")
        XCTAssertEqual(compoundSearch.filters.region, "global/science")

        let content = ContentQuery(
            scope: .nodes([CatalogNodeID(rawValue: 10), CatalogNodeID(rawValue: 11)]),
            mediaKinds: [.text, .audio],
            languages: ["en", "pt"],
            searchText: "waves"
        )
        XCTAssertEqual(content.scope, .nodes([CatalogNodeID(rawValue: 10), CatalogNodeID(rawValue: 11)]))
        XCTAssertEqual(content.mediaKinds, [.text, .audio])
        XCTAssertEqual(content.languages, ["en", "pt"])
        XCTAssertEqual(content.searchText, "waves")
    }

    func testSourceSummaryAndDetailsStaySeparated() throws {
        let sourceID = SourceID(rawValue: 501)
        let summary = SourceSummary(
            id: sourceID,
            title: "Acoustics Today",
            displayHost: "acousticstoday.org",
            mediaKind: .text,
            language: "en"
        )
        let details = SourceDetails(
            id: sourceID,
            title: "Acoustics Today",
            declaredURL: try XCTUnwrap(URL(string: "https://acousticstoday.org/feed/")),
            requestURL: try XCTUnwrap(URL(string: "https://acousticstoday.org/feed/")),
            mediaKind: .text,
            language: "en",
            placements: []
        )

        XCTAssertEqual(summary.id, details.id)
        XCTAssertEqual(summary.title, details.title)
        XCTAssertEqual(summary.displayHost, "acousticstoday.org")
        XCTAssertTrue(details.placements.isEmpty)
    }

    func testSingleSourceCanAppearInMultipleCatalogNodes() throws {
        let sourceID = SourceID(rawValue: 700)
        let details = SourceDetails(
            id: sourceID,
            title: "Startupi",
            declaredURL: try XCTUnwrap(URL(string: "https://startupi.com.br/feed/")),
            requestURL: try XCTUnwrap(URL(string: "https://startupi.com.br/feed/")),
            mediaKind: .text,
            language: "pt",
            placements: [
                SourcePlacementSummary(
                    id: 1,
                    nodeID: CatalogNodeID(rawValue: 10),
                    nodeName: "Brazil",
                    opmlFile: "countries/brazil/brazil.opml",
                    sortOrder: 12,
                    titleOverride: nil,
                    languageOverride: "pt",
                    mediaKindOverride: nil
                ),
                SourcePlacementSummary(
                    id: 2,
                    nodeID: CatalogNodeID(rawValue: 20),
                    nodeName: "Portuguese Entrepreneurship",
                    opmlFile: "languages/pt/entrepreneurship.opml",
                    sortOrder: 3,
                    titleOverride: nil,
                    languageOverride: "pt",
                    mediaKindOverride: nil
                ),
            ]
        )

        XCTAssertEqual(details.id, sourceID)
        XCTAssertEqual(details.placements.count, 2)
        XCTAssertEqual(Set(details.placements.map(\.nodeID)).count, 2)
        XCTAssertEqual(Set(details.placements.map(\.opmlFile)).count, 2)
    }

    func testFeedEngineProtocolReturnsBoundedPages() async throws {
        let engine = BoundedMockFeedEngine()
        let page = try await engine.browseCatalog(
            query: CatalogBrowseQuery(parentID: .root),
            cursor: nil,
            limit: 10_000
        )

        XCTAssertEqual(page.sources.count, FeedEnginePageLimit.maximumLimit)
        XCTAssertNotNil(page.nextCursor)
    }
}

private struct BoundedMockFeedEngine: FeedEngineProtocol {
    func browseCatalog(
        query: CatalogBrowseQuery,
        cursor: CatalogCursor?,
        limit: Int
    ) async throws -> CatalogPage {
        let boundedLimit = FeedEnginePageLimit.bounded(limit)
        let sources = (0..<boundedLimit).map { index in
            SourceSummary(
                id: SourceID(rawValue: UInt32(index + 1)),
                title: "Source \(index)",
                displayHost: "example.com",
                mediaKind: .text,
                language: "en"
            )
        }
        return CatalogPage(
            nodes: [],
            sources: sources,
            nextCursor: CatalogCursor(catalogVersion: 1, sortKey: "Source \(boundedLimit - 1)", entityID: UInt32(boundedLimit)),
            estimatedTotalCount: nil
        )
    }

    func searchCatalog(
        query: CatalogSearchQuery,
        cursor: CatalogCursor?,
        limit: Int
    ) async throws -> CatalogPage {
        CatalogPage(nodes: [], sources: [], nextCursor: nil, estimatedTotalCount: nil)
    }

    func loadSourceDetails(sourceID: SourceID) async throws -> SourceDetails {
        SourceDetails(
            id: sourceID,
            title: "Source",
            declaredURL: URL(string: "https://example.com/feed")!,
            requestURL: URL(string: "https://example.com/feed")!,
            mediaKind: .text,
            language: nil,
            placements: []
        )
    }

    func loadTimeline(
        query: ContentQuery,
        cursor: TimelineCursor?,
        limit: Int
    ) async throws -> TimelinePage {
        TimelinePage(items: [], nextCursor: nil)
    }
}
