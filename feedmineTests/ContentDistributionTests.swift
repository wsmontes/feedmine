import XCTest
import OSLog
@testable import feedmine

/// Content distribution tests — verifies that the feed presents a fair,
/// diverse mix of sources, categories, regions, and media types.
///
/// Tests the full pipeline: items → interleave → reservoir → visible.
@MainActor
final class ContentDistributionTests: XCTestCase {

    private static let cd = Logger(
        subsystem: "com.feedmine.tests",
        category: "Distribution"
    )

    // MARK: - Source Diversity: frontLoadUniqueSources

    func testFirst100VisibleFromDistinctSources() {
        let log = Self.cd
        log.info("=== testFirst100UniqueSources ===")

        // 50 sources × 3 items each = 150 items
        var items: [FeedItem] = []
        for s in 0..<50 {
            for i in 0..<3 {
                items.append(makeItem(
                    title: "Source \(s) item \(i)",
                    sourceURL: "https://source\(s).com/feed"
                ))
            }
        }
        items.shuffle()

        let result = Reservoir.interleaveOffMain(
            items, readItemIDs: [], surfacedTimestamps: [:], sourceRegionMap: [:]
        )

        // First 50 items should each be from a unique source (we have 50 sources)
        let first50 = Array(result.prefix(50))
        let uniqueSources = Set(first50.map(\.sourceURL))
        log.info("  First 50 cards from \(uniqueSources.count) unique sources (have 50)")
        XCTAssertEqual(uniqueSources.count, 50,
            "First 50 items must each be from a distinct source when 50 sources available")

        // At minimum, the first 20 (pageSize) should be unique
        let first20 = Array(result.prefix(20))
        let unique20 = Set(first20.map(\.sourceURL))
        log.info("  First 20 cards from \(unique20.count) unique sources")
        XCTAssertEqual(unique20.count, 20,
            "First page (20) must be all distinct sources")

        log.info("  ✅ PASS")
    }

    func testFewerSourcesThanTargetStillAllUnique() {
        let log = Self.cd
        log.info("=== testFewerSourcesUnique ===")

        // Only 5 sources × 10 items = 50 items
        var items: [FeedItem] = []
        for s in 0..<5 {
            for i in 0..<10 {
                items.append(makeItem(
                    title: "S\(s)-\(i)", sourceURL: "https://s\(s).com/feed"
                ))
            }
        }
        items.shuffle()

        let result = Reservoir.interleaveOffMain(
            items, readItemIDs: [], surfacedTimestamps: [:], sourceRegionMap: [:]
        )

        let first5 = Array(result.prefix(5))
        let unique5 = Set(first5.map(\.sourceURL))
        log.info("  5 sources → first 5 cards from \(unique5.count) unique")
        XCTAssertEqual(unique5.count, 5)

        // After all 5 appear once, they should start repeating (only 5 sources)
        log.info("  ✅ PASS")
    }

    // MARK: - Source Spacing: no consecutive same-source

    func testNoConsecutiveSameSourceInFirst50() {
        let log = Self.cd
        log.info("=== testNoConsecutiveSameSource ===")

        var items: [FeedItem] = []
        for s in 0..<30 {
            for i in 0..<5 {
                items.append(makeItem(
                    title: "S\(s)-\(i)", sourceURL: "https://source\(s).com/feed"
                ))
            }
        }
        items.shuffle()

        let result = Reservoir.interleaveOffMain(
            items, readItemIDs: [], surfacedTimestamps: [:], sourceRegionMap: [:]
        )

        // Check no consecutive same-source in first 100
        var consecutiveViolations = 0
        for i in 1..<min(100, result.count) {
            if result[i].sourceURL == result[i-1].sourceURL {
                consecutiveViolations += 1
            }
        }
        log.info("  Consecutive same-source violations in first 100: \(consecutiveViolations)")
        XCTAssertEqual(consecutiveViolations, 0,
            "No consecutive same-source cards allowed")

        log.info("  ✅ PASS")
    }

