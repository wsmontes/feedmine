import XCTest
@testable import feedmine

final class SQLiteCatalogStoreTests: XCTestCase {
    func testOPMLFolderScannerIncludesFileNameAsCatalogNode() {
        let topicNodes = OPMLCatalogScanner.folderNodes(
            for: "Industry_Business/entrepreneurship.opml",
            fileName: "entrepreneurship"
        )
        XCTAssertEqual(topicNodes.map(\.keyComponent), ["industry-business", "entrepreneurship"])
        XCTAssertEqual(topicNodes.map(\.kind), [.topic, .subcategory])

        let countryNodes = OPMLCatalogScanner.folderNodes(
            for: "countries/brazil/brazil-acre.opml",
            fileName: "brazil-acre"
        )
        XCTAssertEqual(countryNodes.map(\.keyComponent), ["countries", "brazil", "acre"])
        XCTAssertEqual(countryNodes.map(\.kind), [.topic, .country, .region])

        let languageNodes = OPMLCatalogScanner.folderNodes(
            for: "languages/pt/entrepreneurship.opml",
            fileName: "entrepreneurship"
        )
        XCTAssertEqual(languageNodes.map(\.keyComponent), ["languages", "pt", "entrepreneurship"])
        XCTAssertEqual(languageNodes.map(\.kind), [.topic, .language, .subcategory])
    }

    func testCompilerDeduplicatesSourcesAndKeepsPlacements() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.cleanup() }
        let report = try await fixture.compile()

        XCTAssertEqual(report.sourceCount, 2)
        XCTAssertEqual(report.placementCount, 3)
        XCTAssertEqual(report.duplicateOccurrenceCount, 1)
        XCTAssertEqual(report.failedFileCount, 0)

        let repository = try SQLiteCatalogRepository(databaseURL: fixture.databaseURL)
        let sourceID = CatalogIdentity.sourceID(for: CatalogIdentity.sourceKey(for: "https://startupi.com.br/feed/"))
        let details = try await repository.loadSourceDetails(sourceID: sourceID)

        XCTAssertEqual(details.title, "Startupi")
        XCTAssertEqual(details.language, "pt")
        XCTAssertEqual(details.placements.count, 2)
        XCTAssertEqual(Set(details.placements.map(\.opmlFile)), [
            "countries/brazil/business.opml",
            "languages/pt/entrepreneurship.opml",
        ])
    }

    func testBrowseCatalogReturnsRootNodesAndPagedSources() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.compile()

        let repository = try SQLiteCatalogRepository(databaseURL: fixture.databaseURL)
        let rootPage = try await repository.browseCatalog(query: CatalogBrowseQuery(parentID: .root), cursor: nil, limit: 2)

        XCTAssertEqual(rootPage.nodes.map(\.name), ["Countries", "Global"])
        XCTAssertTrue(rootPage.sources.isEmpty)
        XCTAssertNotNil(rootPage.nextCursor)

        let rootNextPage = try await repository.browseCatalog(
            query: CatalogBrowseQuery(parentID: .root),
            cursor: rootPage.nextCursor,
            limit: 2
        )

        XCTAssertEqual(rootNextPage.nodes.map(\.name), ["Languages"])
        XCTAssertTrue(rootNextPage.sources.isEmpty)
        XCTAssertNil(rootNextPage.nextCursor)

        let brazilID = CatalogIdentity.nodeID(for: CatalogIdentity.nodeKey(pathComponents: ["countries", "brazil"]))
        let brazilPage = try await repository.browseCatalog(
            query: CatalogBrowseQuery(parentID: brazilID),
            cursor: nil,
            limit: 10
        )

        XCTAssertEqual(brazilPage.nodes.map(\.name), ["Business"])
        XCTAssertTrue(brazilPage.sources.isEmpty)
        XCTAssertNil(brazilPage.nextCursor)

        let businessID = CatalogIdentity.nodeID(for: CatalogIdentity.nodeKey(pathComponents: ["countries", "brazil", "business"]))
        let businessPage = try await repository.browseCatalog(query: CatalogBrowseQuery(parentID: businessID), cursor: nil, limit: 10)

        XCTAssertTrue(businessPage.nodes.isEmpty)
        XCTAssertEqual(businessPage.sources.map(\.title), ["Startupi"])
        XCTAssertNil(businessPage.nextCursor)
    }

    func testSearchCatalogUsesLocalFTSAndFilters() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.compile()

        let repository = try SQLiteCatalogRepository(databaseURL: fixture.databaseURL)
        let startupResults = try await repository.searchCatalog(
            query: CatalogSearchQuery(text: "startupi"),
            cursor: nil,
            limit: 10
        )

        XCTAssertTrue(startupResults.nodes.isEmpty)
        XCTAssertEqual(startupResults.sources.map(\.title), ["Startupi"])
        XCTAssertEqual(startupResults.sources.first?.displayHost, "startupi.com.br")

        let portugueseResults = try await repository.searchCatalog(
            query: CatalogSearchQuery(
                text: "entrepreneurship",
                filters: CatalogSearchFilters(language: "pt")
            ),
            cursor: nil,
            limit: 10
        )

        XCTAssertEqual(portugueseResults.sources.map(\.title), ["Startupi"])

        let filteredOut = try await repository.searchCatalog(
            query: CatalogSearchQuery(
                text: "entrepreneurship",
                filters: CatalogSearchFilters(language: "en")
            ),
            cursor: nil,
            limit: 10
        )

        XCTAssertTrue(filteredOut.sources.isEmpty)
    }
}

