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
        XCTAssertEqual(topicNode.name, "global")  // region as topic name
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
}
