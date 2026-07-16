import XCTest
@testable import feedmine

@MainActor
final class FeedStoreTests: XCTestCase {

    override func tearDown() async throws {
        // Reset TaxonomyStore singleton between tests to avoid state leakage
        TaxonomyStore.shared.clearSelection()
        try await super.tearDown()
    }

    func testV7MigrationAddsLanguageColumn() throws {
        let store = try FeedStore(inMemory: true)
        try store.db.write { db in
            // Verify column exists by inserting a row with language
            try db.execute(sql: """
                INSERT INTO feed_item (id, source_url, source_title, region, category,
                                       title, excerpt, url, published_at, fetched_at, language)
                VALUES ('test-id', 'https://example.com/feed', 'Test', 'global', 'News',
                        'Title', 'Excerpt', 'https://example.com', 0, 0, 'en')
            """)
            let lang: String? = try String.fetchOne(db, sql: "SELECT language FROM feed_item WHERE id = 'test-id'")
            XCTAssertEqual(lang, "en")
        }
    }

    func testReloadFromSQLiteFiltersByTaxonomySourceURL() async throws {
        let store = try FeedStore(inMemory: true)

        // Seed sources and taxonomy
        let source = FeedSource(title: "Coffee Blog", url: "https://coffee.com/feed",
                                category: "Coffee", region: "global")
        store.registry.sources = [source]
        await TaxonomyStore.shared.build(from: [source])

        // Find the taxonomy node for our source
        let nodeID = try XCTUnwrap(TaxonomyStore.shared.nodeID(for: "https://coffee.com/feed"))

        // Insert test items before triggering reload:
        // one item matching the taxonomy node, one that does not
        let matchingItem = FeedItemRecord(
            from: FeedItem(id: "match", sourceTitle: "S", sourceURL: "https://coffee.com/feed",
                           category: "Coffee", title: "Match", excerpt: "E",
                           url: "https://coffee.com/1", imageURL: nil, publishedAt: Date(),
                           audioURL: nil, duration: nil, region: "global"),
            region: "global"
        )
        let nonMatchingItem = FeedItemRecord(
            from: FeedItem(id: "nomatch", sourceTitle: "S", sourceURL: "https://other.com/feed",
                           category: "Other", title: "No Match", excerpt: "E",
                           url: "https://other.com/1", imageURL: nil, publishedAt: Date(),
                           audioURL: nil, duration: nil, region: "global"),
            region: "global"
        )
        try await store.db.write { db in
            try matchingItem.insert(db)
            try nonMatchingItem.insert(db)
        }

        // Trigger reload via setFilter — this computes cachedTaxonomyFeedURLs
        // internally and then flushes the pipeline after a 300ms debounce.
        store.setFilter(region: nil, nodeIDs: [nodeID], type: .all, mood: .all, languages: [])

        // Poll for result with timeout instead of a fixed sleep (avoids CI flakiness).
        let deadline = Date().addingTimeInterval(5)
        while store.visibleItems.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        // Verify only matching item appears
        XCTAssertEqual(store.visibleItems.count, 1)
        XCTAssertEqual(store.visibleItems.first?.sourceURL, "https://coffee.com/feed")
    }

    // MARK: - Language Filter (shared rule)

    func testLanguageFilterNilPassesWhenDeviceLanguageSelected() {
        // nil language + English selected + device = English → pass
        let result = FeedStore.languageFilterMatches(
            itemLanguage: nil,
            selectedLanguages: ["en", "pt"],
            deviceLanguage: "en"
        )
        XCTAssertTrue(result, "nil-language item should pass when device language (en) is selected")
    }

    func testLanguageFilterNilBlockedWhenDeviceLanguageNotSelected() {
        // nil language + Japanese selected + device = English → block
        let result = FeedStore.languageFilterMatches(
            itemLanguage: nil,
            selectedLanguages: ["ja"],
            deviceLanguage: "en"
        )
        XCTAssertFalse(result, "nil-language item must not pass when device language (en) is NOT among selected (ja)")
    }

    func testLanguageFilterKnownLanguagePasses() {
        // ja + Japanese selected → pass
        let result = FeedStore.languageFilterMatches(
            itemLanguage: "ja",
            selectedLanguages: ["ja"],
            deviceLanguage: "en"
        )
        XCTAssertTrue(result)
    }

    func testLanguageFilterKnownLanguageBlocked() {
        // en + Japanese selected → block
        let result = FeedStore.languageFilterMatches(
            itemLanguage: "en",
            selectedLanguages: ["ja"],
            deviceLanguage: "pt"
        )
        XCTAssertFalse(result)
    }

    func testLanguageFilterEmptySelectionPassesAll() {
        // No selection → all pass (nil, known, any device language)
        XCTAssertTrue(FeedStore.languageFilterMatches(itemLanguage: nil, selectedLanguages: [], deviceLanguage: "en"))
        XCTAssertTrue(FeedStore.languageFilterMatches(itemLanguage: "ja", selectedLanguages: [], deviceLanguage: "en"))
        XCTAssertTrue(FeedStore.languageFilterMatches(itemLanguage: "pt", selectedLanguages: [], deviceLanguage: nil))
    }

    // MARK: - Language persistence: memory ↔ SQLite consistency

