import Foundation
import XCTest

@MainActor
final class FeedmineUITests: XCTestCase {

    let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = true
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-UITestResetFilters", "-UITestSkipOnboarding",
        ]
        app.launch()
    }

    func testOnboardingSeedsARealTaxonomyReadingLens() {
        app.terminate()
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-UITestResetFilters", "-UITestShowOnboarding",
        ]
        app.launch()

        let next = app.buttons["onboarding-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 40), "Onboarding must appear on a clean launch")
        for _ in 0..<5 {
            XCTAssertTrue(next.waitForExistence(timeout: 5))
            next.tap()
        }

        let astronomy = app.buttons[
            "onboarding-interest-04_technology_&_science/space_and_astronomy"
        ]
        XCTAssertTrue(
            astronomy.waitForExistence(timeout: 20),
            "Interest choices must resolve from the live OPML taxonomy"
        )
        astronomy.tap()
        XCTAssertEqual(astronomy.value as? String, "selected")

        let start = app.buttons["onboarding-start-reading"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()

        let filterButton = app.buttons["filter-button"]
        XCTAssertTrue(filterButton.waitForExistence(timeout: 15))
        XCTAssertGreaterThan(
            Int(filterButton.value as? String ?? "") ?? 0,
            0,
            "Finishing onboarding must persist the chosen taxonomy lens"
        )
    }

    // MARK: - Acoustics (4 feeds, topic)

    func testAcousticsFilterShowsAcousticsCards() {
        selectTaxonomyCategory(
            searchTerm: "Acoustics",
            expectedKeywords: ["Acoustics Today", "Audio Engineering", "acoustics.org"],
            forbiddenSources: ["CNN", "BBC News", "Daring Fireball", "MacStories"],
            screenshotName: "acoustics-verified"
        )
    }

    // MARK: - Duplicate-name taxonomy category

    func testMythologyCategoryPrefersEditorialTopicOverCountryDuplicates() {
        selectTaxonomyCategory(
            searchTerm: "Mythology & Folklore",
            expectedKeywords: ["American Folklore Society", "Folklore"],
            forbiddenSources: ["CNN", "BBC News", "Snopes"],
            screenshotName: "mythology-editorial-topic-verified"
        )
    }

    func testFactCheckingCategoryOwnsMisinformationSources() {
        selectTaxonomyCategory(
            searchTerm: "Fact-Checking & Media Literacy",
            expectedKeywords: ["Snopes", "Conspiracy Watch"],
            forbiddenSources: ["Myths Your Teacher Hated", "Freaky Folklore"],
            screenshotName: "fact-checking-editorial-topic-verified"
        )
    }

    // MARK: - Humor topic category

    func testHumorCategoryShowsCards() {
        // Comedy and performance sources share one content-derived category.
        selectTaxonomyCategory(
            searchTerm: "Comedy & Performance",
            expectedKeywords: ["comedy", "funny", "humor"],
            forbiddenSources: ["CNN", "BBC News", "Daring Fireball"],
            screenshotName: "podcast-verified"
        )
    }

    // MARK: - Video/YouTube category

    func testVideoCategoryShowsCards() {
        selectTaxonomyCategory(
            searchTerm: "Cooking & Recipes",
            expectedKeywords: ["Sorted Food", "cooking", "recipe"],
            forbiddenSources: ["CNN", "BBC News", "MacStories"],
            screenshotName: "video-verified"
        )
    }

    // MARK: - Country-based category

    func testCountryCategoryShowsCards() {
        selectTaxonomyCategory(
            searchTerm: "Algeria",
            expectedKeywords: ["Algeria", "algerie", "Echorouk"],
            forbiddenSources: ["This Day in History"],
            screenshotName: "country-verified"
        )
    }

    // MARK: - Many-feeds category

    func testManyFeedsCategoryShowsCards() {
        selectTaxonomyCategory(
            searchTerm: "Visual Arts",
            expectedKeywords: ["photography", "photo", "camera"],
            forbiddenSources: ["CNN", "BBC News"],
            screenshotName: "many-feeds-verified"
        )
    }

    // MARK: - Clear filters restores normal feed

    func testClearFiltersRestoresFullFeed() {
        waitForAppReady()

        // Apply a filter so we can verify it's cleared
        openFilterAndSelectTopic(searchTerm: "Acoustics")
        dismissTopicsAndFilter()
        sleep(5)
        _ = app.cells.firstMatch.waitForExistence(timeout: 20)
        let beforeClear = app.cells.count
        print("Cells with Acoustics filter: \(beforeClear)")

        // Open filter and tap "Clear All Filters"
        let filterButton = app.buttons["filter-button"]
        filterButton.tap()
        sleep(2)
        _ = app.buttons["filter-done"].waitForExistence(timeout: 5)
        let clearBtn = app.buttons["Clear All Filters"]
        XCTAssertTrue(clearBtn.exists, "Clear All Filters button must be visible")
        clearBtn.tap()
        // clearAllFilters() calls dismiss() internally
        sleep(3)

        // After clear, the filter badge on the button should be gone
        // (activeCount == 0 means no badge circle with number)
        // Verify the filter button still exists (sheet dismissed successfully)
        XCTAssertTrue(filterButton.waitForExistence(timeout: 5),
                      "App should return to feed after clearing filters")

        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.lifetime = .keepAlways
        attachment.name = "clear-filters-verified"
        add(attachment)

        let cards = waitForFeedItemIdentifiers(timeout: 20)
        XCTAssertFalse(cards.isEmpty, "Clearing filters must restore feed cards")
    }

    func testContentTypeFilterTapsRespondImmediately() {
        waitForAppReady()
        let filterButton = app.buttons["filter-button"]
        XCTAssertTrue(filterButton.waitForExistence(timeout: 5))
        filterButton.tap()
        XCTAssertTrue(app.buttons["filter-done"].waitForExistence(timeout: 3))

        let id = "content-type-videos"
        let button = app.buttons[id]
        for _ in 0..<4 where !button.isHittable { app.swipeUp() }
        XCTAssertTrue(button.waitForExistence(timeout: 2), "Missing \(id) filter")
        if (button.value as? String) == "selected" {
            button.tap()
        }
        let start = CFAbsoluteTimeGetCurrent()
        button.tap()
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertLessThan(elapsed, 1.3, "\(id) filter tap blocked the UI for \(elapsed)s")
        app.buttons["filter-done"].tap()
        XCTAssertTrue(filterButton.waitForExistence(timeout: 3))
    }

    func testUnifiedSearchFindsAndOpensContentAnalyzedSource() {
        let searchButton = app.buttons["search-button"]
        XCTAssertTrue(searchButton.waitForExistence(timeout: 45), "Search button must be available")
        searchButton.tap()

        let field = app.textFields["unified-search-field"]
        var didOpenSearch = field.waitForExistence(timeout: 15)
        if !didOpenSearch, searchButton.exists {
            // The first tap can coincide with the initial taxonomy publication
            // on slower simulators. Retry the idempotent presentation action
            // once instead of turning startup load into a false UI failure.
            searchButton.tap()
            didOpenSearch = field.waitForExistence(timeout: 20)
        }
        XCTAssertTrue(didOpenSearch, "Unified search field must open")
        guard didOpenSearch else { return }
        field.tap()
        field.typeText("astronomy")

        XCTAssertTrue(app.staticTexts["Sources"].waitForExistence(timeout: 12),
                      "Content-analyzed source tier must be first")
        let astronomySource = app.staticTexts["Astronomy Magazine"].firstMatch
        XCTAssertTrue(astronomySource.waitForExistence(timeout: 8),
                      "Astronomy source should be found from catalog tags/descriptions")
        astronomySource.tap()

        XCTAssertTrue(app.navigationBars["Astronomy Magazine"].waitForExistence(timeout: 8),
                      "Tapping a source should open its complete source feed")
        XCTAssertTrue(app.buttons["Add source to collection"].exists)
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label ==[c] %@", "astronomy")).firstMatch.exists,
            "Source feed should expose its content-derived astronomy tag"
        )
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "currently exposed by the feed")).firstMatch.exists,
            "Source view should explain the honest RSS history boundary"
        )

        // A source result can be put into a reusable many-to-many playlist
        // without enabling or moving its catalog/OPML entry.
        app.buttons["Add source to collection"].tap()
        let collectionName = "Astronomy reading \(Int(Date().timeIntervalSince1970))"
        let collectionField = app.textFields["Collection name"]
        XCTAssertTrue(collectionField.waitForExistence(timeout: 5))
        collectionField.tap()
        collectionField.typeText(collectionName)
        app.buttons["Create Collection"].tap()
        XCTAssertTrue(app.staticTexts[collectionName].waitForExistence(timeout: 5))

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "unified-search-astronomy-source"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testRecoveredDormantAstronomySourceIsSearchableButNotAutoEnabled() {
        let searchButton = app.buttons["search-button"]
        XCTAssertTrue(searchButton.waitForExistence(timeout: 45), "Search button must be available")
        searchButton.tap()

        let field = app.textFields["unified-search-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "Unified search field must open")
        guard field.exists else { return }
        field.tap()
        field.typeText("Turk Astronomi")

        XCTAssertTrue(app.staticTexts["Sources"].waitForExistence(timeout: 12))
        let recoveredSource = app.staticTexts["Türk Astronomi Derneği (TAD)"].firstMatch
        XCTAssertTrue(
            recoveredSource.waitForExistence(timeout: 8),
            "A recovered source must be discoverable through its analyzed catalog metadata"
        )
        recoveredSource.tap()

        XCTAssertTrue(
            app.navigationBars["Türk Astronomi Derneği (TAD)"].waitForExistence(timeout: 8),
            "The recovered source result must open its exact source view"
        )
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label ==[c] %@", "astronomy")).firstMatch.exists,
            "The source must retain its content-derived astronomy classification"
        )
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", "Dormant in the automatic feed")
            ).firstMatch.exists,
            "Dormant current-sensitive sources must remain searchable without auto-enabling them"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "recovered-dormant-astronomy-source"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLongPressCardOpensThatExactSource() {
        waitForAppReady()
        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "feed-item-"))
            .firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30), "A feed card is required for source navigation")
        guard card.exists else { return }

        card.press(forDuration: 1.2)
        let viewSource = app.buttons["View Source"]
        XCTAssertTrue(viewSource.waitForExistence(timeout: 5), "Long press must offer direct source navigation")
        viewSource.tap()

        XCTAssertTrue(app.buttons["Add source to collection"].waitForExistence(timeout: 8),
                      "The exact source feed should open from the card menu")
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "currently exposed by the feed")).firstMatch.exists,
            "The source screen should be content-first and disclose feed history limits"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "long-press-view-source"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Helpers

    /// Full flow: wait for app, open filter, search topic, select it, verify results.
    private func selectTaxonomyCategory(
        searchTerm: String,
        expectedKeywords: [String],
        forbiddenSources: [String],
        screenshotName: String,
        allowEmptyCards: Bool = false
    ) {
        waitForAppReady()
        openFilterAndSelectTopic(searchTerm: searchTerm)
        dismissTopicsAndFilter()

        // Wait for cards and verify
        print("Waiting for cards after selecting '\(searchTerm)'...")
        let cardIdentifiers = waitForFeedItemIdentifiers(timeout: 30)
        let cardsExist = !cardIdentifiers.isEmpty
        print("Total visible cards: \(cardIdentifiers.count)")

        let allTexts = app.staticTexts

        // Verify expected keywords
        var foundExpected = expectedKeywords.isEmpty
        for kw in expectedKeywords {
            if allTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", kw)).firstMatch.exists {
                foundExpected = true
                break
            }
        }

        // Collect diagnostics
        var labels: [String] = []
        for i in 0..<min(cardIdentifiers.count, 5) {
            labels.append(cardIdentifiers[i])
        }

        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.lifetime = .keepAlways
        attachment.name = screenshotName
        add(attachment)

        if !allowEmptyCards {
            XCTAssertTrue(cardsExist,
                          "No cards visible for '\(searchTerm)' after 30 seconds. Cards: \(labels)")
            XCTAssertTrue(foundExpected,
                          "No \(searchTerm) card found. Cards: \(labels)")
        }

        // Verify no leakage
        for source in forbiddenSources {
            let match = allTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", source)).firstMatch
            XCTAssertFalse(match.exists,
                          "Non-\(searchTerm) source '\(source)' leaked into filtered feed!")
        }
    }

    /// Waits for app to load, opens filter, searches for and selects a topic.
    private func openFilterAndSelectTopic(searchTerm: String) {
        let filterButton = app.buttons["filter-button"]
        guard filterButton.waitForExistence(timeout: 40) else {
            XCTFail("App failed to load — filter button not found")
            return
        }
        sleep(8)  // Let progressive fetch settle

        // Open filter
        filterButton.tap()
        sleep(2)

        // Ensure sheet is visible
        let doneButton = app.buttons["Done"]
        let filterDone = app.buttons["filter-done"]
        let sheetVisible = doneButton.waitForExistence(timeout: 5) ||
                           filterDone.waitForExistence(timeout: 5)
        if !sheetVisible {
            filterButton.tap()
            sleep(2)
            guard doneButton.waitForExistence(timeout: 5) || filterDone.waitForExistence(timeout: 5) else {
                XCTFail("Filter sheet did not open")
                return
            }
        }

        // Find and tap Browse Topics
        sleep(1)
        let browsePred = NSPredicate(format: "label CONTAINS[c] %@", "Browse Topics")
        var foundBrowse = false
        for _ in 0..<8 {
            let btn = app.buttons.element(matching: browsePred)
            let text = app.staticTexts.element(matching: browsePred)
            if btn.exists { btn.tap(); foundBrowse = true; break }
            else if text.exists { text.tap(); foundBrowse = true; break }
            app.swipeUp()
            usleep(500_000)
        }
        guard foundBrowse else {
            XCTFail("Browse Topics not found")
            return
        }

        sleep(1)

        // Wait for search field and search
        let searchField = app.textFields["search-topics"]
        guard searchField.waitForExistence(timeout: 10) else {
            XCTFail("Topics search field did not appear")
            return
        }
        searchField.tap()
        sleep(1)
        searchField.typeText(searchTerm)
        sleep(2)
        searchField.typeText("\n")
        usleep(300_000)

        // Tap search result
        let resultPred = NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
            "taxonomy-node-", searchTerm
        )
        let resultBtn = app.buttons.matching(resultPred).firstMatch
        guard resultBtn.waitForExistence(timeout: 5) else {
            XCTFail("'\(searchTerm)' not found in search results")
            return
        }
        let searchShot = XCTAttachment(screenshot: app.screenshot())
        searchShot.name = "topic-search-\(searchTerm)"
        searchShot.lifetime = .deleteOnSuccess
        add(searchShot)
        XCTAssertTrue(resultBtn.isHittable,
                      "Topic result is not hittable: \(resultBtn.identifier), \(resultBtn.label)")
        resultBtn.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        XCTAssertGreaterThan(
            Int(app.buttons["topics-done"].value as? String ?? "") ?? 0,
            0,
            "Topic selection must update immediately after tapping '\(resultBtn.label)' (\(resultBtn.identifier))"
        )
        sleep(1)
    }

    /// Dismisses Topics view and Filter sheet.
    private func dismissTopicsAndFilter() {
        let topicsDone = app.buttons["topics-done"]
        if topicsDone.exists { topicsDone.tap() }
        else {
            let doneBtn = app.buttons["Done"]
            if doneBtn.exists { doneBtn.tap() }
        }
        sleep(1)

        let selectedTopicCount = Int(app.buttons["browse-topics"].value as? String ?? "") ?? 0
        XCTAssertGreaterThan(selectedTopicCount, 0,
                             "Topic selection must remain active after leaving the topic browser")

        let filterDoneBtn = app.buttons["filter-done"]
        if filterDoneBtn.exists { filterDoneBtn.tap() }
        else {
            let doneBtn = app.buttons["Done"]
            if doneBtn.exists { doneBtn.tap() }
        }
        sleep(2)

        let activeFilterCount = Int(app.buttons["filter-button"].value as? String ?? "") ?? 0
        XCTAssertGreaterThan(activeFilterCount, 0,
                             "Topic selection must remain active after dismissing filters")
    }

    /// Wait for app to finish initial loading.
    private func waitForAppReady() {
        guard app.buttons["filter-button"].waitForExistence(timeout: 40) else {
            XCTFail("App failed to load")
            return
        }
        sleep(8)
    }

    private func waitForFeedItemIdentifiers(timeout: TimeInterval) -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let identifiers = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "feed-item-"))
                .allElementsBoundByIndex
                .map(\.identifier)
            if !identifiers.isEmpty { return identifiers }
            usleep(100_000)
        } while Date() < deadline
        return []
    }
}
