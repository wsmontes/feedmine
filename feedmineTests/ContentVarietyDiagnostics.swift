import XCTest
import OSLog
@testable import feedmine

/// Diagnostic battery: measures the severity of provider and category
/// clustering in the feed. The rule is minimum same-provider or same-category
/// within 10 cards of each other. These tests measure how often the rule
/// is violated under various real-world distributions.
///
/// Output is structured for analysis — log metrics, not just pass/fail.
@MainActor
final class ContentVarietyDiagnostics: XCTestCase {

    private static let v = Logger(
        subsystem: "com.feedmine.tests",
        category: "Variety"
    )

    // MARK: - Config

    /// The window within which a repeat is considered a violation
    private static let violationWindow = 10

    // MARK: - Scenario 1: Flat distribution (equal items per source)

    func test_diag_flatDistribution() {
        let log = Self.v
        log.info("=== DIAG: Flat distribution ===")
        log.info("  50 sources × 10 items each = 500 items")

        var items: [FeedItem] = []
        let categories = ["Tech", "Sports", "Politics", "Science", "Arts",
                          "Health", "Business", "Entertainment", "Travel", "Education"]
        for s in 0..<50 {
            let cat = categories[s % categories.count]
            for i in 0..<10 {
                items.append(item(
                    title: "S\(s)-\(i): \(cat) news",
                    sourceURL: "https://source\(s).com/feed",
                    category: cat
                ))
            }
        }
        items.shuffle()

        let result = Reservoir.interleaveOffMain(
            items, readItemIDs: [], surfacedTimestamps: [:], sourceRegionMap: [:]
        )

        let (srcV, catV) = measureViolations(result, log: log)
        log.info("  Source violations:  \(srcV.count)/\(result.count) (\(String(format: "%.1f", srcV.rate))%)")
        log.info("  Category violations: \(catV.count)/\(result.count) (\(String(format: "%.1f", catV.rate))%)")
        log.info("  Worst source gap: \(srcV.worstGap) cards, Worst category gap: \(catV.worstGap) cards")
    }

    // MARK: - Scenario 2: Prolific sources (power-law distribution)

    func test_diag_powerLawDistribution() {
        let log = Self.v
        log.info("=== DIAG: Power-law distribution ===")
        log.info("  5 prolific sources (60 items each) + 45 normal sources (4 each)")

        let categories = ["Tech", "Sports", "Politics", "Science", "Arts",
                          "Health", "Business", "Entertainment", "Travel", "Education"]
        var items: [FeedItem] = []

        // 5 prolific sources (simulating CNN, BBC, etc.)
        for s in 0..<5 {
            let cat = categories[s]
            for i in 0..<60 {
                items.append(item(
                    title: "PROLIFIC-\(s)-\(i): \(cat) headline",
                    sourceURL: "https://big-source\(s).com/feed",
                    category: cat
                ))
            }
        }

        // 45 normal sources
        for s in 5..<50 {
            let cat = categories[s % categories.count]
            for i in 0..<4 {
                items.append(item(
                    title: "Normal-\(s)-\(i): \(cat) story",
                    sourceURL: "https://small-source\(s).com/feed",
                    category: cat
                ))
            }
        }

        items.shuffle()

        let result = Reservoir.interleaveOffMain(
            items, readItemIDs: [], surfacedTimestamps: [:], sourceRegionMap: [:]
        )

        let (srcV, catV) = measureViolations(result, log: log)
        log.info("  Source violations:  \(srcV.count)/\(result.count) (\(String(format: "%.1f", srcV.rate))%)")
        log.info("  Category violations: \(catV.count)/\(result.count) (\(String(format: "%.1f", catV.rate))%)")
        log.info("  Worst source gap: \(srcV.worstGap), Worst category gap: \(catV.worstGap)")

        // Check small sources: are they getting drowned by prolific ones?
        let smallSourceURLs = Set((5..<50).map { "https://small-source\($0).com/feed" })
        let first100 = Array(result.prefix(100))
        let smallInFirst100 = first100.filter { smallSourceURLs.contains($0.sourceURL) }.count
        log.info("  Small sources in first 100: \(smallInFirst100)/100")
        let uniqueSmall = Set(first100.filter { smallSourceURLs.contains($0.sourceURL) }.map(\.sourceURL)).count
        log.info("  Unique small sources in first 100: \(uniqueSmall)/45")
    }

    // MARK: - Scenario 3: Extreme — 1 prolific, 99 small

