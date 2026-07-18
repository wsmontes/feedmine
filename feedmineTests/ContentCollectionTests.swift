import XCTest
import OSLog
@testable import feedmine

/// Content collection pipeline benchmarks — fetch, persist, interleave,
/// language detection, and end-to-end filter→reload cycle performance.
@MainActor
final class ContentCollectionTests: XCTestCase {

    private static let cc = Logger(
        subsystem: "com.feedmine.tests",
        category: "ContentCollection"
    )

    private var store: FeedStore!

    override func setUp() async throws {
        store = try FeedStore(inMemory: true)
    }

    override func tearDown() {
        store = nil
    }

    // MARK: - Reservoir Interleave at Scale

    func testReservoirInterleavePerformance_1000Items() {
        let log = Self.cc
        log.info("=== testReservoirInterleave_1000 ===")

        let items = makeItems(count: 1000, sourceSpread: 50)
        let start = CFAbsoluteTimeGetCurrent()
        let interleaved = Reservoir.interleaveOffMain(
            items, readItemIDs: [], surfacedTimestamps: [:], sourceRegionMap: [:]
        )
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000

        log.info("  Interleaved \(interleaved.count) items from 50 sources in \(String(format: "%.2f", ms))ms")
        XCTAssertEqual(interleaved.count, 1000)
        XCTAssertLessThan(ms, 400, "Interleave 1000 items under 400ms")

        // Verify diversity — first 100 items should not repeat sources in any 3-card window
        let prefix = Array(interleaved.prefix(100))
        let violations = (3..<prefix.count).filter { idx in
            let recent = Set(prefix[(idx-3)..<idx].map(\.sourceURL))
            return recent.contains(prefix[idx].sourceURL)
        }
        log.info("  Diversity: \(violations.count) source-repeat violations in 100 items (3-card window)")
        // With 50 sources and 1000 items, the first 100 should be very diverse
        XCTAssertLessThanOrEqual(violations.count, 10, "At most 10% source-repeat rate in 3-card window")
    }

    func testReservoirInterleavePerformance_5000Items() {
        let log = Self.cc
        log.info("=== testReservoirInterleave_5000 ===")

        let items = makeItems(count: 5000, sourceSpread: 100)
        let start = CFAbsoluteTimeGetCurrent()
        let interleaved = Reservoir.interleaveOffMain(
            items, readItemIDs: [], surfacedTimestamps: [:], sourceRegionMap: [:]
        )
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000

        log.info("  Interleaved \(interleaved.count) items from 100 sources in \(String(format: "%.2f", ms))ms")
        XCTAssertEqual(interleaved.count, 5000)
        XCTAssertLessThan(ms, 2000, "Interleave 5000 items under 2s")

        log.info("  ✅ PASS")
    }

    // MARK: - Language Detection Throughput

    func testLanguageDetectionBatchSpeed() async throws {
        let log = Self.cc
        log.info("=== testLanguageDetection ===")

        // Create items with mixed-language content
        let samples: [(String, String)] = [
            ("Breaking news from Washington DC today", "en"),
            ("Le président français a annoncé une nouvelle réforme", "fr"),
            ("Brasil conquista medalha de ouro nas olimpíadas", "pt"),
            ("La economía española crece un tres por ciento", "es"),
            ("Deutsche Bundeskanzler trifft europäische Partner", "de"),
            ("Latest technology review and analysis report", "en"),
            ("Nova descoberta científica revoluciona o mercado", "pt"),
            ("El presidente mexicano visita la capital francesa", "es"),
        ]

        var items: [FeedItem] = []
        for i in 0..<200 {
            let sample = samples[i % samples.count]
            items.append(item(
                title: "\(sample.0) — edition \(i)",
                sourceURL: "https://news\(i % 10).com/feed",
                language: nil  // Will be detected
            ))
        }

        // Measure persist time (includes language detection)
        let start = CFAbsoluteTimeGetCurrent()
        let persisted = await store.persistFetchedItems(items)
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000

        let detected = persisted.filter { $0.language != nil }.count
        log.info("  Persisted \(persisted.count) items with language detection in \(String(format: "%.2f", ms))ms")
        log.info("  Languages detected: \(detected)/\(persisted.count)")
        log.info("  Throughput: \(String(format: "%.1f", Double(persisted.count) / ms * 1000)) items/s")

        XCTAssertGreaterThan(detected, 0, "Some languages should be detected")
        XCTAssertLessThan(ms, 5000, "200 items with lang detect under 5s")

        log.info("  ✅ PASS")
    }

    // MARK: - End-to-End: Persist → Filter → Reload