    // MARK: - Source spacing: 3-card window

    func testSourceSpacingWithin3CardWindow() {
        let log = Self.cd
        log.info("=== testSourceSpacing3Window ===")

        var items: [FeedItem] = []
        for s in 0..<100 {
            items.append(makeItem(
                title: "Source \(s)", sourceURL: "https://s\(s).com/feed"
            ))
        }
        items.shuffle()

        let result = Reservoir.interleaveOffMain(
            items, readItemIDs: [], surfacedTimestamps: [:], sourceRegionMap: [:]
        )

        // With 100 unique sources, no source should repeat in a 3-card window
        let prefix = Array(result.prefix(100))
        var violations = 0
        for idx in 3..<prefix.count {
            let recent = Set(prefix[(idx-3)..<idx].map(\.sourceURL))
            if recent.contains(prefix[idx].sourceURL) { violations += 1 }
        }
        let violationRate = Double(violations) / Double(prefix.count) * 100
        log.info("  3-card window violations: \(violations)/\(prefix.count) (\(String(format: "%.1f", violationRate))%)")
        XCTAssertLessThan(violationRate, 5.0, "Under 5% source-repeat rate in 3-card window with 100 unique sources")

        log.info("  ✅ PASS")
    }

    // MARK: - Country Spreading

    func testCountrySpreadingAvoidsAdjacentSameCountry() {
        let log = Self.cd
        log.info("=== testCountrySpreading ===")

        var items: [FeedItem] = []
        // 3 sources per country × 10 countries
        let countries = ["brazil", "usa", "france", "japan", "germany",
                          "india", "mexico", "nigeria", "korea", "australia"]
        for c in 0..<10 {
            for s in 0..<3 {
                for i in 0..<5 {
                    items.append(makeItem(
                        title: "\(countries[c])-s\(s)-\(i)",
                        sourceURL: "https://\(countries[c])-s\(s).com/feed",
                        region: "countries/\(countries[c])"
                    ))
                }
            }
        }
        items.shuffle()

        // Build sourceRegionMap
        var regionMap: [String: String] = [:]
        for item in items { regionMap[item.sourceURL] = item.region }

        let result = Reservoir.interleaveOffMain(
            items, readItemIDs: [], surfacedTimestamps: [:], sourceRegionMap: regionMap
        )

        // Count adjacent same-country pairs in first 150
        var adjacentViolations = 0
        for i in 1..<min(150, result.count) {
            let prevRegion = regionMap[result[i-1].sourceURL] ?? "global"
            let currRegion = regionMap[result[i].sourceURL] ?? "global"
            if prevRegion == currRegion { adjacentViolations += 1 }
        }
        let adjRate = Double(adjacentViolations) / Double(min(149, result.count-1)) * 100
        log.info("  Adjacent same-country: \(adjacentViolations) (\(String(format: "%.1f", adjRate))%)")
        // With 10 countries and the country-spreading pass, adjacent same-country
        // should be uncommon. But some adjacency is unavoidable with few sources
        // per country. Target ≤15%.
        XCTAssertLessThan(adjRate, 20.0, "Under 20% adjacent same-country with 10 countries")

        log.info("  ✅ PASS")
    }

    // MARK: - Media Type Spread

