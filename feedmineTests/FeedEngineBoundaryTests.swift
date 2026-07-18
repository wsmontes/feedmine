import Foundation
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

    func testBundledYouTubeLanguageOverridesAreAppliedAtSourceLevel() throws {
        let expectedLanguages = [
            "UC2p1nohpGOnK7u_3JgDpvog": "ko",
            "UC371icpvZj2oQaocL0i9L-g": "pt",
            "UC48h7Dst_hX82HxOf3xJw_w": "th",
            "UC4LHNX8d8RqnDX0OezgmCTg": "es",
            "UCAy_KEOjhjKP7BETzJrsaxg": "es",
            "UCC9h3H-sGrvqd2otknZntsQ": "de",
            "UCEeEQxm6qc_qaTE7qTV5aLQ": "ur",
            "UCJg19noZp7-BYIGvypu_cow": "hi",
            "UCLYqpLGnCoQfcD7BdDKsSxQ": "es",
            "UCSiDGb0MnHFGjs4E2WKvShw": "hi",
            "UCj-SWZSE0AmotGSQ3apROHw": "hi",
            "UClgRkhTL3_hImCAmdLfDE4g": "de",
            "UCw7xjxzbMwgBSmbeYwqYRMg": "hi",
            "UCx8Z14PpntdaxCt2hakbQLQ": "hi",
            "UCxtLc0Jqq3SKBWlIXM_OC9g": "ko",
            "UCyoXW-Dse7fURq30EWl_CUA": "hi",
            "UCzw-C7fNfs018R1FzIKnlaA": "ko",
        ]
        let feedsURL = try XCTUnwrap(
            Bundle.main.resourceURL?.appendingPathComponent("Feeds", isDirectory: true),
            "The installed app bundle must contain the Feeds resource directory"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: feedsURL.path),
            "Bundled Feeds directory does not exist at \(feedsURL.path)"
        )
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: feedsURL, includingPropertiesForKeys: nil)
        )
        var counts = Dictionary(uniqueKeysWithValues: expectedLanguages.keys.map { ($0, 0) })
        var mismatches: [String] = []
        var misplacedLanguageElements: [String] = []
        var sourcesMissingLanguage: [String] = []

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "opml" {
            let relativePath = fileURL.path.replacingOccurrences(of: feedsURL.path + "/", with: "")
            let delegate = BundledOPMLLanguageAuditDelegate(
                expectedLanguages: expectedLanguages,
                relativePath: relativePath
            )
            let parser = try XCTUnwrap(XMLParser(contentsOf: fileURL))
            parser.delegate = delegate

            XCTAssertTrue(parser.parse(), "Failed to parse \(relativePath): \(String(describing: parser.parserError))")
            misplacedLanguageElements.append(contentsOf: delegate.misplacedLanguageElements)
            sourcesMissingLanguage.append(contentsOf: delegate.sourcesMissingLanguage)
            for occurrence in delegate.occurrences {
                counts[occurrence.channelID, default: 0] += 1
                if occurrence.language != occurrence.expectedLanguage {
                    mismatches.append(
                        "\(occurrence.relativePath): \(occurrence.channelID) language=\(occurrence.language ?? "nil"), expected=\(occurrence.expectedLanguage)"
                    )
                }
            }
        }

        let missingChannels = counts
            .filter { $0.value == 0 }
            .map(\.key)
            .sorted()
        XCTAssertTrue(missingChannels.isEmpty, "No OPML occurrence found for channels: \(missingChannels)")
        XCTAssertTrue(misplacedLanguageElements.isEmpty, misplacedLanguageElements.sorted().joined(separator: "\n"))
        XCTAssertTrue(sourcesMissingLanguage.isEmpty, sourcesMissingLanguage.sorted().joined(separator: "\n"))
        XCTAssertTrue(mismatches.isEmpty, mismatches.sorted().joined(separator: "\n"))
    }
}

final class RSSFetcherTextSanitizerTests: XCTestCase {
    func testSanitizedHTMLTextDecodesNumericEntities() {
        let text = RSSFetcher.sanitizedHTMLText("That&#8217;s &quot;clean&quot; &amp; readable &#38; done")

        XCTAssertEqual(text, "That\u{2019}s \"clean\" & readable & done")
    }

    func testSanitizedHTMLTextDecodesTypographicNumericEntities() {
        let text = RSSFetcher.sanitizedHTMLText("She said &#8220;yes&#8221; &#8211; then left")

        XCTAssertEqual(text, "She said \u{201C}yes\u{201D} \u{2013} then left")
    }

    func testSanitizedHTMLTextDecodesNumericEntitiesWithoutSemicolon() {
        let text = RSSFetcher.sanitizedHTMLText("That&#8217s still readable")

        XCTAssertEqual(text, "That\u{2019}s still readable")
    }

    func testSanitizedHTMLTextStripsEscapedMarkup() {
        let text = RSSFetcher.sanitizedHTMLText("&lt;p&gt;A short &amp; useful summary.&lt;/p&gt;")

        XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), "A short & useful summary.")
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

private final class BundledOPMLLanguageAuditDelegate: NSObject, XMLParserDelegate {
    struct Occurrence {
        let relativePath: String
        let channelID: String
        let language: String?
        let expectedLanguage: String
    }

    let expectedLanguages: [String: String]
    let relativePath: String
    var occurrences: [Occurrence] = []
    var misplacedLanguageElements: [String] = []
    var sourcesMissingLanguage: [String] = []

    private var elementStack: [String] = []
    private var outlinePushStack: [Bool] = []
    private var languageStack: [String?] = []
    private var fileLanguage: String?
    private var activeLanguageParent: String?
    private var languageBuffer = ""

    init(expectedLanguages: [String: String], relativePath: String) {
        self.expectedLanguages = expectedLanguages
        self.relativePath = relativePath
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let parentElement = elementStack.last
        if elementName == "language" {
            activeLanguageParent = parentElement
            languageBuffer = ""
            if parentElement != "head" {
                misplacedLanguageElements.append("\(relativePath): <language> parent=\(parentElement ?? "nil")")
            }
        }
        elementStack.append(elementName)

        guard elementName == "outline" else { return }

        let xmlURL = attributeDict["xmlUrl"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let language = normalizedLanguage(attributeDict["language"])
        if xmlURL.isEmpty {
            languageStack.append(language ?? languageStack.last ?? fileLanguage)
            outlinePushStack.append(true)
            return
        }

        outlinePushStack.append(false)
        let resolvedLanguage = language ?? languageStack.last ?? fileLanguage
        if resolvedLanguage == nil {
            sourcesMissingLanguage.append("\(relativePath): \(attributeDict["title"] ?? attributeDict["text"] ?? xmlURL)")
        }

        for (channelID, expectedLanguage) in expectedLanguages where xmlURL.contains("channel_id=\(channelID)") {
            occurrences.append(
                Occurrence(
                    relativePath: relativePath,
                    channelID: channelID,
                    language: attributeDict["language"],
                    expectedLanguage: expectedLanguage
                )
            )
            return
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard activeLanguageParent != nil else { return }
        languageBuffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "outline" {
            let didPushLanguage = outlinePushStack.popLast() ?? false
            if didPushLanguage, !languageStack.isEmpty {
                languageStack.removeLast()
            }
        }

        if elementName == "language" {
            if activeLanguageParent == "head" {
                fileLanguage = normalizedLanguage(languageBuffer)
            }
            activeLanguageParent = nil
            languageBuffer = ""
        }

        if !elementStack.isEmpty {
            elementStack.removeLast()
        }
    }

    private func normalizedLanguage(_ language: String?) -> String? {
        let trimmed = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
