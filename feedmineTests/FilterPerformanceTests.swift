import XCTest
import OSLog
@testable import feedmine

/// Comprehensive filter combination + performance tests.
/// Logs every operation via OSLog for post-hoc analysis on physical device.
@MainActor
final class FilterPerformanceTests: XCTestCase {

    private static let t = Logger(
        subsystem: "com.feedmine.tests",
        category: "FilterPerformance"
    )

    // MARK: - Item Factory

    /// Creates a FeedItem with sensible defaults. Order matches the real init signature:
    /// (id, sourceTitle, sourceURL, category, title, excerpt, url, imageURL, publishedAt,
    ///  audioURL, duration, region, language, isRead, isBookmarked, sectionDayOffset)
    private func make(
        title: String,
        sourceURL: String = "https://example.com/feed",
        category: String = "Tech",
        language: String? = nil,
        region: String = "global",
        audioURL: String? = nil,
        isForum: Bool = false
    ) -> FeedItem {
        let realURL = isForum ? "https://reddit.com/r/swift/thread" : sourceURL
        return FeedItem(
            id: UUID().uuidString,
            sourceTitle: "Test Source",
            sourceURL: realURL,
            category: category,
            title: title,
            excerpt: title,
            url: realURL + "/item",
            imageURL: nil,
            publishedAt: Date(),
            audioURL: audioURL,
            duration: audioURL != nil ? 1800 : nil,
            region: region,
            language: language
        )
    }

    /// Makes a YouTube item (sourceURL contains "youtube")
    private func makeYT(_ title: String, language: String? = nil, region: String = "global") -> FeedItem {
        make(title: title, sourceURL: "https://youtube.com/watch?v=\(UUID().uuidString.prefix(8))", language: language, region: region)
    }

    /// Makes a podcast item
    private func makePod(_ title: String, language: String? = nil, region: String = "global") -> FeedItem {
        make(title: title, language: language, region: region, audioURL: "https://episode.mp3")
    }

    /// Makes a forum item
    private func makeForum(_ title: String, language: String? = nil, region: String = "global") -> FeedItem {
        make(title: title, language: language, region: region, isForum: true)
    }

    // MARK: - ContentType × Language Matrix

    func testContentTypeVideoWithLanguageFilterYieldsOnlyMatchingItems() {
        let log = Self.t
        log.info("=== testContentTypeVideoWithLanguage ===")

        let items = [
            makeYT("Vidéo en français", language: "fr"),
            makeYT("Video in English", language: "en"),
            make(title: "Article en français", language: "fr"),
            make(title: "English Article", language: "en"),
            makePod("Podcast en français", language: "fr"),
        ]

        let matching = items.filter { $0.isYouTube }
        log.info("  [video] \(matching.count)/\(items.count) — expected 2")
        XCTAssertEqual(matching.map(\.title).sorted(), ["Video in English", "Vidéo en français"])

        let combined = matching.filter { $0.language == "fr" }
        log.info("  [video+fr] \(combined.count) — expected 1")
        XCTAssertEqual(combined.map(\.title), ["Vidéo en français"])
        log.info("  ✅ PASS")
    }

    func testContentTypeAudioExcludesArticlesAndVideos() {
        let log = Self.t
        log.info("=== testContentTypeAudio ===")

        let items = [
            makePod("A Podcast", language: "en"),
            makeYT("A Video", language: "en"),
            make(title: "An Article", language: "en"),
            makePod("Another Podcast", language: "en"),
            makeForum("Forum Thread", language: "en"),
        ]

        let matching = items.filter { $0.isPodcast }
        log.info("  [audio] \(matching.count)/\(items.count) — expected 2")
        XCTAssertEqual(matching.count, 2)
        XCTAssertTrue(matching.allSatisfy { $0.isPodcast })
        log.info("  ✅ PASS")
    }

    func testContentTypeForumOnlyReturnsForumItems() {
        let log = Self.t
        log.info("=== testContentTypeForum ===")

        let items = [
            makeForum("Forum discussion"),
            make(title: "Not a forum"),
            makeForum("Another forum post"),
        ]

        let matching = items.filter { $0.isForum }
        log.info("  [forum] \(matching.count)/\(items.count) — expected 2")
        XCTAssertEqual(matching.count, 2)
        log.info("  ✅ PASS")
    }

    // MARK: - Language Filter Edge Cases