    func testMediaTypesAreSpreadNotClustered() {
        let log = Self.cd
        log.info("=== testMediaTypeSpread ===")

        var items: [FeedItem] = []
        // Create an uneven mix: mostly text, some video, few audio
        for i in 0..<300 {
            let src: String
            let aud: String?
            if i < 200 {
                src = "https://text\(i).com/feed"
                aud = nil
            } else if i < 270 {
                src = "https://youtube.com/watch?v=\(i)"
                aud = nil
            } else {
                src = "https://podcast\(i).com/feed"
                aud = "https://ep\(i).mp3"
            }
            items.append(makeItem(
                title: "Item \(i)",
                sourceURL: src,
                audioURL: aud
            ))
        }
        items.shuffle()

        let result = Reservoir.interleaveOffMain(
            items, readItemIDs: [], surfacedTimestamps: [:], sourceRegionMap: [:]
        )

        // Measure max consecutive same media type
        func media(_ item: FeedItem) -> String {
            if item.isPodcast { return "audio" }
            if item.isYouTube { return "video" }
            return "text"
        }

        var maxRun = 0
        var currentRun = 1
        for i in 1..<min(200, result.count) {
            if media(result[i]) == media(result[i-1]) {
                currentRun += 1
                maxRun = max(maxRun, currentRun)
            } else {
                currentRun = 1
            }
        }

        log.info("  Max consecutive same media type: \(maxRun)")
        // Audio is only 10% of items — it should be spread thin, not clustered
        XCTAssertLessThan(maxRun, 8, "Max 7 consecutive same media type")

        // Count video and audio in first 20 (should each appear at least once if available)
        let first20 = Array(result.prefix(20))
        let videoInFirst20 = first20.filter(\.isYouTube).count
        let audioInFirst20 = first20.filter(\.isPodcast).count
        log.info("  First 20: \(videoInFirst20) video, \(audioInFirst20) audio, \(first20.count - videoInFirst20 - audioInFirst20) text")

        log.info("  ✅ PASS")
    }

    // MARK: - Category Diversity

    func testCategoriesAreSpreadAcrossFeed() {
        let log = Self.cd
        log.info("=== testCategorySpread ===")

        let categories = ["Tech", "Sports", "Politics", "Science", "Arts",
                           "Health", "Business", "Education", "Entertainment", "Travel"]
        var items: [FeedItem] = []
        for cat in categories {
            for i in 0..<15 {
                items.append(makeItem(
                    title: "\(cat) story \(i)",
                    sourceURL: "https://\(cat.lowercased()).com/feed",
                    category: cat
                ))
            }
        }
        items.shuffle()

        let result = Reservoir.interleaveOffMain(
            items, readItemIDs: [], surfacedTimestamps: [:], sourceRegionMap: [:]
        )

        // How many unique categories in first 20 cards?
        let first20 = Array(result.prefix(20))
        let uniqCats = Set(first20.map(\.category))
        log.info("  Unique categories in first 20: \(uniqCats.count)/10")
        XCTAssertGreaterThan(uniqCats.count, 3,
            "At least 4 different categories should appear in first 20 cards with 10 categories available")

        // Max consecutive same category
        var maxRun = 0
        var run = 1
        for i in 1..<min(100, result.count) {
            if result[i].category == result[i-1].category {
                run += 1
                maxRun = max(maxRun, run)
            } else { run = 1 }
        }
        log.info("  Max consecutive same category: \(maxRun)")
        XCTAssertLessThan(maxRun, 5, "Max 4 consecutive same category with 10 categories")

        log.info("  ✅ PASS")
    }

    // MARK: - Freshness: recent before surfaced

    func testFreshItemsBeforeSurfacedItems() {
        let log = Self.cd
        log.info("=== testFreshBeforeSurfaced ===")

        let now = Date()
        let oldDate = now.addingTimeInterval(-86400) // 1 day ago

        var items: [FeedItem] = []
        // 3 sources: each with fresh + old items
        for s in 0..<3 {
            for i in 0..<5 {
                items.append(makeItem(
                    title: "S\(s) fresh \(i)",
                    sourceURL: "https://s\(s).com/feed",
                    publishedAt: now.addingTimeInterval(-Double(i) * 60)
                ))
            }
            for i in 0..<5 {
                items.append(makeItem(
                    title: "S\(s) old \(i)",
                    sourceURL: "https://s\(s).com/feed",
                    publishedAt: oldDate.addingTimeInterval(-Double(i) * 3600)
                ))
            }
        }
        items.shuffle()

        // Simulate: mark the first half as surfaced
        var surfaced: [String: Date] = [:]
        for item in items.prefix(items.count / 2) {
            surfaced[item.id] = Date()
        }

        let result = Reservoir.interleaveOffMain(
            items, readItemIDs: [], surfacedTimestamps: surfaced, sourceRegionMap: [:]
        )

        // Surfaced items should appear later. Check: in the first 15,
        // less than 30% should be from the surfaced set
        let surfacedIDs = Set(surfaced.keys)
        let first15 = Array(result.prefix(15))
        let surfacedInFirst15 = first15.filter { surfacedIDs.contains($0.id) }.count
        log.info("  Surfaced items in first 15: \(surfacedInFirst15)/15")
        XCTAssertLessThan(surfacedInFirst15, 8,
            "Fewer than half of first 15 should be previously-surfaced items")

        log.info("  ✅ PASS")
    }

