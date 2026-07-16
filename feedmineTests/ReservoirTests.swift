import XCTest
@testable import feedmine

@MainActor
final class ReservoirTests: XCTestCase {

    // MARK: - seed

    func testSeedEmpty() async {
        let r = Reservoir()
        await r.seed(items: [])
        XCTAssertTrue(r.visibleItems.isEmpty)
        XCTAssertEqual(r.reservoirCount, 0)
    }

    func testSeedSingleSource() async {
        let r = Reservoir()
        let items = makeItems(count: 30, sourceURL: "https://a.com/feed")
        await r.seed(items: items)
        XCTAssertFalse(r.visibleItems.isEmpty)
        XCTAssertEqual(r.reservoirCount, 30 - r.visibleItems.count)
    }

    func testSeedMultipleSourcesInterleaves() async {
        let r = Reservoir()
        let a = makeItems(count: 10, sourceURL: "https://a.com/feed")
        let b = makeItems(count: 10, sourceURL: "https://b.com/feed")
        await r.seed(items: a + b)
        // Interleave should spread sources — no 3 consecutive from same source
        for i in 0..<(r.visibleItems.count - 3) {
            let slice = r.visibleItems[i..<(i + 3)]
            let sources = Set(slice.map(\.sourceURL))
            XCTAssertTrue(sources.count >= 2, "3 consecutive from same source at idx \(i)")
        }
    }

    // MARK: - append

    func testAppendDoesNotReorderVisible() async {
        let r = Reservoir()
        let initial = makeItems(count: 25, sourceURL: "https://a.com/feed")
        await r.seed(items: initial)
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

    func testSeedProducesPageSize() async {
        let r = Reservoir()
        let items = makeItems(count: 100, sourceURL: "https://a.com/feed")
        await r.seed(items: items)
        XCTAssertLessThanOrEqual(r.visibleItems.count, Reservoir.pageSize)
    }

    func testReservoirCapped() async {
        let r = Reservoir()
        await r.seed(items: makeItems(count: 600, sourceURL: "https://a.com/feed"))
        XCTAssertLessThanOrEqual(r.reservoirCount, Reservoir.maxReservoirSize)
    }

    // MARK: - interleaveOffMain diversity

    func testInterleaveOffMainSpreadsSources() {
        let a = makeItems(count: 15, sourceURL: "https://a.com/feed")
        let b = makeItems(count: 15, sourceURL: "https://b.com/feed")
        let c = makeItems(count: 15, sourceURL: "https://c.com/feed")
        let all = a + b + c
        let result = Reservoir.interleaveOffMain(
            all, readItemIDs: [], surfacedTimestamps: [:], sourceRegionMap: [:]
        )
        // Should not have 3+ consecutive from same source
        for i in 0..<(result.count - 3) {
            let slice = result[i..<(i + 3)]
            let sources = Set(slice.map(\.sourceURL))
            XCTAssertTrue(sources.count >= 2, "3 consecutive from same source at idx \(i)")
        }
    }

    func testInterleaveOffMainSpreadsTextItems() {
        // Three feeds: two text-only (News, Sports) and one all-podcast
        // (Technology). The round-robin naturally places text items from News
        // and Sports adjacent, creating text-text clashes that exercise the
        // spreadConsecutiveImpl text-text detection path. The podcast items
        // from Technology serve as swap candidates, so the post-processing
        // can actually reduce consecutive text-text pairs below threshold.
        let news = makeItems(count: 15, sourceURL: "https://news.com/feed",
                            category: "News")
        let sports = makeItems(count: 15, sourceURL: "https://sports.com/feed",
                              category: "Sports")
        // Use 18 podcast items so there is excess capacity for swap candidates
        // beyond the 15 text-text pairs created by the News/Sports round-robin.
        let tech = makeItems(count: 18, sourceURL: "https://tech.com/feed",
                            category: "Technology",
                            audioURL: "https://tech.com/episode")
        let all = news + sports + tech
        let result = Reservoir.interleaveOffMain(
            all, readItemIDs: [], surfacedTimestamps: [:], sourceRegionMap: [:]
        )
        // Verify the text-text clash detection fired and the spread reduced
        // consecutive text-text pairs below 30% of total adjacent pairs.
        var consecutiveTextCount = 0
        for i in 0..<(result.count - 1) {
            let a = result[i], b = result[i + 1]
            if !a.isYouTube && !a.isPodcast && !b.isYouTube && !b.isPodcast {
                consecutiveTextCount += 1
            }
        }
        let totalPairs = result.count - 1
        XCTAssertLessThan(consecutiveTextCount, totalPairs * 30 / 100,
                          "Too many consecutive text pairs: \(consecutiveTextCount)/\(totalPairs)")
    }

    func testInterleaveOffMainUsesSourceRegionMap() {
        // Items from 3 different countries — region map should spread them
        var regionMap: [String: String] = [:]
        let br = makeItems(count: 10, sourceURL: "https://br.com/feed")
        let jp = makeItems(count: 10, sourceURL: "https://jp.com/feed")
        let de = makeItems(count: 10, sourceURL: "https://de.com/feed")
        regionMap["https://br.com/feed"] = "countries/brazil"
        regionMap["https://jp.com/feed"] = "countries/japan"
        regionMap["https://de.com/feed"] = "countries/germany"
        let all = br + jp + de
        let result = Reservoir.interleaveOffMain(
            all, readItemIDs: [], surfacedTimestamps: [:], sourceRegionMap: regionMap
        )
        // Should not have 4+ consecutive from same country
        for i in 0..<(result.count - 4) {
            let slice = result[i..<(i + 4)]
            let countries = Set(slice.map { regionMap[$0.sourceURL] ?? "unknown" })
            XCTAssertTrue(countries.count >= 2,
                          "4 consecutive from same country at idx \(i): \(countries)")
        }
    }

    // MARK: - Helpers

    private func makeItems(count: Int, sourceURL: String, category: String = "Tech", audioURL: String? = nil) -> [FeedItem] {
        (0..<count).map { i in
            FeedItem(
                id: "\(sourceURL)#\(i)",
                sourceTitle: "Source",
                sourceURL: sourceURL,
                category: category,
                title: "Item \(i)",
                excerpt: "Excerpt \(i)",
                url: "https://example.com/\(i)",
                imageURL: nil,
                publishedAt: Date().addingTimeInterval(-Double(i) * 3600),
                audioURL: audioURL.map { _ in "\(sourceURL)/episode\(i).mp3" },
                duration: audioURL != nil ? 1800 : nil,
                region: "global"
            )
        }
    }
}
