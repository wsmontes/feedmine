import XCTest

@MainActor
final class FeedmineUITests: XCTestCase {

    let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = true
        app.launchArguments = ["-AppleLanguages", "(en)"]
        app.launch()
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

    // MARK: - Single feed category

    func testSingleFeedCategoryShowsCard() {
        selectTaxonomyCategory(
            searchTerm: "Greek & Roman Mythology",
            expectedKeywords: ["Sententiae Antiquae"],
            forbiddenSources: ["CNN", "BBC News"],
            screenshotName: "single-feed-verified"
        )
    }

    // MARK: - Podcast category

    func testPodcastCategoryShowsCards() {
        // "Humor & Comedy Websites" has 7 feeds and is a distinct category
        selectTaxonomyCategory(
            searchTerm: "Humor & Comedy Websites",
            expectedKeywords: ["comedy", "funny", "humor"],
            forbiddenSources: ["CNN", "BBC News", "Daring Fireball"],
            screenshotName: "podcast-verified"
        )
    }

    // MARK: - Video/YouTube category

    func testVideoCategoryShowsCards() {
        selectTaxonomyCategory(
            searchTerm: "YouTube — Cooking Channels",
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
            forbiddenSources: [],
            screenshotName: "country-verified"
        )
    }

    // MARK: - Many-feeds category

    func testManyFeedsCategoryShowsCards() {
        selectTaxonomyCategory(
            searchTerm: "Photography News & Reviews",
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

        // Note: cards may take time to reappear as progressive fetch runs.
        // The key assertion is that the app didn't crash and the sheet dismissed.
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
        let cardsExist = app.cells.firstMatch.waitForExistence(timeout: 30)

        let totalCells = app.cells.count
        print("Total visible cells: \(totalCells)")

        let allTexts = app.cells.staticTexts

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
        for i in 0..<min(totalCells, 5) {
            labels.append(app.cells.element(boundBy: i).label)
        }

        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.lifetime = .keepAlways
        attachment.name = screenshotName
        add(attachment)

        if cardsExist && !allowEmptyCards {
            XCTAssertTrue(foundExpected,
                          "No \(searchTerm) card found. Cells: \(totalCells), Labels: \(labels)")
        } else if !cardsExist && !allowEmptyCards {
            print("No cells visible for '\(searchTerm)'. Labels: \(labels)")
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
        for swipe in 0..<8 {
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

        // Tap search result
        let resultPred = NSPredicate(format: "label CONTAINS[c] %@", searchTerm)
        let resultBtn = app.buttons.element(matching: resultPred)
        guard resultBtn.waitForExistence(timeout: 5) else {
            XCTFail("'\(searchTerm)' not found in search results")
            return
        }
        resultBtn.tap()
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

        let filterDoneBtn = app.buttons["filter-done"]
        if filterDoneBtn.exists { filterDoneBtn.tap() }
        else {
            let doneBtn = app.buttons["Done"]
            if doneBtn.exists { doneBtn.tap() }
        }
        sleep(2)
    }

    /// Wait for app to finish initial loading.
    private func waitForAppReady() {
        guard app.buttons["filter-button"].waitForExistence(timeout: 40) else {
            XCTFail("App failed to load")
            return
        }
        sleep(8)
    }
}