    func test_diag_oneProlificSource() {
        let log = Self.v
        log.info("=== DIAG: One dominant source ===")
        log.info("  1 source with 200 items + 99 sources with 3 items each")

        let categories = ["Tech", "Sports", "Politics", "Science", "Arts",
                          "Health", "Business", "Entertainment", "Travel", "Education"]
        var items: [FeedItem] = []

        // One massive source
        for i in 0..<200 {
            items.append(item(
                title: "DOMINANT-\(i): Tech news",
                sourceURL: "https://dominant-source.com/feed",
                category: "Tech"
            ))
        }

        // 99 small sources
        for s in 1..<100 {
            let cat = categories[s % categories.count]
            for i in 0..<3 {
                items.append(item(
                    title: "Small-\(s)-\(i): \(cat)",
                    sourceURL: "https://tiny\(s).com/feed",
                    category: cat
                ))
            }
        }

        items.shuffle()

        let result = Reservoir.interleaveOffMain(
            items, readItemIDs: [], surfacedTimestamps: [:], sourceRegionMap: [:]
        )

        let (srcV, catV) = measureViolations(result, log: log)
        log.info("  Source violations:  \(srcV.count)/\(result.count) (\(String(format: "%.1f", srcV.rate))%)")
        log.info("  Category violations: \(catV.count)/\(result.count) (\(String(format: "%.1f", catV.rate))%)")
        log.info("  Worst source gap: \(srcV.worstGap), Worst category gap: \(catV.worstGap)")

        // How dominant is the big source in the first page?
        let first20 = Array(result.prefix(20))
        let dominantInFirst20 = first20.filter { $0.sourceURL == "https://dominant-source.com/feed" }.count
        log.info("  Dominant source in first 20: \(dominantInFirst20)/20")
    }

    // MARK: - Scenario 4: Category clustering (many sources, few categories)

    func test_diag_fewCategories() {
        let log = Self.v
        log.info("=== DIAG: Few categories (3) ===")
        log.info("  60 sources across only 3 categories")

        let categories = ["Tech", "Sports", "Politics"]
        var items: [FeedItem] = []
        for s in 0..<60 {
            let cat = categories[s % 3]
            for i in 0..<8 {
                items.append(item(
                    title: "S\(s)-\(i): \(cat)",
                    sourceURL: "https://source\(s).com/feed",
                    category: cat
                ))
            }
        }
        items.shuffle()

        let result = Reservoir.interleaveOffMain(
            items, readItemIDs: [], surfacedTimestamps: [:], sourceRegionMap: [:]
        )

        let (srcV, catV) = measureViolations(result, log: log)
        log.info("  Source violations:  \(srcV.count)/\(result.count) (\(String(format: "%.1f", srcV.rate))%)")
        log.info("  Category violations: \(catV.count)/\(result.count) (\(String(format: "%.1f", catV.rate))%)")
        log.info("  Worst source gap: \(srcV.worstGap), Worst category gap: \(catV.worstGap)")
    }

    // MARK: - Scenario 5: Realistic feedmine distribution

    func test_diag_realisticDistribution() {
        let log = Self.v
        log.info("=== DIAG: Realistic Feedmine distribution ===")

        // Simulates actual feedmine source distribution:
        // ~800 sources, most with 1-5 items, a few with 20-50
        let categories = ["News", "Tech", "Sports", "Politics", "Science",
                          "Health", "Business", "Entertainment", "Arts", "Education",
                          "Travel", "Food", "Music", "Gaming", "Fashion"]
        let regions = ["global", "countries/brazil", "countries/usa", "countries/uk",
                        "countries/france", "countries/japan", "countries/india",
                        "countries/germany", "countries/mexico", "global"]
        var items: [FeedItem] = []

        // 10 prolific sources (YouTube channels, major news)
        for s in 0..<10 {
            let cat = categories[s]
            let count = [45, 38, 35, 30, 28, 25, 22, 20, 18, 15][s]
            for i in 0..<count {
                items.append(item(
                    title: "Big-\(s)-\(i): \(cat) headline",
                    sourceURL: "https://big\(s).com/feed",
                    category: cat,
                    region: regions[s % regions.count]
                ))
            }
        }

        // 40 medium sources
        for s in 10..<50 {
            let cat = categories[s % categories.count]
            let count = [8, 7, 6, 5, 5, 4, 4, 3, 3, 2][s % 10]
            for i in 0..<count {
                items.append(item(
                    title: "Med-\(s)-\(i): \(cat)",
                    sourceURL: "https://med\(s).com/feed",
                    category: cat,
                    region: regions[s % regions.count]
                ))
            }
        }

        // 200 small sources (1-2 items each)
        for s in 50..<250 {
            let cat = categories[s % categories.count]
            let count = s % 3 == 0 ? 2 : 1
            for i in 0..<count {
                items.append(item(
                    title: "Small-\(s)-\(i): \(cat) brief",
                    sourceURL: "https://small\(s).com/feed",
                    category: cat,
                    region: regions[s % regions.count]
                ))
            }
        }

        items.shuffle()
        log.info("  Input: \(items.count) items from \(Set(items.map(\.sourceURL)).count) sources")

        var regionMap: [String: String] = [:]
        for item in items { regionMap[item.sourceURL] = item.region }

        let result = Reservoir.interleaveOffMain(
            items, readItemIDs: [], surfacedTimestamps: [:], sourceRegionMap: regionMap
        )

        let (srcV, catV) = measureViolations(result, log: log)
        log.info("  Source violations:  \(srcV.count)/\(result.count) (\(String(format: "%.1f", srcV.rate))%)")
        log.info("  Category violations: \(catV.count)/\(result.count) (\(String(format: "%.1f", catV.rate))%)")
        log.info("  Worst source gap: \(srcV.worstGap), Worst category gap: \(catV.worstGap)")

        // Page 1 analysis
        let page1 = Array(result.prefix(20))
        let page1Sources = Set(page1.map(\.sourceURL)).count
        let page1Cats = Set(page1.map(\.category)).count
        log.info("  Page 1: \(page1Sources) sources, \(page1Cats) categories")
    }