    func testPersistDetectedLanguageReturnsEnrichedItem() async throws {
        let store = try FeedStore(inMemory: true)

        // Register a source WITHOUT explicit language — detection must fill it
        let source = FeedSource(title: "Asahi Shimbun", url: "https://asahi.com/feed",
                                category: "News", region: "countries/japan", language: nil)
        store.registry.sources = [source]

        // Item with clearly Japanese title/excerpt, no language from the source
        let item = FeedItem(
            id: "ja-item-1", sourceTitle: "Asahi Shimbun",
            sourceURL: "https://asahi.com/feed",
            category: "News",
            title: "日本の首相が記者会見を開き新たな経済政策を発表しました",
            excerpt: "本日午前、首相官邸で記者会見が行われ、新しい経済政策について詳細が明らかになりました。",
            url: "https://asahi.com/article/1", imageURL: nil,
            publishedAt: Date(),
            region: "countries/japan",
            language: nil  // explicitly nil — detection must fill this
        )

        let result = await store.persistFetchedItems([item])

        // 1. The returned item must carry the detected language
        let returned: FeedItem = try XCTUnwrap(result.first)
        XCTAssertEqual(returned.language, "ja",
                       "persistFetchedItems must return an enriched FeedItem with detected language")

        // 2. The SQLite record must also have the same language
        let dbLanguage: String? = try await store.db.read { db in
            try String.fetchOne(db, sql: "SELECT language FROM feed_item WHERE id = ?", arguments: [item.id])
        }
        XCTAssertEqual(dbLanguage, "ja",
                       "SQLite record must contain the same detected language as the returned item")

        // 3. Both representations produce identical results in the language filter
        let japaneseSelected: Set<String> = ["ja"]
        let englishDevice = "en"
        XCTAssertTrue(FeedStore.languageFilterMatches(itemLanguage: returned.language, selectedLanguages: japaneseSelected, deviceLanguage: englishDevice),
                      "Enriched item (ja) must pass Japanese filter")
        XCTAssertTrue(FeedStore.languageFilterMatches(itemLanguage: dbLanguage, selectedLanguages: japaneseSelected, deviceLanguage: englishDevice),
                      "DB record (ja) must pass Japanese filter")

        // 4. Both reject English-only selection
        let englishSelected: Set<String> = ["en"]
        XCTAssertFalse(FeedStore.languageFilterMatches(itemLanguage: returned.language, selectedLanguages: englishSelected, deviceLanguage: englishDevice),
                       "Enriched item (ja) must NOT pass English filter")
        XCTAssertFalse(FeedStore.languageFilterMatches(itemLanguage: dbLanguage, selectedLanguages: englishSelected, deviceLanguage: englishDevice),
                       "DB record (ja) must NOT pass English filter")
    }

    func testPersistPreservesItemLanguageOverDetection() async throws {
        let store = try FeedStore(inMemory: true)

        // Source has NO explicit language — detection would be needed
        let source = FeedSource(title: "Le Monde", url: "https://lemonde.fr/feed",
                                category: "News", region: "countries/france", language: nil)
        store.registry.sources = [source]

        // But the item itself already carries "fr" (set by the fetcher).
        // Short, ambiguous text that could mislead detection.
        let item = FeedItem(
            id: "fr-item-1", sourceTitle: "Le Monde",
            sourceURL: "https://lemonde.fr/feed",
            category: "News",
            title: "Édito",
            excerpt: "Bref.",
            url: "https://lemonde.fr/article/1", imageURL: nil,
            publishedAt: Date(),
            region: "countries/france",
            language: "fr"  // already known — must not be overwritten
        )

        let result = await store.persistFetchedItems([item])
        let returned: FeedItem = try XCTUnwrap(result.first)

        // The item's own language must survive, even with no registry language
        // and text too short for reliable detection
        XCTAssertEqual(returned.language, "fr",
                       "Item's own language 'fr' must be preserved when registry has none and text is short")

        let dbLanguage: String? = try await store.db.read { db in
            try String.fetchOne(db, sql: "SELECT language FROM feed_item WHERE id = ?", arguments: [item.id])
        }
        XCTAssertEqual(dbLanguage, "fr",
                       "SQLite must also store the item's own language")
    }

    func testPersistExplicitSourceLanguagePreserved() async throws {
        let store = try FeedStore(inMemory: true)

        // Register a source WITH explicit Portuguese language
        let source = FeedSource(title: "Folha", url: "https://folha.com/feed",
                                category: "News", region: "countries/brazil", language: "pt")
        store.registry.sources = [source]

        // Item where the text might be detected as something else, but the
        // explicit source language must win
        let item = FeedItem(
            id: "pt-item-1", sourceTitle: "Folha",
            sourceURL: "https://folha.com/feed",
            category: "News",
            title: "Governo anuncia novas medidas econômicas para o segundo semestre",
            excerpt: "O ministro da Fazenda apresentou hoje as projeções atualizadas para o PIB.",
            url: "https://folha.com/article/1", imageURL: nil,
            publishedAt: Date(),
            region: "countries/brazil",
            language: nil
        )

        let result = await store.persistFetchedItems([item])
        let returned: FeedItem = try XCTUnwrap(result.first)

        // Explicit source language "pt" must be preserved — not overwritten by
        // text detection (which might also return "pt", but the point is the
        // source language takes priority)
        XCTAssertEqual(returned.language, "pt",
                       "Explicit source language 'pt' must be preserved in enriched item")

        let dbLanguage: String? = try await store.db.read { db in
            try String.fetchOne(db, sql: "SELECT language FROM feed_item WHERE id = ?", arguments: [item.id])
        }
        XCTAssertEqual(dbLanguage, "pt",
                       "SQLite must also store the explicit source language")
    }
}