    func testEndToEndFilterReloadCycle() async throws {
        let log = Self.cc
        log.info("=== testEndToEndFilterReload ===")

        // Seed 2000 items with realistic distribution
        var items = makeItems(count: 2000, sourceSpread: 30)
        for i in items.indices {
            if i % 8 == 0 {
                items[i] = item(title: "Video \(i)", sourceURL: "https://youtube.com/watch?v=\(i)", language: ["en","pt","fr"][i%3])
            } else if i % 10 == 0 {
                items[i] = item(title: "Podcast \(i)", sourceURL: "https://podcast\(i).com/feed", language: ["en","es"][i%2], audioURL: "https://ep\(i).mp3")
            }
        }

        // Phase 1: Persist
        let start1 = CFAbsoluteTimeGetCurrent()
        let persisted = await store.persistFetchedItems(items)
        let persistMs = (CFAbsoluteTimeGetCurrent() - start1) * 1000
        log.info("  Phase 1 — Persist \(persisted.count) items: \(String(format: "%.2f", persistMs))ms")

        // Phase 2: Set filter and reload
        let filterCombos: [(FeedLoader.ContentType, Set<String>)] = [
            (.all, []), (.video, ["en"]), (.all, ["pt"]), (.video, []), (.all, [])
        ]

        var reloadTimings: [Double] = []
        for (type, langs) in filterCombos {
            let start = CFAbsoluteTimeGetCurrent()
            store.setFilter(region: nil, nodeIDs: [], type: type, mood: .all, languages: langs)
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            reloadTimings.append(ms)

            let visible = store.visibleItems.count
            let contentType = type == .video ? "video" : "all"
            let langStr = langs.isEmpty ? "all" : langs.first!
            log.info("  Phase 2 — [\(contentType)+\(langStr)]: \(visible) visible in \(String(format: "%.2f", ms))ms")
        }

        let avgReload = reloadTimings.reduce(0, +) / Double(reloadTimings.count)
        log.info("  Avg filter switch: \(String(format: "%.2f", avgReload))ms")
        XCTAssertLessThan(avgReload, 200, "Filter switch avg under 200ms")

        log.info("  ✅ PASS")
    }

    // MARK: - Source Enablement Check Speed

    func testSourceEnablementCheckSpeed() {
        let log = Self.cc
        log.info("=== testSourceEnablementCheck ===")

        // Toggle several sources to build up the registry
        for i in 0..<50 {
            store.registry.toggleSource("https://source\(i).com/feed")
            // Toggle again to keep them on
            store.registry.toggleSource("https://source\(i).com/feed")
        }

        // Measure isSourceEnabled check speed (cold: not yet cached)
        let start = CFAbsoluteTimeGetCurrent()
        for i in 0..<50 {
            _ = store.registry.isSourceEnabled("https://source\(i).com/feed")
        }
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000

        log.info("  50 enablement checks in \(String(format: "%.2f", ms))ms")
        XCTAssertLessThan(ms, 50, "50 source checks under 50ms")

        log.info("  ✅ PASS")
    }

    // MARK: - Bulk Persist with Duplicate Detection

    func testBulkPersistDedupPerformance() async throws {
        let log = Self.cc
        log.info("=== testBulkPersistDedup ===")

        // First batch
        let batch1 = makeItems(count: 500, sourceSpread: 10)
        let p1 = await store.persistFetchedItems(batch1)
        log.info("  Batch 1: \(p1.count) persisted")

        // Second batch — 50% duplicates
        let batch2 = makeItems(count: 500, sourceSpread: 10)
        let start = CFAbsoluteTimeGetCurrent()
        let p2 = await store.persistFetchedItems(batch2)
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000

        let newItems = p2.count
        let dupes = 500 - newItems
        log.info("  Batch 2: \(newItems) new, \(dupes) duplicates in \(String(format: "%.2f", ms))ms")
        log.info("  Dedup overhead: \(String(format: "%.2f", ms))ms for 500 items")

        XCTAssertLessThan(ms, 1000, "Dedup 500 items under 1s")
        log.info("  ✅ PASS")
    }

    // MARK: - Read-Modify-Write Cycle (bookmark toggle)

    func testReadModifyWriteCycle() async throws {
        let log = Self.cc
        log.info("=== testReadModifyWrite ===")

        // Seed items
        let items = makeItems(count: 100, sourceSpread: 5)
        let persisted = await store.persistFetchedItems(items)
        log.info("  Seeded \(persisted.count) items")

        // Toggle bookmarks rapidly
        let ids = persisted.prefix(20).map(\.id)
        let start = CFAbsoluteTimeGetCurrent()
        for id in ids {
            try await store.toggleBookmark(itemID: id)
        }
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000

        log.info("  20 bookmark toggles in \(String(format: "%.2f", ms))ms")
        log.info("  Avg per toggle: \(String(format: "%.2f", ms/20))ms")
        XCTAssertLessThan(ms, 500, "20 bookmark toggles under 500ms")

        log.info("  ✅ PASS")
    }

    // MARK: - Helpers

    private func item(
        title: String,
        sourceURL: String = "https://example.com/feed",
        category: String = "Tech",
        language: String? = nil,
        region: String = "global",
        audioURL: String? = nil
    ) -> FeedItem {
        FeedItem(
            id: UUID().uuidString,
            sourceTitle: "Test Source",
            sourceURL: sourceURL,
            category: category,
            title: title,
            excerpt: title,
            url: sourceURL + "/item",
            imageURL: nil,
            publishedAt: Date().addingTimeInterval(-Double.random(in: 0...86400)),
            audioURL: audioURL,
            duration: audioURL != nil ? 1800 : nil,
            region: region,
            language: language
        )
    }

    private func makeItems(count: Int, sourceSpread: Int) -> [FeedItem] {
        (0..<count).map { i in
            item(
                title: "Item #\(i): content about topic \(i % 40)",
                sourceURL: "https://source\(i % sourceSpread).com/feed",
                language: ["en", "pt", "fr", "es", "de", nil][i % 6],
                region: i % 12 == 0 ? "countries/brazil" : "global"
            )
        }
    }
}
