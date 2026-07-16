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

    func testEmptyItemLanguageFallsBackToRegistryLanguage() async throws {
        let store = try FeedStore(inMemory: true)

        // Source has explicit "pt" language in the registry
        let source = FeedSource(title: "Folha", url: "https://folha.com/feed",
                                category: "News", region: "countries/brazil", language: "pt")
        store.registry.sources = [source]

        // Item has empty string for language — must fall back to registry "pt"
        let item = FeedItem(
            id: "empty-lang-1", sourceTitle: "Folha",
            sourceURL: "https://folha.com/feed",
            category: "News",
            title: "Breve",
            excerpt: "Nota.",
            url: "https://folha.com/article/1", imageURL: nil,
            publishedAt: Date(),
            region: "countries/brazil",
            language: ""  // empty — should fall through to registry
        )

        let result = await store.persistFetchedItems([item])
        let returned: FeedItem = try XCTUnwrap(result.first)

        XCTAssertEqual(returned.language, "pt",
                       "Empty item.language must fall back to registry language 'pt'")

        let dbLanguage: String? = try await store.db.read { db in
            try String.fetchOne(db, sql: "SELECT language FROM feed_item WHERE id = ?", arguments: [item.id])
        }
        XCTAssertEqual(dbLanguage, "pt",
                       "SQLite must store the registry language when item.language is empty")
    }

    func testWhitespaceItemLanguageFallsBackToRegistryLanguage() async throws {
        let store = try FeedStore(inMemory: true)

        let source = FeedSource(title: "Asahi", url: "https://asahi.com/feed",
                                category: "News", region: "countries/japan", language: "ja")
        store.registry.sources = [source]

        let item = FeedItem(
            id: "ws-lang-1", sourceTitle: "Asahi",
            sourceURL: "https://asahi.com/feed",
            category: "News",
            title: "短い",
            excerpt: "記事。",
            url: "https://asahi.com/article/1", imageURL: nil,
            publishedAt: Date(),
            region: "countries/japan",
            language: "   "  // whitespace-only — should fall through to registry
        )

        let result = await store.persistFetchedItems([item])
        let returned: FeedItem = try XCTUnwrap(result.first)

        XCTAssertEqual(returned.language, "ja",
                       "Whitespace-only item.language must fall back to registry language 'ja'")

        let dbLanguage: String? = try await store.db.read { db in
            try String.fetchOne(db, sql: "SELECT language FROM feed_item WHERE id = ?", arguments: [item.id])
        }
        XCTAssertEqual(dbLanguage, "ja",
                       "SQLite must store the registry language when item.language is whitespace")
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

    // MARK: - Language code normalization (BCP 47 → ISO 639-1)

    func testNormalizedLanguageCodeExtractsBaseCode() {
        XCTAssertEqual(FeedStore.normalizedLanguageCode("pt-BR"), "pt")
        XCTAssertEqual(FeedStore.normalizedLanguageCode("pt_BR"), "pt")
        XCTAssertEqual(FeedStore.normalizedLanguageCode(" EN-us "), "en")
        XCTAssertEqual(FeedStore.normalizedLanguageCode("zh-Hant"), "zh")
        XCTAssertEqual(FeedStore.normalizedLanguageCode("fr-CA"), "fr")
        XCTAssertEqual(FeedStore.normalizedLanguageCode("es-MX"), "es")
        XCTAssertNil(FeedStore.normalizedLanguageCode(""))
        XCTAssertNil(FeedStore.normalizedLanguageCode("   "))
        XCTAssertNil(FeedStore.normalizedLanguageCode(nil))
        // Already-clean codes pass through unchanged
        XCTAssertEqual(FeedStore.normalizedLanguageCode("pt"), "pt")
        XCTAssertEqual(FeedStore.normalizedLanguageCode("ja"), "ja")
    }

    func testBCP47ItemMatchesBaseCodeFilter() {
        // pt-BR vs pt → must match
        XCTAssertTrue(FeedStore.languageFilterMatches(
            itemLanguage: "pt-BR", selectedLanguages: ["pt"], deviceLanguage: "en"))
        // en-US vs en → must match
        XCTAssertTrue(FeedStore.languageFilterMatches(
            itemLanguage: "en-US", selectedLanguages: ["en"], deviceLanguage: "pt"))
        // fr-CA vs fr → must match
        XCTAssertTrue(FeedStore.languageFilterMatches(
            itemLanguage: "fr-CA", selectedLanguages: ["fr"], deviceLanguage: "en"))
    }

    func testBCP47ItemBlockedByDifferentBaseCodeFilter() {
        // pt-BR vs en → must NOT match
        XCTAssertFalse(FeedStore.languageFilterMatches(
            itemLanguage: "pt-BR", selectedLanguages: ["en"], deviceLanguage: "en"))
        // en-US vs ja → must NOT match
        XCTAssertFalse(FeedStore.languageFilterMatches(
            itemLanguage: "en-US", selectedLanguages: ["ja"], deviceLanguage: "en"))
    }

    func testBCP47PersistedAsBaseCode() async throws {
        let store = try FeedStore(inMemory: true)
        let source = FeedSource(title: "Test", url: "https://test.com/feed",
                                category: "News", region: "countries/brazil", language: "pt-BR")
        store.registry.sources = [source]

        let item = FeedItem(
            id: "bcp47-1", sourceTitle: "Test",
            sourceURL: "https://test.com/feed",
            category: "News",
            title: "Título em português do Brasil",
            excerpt: "Conteúdo do artigo com texto suficiente para detecção confiável de idioma.",
            url: "https://test.com/article/1", imageURL: nil,
            publishedAt: Date(),
            region: "countries/brazil",
            language: "pt-BR"  // BCP 47 — must be stored as "pt"
        )

        let result = await store.persistFetchedItems([item])
        let returned: FeedItem = try XCTUnwrap(result.first)

        XCTAssertEqual(returned.language, "pt",
                       "BCP 47 'pt-BR' must be normalized to 'pt' in returned item")

        let dbLanguage: String? = try await store.db.read { db in
            try String.fetchOne(db, sql: "SELECT language FROM feed_item WHERE id = ?", arguments: [item.id])
        }
        XCTAssertEqual(dbLanguage, "pt",
                       "BCP 47 'pt-BR' must be stored as 'pt' in SQLite")
    }

    // MARK: - BCP 47 normalization in selectedLanguages + deviceLanguage

    func testBCP47SelectedLanguagesNormalizedDefensively() {
        // item = "pt", selected = ["pt-BR"] → must match because both normalize to "pt"
        XCTAssertTrue(FeedStore.languageFilterMatches(
            itemLanguage: "pt",
            selectedLanguages: ["pt-BR"],
            deviceLanguage: "en-US"
        ))
    }

    func testBCP47DeviceLanguageNormalizedDefensively() {
        // nil language + selected ["en"] + device "en-GB" → must match (nil falls back to device)
        XCTAssertTrue(FeedStore.languageFilterMatches(
            itemLanguage: nil,
            selectedLanguages: ["en"],
            deviceLanguage: "en-GB"
        ))
    }

    func testNormalizedLanguageSetConvergesVariants() {
        let raw = ["pt-BR", "pt", "pt_BR", "en-US", "EN-us", "ja"]
        let normalized = FeedStore.normalizedLanguageSet(raw)
        XCTAssertEqual(normalized, ["pt", "en", "ja"])
    }

    func testLegacyBCP47SettingsNormalizedOnRestore() async throws {
        let store = try FeedStore(inMemory: true)

        // Simulate legacy persisted settings with BCP 47 codes
        UserDefaults.standard.set(["pt-BR", "en-US"], forKey: "filterLanguages")
        UserDefaults.standard.set(true, forKey: "filterAutoExpire")
        // Set a recent timestamp so auto-expire doesn't kick in
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "filterSetAt")
        // Persist neutral values for other filters
        UserDefaults.standard.set(nil, forKey: "filterRegion")
        UserDefaults.standard.set([], forKey: "filterTaxonomyNodes")
        UserDefaults.standard.set("All", forKey: "filterContentType")
        UserDefaults.standard.set("all", forKey: "filterMood")

        // Call restoreFilters directly — this is the actual code path that
        // reads legacy settings and populates activeLanguages
        store.restoreFilters()

        // activeLanguages must contain normalized base codes, not raw BCP 47
        XCTAssertEqual(store.activeLanguages, ["en", "pt"],
                       "restoreFilters must normalize legacy BCP 47 settings to ISO 639-1 base codes")

        // Clean up
        UserDefaults.standard.removeObject(forKey: "filterLanguages")
        UserDefaults.standard.removeObject(forKey: "filterAutoExpire")
        UserDefaults.standard.removeObject(forKey: "filterSetAt")
        UserDefaults.standard.removeObject(forKey: "filterRegion")
        UserDefaults.standard.removeObject(forKey: "filterTaxonomyNodes")
        UserDefaults.standard.removeObject(forKey: "filterContentType")
        UserDefaults.standard.removeObject(forKey: "filterMood")
    }

    func testSetFilterNormalizesLanguagesOnEntry() async throws {
        let store = try FeedStore(inMemory: true)

        store.setFilter(region: nil, nodeIDs: [], type: .all, mood: .all, languages: ["pt-BR", "en-US"])

        XCTAssertEqual(store.activeLanguages, ["en", "pt"],
                       "setFilter must normalize BCP 47 codes to base codes")
    }

    // MARK: - Taxonomy eligibility (category/region bypass)

    func testSourceExplicitlyDisabledFlag() {
        let registry = SourceRegistry()
        registry.sources = [
            FeedSource(title: "A", url: "https://a.com/feed", category: "Acoustics", region: "global"),
            FeedSource(title: "B", url: "https://b.com/feed", category: "Acoustics", region: "global"),
        ]
        // Disable source A individually
        registry.toggleSource("https://a.com/feed")

        XCTAssertTrue(registry.isSourceExplicitlyDisabled("https://a.com/feed"))
        XCTAssertFalse(registry.isSourceExplicitlyDisabled("https://b.com/feed"))
    }

    func testTaxonomySelectionMakesDisabledCategorySourcesEligible() async throws {
        let store = try FeedStore(inMemory: true)

        // Four sources in Acoustics, category disabled
        let sources = [
            FeedSource(title: "Sound1", url: "https://sound1.com/feed", category: "Acoustics", region: "global"),
            FeedSource(title: "Sound2", url: "https://sound2.com/feed", category: "Acoustics", region: "global"),
            FeedSource(title: "Sound3", url: "https://sound3.com/feed", category: "Acoustics", region: "global"),
            FeedSource(title: "Sound4", url: "https://sound4.com/feed", category: "Acoustics", region: "global"),
        ]
        store.registry.sources = sources
        store.registry.toggleCategory("Acoustics")  // disable entire category

        // Normally none are enabled
        XCTAssertFalse(store.registry.isSourceEnabled("https://sound1.com/feed"))
        XCTAssertFalse(store.registry.isSourceEnabled("https://sound2.com/feed"))

        // Build taxonomy tree
        await TaxonomyStore.shared.build(from: sources)
        let nodeID = try XCTUnwrap(TaxonomyStore.shared.nodeID(for: "https://sound1.com/feed"))
        let taxonomyURLs = TaxonomyStore.shared.feedURLs(inSubtreesOf: [nodeID])
        XCTAssertEqual(taxonomyURLs.count, 4)

        // Set taxonomy filter (simulates selecting Acoustics node)
        store.setFilter(region: nil, nodeIDs: [nodeID], type: .all, mood: .all, languages: [])

        // Poll for pipeline flush
        let deadline = Date().addingTimeInterval(5)
        while store.loadingState != .idle && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        // All four should now be visible as eligible (category bypassed, none individually disabled)
        // Insert test items for these sources and verify they pass filters
        let items = sources.map { src in
            FeedItem(id: FeedItem.generateID(sourceURL: src.url, guid: src.url, link: nil),
                     sourceTitle: src.title, sourceURL: src.url, category: "Acoustics",
                     title: "Test Article", excerpt: "Content.",
                     url: src.url + "/article/1", imageURL: nil,
                     publishedAt: Date(), region: "global")
        }
        let persisted = await store.persistFetchedItems(items)
        XCTAssertEqual(persisted.count, 4, "All 4 items should be persisted (taxonomy override)")

        // All 4 items from taxonomy URLs, none individually disabled → should survive applyFilters
        let filtered = persisted.filter { item in
            FeedStore.languageFilterMatches(itemLanguage: item.language, selectedLanguages: [], deviceLanguage: "en")
        }
        XCTAssertEqual(filtered.count, 4, "All 4 taxonomy items must survive filters when no individual disable")
    }

    func testTaxonomySelectionStillBlocksIndividuallyDisabledSource() async throws {
        let store = try FeedStore(inMemory: true)

        let sources = [
            FeedSource(title: "S1", url: "https://s1.com/feed", category: "Acoustics", region: "global"),
            FeedSource(title: "S2", url: "https://s2.com/feed", category: "Acoustics", region: "global"),
        ]
        store.registry.sources = sources
        // Toggle S1 off individually FIRST (category still enabled)
        store.registry.toggleSource("https://s1.com/feed")  // S1 → disabled
        // Then disable the category (S2 now blocked by category, S1 still individually off)
        store.registry.toggleCategory("Acoustics")

        await TaxonomyStore.shared.build(from: sources)
        let nodeID = try XCTUnwrap(TaxonomyStore.shared.nodeID(for: "https://s1.com/feed"))

        // Select Acoustics node
        store.setFilter(region: nil, nodeIDs: [nodeID], type: .all, mood: .all, languages: [])

        let deadline = Date().addingTimeInterval(5)
        while store.loadingState != .idle && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        // S1 individually disabled → must be blocked
        // S2 category-disabled but taxonomy overrides → must be eligible
        XCTAssertTrue(store.registry.isSourceExplicitlyDisabled("https://s1.com/feed"),
                      "S1 is individually off")
        XCTAssertFalse(store.registry.isSourceExplicitlyDisabled("https://s2.com/feed"),
                       "S2 is NOT individually off")

        let items = sources.map { src in
            FeedItem(id: FeedItem.generateID(sourceURL: src.url, guid: src.url, link: nil),
                     sourceTitle: src.title, sourceURL: src.url, category: "Acoustics",
                     title: "Test", excerpt: "Content.",
                     url: src.url + "/a/1", imageURL: nil,
                     publishedAt: Date(), region: "global")
        }
        let persisted = await store.persistFetchedItems(items)
        XCTAssertEqual(persisted.count, 2)
    }

    func testClearingTaxonomyRestoresNormalEnablement() async throws {
        let store = try FeedStore(inMemory: true)

        let sources = [
            FeedSource(title: "S1", url: "https://s1.com/feed", category: "Acoustics", region: "global"),
        ]
        store.registry.sources = sources
        store.registry.toggleCategory("Acoustics")

        XCTAssertFalse(store.registry.isSourceEnabled("https://s1.com/feed"),
                       "Category disabled → source not enabled")

        await TaxonomyStore.shared.build(from: sources)
        let nodeID = try XCTUnwrap(TaxonomyStore.shared.nodeID(for: "https://s1.com/feed"))

        // Select taxonomy → temporarily eligible
        store.setFilter(region: nil, nodeIDs: [nodeID], type: .all, mood: .all, languages: [])
        let deadline = Date().addingTimeInterval(5)
        while store.loadingState != .idle && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        // Clear filters → normal enablement restored
        store.clearAllFilters()
        while store.loadingState != .idle && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        // Source should be disabled again (category still off, no taxonomy override)
        XCTAssertFalse(store.registry.isSourceEnabled("https://s1.com/feed"),
                       "After clearing taxonomy, normal category disable must be restored")
    }
}