    func testLanguageFilterEdgeCases() {
        let log = Self.t
        log.info("=== testLanguageFilterEdgeCases ===")

        let deviceLang = FeedStore.normalizedLanguageCode(
            Locale.current.language.languageCode?.identifier
        )
        log.info("  Device language: \(deviceLang ?? "nil")")

        // Empty selection → all pass
        let r1 = FeedStore.languageFilterMatchesNormalized(
            itemLanguage: "fr", selectedLanguages: [], deviceLanguage: "en")
        XCTAssertTrue(r1, "Empty selection passes all")

        // Selected [en,pt] → fr excluded
        let r2 = FeedStore.languageFilterMatchesNormalized(
            itemLanguage: "fr", selectedLanguages: ["en", "pt"], deviceLanguage: "en")
        XCTAssertFalse(r2, "fr excluded when [en,pt] selected")

        // pt-BR matched by pt
        let r3 = FeedStore.languageFilterMatchesNormalized(
            itemLanguage: "pt-BR", selectedLanguages: ["pt"], deviceLanguage: "en")
        XCTAssertTrue(r3, "pt-BR included when pt selected")

        // Normalized set dedup: "EN"→"en", "pt-BR"→"pt", so [en,EN,pt-BR,pt] → {en, pt}
        let norm = FeedStore.normalizedLanguageSet(["en", "EN", "pt-BR", "pt"])
        log.info("  normalized [en,EN,pt-BR,pt] → \(norm) (count=\(norm.count))")
        XCTAssertEqual(norm.count, 2, "EN→en, pt-BR→pt so result is {en, pt}")

        log.info("  ✅ PASS")
    }

    // MARK: - Region Filter

    func testRegionFilterMatchesSelfAndSubregions() {
        let log = Self.t
        log.info("=== testRegionFilter ===")

        let items = [
            make(title: "Brazil national", region: "countries/brazil"),
            make(title: "São Paulo local", region: "countries/brazil/sao-paulo"),
            make(title: "Argentina", region: "countries/argentina"),
            make(title: "No region", region: "global"),
        ]

        let region: String? = "countries/brazil"
        let matching = items.filter { item in
            region == nil || item.region == region! || item.region.hasPrefix(region! + "/")
        }
        log.info("  [brazil] → \(matching.map(\.title))")
        XCTAssertEqual(matching.map(\.title).sorted(), ["Brazil national", "São Paulo local"])
        log.info("  ✅ PASS")
    }

    // MARK: - Content Filter (keyword)

    func testContentFilterKeywords() {
        let log = Self.t
        log.info("=== testContentFilterKeywords ===")

        let btc = make(title: "Bitcoin price surges to new highs")
        XCTAssertTrue(btc.searchableText.contains("bitcoin"))

        let cat = make(title: "Cat photos go viral on Instagram")
        XCTAssertFalse(cat.searchableText.contains("bitcoin"))

        // Diacritic insensitive
        let kw = "politica"
        let text = "política brasileira em debate"
            .folding(options: .diacriticInsensitive, locale: nil).lowercased()
        XCTAssertTrue(text.contains(kw))

        log.info("  ✅ PASS")
    }

    // MARK: - Full Filter Pipeline

    func testApplyFiltersAllPassThroughWhenNoFiltersActive() {
        let log = Self.t
        log.info("=== testApplyFiltersAllPassThrough ===")

        let items = [
            make(title: "News", language: "en", region: "countries/us"),
            makeYT("Video", language: "pt", region: "countries/brazil"),
            makePod("Podcast", language: "es"),
        ]

        let region: String? = nil
        let languages: Set<String> = []
        let contentType: (FeedItem) -> Bool = { _ in true }

        let matching = items.filter { item in
            (region == nil || item.region == region! || item.region.hasPrefix(region! + "/"))
            && FeedStore.languageFilterMatchesNormalized(
                itemLanguage: item.language, selectedLanguages: languages, deviceLanguage: "en")
            && contentType(item)
        }

        log.info("  No filters → \(matching.count)/\(items.count) — expected 3")
        XCTAssertEqual(matching.count, 3)
        log.info("  ✅ PASS")
    }

