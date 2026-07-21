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
        // With two text providers and one podcast provider, strict provider
        // rotation has a theoretical one-in-three text/text floor.
        var consecutiveTextCount = 0
        for i in 0..<(result.count - 1) {
            let a = result[i], b = result[i + 1]
            if !a.isYouTube && !a.isPodcast && !b.isYouTube && !b.isPodcast {
                consecutiveTextCount += 1
            }
        }
        let totalPairs = result.count - 1
        XCTAssertLessThanOrEqual(consecutiveTextCount, (totalPairs + 2) / 3,
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

    func testInterleaveOffMainAvoidsABAProviderRhythmWhenPossible() {
        let all = makeItems(count: 10, sourceURL: "https://a.com/feed")
            + makeItems(count: 10, sourceURL: "https://b.com/feed")
            + makeItems(count: 10, sourceURL: "https://c.com/feed")
            + makeItems(count: 10, sourceURL: "https://d.com/feed")

        let result = Reservoir.interleaveOffMain(
            all, readItemIDs: [], surfacedTimestamps: [:], sourceRegionMap: [:]
        )
        let prefix = Array(result.prefix(24))

        for index in 2..<prefix.count {
            XCTAssertNotEqual(
                prefix[index].sourceURL,
                prefix[index - 2].sourceURL,
                "Provider repeated in A/B/A rhythm at idx \(index)"
            )
        }
    }

    func testInterleaveKeepsProviderOffTheNextScreenfulWhenPossible() {
        let all = (0..<8).flatMap { source in
            makeItems(count: 8, sourceURL: "https://source\(source).com/feed",
                      category: "Category \(source % 4)")
        }

        let result = Reservoir.interleaveOffMain(
            all, readItemIDs: [], surfacedTimestamps: [:], sourceRegionMap: [:]
        )
        let prefix = Array(result.prefix(40))

        for index in prefix.indices {
            let recentStart = max(0, index - 6)
            guard recentStart < index else { continue }
            let recentSources = Set(prefix[recentStart..<index].map(\.sourceURL))
            XCTAssertFalse(
                recentSources.contains(prefix[index].sourceURL),
                "Provider repeated within the previous six cards at idx \(index)"
            )
        }
    }

    func testInterleaveMakesEveryProviderInInitialRunwayUniqueWhenPossible() {
        let all = (0..<120).flatMap { source in
            makeItems(
                count: 2,
                sourceURL: "https://first-page-\(source).com/feed",
                category: "Category \(source % 8)"
            )
        }

        let result = Reservoir.interleaveOffMain(
            all, readItemIDs: [], surfacedTimestamps: [:], sourceRegionMap: [:]
        )
        let initialRunway = Array(result.prefix(Reservoir.initialUniqueSourceTarget))

        XCTAssertEqual(initialRunway.count, Reservoir.initialUniqueSourceTarget)
        XCTAssertEqual(Set(initialRunway.map(\.sourceURL)).count, Reservoir.initialUniqueSourceTarget)
    }

    func testGoogleNewsQueriesCountAsOneProvider() {
        let googleNews = (0..<13).flatMap { query in
            makeItems(
                count: 8,
                sourceURL: "https://news.google.com/rss/search?q=topic-\(query)&hl=zh&gl=CN",
                category: "News"
            )
        }
        let direct = (0..<24).flatMap { source in
            makeItems(
                count: 4,
                sourceURL: "https://publisher-\(source).cn/feed",
                category: "Category \(source % 6)"
            )
        }

        let result = Reservoir.interleaveOffMain(
            googleNews + direct,
            readItemIDs: [],
            surfacedTimestamps: [:],
            sourceRegionMap: [:]
        )
        let firstScreen = Array(result.prefix(Reservoir.pageSize))
        let googleNewsCount = firstScreen.filter {
            URL(string: $0.sourceURL)?.host == "news.google.com"
        }.count

        XCTAssertEqual(googleNewsCount, 1)
        XCTAssertEqual(Set(firstScreen.map(Reservoir.providerKey)).count, firstScreen.count)
    }

    func testGoogleNewsDoesNotRunTogetherWithChineseCollectionRatio() {
        let googleNews = (0..<63).flatMap { query in
            makeItems(
                count: 50,
                sourceURL: "https://news.google.com/rss/search?q=zh-topic-\(query)&hl=zh",
                category: "Category \(query % 12)",
                sourceTitle: "Publisher \(query % 20)"
            )
        }
        let directCounts = [50, 44, 15, 15, 15, 15, 15, 15, 25, 2, 2, 1, 1]
        let direct = directCounts.enumerated().flatMap { provider, count in
            makeItems(
                count: count,
                sourceURL: "https://direct-\(provider).example/feed",
                category: "Category \(provider % 8)"
            )
        }

        let databaseOrder = googleNews + direct
        let sqlWindow = Array(databaseOrder.prefix(FeedStore.candidateReadLimit))
        let pool = FeedStore.balancedCandidatePool(sqlWindow)
        let result = Reservoir.interleaveOffMain(
            pool, readItemIDs: [], surfacedTimestamps: [:], sourceRegionMap: [:]
        )
        let firstHundred = Array(result.prefix(100))
        let keys = firstHundred.map(Reservoir.providerKey)
        let repeatedProvider = zip(keys, keys.dropFirst()).filter(==)

        XCTAssertTrue(repeatedProvider.isEmpty)
        XCTAssertFalse(firstHundred.contains { $0.sourceTitle.hasPrefix("Candidate:") })
    }

    func testYouTubeChannelsRemainDistinctProviders() {
        let channels = (0..<20).flatMap { channel in
            makeItems(
                count: 2,
                sourceURL: "https://youtube.com/feeds/videos.xml?channel_id=channel-\(channel)",
                category: "Video"
            )
        }

        let result = Reservoir.interleaveOffMain(
            channels, readItemIDs: [], surfacedTimestamps: [:], sourceRegionMap: [:]
        )
        let firstScreen = Array(result.prefix(Reservoir.pageSize))

        XCTAssertEqual(Set(firstScreen.map(Reservoir.providerKey)).count, Reservoir.pageSize)
    }

    func testInterleaveSpreadsCategoriesWhenEveryItemIsText() {
        let all = (0..<8).flatMap { source in
            makeItems(count: 6, sourceURL: "https://text\(source).com/feed",
                      category: "Category \(source % 4)")
        }

        let result = Reservoir.interleaveOffMain(
            all, readItemIDs: [], surfacedTimestamps: [:], sourceRegionMap: [:]
        )
        let prefix = Array(result.prefix(32))

        for index in prefix.indices {
            let recentStart = max(0, index - 3)
            guard recentStart < index else { continue }
            let recentCategories = Set(prefix[recentStart..<index].map(\.category))
            XCTAssertFalse(
                recentCategories.contains(prefix[index].category),
                "Category repeated within the previous three text cards at idx \(index)"
            )
        }
    }

    // MARK: - Helpers

    private func makeItems(
        count: Int,
        sourceURL: String,
        category: String = "Tech",
        audioURL: String? = nil,
        sourceTitle: String = "Source"
    ) -> [FeedItem] {
        (0..<count).map { i in
            FeedItem(
                id: "\(sourceURL)#\(i)",
                sourceTitle: sourceTitle,
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