private struct CatalogFixture {
    let directoryURL: URL
    let databaseURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("feedmine-catalog-\(UUID().uuidString)", isDirectory: true)
        databaseURL = directoryURL.appendingPathComponent("catalog.sqlite")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func compile() async throws -> CatalogCompileReport {
        let compiler = SQLiteCatalogCompiler(
            input: .occurrences(Self.occurrences),
            databaseURL: databaseURL
        )
        return try await compiler.compileFull()
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    private static let occurrences: [CatalogSourceOccurrence] = [
        CatalogSourceOccurrence(
            title: "Startupi",
            declaredURL: "https://startupi.com.br/feed/",
            mediaKind: .text,
            language: "pt",
            nodePath: [
                CatalogInputNode(name: "Countries", kind: .topic, keyComponent: "countries"),
                CatalogInputNode(name: "Brazil", kind: .country, keyComponent: "brazil", language: "pt"),
                CatalogInputNode(name: "Business", kind: .subcategory, keyComponent: "business", language: "pt"),
            ],
            opmlFile: "countries/brazil/business.opml",
            sortOrder: 1,
            languageOverride: "pt"
        ),
        CatalogSourceOccurrence(
            title: "Startupi",
            declaredURL: "https://startupi.com.br/feed/",
            mediaKind: .text,
            language: "pt",
            nodePath: [
                CatalogInputNode(name: "Languages", kind: .topic, keyComponent: "languages"),
                CatalogInputNode(name: "Portuguese", kind: .language, keyComponent: "pt", language: "pt"),
                CatalogInputNode(name: "Entrepreneurship", kind: .subcategory, keyComponent: "entrepreneurship", language: "pt"),
            ],
            opmlFile: "languages/pt/entrepreneurship.opml",
            sortOrder: 2,
            languageOverride: "pt"
        ),
        CatalogSourceOccurrence(
            title: "Acoustics Today",
            declaredURL: "https://acousticstoday.org/feed/",
            mediaKind: .text,
            language: "en",
            nodePath: [
                CatalogInputNode(name: "Global", kind: .topic, keyComponent: "global"),
                CatalogInputNode(name: "Science", kind: .subcategory, keyComponent: "science", language: "en"),
                CatalogInputNode(name: "Acoustics", kind: .subcategory, keyComponent: "acoustics", language: "en"),
            ],
            opmlFile: "global/science/acoustics.opml",
            sortOrder: 3,
            languageOverride: "en"
        ),
    ]
}