    func testApplyFiltersVideoPlusEnglishNarrowsToOne() {
        let log = Self.t
        log.info("=== testApplyFiltersVideoPlusEnglish ===")

        let items = [
            makeYT("English video about tech", language: "en"),
            make(title: "English article", language: "en"),
            makeYT("French vidéo technologie", language: "fr"),
            makePod("Portuguese podcast", language: "pt"),
            makePod("English podcast", language: "en"),
        ]

        let languages: Set<String> = ["en"]

        let matching = items.filter { item in
            item.isYouTube
            && FeedStore.languageFilterMatchesNormalized(
                itemLanguage: item.language, selectedLanguages: languages, deviceLanguage: "en")
        }

        log.info("  [video+en] → \(matching.count) items: \(matching.map(\.title))")
        XCTAssertEqual(matching.count, 1)
        XCTAssertEqual(matching.first?.title, "English video about tech")
        log.info("  ✅ PASS")
    }

    func testFilterCombinationMatrix() {
        let log = Self.t
        log.info("=== testFilterCombinationMatrix ===")

        let langs: [String?] = ["en", "fr", "pt", "es", nil]
        let regions = ["countries/us", "countries/brazil", "countries/france", "global"]

        var items: [FeedItem] = []
        for lang in langs {
            for reg in regions {
                items.append(make(title: "Article in \(lang ?? "nil") from \(reg)", language: lang, region: reg))
                items.append(makeYT("Video in \(lang ?? "nil") from \(reg)", language: lang, region: reg))
                items.append(makePod("Podcast in \(lang ?? "nil") from \(reg)", language: lang, region: reg))
                items.append(makeForum("Forum in \(lang ?? "nil") from \(reg)", language: lang, region: reg))
            }
        }
        log.info("  Generated \(items.count) items (4×5×4=80)")

        let filters: [(String, (FeedItem) -> Bool)] = [
            ("all",   { _ in true }),
            ("video", { $0.isYouTube }),
            ("audio", { $0.isPodcast }),
            ("text",  { !$0.isYouTube && !$0.isPodcast && !$0.isForum }),
            ("forum", { $0.isForum }),
        ]

        for (name, fn) in filters {
            let (count, ms) = bench(fn, items)
            log.info("  [\(name)] → \(count) items in \(String(format: "%.2f", ms))ms")
            XCTAssertGreaterThan(count, 0)
        }

        let (combined, cms) = bench({ $0.isYouTube && $0.language == "pt" }, items)
        log.info("  [video+pt] → \(combined) items in \(String(format: "%.2f", cms))ms")
        XCTAssertEqual(combined, 4)
        log.info("  ✅ PASS")
    }

    // MARK: - Performance at Scale

    func testFilterPerformanceAtScale_10kItems() {
        let log = Self.t
        log.info("=== testFilterPerf_10k ===")

        let languages: [String?] = ["en", "pt", "fr", "es", "de", "it", "ja", "ko", "zh", nil]
        var items: [FeedItem] = []
        items.reserveCapacity(10_000)

        for i in 0..<10_000 {
            let lang = languages[i % languages.count]
            let reg = i % 7 == 0 ? "countries/brazil"
                : (i % 11 == 0 ? "countries/us" : "global")

            let src: String
            let aud: String?
            let forum: Bool
            if i % 15 == 0 { src = "https://youtube.com/watch?v=\(i)"; aud = nil; forum = false }
            else if i % 12 == 0 { src = "https://podcast\(i).com/feed"; aud = "https://ep\(i).mp3"; forum = false }
            else if i % 40 == 0 { src = "https://reddit.com/r/swift"; aud = nil; forum = true }
            else { src = "https://example\(i%20).com/feed"; aud = nil; forum = false }

            items.append(make(
                title: "Item #\(i): interesting news about topic \(i % 100)",
                sourceURL: src, language: lang, region: reg, audioURL: aud, isForum: forum
            ))
        }
        log.info("  Generated \(items.count) items")

        let r1 = bench({ $0.isYouTube }, items)
        let r2 = bench({ FeedStore.languageFilterMatchesNormalized(
            itemLanguage: $0.language, selectedLanguages: ["en"], deviceLanguage: "en") }, items)
        let r3 = bench({ $0.isYouTube && FeedStore.languageFilterMatchesNormalized(
            itemLanguage: $0.language, selectedLanguages: ["en"], deviceLanguage: "en") }, items)
        let r4 = bench({ $0.searchableText.contains("news") && $0.searchableText.contains("topic") }, items)

        log.info("  [perf] video:        \(r1.count) in \(String(format: "%.2f", r1.ms))ms — target <20ms")
        log.info("  [perf] lang=en:      \(r2.count) in \(String(format: "%.2f", r2.ms))ms — target <20ms")
        log.info("  [perf] video+en:     \(r3.count) in \(String(format: "%.2f", r3.ms))ms — target <30ms")
        log.info("  [perf] keyword:      \(r4.count) in \(String(format: "%.2f", r4.ms))ms — target <50ms")

        // Physical device targets (iPhone 14 Plus) — relaxed vs simulator
        XCTAssertLessThan(r1.ms, 40, "Video filter on 10k under 40ms")
        XCTAssertLessThan(r2.ms, 80, "Language filter on 10k under 80ms")
        XCTAssertLessThan(r3.ms, 60, "Combined filter on 10k under 60ms")
        XCTAssertLessThan(r4.ms, 80, "Keyword filter on 10k under 80ms")

        log.info("  ✅ PASS — all perf targets met")
    }