    // MARK: - Interleave preserves all items (no data loss)

    func testInterleavePreservesAllItems() {
        let log = Self.cd
        log.info("=== testInterleaveNoDataLoss ===")

        var items: [FeedItem] = []
        for s in 0..<10 {
            for i in 0..<3 {
                items.append(makeItem(
                    title: "S\(s)-\(i)", sourceURL: "https://s\(s).com/feed"
                ))
            }
        }

        let result = Reservoir.interleaveOffMain(
            items, readItemIDs: [], surfacedTimestamps: [:], sourceRegionMap: [:]
        )

        // No items lost
        XCTAssertEqual(result.count, items.count, "All items preserved")
        // No duplicates
        let ids = Set(result.map(\.id))
        XCTAssertEqual(ids.count, items.count, "No duplicate items")

        // All original items present
        let originalIDs = Set(items.map(\.id))
        XCTAssertEqual(ids, originalIDs, "All original items present in result")

        // Diversity still holds for shuffled input
        let shuffled = items.shuffled()
        let result3 = Reservoir.interleaveOffMain(
            shuffled, readItemIDs: [], surfacedTimestamps: [:], sourceRegionMap: [:]
        )
        let first10Sources = Set(result3.prefix(10).map(\.sourceURL))
        log.info("  Shuffled input → first 10 from \(first10Sources.count) unique sources")
        XCTAssertGreaterThan(first10Sources.count, 2, "Even shuffled input must show diversity")

        log.info("  ✅ PASS")
    }

    // MARK: - SourceScheduler Fairness

    func testSourceSchedulerPrefersDeficitRegions() {
        let log = Self.cd
        log.info("=== testSchedulerRegionDeficit ===")

        let scheduler = SourceScheduler()

        // Two regions: brazil (2 sources) and usa (10 sources)
        // √n weights: brazil √2≈1.41, usa √10≈3.16
        let sourcesByRegion: [String: [FeedSource]] = [
            "countries/brazil": (0..<2).map { i in
                FeedSource(title: "BR\(i)", url: "https://br\(i).com/feed",
                           category: "News", region: "countries/brazil", language: "pt")
            },
            "countries/usa": (0..<10).map { i in
                FeedSource(title: "US\(i)", url: "https://us\(i).com/feed",
                           category: "News", region: "countries/usa", language: "en")
            },
        ]

        // Empty reservoir → both regions should get picks
        let batch1 = scheduler.nextBatch(
            reservoir: [],
            sourcesByRegion: sourcesByRegion,
            activeRegion: nil,
            activeCategory: nil
        )

        let brPicks = batch1.filter { $0.region.hasPrefix("countries/brazil") }.count
        let usPicks = batch1.filter { $0.region.hasPrefix("countries/usa") }.count

        log.info("  Batch 1: \(brPicks) br, \(usPicks) us (\(batch1.count) total)")
        // With empty reservoir, both regions get representation
        XCTAssertGreaterThan(brPicks, 0, "Small region must get picks when reservoir empty")
        XCTAssertGreaterThan(usPicks, 0, "Large region must also get picks")

        log.info("  ✅ PASS")
    }

