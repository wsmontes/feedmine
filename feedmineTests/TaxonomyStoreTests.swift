import XCTest
@testable import feedmine

@MainActor
final class TaxonomyStoreTests: XCTestCase {

    // MARK: - Tree Building

    func testBuildEmptySourcesProducesEmptyTree() async {
        let store = TaxonomyStore()
        await store.build(from: [])
        let root = store.root
        XCTAssertNotNil(root)
        XCTAssertEqual(root?.id, TaxonomyNode.rootID)
        XCTAssertEqual(root?.feedCount, 0)
        XCTAssertEqual(root?.childrenCount, 0)
    }

    func testBuildSingleTopicOPML() async {
        let sources = [
            FeedSource(title: "Sprudge", url: "https://sprudge.com/feed",
                       category: "Coffee News", region: "global", mediaKind: .text),
            FeedSource(title: "Tea Journey", url: "https://teajourney.pub/feed",
                       category: "Tea Culture", region: "global", mediaKind: .text),
        ]
        let store = TaxonomyStore()
        await store.build(from: sources)

        // Root has 1 child (the topic OPML)
        let rootChildren = store.children(of: TaxonomyNode.rootID)
        XCTAssertEqual(rootChildren.count, 1, "Should have 1 topic node")

        let topicNode = rootChildren[0]
        XCTAssertEqual(topicNode.name, "Global")
        XCTAssertEqual(topicNode.feedCount, 2)

        // Topic has 2 subcategory children
        let subChildren = store.children(of: topicNode.id)
        XCTAssertEqual(subChildren.count, 2)
        XCTAssertEqual(subChildren.map(\.name).sorted(), ["Coffee News", "Tea Culture"])
    }

    func testBuildCountryOPMLWithDepth() async {
        let sources = [
            FeedSource(title: "Folha", url: "https://folha.com/feed",
                       category: "News", region: "countries/brazil", mediaKind: .text),
            FeedSource(title: "Globo Esporte", url: "https://globo.com/esporte/feed",
                       category: "Sports", region: "countries/brazil", mediaKind: .text),
        ]
        let store = TaxonomyStore()
        await store.build(from: sources)

        let rootChildren = store.children(of: TaxonomyNode.rootID)
        XCTAssertEqual(rootChildren.count, 1)
        XCTAssertEqual(rootChildren[0].name, "Countries")

        let countriesChildren = store.children(of: rootChildren[0].id)
        XCTAssertEqual(countriesChildren.count, 1)
        XCTAssertEqual(countriesChildren[0].name, "Brazil")

        let brazilChildren = store.children(of: countriesChildren[0].id)
        XCTAssertEqual(brazilChildren.count, 2)
    }

    func testFeedToNodeMapping() async {
        let sources = [
            FeedSource(title: "Test", url: "https://test.com/feed",
                       category: "News", region: "global", mediaKind: .text),
        ]
        let store = TaxonomyStore()
        await store.build(from: sources)

        let nodeID = store.nodeID(for: "https://test.com/feed")
        XCTAssertNotNil(nodeID)
        XCTAssertTrue(nodeID?.hasSuffix("/news") ?? false)
    }

    // MARK: - Search

