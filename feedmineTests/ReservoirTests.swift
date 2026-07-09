import XCTest
@testable import feedmine

final class ReservoirTests: XCTestCase {

    // MARK: - seed

    func testSeedEmpty() {
        let r = Reservoir()
        r.seed(items: [])
        XCTAssertTrue(r.visibleItems.isEmpty)
        XCTAssertEqual(r.reservoirCount, 0)
    }

    func testSeedSingleSource() {
        let r = Reservoir()
        let items = makeItems(count: 30, sourceURL: "https://a.com/feed")
        r.seed(items: items)
        XCTAssertFalse(r.visibleItems.isEmpty)
        XCTAssertEqual(r.reservoirCount, 30 - r.visibleItems.count)
    }

    func testSeedMultipleSourcesInterleaves() {
        let r = Reservoir()
        let a = makeItems(count: 10, sourceURL: "https://a.com/feed")
        let b = makeItems(count: 10, sourceURL: "https://b.com/feed")
        r.seed(items: a + b)
        // Interleave should spread sources — no 3 consecutive from same source
        for i in 0..<(r.visibleItems.count - 3) {
            let slice = r.visibleItems[i..<(i + 3)]
            let sources = Set(slice.map(\.sourceURL))
            XCTAssertTrue(sources.count >= 2, "3 consecutive from same source at idx \(i)")
        }
    }

    // MARK: - append

    func testAppendDoesNotReorderVisible() {
        let r = Reservoir()
        let initial = makeItems(count: 25, sourceURL: "https://a.com/feed")
        r.seed(items: initial)
        let before = r.visibleItems.map(\.id)

        let more = makeItems(count: 10, sourceURL: "https://b.com/feed")
        r.append(more)

        // Existing visible items must not move
        let after = r.visibleItems.map(\.id)
        for (idx, id) in before.enumerated() {
            XCTAssertEqual(after[idx], id, "Visible item moved at idx \(idx)")
        }
    }

    // MARK: - capacity

    func testSeedProducesPageSize() {
        let r = Reservoir()
        let items = makeItems(count: 100, sourceURL: "https://a.com/feed")
        r.seed(items: items)
        XCTAssertLessThanOrEqual(r.visibleItems.count, Reservoir.pageSize)
    }

    func testReservoirCapped() {
        let r = Reservoir()
        r.seed(items: makeItems(count: 600, sourceURL: "https://a.com/feed"))
        XCTAssertLessThanOrEqual(r.reservoirCount, Reservoir.maxReservoirSize)
    }

    // MARK: - Helpers

    private func makeItems(count: Int, sourceURL: String) -> [FeedItem] {
        (0..<count).map { i in
            FeedItem(
                id: "\(sourceURL)#\(i)",
                sourceTitle: "Source",
                sourceURL: sourceURL,
                category: "Tech",
                title: "Item \(i)",
                excerpt: "Excerpt \(i)",
                url: "https://example.com/\(i)",
                imageURL: nil,
                publishedAt: Date().addingTimeInterval(-Double(i) * 3600),
                audioURL: nil,
                duration: nil,
                region: "global"
            )
        }
    }
}