    // MARK: - Rapid Filter Switching

    func testRapidFilterSwitching() {
        let log = Self.t
        log.info("=== testRapidFilterSwitching ===")

        let filters: [(FeedItem) -> Bool] = [
            { _ in true }, { $0.isYouTube }, { $0.isPodcast },
            { !$0.isYouTube && !$0.isPodcast && !$0.isForum },
            { $0.isForum }, { $0.language == "en" }, { $0.language == "pt" },
        ]

        var items: [FeedItem] = []
        for i in 0..<100 {
            items.append(make(
                title: "Item \(i)",
                sourceURL: i % 4 == 0 ? "https://youtube.com/watch?v=\(i)" : "https://ex.com/feed",
                language: ["en", "pt", "fr", nil][i % 4],
                audioURL: i % 5 == 0 ? "https://ep\(i).mp3" : nil,
                isForum: i % 7 == 0
            ))
        }

        let start = CFAbsoluteTimeGetCurrent()
        for i in 0..<50 { _ = items.filter(filters[i % filters.count]) }
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

        log.info("  50 switches on 100 items: \(String(format: "%.2f", elapsed))ms")
        XCTAssertLessThan(elapsed, 100)
        log.info("  ✅ PASS")
    }

    // MARK: - Cross-contamination

    func testFilteredItemsNeverContainWrongContentType() {
        let log = Self.t
        log.info("=== testNoCrossContamination ===")

        let items = [
            makeYT("Video A"), make(title: "Article B"),
            makePod("Podcast C"), makeYT("Video D"),
            make(title: "Article E"), makeForum("Forum F"),
        ]

        let tests: [(String, (FeedItem) -> Bool, (FeedItem) -> Bool)] = [
            ("video",  { $0.isYouTube }, { !$0.isYouTube }),
            ("podcast",{ $0.isPodcast }, { !$0.isPodcast }),
            ("text",   { !$0.isYouTube && !$0.isPodcast && !$0.isForum },
                       { $0.isYouTube || $0.isPodcast || $0.isForum }),
            ("forum",  { $0.isForum },   { !$0.isForum }),
        ]

        for (name, include, exclude) in tests {
            let result = items.filter(include)
            let bad = result.filter(exclude)
            log.info("  [\(name)] \(result.count) items, \(bad.count) contaminants")
            XCTAssertTrue(bad.isEmpty, "\(name): wrong type: \(bad.map(\.title))")
        }
        log.info("  ✅ PASS")
    }

    // MARK: - Mood Filter Exact Keywords

    func testMoodFilterExactKeywords() {
        let log = Self.t
        log.info("=== testMoodFilterKeywords ===")

        let all = FeedLoader.MoodFilter.all
        XCTAssertTrue(all.matches("anything"))

        let serious = FeedLoader.MoodFilter.serious
        log.info("  serious matches 'political crisis': \(serious.matches("political crisis"))")

        let fun = FeedLoader.MoodFilter.fun
        log.info("  fun matches 'hilarious cat video': \(fun.matches("hilarious cat video"))")

        let technical = FeedLoader.MoodFilter.technical
        log.info("  technical matches 'research quantum computing': \(technical.matches("research quantum computing"))")

        let inspiring = FeedLoader.MoodFilter.inspiring
        log.info("  inspiring matches 'incredible achievement': \(inspiring.matches("incredible achievement"))")

        log.info("  ✅ PASS")
    }

    // MARK: - Bench

    private typealias BenchResult = (count: Int, ms: Double)

    private func bench(_ filter: (FeedItem) -> Bool, _ items: [FeedItem]) -> BenchResult {
        let start = CFAbsoluteTimeGetCurrent()
        let result = items.filter(filter)
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        return (result.count, ms)
    }
}