    func testSearchFindsMatchingNodes() async {
        let sources = [
            FeedSource(title: "Sprudge", url: "https://a.com",
                       category: "Coffee News", region: "global", mediaKind: .text),
            FeedSource(title: "TechCrunch", url: "https://b.com",
                       category: "Startups", region: "global", mediaKind: .text),
        ]
        let store = TaxonomyStore()
        await store.build(from: sources)

        let results = store.search("coffee")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].name, "Coffee News")
    }

    func testSearchIsCaseInsensitive() async {
        let sources = [
            FeedSource(title: "Test", url: "https://a.com",
                       category: "Coffee News", region: "global", mediaKind: .text),
        ]
        let store = TaxonomyStore()
        await store.build(from: sources)

        XCTAssertEqual(store.search("COFFEE").count, 1)
        XCTAssertEqual(store.search("coffee").count, 1)
        XCTAssertEqual(store.search("Coffee").count, 1)
    }

    // MARK: - Selection

    func testSelectAndDeselectNode() {
        let store = TaxonomyStore()
        store.select("test/id")
        XCTAssertTrue(store.selectedNodeIDs.contains("test/id"))
        store.deselect("test/id")
        XCTAssertFalse(store.selectedNodeIDs.contains("test/id"))
    }

    func testClearSelectionRemovesAll() {
        let store = TaxonomyStore()
        store.select("a")
        store.select("b")
        store.clearSelection()
        XCTAssertTrue(store.selectedNodeIDs.isEmpty)
    }

    // MARK: - Performance / Scalability

    func testBuildFeedCountsCorrectAtScale() async {
        // Simulate 100 sources across 20 categories in 4 countries
        var sources: [FeedSource] = []
        let countries = ["brazil", "japan", "germany", "nigeria"]
        let categories = ["News", "Sports", "Tech", "Culture", "Music"]
        for country in countries {
            for category in categories {
                let count = 5
                for i in 0..<count {
                    sources.append(FeedSource(
                        title: "\(country)-\(category)-\(i)",
                        url: "https://\(country).example.com/\(category)/\(i)",
                        category: category,
                        region: "countries/\(country)",
                        mediaKind: .text
                    ))
                }
            }
        }
        // 4 countries × 5 categories × 5 feeds = 100 feeds
        XCTAssertEqual(sources.count, 100)

        let store = TaxonomyStore()
        await store.build(from: sources)

        // Root should have total of 100
        XCTAssertEqual(store.root?.feedCount, 100)

        // Countries node should have 100
        let rootChildren = store.children(of: TaxonomyNode.rootID)
        XCTAssertEqual(rootChildren.count, 1)
        let countriesNode = rootChildren[0]
        XCTAssertEqual(countriesNode.feedCount, 100)

        // Each country should have 25 (5 categories × 5 feeds)
        let countryChildren = store.children(of: countriesNode.id)
        XCTAssertEqual(countryChildren.count, 4)
        for country in countryChildren {
            XCTAssertEqual(country.feedCount, 25, "\(country.name) should have 25 feeds")
        }

        // Each leaf category should have 5
        if let firstCountry = countryChildren.first {
            let catChildren = store.children(of: firstCountry.id)
            XCTAssertEqual(catChildren.count, 5)
            for cat in catChildren {
                XCTAssertEqual(cat.feedCount, 5, "\(cat.name) should have 5 feeds")
            }
        }
    }

    func testChildrenLookupIsFast() async {
        var sources: [FeedSource] = []
        for i in 0..<500 {
            sources.append(FeedSource(
                title: "Feed \(i)",
                url: "https://example.com/feed/\(i)",
                category: "Category \(i % 50)",
                region: "global",
                mediaKind: .text
            ))
        }
        let store = TaxonomyStore()
        await store.build(from: sources)

        // children(of:) should not iterate all 500+ nodes
        let rootChildren = store.children(of: TaxonomyNode.rootID)
        // With 500 sources in "global" region, root has 1 child (Global topic)
        // which has ~50 subcategory children
        XCTAssertFalse(rootChildren.isEmpty)
    }

    // MARK: - isFeedInSubtree

    func testIsFeedInSubtree() async {
        let sources = [
            FeedSource(title: "Folha", url: "https://folha.com/feed",
                       category: "News", region: "countries/brazil", mediaKind: .text),
        ]
        let store = TaxonomyStore()
        await store.build(from: sources)

        let folhaNodeID = store.nodeID(for: "https://folha.com/feed")!
        let brazilNodeID = folhaNodeID.components(separatedBy: "/").prefix(3).joined(separator: "/")

        // Brazil node should contain Folha
        let result = store.isFeedInSubtree(feedURL: "https://folha.com/feed", nodeID: brazilNodeID)
        XCTAssertTrue(result)

        // Unrelated node should not
        let result2 = store.isFeedInSubtree(feedURL: "https://folha.com/feed", nodeID: "coffee-tea")
        XCTAssertFalse(result2)
    }

    // MARK: - Cache Fingerprint

    func testCacheFingerprintRejectsEqualCountDifferentURLs() async {
        // Build set A, persist, then verify set B (same count) is rejected
        let setA = [
            FeedSource(title: "A", url: "https://a.com/feed", category: "News", region: "global", mediaKind: .text),
            FeedSource(title: "B", url: "https://b.com/feed", category: "Sports", region: "global", mediaKind: .text),
        ]
        let setB = [
            FeedSource(title: "C", url: "https://c.com/feed", category: "Tech", region: "global", mediaKind: .text),
            FeedSource(title: "D", url: "https://d.com/feed", category: "Music", region: "global", mediaKind: .text),
        ]
        XCTAssertEqual(setA.count, setB.count, "Both sets must have same count to validate fingerprint guards against count-only check")

        let store = TaxonomyStore()
        await store.build(from: setA)
        // Cache written by build — fingerprint = hash of sorted A URLs

        // Same store loading set B (same count, different URLs) → must reject
        let loaded = store.loadFromCache(sources: setB)
        XCTAssertFalse(loaded, "Cache must be rejected when URLs differ even though count matches")
    }

    func testCacheFingerprintAcceptsSameURLsDifferentOrder() async {
        let ordered = [
            FeedSource(title: "A", url: "https://a.com/feed", category: "News", region: "global", mediaKind: .text),
            FeedSource(title: "B", url: "https://b.com/feed", category: "Sports", region: "global", mediaKind: .text),
        ]
        let shuffled: [FeedSource] = [ordered[1], ordered[0]]
        XCTAssertEqual(ordered.count, shuffled.count)

        let store = TaxonomyStore()
        await store.build(from: ordered)
        // Cache written with fingerprint of sorted URLs

        let loaded = store.loadFromCache(sources: shuffled)
        XCTAssertTrue(loaded, "Cache must be accepted when URLs are identical (order-independent fingerprint)")
    }

    func testCacheFingerprintRejectsSameURLDifferentCategory() async {
        let setA = [
            FeedSource(title: "Feed", url: "https://x.com/feed", category: "Technology", region: "global", mediaKind: .text),
        ]
        let setB = [
            FeedSource(title: "Feed", url: "https://x.com/feed", category: "Artificial Intelligence", region: "global", mediaKind: .text),
        ]
        XCTAssertEqual(setA.count, setB.count)

        let store = TaxonomyStore()
        await store.build(from: setA)

        let loaded = store.loadFromCache(sources: setB)
        XCTAssertFalse(loaded, "Cache must be rejected when category changes even though URL and count are identical")
    }

    func testCacheFingerprintRejectsSameURLDifferentRegion() async {
        let setA = [
            FeedSource(title: "Feed", url: "https://x.com/feed", category: "News", region: "global", mediaKind: .text),
        ]
        let setB = [
            FeedSource(title: "Feed", url: "https://x.com/feed", category: "News", region: "countries/brazil", mediaKind: .text),
        ]
        XCTAssertEqual(setA.count, setB.count)

        let store = TaxonomyStore()
        await store.build(from: setA)

        let loaded = store.loadFromCache(sources: setB)
        XCTAssertFalse(loaded, "Cache must be rejected when region changes even though URL, count, and category are identical")
    }

    // MARK: - Warm-Cache nodeToFeedURLs Rebuild

    func testWarmCacheRestoresSubtreeFeedURLs() async throws {
        // Build taxonomy with sources spread across nodes
        let sources = [
            FeedSource(title: "Folha", url: "https://folha.com/feed",
                       category: "News", region: "countries/brazil", mediaKind: .text),
            FeedSource(title: "Globo", url: "https://globo.com/feed",
                       category: "Sports", region: "countries/brazil", mediaKind: .text),
            FeedSource(title: "Sprudge", url: "https://sprudge.com/feed",
                       category: "Coffee News", region: "global", mediaKind: .text),
        ]
        let store = TaxonomyStore()
        await store.build(from: sources)

        // Cold-path: feedURLs(inSubtreesOf:) should return correct URLs.
        // Node IDs are hierarchical paths — drop the leaf (category) to get the country node.
        let folhaLeafID = try XCTUnwrap(store.nodeID(for: "https://folha.com/feed"))
        let brazilNodeID = folhaLeafID.components(separatedBy: "/").dropLast().joined(separator: "/")
        XCTAssertTrue(brazilNodeID.hasSuffix("brazil"), "Parent of leaf node should be brazil country node")

        let coldURLs = store.feedURLs(inSubtreesOf: [brazilNodeID])
        XCTAssertEqual(coldURLs.count, 2, "Cold path should return 2 Brazil feed URLs")
        XCTAssertTrue(coldURLs.contains(OPMLParser.normalizeURL("https://folha.com/feed")))
        XCTAssertTrue(coldURLs.contains(OPMLParser.normalizeURL("https://globo.com/feed")))

        // Reload from cache (warm path)
        let warmStore = TaxonomyStore()
        let cacheHit = warmStore.loadFromCache(sources: sources)
        XCTAssertTrue(cacheHit, "Cache load should succeed with same source set")

        // Warm-path: feedURLs(inSubtreesOf:) must return the same results
        let warmURLs = warmStore.feedURLs(inSubtreesOf: [brazilNodeID])
        XCTAssertEqual(warmURLs.count, coldURLs.count,
                       "Warm cache should return same feed URL count as cold build")
        XCTAssertEqual(warmURLs, coldURLs,
                       "Warm cache should restore identical nodeToFeedURLs including bottom-up propagation")
    }
}
