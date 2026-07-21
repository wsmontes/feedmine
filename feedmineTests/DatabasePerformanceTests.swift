import XCTest
import OSLog
@testable import feedmine
import GRDB

/// Database performance benchmarks — measures GRDB query throughput
/// on the physical device for filter-critical paths.
@MainActor
final class DatabasePerformanceTests: XCTestCase {

    private static let dbg = Logger(
        subsystem: "com.feedmine.tests",
        category: "DBPerf"
    )

    private var store: FeedStore!

    override func setUp() async throws {
        store = try FeedStore(inMemory: true)
    }

    override func tearDown() {
        store = nil
    }

    // MARK: - Write Throughput

    func testBulkInsertThroughput_1000Items() async throws {
        let log = Self.dbg
        log.info("=== testBulkInsert_1000 ===")

        let items = makeBulk(count: 1000)
        let start = CFAbsoluteTimeGetCurrent()
        let persisted = await store.persistFetchedItems(items)
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

        log.info("  Persisted \(persisted.count)/1000 items in \(String(format: "%.2f", elapsed))ms")
        let tput = Double(persisted.count) / (elapsed / 1000)
        log.info("  Throughput: \(String(format: "%.1f", tput)) items/sec")

        XCTAssertEqual(persisted.count, 1000, "All items must persist")
        XCTAssertLessThan(elapsed, 3000, "1000 inserts under 3s")

        log.info("  ✅ PASS")
    }

    func testBulkInsertThroughput_5000Items() async throws {
        let log = Self.dbg
        log.info("=== testBulkInsert_5000 ===")

        let items = makeBulk(count: 5000)
        let start = CFAbsoluteTimeGetCurrent()
        let persisted = await store.persistFetchedItems(items)
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

        log.info("  Persisted \(persisted.count)/5000 items in \(String(format: "%.2f", elapsed))ms")
        let tput = Double(persisted.count) / (elapsed / 1000)
        log.info("  Throughput: \(String(format: "%.1f", tput)) items/sec")

        XCTAssertGreaterThan(persisted.count, 0, "Some items must persist")
        XCTAssertLessThan(elapsed, 15000, "5000 inserts under 15s")

        log.info("  ✅ PASS")
    }

    // MARK: - Read Throughput (filtered queries)

    func testFilteredReadPerformance_1000Items() async throws {
        let log = Self.dbg
        log.info("=== testFilteredRead_1000 ===")

        var items = makeBulk(count: 1000)
        for i in items.indices {
            if i % 8 == 0 {
                items[i] = item(title: "Item \(i)", sourceURL: "https://youtube.com/watch?v=\(i)", language: "pt", region: "countries/brazil")
            } else if i % 6 == 0 {
                items[i] = item(title: "Item \(i)", sourceURL: "https://youtube.com/watch?v=\(i)", language: "fr", region: "countries/france")
            }
        }
        _ = await store.persistFetchedItems(items)

        // Set filter and measure
        store.setFilter(region: nil, nodeIDs: [], type: .all, mood: .all, languages: ["pt"])

        let start = CFAbsoluteTimeGetCurrent()
        let visible = store.visibleItems
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

        log.info("  Filter [lang=pt] → \(visible.count) visible items in \(String(format: "%.2f", elapsed))ms")
        XCTAssertLessThan(elapsed, 1000, "Filtered read under 1s")

        log.info("  ✅ PASS")
    }

    // MARK: - Filter Switching Speed

    func testRapidFilterSwitchingOnDB() async throws {
        let log = Self.dbg
        log.info("=== testRapidFilterSwitchOnDB ===")

        let items = makeBulk(count: 500)
        _ = await store.persistFetchedItems(items)

        let configs: [(FeedLoader.ContentType, Set<String>)] = [
            (.all, []), (.video, ["en"]), (.all, ["pt"]),
            (.all, []), (.video, []), (.all, ["fr"]),
            (.all, []), (.video, ["pt"]),
        ]

        var timings: [Double] = []
        for (type, langs) in configs {
            let start = CFAbsoluteTimeGetCurrent()
            store.setFilter(region: nil, nodeIDs: [], type: type, mood: .all, languages: langs)
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            timings.append(ms)
        }

        let avg = timings.reduce(0, +) / Double(timings.count)
        let max = timings.max() ?? 0
        log.info("  8 rapid filter switches: avg=\(String(format: "%.2f", avg))ms max=\(String(format: "%.2f", max))ms")

        XCTAssertLessThan(avg, 100, "Filter switch avg under 100ms")
        log.info("  ✅ PASS")
    }

    // MARK: - Item Count vs Filter Speed

    func testItemCountImpactOnFilterSpeed() async throws {
        let log = Self.dbg
        log.info("=== testItemCountVsFilterSpeed ===")

        let sizes = [100, 500, 2000, 5000]
        for size in sizes {
            let items = makeBulk(count: size)
            _ = await store.persistFetchedItems(items)

            let start = CFAbsoluteTimeGetCurrent()
            store.setFilter(region: nil, nodeIDs: [], type: .video, mood: .all, languages: [])
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000

            let visible = store.visibleItems.count
            log.info("  Filter[video] on \(size) items → \(visible) visible in \(String(format: "%.2f", ms))ms")
        }

        log.info("  ✅ PASS")
    }

    // MARK: - FTS Search Performance

    func testFTSSearchPerformance() async throws {
        let log = Self.dbg
        log.info("=== testFTSSearch ===")

        let topics = ["quantum breakthrough", "football championship",
                       "economic policy", "climate science",
                       "artificial intelligence", "space mission"]
        var items: [FeedItem] = []
        for i in 0..<300 {
            items.append(item(
                title: "#\(i): \(topics[i % topics.count]) in depth",
                sourceURL: "https://news\(i%10).com/feed"
            ))
        }
        _ = await store.persistFetchedItems(items)

        let queries = ["quantum", "football", "climate", "artificial", "mission"]
        for q in queries {
            let start = CFAbsoluteTimeGetCurrent()
            let results = await store.searchEngine.search(q, region: nil, category: nil)
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000

            log.info("  FTS '\(q)': \(results.count) results in \(String(format: "%.2f", ms))ms")
            XCTAssertLessThan(ms, 200, "FTS search under 200ms for '\(q)'")
        }

        log.info("  ✅ PASS")
    }

    // MARK: - Helpers

    private func item(
        title: String,
        sourceURL: String = "https://example.com/feed",
        language: String? = nil,
        region: String = "global"
    ) -> FeedItem {
        FeedItem(
            id: UUID().uuidString,
            sourceTitle: "Test",
            sourceURL: sourceURL,
            category: "Tech",
            title: title,
            excerpt: title,
            url: sourceURL + "/item",
            imageURL: nil,
            publishedAt: Date(),
            audioURL: nil,
            duration: nil,
            region: region,
            language: language
        )
    }

    private func makeBulk(count: Int, startIndex: Int = 0) -> [FeedItem] {
        (startIndex..<(startIndex + count)).map { i in
            item(
                title: "Item #\(i): content topic \(i % 50)",
                sourceURL: "https://source\(i % 30).com/feed",
                language: ["en", "pt", "fr", "es", nil][i % 5],
                region: i % 10 == 0 ? "countries/brazil" : "global"
            )
        }
    }
}