    // MARK: - Scenario 6: With surfaced timestamps (partially consumed feed)

    func test_diag_withSurfacedItems() {
        let log = Self.v
        log.info("=== DIAG: Partially consumed feed ===")
        log.info("  30% of items already surfaced by user")

        let categories = ["Tech", "Sports", "Politics", "Science", "Arts",
                          "Health", "Business", "Entertainment", "Travel", "Education"]
        var items: [FeedItem] = []
        for s in 0..<30 {
            let cat = categories[s % categories.count]
            for i in 0..<10 {
                items.append(item(
                    title: "S\(s)-\(i): \(cat)",
                    sourceURL: "https://source\(s).com/feed",
                    category: cat
                ))
            }
        }
        items.shuffle()

        // Mark first 30% as surfaced
        var surfaced: [String: Date] = [:]
        let surfacedCount = items.count * 30 / 100
        for item in items.prefix(surfacedCount) {
            surfaced[item.id] = Date()
        }

        let result = Reservoir.interleaveOffMain(
            items, readItemIDs: [], surfacedTimestamps: surfaced, sourceRegionMap: [:]
        )

        let (srcV, catV) = measureViolations(result, log: log)
        log.info("  Source violations:  \(srcV.count)/\(result.count) (\(String(format: "%.1f", srcV.rate))%)")
        log.info("  Category violations: \(catV.count)/\(result.count) (\(String(format: "%.1f", catV.rate))%)")

        // Are surfaced items actually pushed back?
        let surfacedIDs = Set(surfaced.keys)
        let first50 = Array(result.prefix(50))
        let surfacedInFirst50 = first50.filter { surfacedIDs.contains($0.id) }.count
        log.info("  Surfaced items in first 50: \(surfacedInFirst50)/50")
    }

    // MARK: - Aggregate report

    func test_diag_aggregateReport() {
        let log = Self.v
        log.info("==============================================")
        log.info("  CONTENT VARIETY DIAGNOSTIC REPORT")
        log.info("  Rule: ≤1 repeat per source/category within 10-card window")
        log.info("==============================================")
        // Individual scenarios log their own metrics above.
        // This test ensures the battery completes.
        log.info("  All scenarios executed. Check logs above for metrics.")
        log.info("==============================================")
    }

    // MARK: - Measurement engine

    private struct ViolationReport {
        let count: Int
        let rate: Double
        let worstGap: Int
    }

    private func measureViolations(
        _ items: [FeedItem],
        log: Logger
    ) -> (source: ViolationReport, category: ViolationReport) {
        let window = Self.violationWindow
        var sourceViolations = 0
        var categoryViolations = 0
        var worstSourceGap = 0
        var worstCategoryGap = 0

        for i in 0..<items.count {
            let limit = min(i + window, items.count)
            let currentSource = items[i].sourceURL
            let currentCategory = items[i].category

            var srcDist = Int.max
            var catDist = Int.max

            for j in (i + 1)..<limit {
                if items[j].sourceURL == currentSource { srcDist = min(srcDist, j - i) }
                if items[j].category == currentCategory { catDist = min(catDist, j - i) }
            }

            if srcDist <= window { sourceViolations += 1; worstSourceGap = max(worstSourceGap, srcDist) }
            if catDist <= window { categoryViolations += 1; worstCategoryGap = max(worstCategoryGap, catDist) }
        }

        let total = Double(max(items.count, 1))

        return (
            source: ViolationReport(
                count: sourceViolations,
                rate: Double(sourceViolations) / total * 100,
                worstGap: sourceViolations > 0 ? worstSourceGap : window + 1
            ),
            category: ViolationReport(
                count: categoryViolations,
                rate: Double(categoryViolations) / total * 100,
                worstGap: categoryViolations > 0 ? worstCategoryGap : window + 1
            )
        )
    }

    // MARK: - Helpers

    private func item(
        title: String,
        sourceURL: String = "https://example.com/feed",
        category: String = "Tech",
        region: String = "global",
        publishedAt: Date = Date()
    ) -> FeedItem {
        FeedItem(
            id: UUID().uuidString,
            sourceTitle: "Source",
            sourceURL: sourceURL,
            category: category,
            title: title,
            excerpt: title,
            url: sourceURL + "/item",
            imageURL: nil,
            publishedAt: publishedAt,
            audioURL: nil,
            duration: nil,
            region: region,
            language: nil
        )
    }
}