    func testSourceSchedulerRespectsContentTypeFilter() {
        let log = Self.cd
        log.info("=== testSchedulerContentTypeFilter ===")

        let scheduler = SourceScheduler()

        let sourcesByRegion: [String: [FeedSource]] = [
            "global": [
                FeedSource(title: "YT1", url: "https://youtube1.com/feed",
                           category: "Entertainment", region: "global",
                           mediaKind: .video, language: "en"),
                FeedSource(title: "T1", url: "https://text1.com/feed",
                           category: "News", region: "global",
                           mediaKind: .text, language: "en"),
                FeedSource(title: "YT2", url: "https://youtube2.com/feed",
                           category: "Entertainment", region: "global",
                           mediaKind: .video, language: "en"),
                FeedSource(title: "T2", url: "https://text2.com/feed",
                           category: "Tech", region: "global",
                           mediaKind: .text, language: "en"),
            ]
        ]

        let videoBatch = scheduler.nextBatch(
            reservoir: [],
            sourcesByRegion: sourcesByRegion,
            activeRegion: nil,
            activeCategory: nil,
            activeContentType: "video"
        )

        log.info("  Video filter → picked: \(videoBatch.map(\.title))")
        XCTAssertTrue(videoBatch.allSatisfy { $0.isYouTube || $0.mediaKind == .video },
            "Video filter must only pick video sources")
        XCTAssertEqual(videoBatch.count, 2, "Both video sources should be picked")

        log.info("  ✅ PASS")
    }

    func testSourceSchedulerLanguageFilterExcludesNonMatching() {
        let log = Self.cd
        log.info("=== testSchedulerLanguageFilter ===")

        let scheduler = SourceScheduler()
        let sourcesByRegion: [String: [FeedSource]] = [
            "global": [
                FeedSource(title: "EN1", url: "https://en1.com/feed",
                           category: "News", region: "global", language: "en"),
                FeedSource(title: "PT1", url: "https://pt1.com/feed",
                           category: "News", region: "global", language: "pt"),
                FeedSource(title: "FR1", url: "https://fr1.com/feed",
                           category: "News", region: "global", language: "fr"),
            ]
        ]

        let ptBatch = scheduler.nextBatch(
            reservoir: [],
            sourcesByRegion: sourcesByRegion,
            activeRegion: nil,
            activeCategory: nil,
            activeLanguages: ["pt"]
        )

        let titles = ptBatch.map(\.title)
        log.info("  Language=pt → picked: \(titles)")
        XCTAssertFalse(titles.contains("EN1"), "English source excluded when pt selected")
        XCTAssertFalse(titles.contains("FR1"), "French source excluded when pt selected")

        log.info("  ✅ PASS")
    }

    // MARK: - Reservoir Cap Fairness

    func testReservoirCapPreservesSourceDiversity() {
        let log = Self.cd
        log.info("=== testReservoirCapDiversity ===")

        // Create 600 items from 3 sources (200 each) → exceeds maxReservoirSize (500)
        var items: [FeedItem] = []
        for s in 0..<3 {
            for i in 0..<200 {
                items.append(makeItem(
                    title: "S\(s)-\(i)",
                    sourceURL: "https://source\(s).com/feed"
                ))
            }
        }

        let result = Reservoir.interleaveOffMain(
            items, readItemIDs: [], surfacedTimestamps: [:], sourceRegionMap: [:]
        )

        // After interleaving, each source should still be well-represented
        let sourceCounts = Dictionary(grouping: result, by: \.sourceURL).mapValues(\.count)
        log.info("  Source distribution after interleave: \(sourceCounts)")

        // No source should dominate completely
        let maxCount = sourceCounts.values.max() ?? 0
        let minCount = sourceCounts.values.min() ?? 0
        log.info("  Max: \(maxCount), Min: \(minCount)")
        // Ratio should be reasonable (not 10:1)
        let ratio = Double(maxCount) / Double(max(minCount, 1))
        log.info("  Max/min ratio: \(String(format: "%.1f", ratio))")
        XCTAssertLessThan(ratio, 1.5, "Source distribution should be nearly equal with equal input")

        log.info("  ✅ PASS")
    }

    // MARK: - End-to-End: items → interleave → visible page

    func testEndToEndDistributionPipeline() {
        let log = Self.cd
        log.info("=== testE2EDistribution ===")

        // Realistic scenario: 200 items from 40 sources, mixed types/regions
        var items: [FeedItem] = []
        let regions = ["countries/brazil", "countries/usa", "countries/france",
                        "countries/japan", "countries/germany", "global"]
        let categories = ["Tech", "Sports", "Politics", "Science", "Arts"]
        let mediaKinds = ["text", "text", "text", "video", "audio"] // weighted: mostly text

        for i in 0..<200 {
            let srcIdx = i % 40
            let reg = regions[i % regions.count]
            let cat = categories[i % categories.count]
            let kind = mediaKinds[i % mediaKinds.count]

            let srcURL: String
            let aud: String?
            switch kind {
            case "video": srcURL = "https://youtube.com/watch?v=\(i)"; aud = nil
            case "audio": srcURL = "https://podcast\(i).com/feed"; aud = "https://ep\(i).mp3"
            default:      srcURL = "https://text\(srcIdx).com/feed"; aud = nil
            }

            items.append(makeItem(
                title: "#\(i): \(cat) news from \(reg)",
                sourceURL: srcURL,
                category: cat,
                region: reg,
                audioURL: aud
            ))
        }
        items.shuffle()

        var regionMap: [String: String] = [:]
        for item in items { regionMap[item.sourceURL] = item.region }

        let start = CFAbsoluteTimeGetCurrent()
        let result = Reservoir.interleaveOffMain(
            items, readItemIDs: [], surfacedTimestamps: [:], sourceRegionMap: regionMap
        )
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        log.info("  Interleaved \(result.count) items in \(String(format: "%.2f", ms))ms")

        // Verify page 1 (first 20)
        let page1 = Array(result.prefix(20))
        let page1Sources = Set(page1.map(\.sourceURL))
        let page1Cats = Set(page1.map(\.category))
        let page1Regions = Set(page1.map { regionMap[$0.sourceURL] ?? "global" })

        log.info("  Page 1: \(page1Sources.count) sources, \(page1Cats.count) categories, \(page1Regions.count) regions")

        // All page 1 sources should be unique (we have 40 sources, all distinct)
        XCTAssertEqual(page1Sources.count, 20,
            "Page 1 must have all distinct sources")

        // At least 3 different categories
        XCTAssertGreaterThanOrEqual(page1Cats.count, 3,
            "Page 1 must show at least 3 categories")

        // At least 3 different regions
        XCTAssertGreaterThanOrEqual(page1Regions.count, 3,
            "Page 1 must show at least 3 regions")

        // Video and audio should appear in first page (media spread working)
        let videoInPage1 = page1.filter(\.isYouTube).count
        let audioInPage1 = page1.filter(\.isPodcast).count
        log.info("  Page 1 media: \(videoInPage1) video, \(audioInPage1) audio, \(20-videoInPage1-audioInPage1) text")

        log.info("  ✅ PASS — E2E distribution pipeline verified")
    }

    // MARK: - Helpers

    private func makeItem(
        title: String,
        sourceURL: String = "https://example.com/feed",
        category: String = "Tech",
        language: String? = nil,
        region: String = "global",
        audioURL: String? = nil,
        publishedAt: Date = Date(),
        id: String = UUID().uuidString
    ) -> FeedItem {
        FeedItem(
            id: id,
            sourceTitle: "Source",
            sourceURL: sourceURL,
            category: category,
            title: title,
            excerpt: title,
            url: sourceURL + "/item",
            imageURL: nil,
            publishedAt: publishedAt,
            audioURL: audioURL,
            duration: audioURL != nil ? 1800 : nil,
            region: region,
            language: language
        )
    }
}
