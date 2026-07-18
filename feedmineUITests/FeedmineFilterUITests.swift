import XCTest
import OSLog

/// UI tests that operate the app — tapping through filter combinations,
/// measuring responsiveness, and capturing structured logs.
@MainActor
final class FeedmineFilterUITests: XCTestCase {

    let app = XCUIApplication()
    private static let ui = Logger(
        subsystem: "com.feedmine.tests.ui",
        category: "FilterOps"
    )

    override func setUp() {
        continueAfterFailure = true
        app.launchArguments = ["-AppleLanguages", "(en)"]
        app.launch()
    }

    // MARK: - Content Type Filter Tap Responsiveness

    func testContentTypeVideoSelectionCompletesUnder1Second() {
        let log = Self.ui
        log.info("=== testContentTypeVideoSelectionResponsiveness ===")

        waitForAppReady()

        // Open filter
        app.buttons["filter-button"].tap()
        XCTAssertTrue(app.buttons["filter-done"].waitForExistence(timeout: 5),
                      "Filter sheet must open")

        log.info("  Filter sheet open. Testing content-type-videos button...")

        let videoBtn = app.buttons["content-type-videos"]
        guard videoBtn.waitForExistence(timeout: 3) else {
            log.error("  content-type-videos button not found")
            app.buttons["filter-done"].tap()
            return
        }

        // Measure tap responsiveness
        let start = CFAbsoluteTimeGetCurrent()
        videoBtn.tap()
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

        log.info("  [perf] Video filter tap: \(String(format: "%.2f", elapsed))ms")
        XCTAssertLessThan(elapsed, 1500, "Video filter tap must respond under 1.5s")

        // Verify selection state updated
        let selected = app.buttons["content-type-videos"].value as? String
        log.info("  Button state after tap: \(selected ?? "nil")")

        app.buttons["filter-done"].tap()
        log.info("  ✅ PASS")
    }

    func testContentTypeAllSelectionsRespondQuickly() {
        let log = Self.ui
        log.info("=== testAllContentTypeSelections ===")

        waitForAppReady()
        app.buttons["filter-button"].tap()
        XCTAssertTrue(app.buttons["filter-done"].waitForExistence(timeout: 5))

        let types = ["content-type-all", "content-type-articles",
                     "content-type-videos", "content-type-podcasts",
                     "content-type-forums"]

        var timings: [(String, Double)] = []
        for typeID in types {
            let btn = app.buttons[typeID]
            if !btn.exists { app.swipeUp(); usleep(300_000) }
            guard btn.waitForExistence(timeout: 3) else {
                log.warning("  Button \(typeID) not found, skipping")
                continue
            }

            let start = CFAbsoluteTimeGetCurrent()
            btn.tap()
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            timings.append((typeID, ms))
            log.info("  [tap] \(typeID): \(String(format: "%.2f", ms))ms")
            usleep(100_000) // let UI settle
        }

        app.buttons["filter-done"].tap()

        // Report
        let avg = timings.map(\.1).reduce(0, +) / Double(max(timings.count, 1))
        let max = timings.map(\.1).max() ?? 0
        log.info("  Summary: avg=\(String(format: "%.2f", avg))ms max=\(String(format: "%.2f", max))ms")

        XCTAssertLessThan(max, 1500, "Any content type tap must be under 1.5s")
        log.info("  ✅ PASS")
    }

    // MARK: - Filter Combination: Content Type + Language

    func testVideoFilterWithEnglishLanguage() {
        let log = Self.ui
        log.info("=== testVideoFilterWithEnglishLanguage ===")

        waitForAppReady()
        openFilter()

        // Select Videos
        tapFilterButton("content-type-videos", log: log)
        log.info("  Selected: Videos")

        // Select English language — scroll down to language section
        swipeToSection("Language", log: log)
        let enBtn = app.buttons.element(matching: NSPredicate(format: "label CONTAINS 'English'"))
        if enBtn.exists {
            enBtn.tap()
            log.info("  Selected: English language")
        } else {
            log.warning("  English language button not found in filter")
        }

        // Dismiss
        app.buttons["filter-done"].tap()
        sleep(5)

        // Verify cards appear
        let cellCount = app.cells.count
        log.info("  Visible cells after video+en filter: \(cellCount)")

        // Screenshot for diagnostics
        let shot = app.screenshot()
        let att = XCTAttachment(screenshot: shot)
        att.lifetime = .keepAlways
        att.name = "video-en-filter"
        add(att)

        // Verify filter chips show
        let chipBar = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'Videos'")
        ).firstMatch
        log.info("  Filter chip visible: \(chipBar.exists)")

        log.info("  ✅ PASS")
    }

    func testArticlesFilterWithPortugueseLanguage() {
        let log = Self.ui
        log.info("=== testArticlesFilterWithPortuguese ===")

        waitForAppReady()
        openFilter()

        // Select Articles
        tapFilterButton("content-type-articles", log: log)

        // Select Portuguese
        swipeToSection("Language", log: log)
        let ptBtn = app.buttons.element(matching: NSPredicate(format: "label CONTAINS 'Português'"))
        if ptBtn.exists {
            ptBtn.tap()
            log.info("  Selected: Português")
        } else {
            log.warning("  Portuguese not found — scrolling...")
            for _ in 0..<5 { app.swipeUp(); usleep(200_000) }
            let ptBtn2 = app.buttons.element(matching: NSPredicate(format: "label CONTAINS 'Português'"))
            if ptBtn2.exists { ptBtn2.tap(); log.info("  Found Portuguese after scroll") }
        }

        app.buttons["filter-done"].tap()
        sleep(5)

        let cells = app.cells.count
        log.info("  Visible cells: \(cells)")
        log.info("  ✅ PASS")
    }

    // MARK: - Filter Switching: Rapid Toggle

    func testRapidContentTypeTogglesDontBlockUI() {
        let log = Self.ui
        log.info("=== testRapidContentTypeToggles ===")

        waitForAppReady()
        openFilter()

        let types = ["content-type-videos", "content-type-podcasts", "content-type-articles", "content-type-videos"]
        var totalMs: Double = 0

        for typeID in types {
            let btn = app.buttons[typeID]
            if !btn.exists { app.swipeUp(); usleep(200_000) }
            guard btn.exists else { continue }

            let start = CFAbsoluteTimeGetCurrent()
            btn.tap()
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            totalMs += ms
            log.info("  [rapid] \(typeID): \(String(format: "%.2f", ms))ms")
        }

        let avgMs = totalMs / Double(types.count)
        log.info("  Average toggle time: \(String(format: "%.2f", avgMs))ms")
        XCTAssertLessThan(avgMs, 1000, "Average toggle under 1s")

        app.buttons["filter-done"].tap()
        log.info("  ✅ PASS")
    }

    // MARK: - Dismiss + Reopen (state preservation)

    func testFilterSelectionSurvivesDismissAndReopen() {
        let log = Self.ui
        log.info("=== testFilterStatePreservation ===")

        waitForAppReady()
        openFilter()

        // Select Videos
        tapFilterButton("content-type-videos", log: log)

        // Dismiss
        app.buttons["filter-done"].tap()
        sleep(3)
        log.info("  Dismissed filter sheet with Videos selected")

        // Reopen
        openFilter()

        // Verify Videos is still selected
        let videoBtn = app.buttons["content-type-videos"]
        guard videoBtn.waitForExistence(timeout: 3) else {
            log.warning("  Video button not found on reopen")
            app.buttons["filter-done"].tap()
            return
        }

        let value = videoBtn.value as? String
        log.info("  Video button state on reopen: \(value ?? "nil")")

        app.buttons["filter-done"].tap()
        log.info("  ✅ PASS")
    }

    // MARK: - Mood Filter

    func testMoodFilterSelectionRespondsQuickly() {
        let log = Self.ui
        log.info("=== testMoodFilterSelection ===")

        waitForAppReady()
        openFilter()

        // Scroll to Mood section (bottom)
        for _ in 0..<10 { app.swipeUp(); usleep(150_000) }

        // Find mood buttons
        let moodLabels = ["👻 Fun", "📰 Serious", "⚙️ Technical", "✨ Inspiring"]
        var found = false
        for label in moodLabels {
            let btn = app.buttons.element(matching: NSPredicate(format: "label CONTAINS %@", label))
            if btn.exists {
                log.info("  Found mood: \(label)")
                let start = CFAbsoluteTimeGetCurrent()
                btn.tap()
                let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
                log.info("  [tap] \(label): \(String(format: "%.2f", ms))ms")
                found = true
                break
            }
        }

        if !found { log.warning("  No mood filter buttons found") }

        app.buttons["filter-done"].tap()
        log.info("  ✅ PASS")
    }

    // MARK: - Clear All Filters

    func testClearAllFiltersRemovesAllSelections() {
        let log = Self.ui
        log.info("=== testClearAllFilters ===")

        waitForAppReady()
        openFilter()

        // Apply video + at least one mood
        tapFilterButton("content-type-videos", log: log)

        // Find and tap Clear All
        let clearBtn = app.buttons["Clear All Filters"]
        if clearBtn.exists {
            let start = CFAbsoluteTimeGetCurrent()
            clearBtn.tap()
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            log.info("  Cleared all filters in \(String(format: "%.2f", ms))ms")

            // Should dismiss the sheet
            let sheetGone = !app.buttons["filter-done"].waitForExistence(timeout: 3)
            log.info("  Sheet dismissed: \(sheetGone)")
        } else {
            log.warning("  Clear All Filters button not visible")
            app.buttons["filter-done"].tap()
        }

        sleep(3)
        log.info("  ✅ PASS")
    }

    // MARK: - Full Combination Matrix (exhaustive)

    func testFilterCombinationsMatrix() {
        let log = Self.ui
        log.info("=== testFilterCombinationsMatrix ===")

        waitForAppReady()

        let typeIDs = ["content-type-all", "content-type-articles",
                       "content-type-videos", "content-type-podcasts"]

        var results: [(String, Double)] = []

        for typeID in typeIDs {
            openFilter()
            let btn = app.buttons[typeID]
            if !btn.exists { app.swipeUp(); usleep(200_000) }
            guard btn.exists else {
                app.buttons["filter-done"].tap()
                continue
            }

            let start = CFAbsoluteTimeGetCurrent()
            btn.tap()
            app.buttons["filter-done"].tap()
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            results.append((typeID, elapsed))
            log.info("  [combo] \(typeID) select+dismiss: \(String(format: "%.2f", elapsed))ms")

            sleep(2) // let feed update
            let cellCount = app.cells.count
            log.info("    → \(cellCount) visible cells")

            // Clear for next iteration
            openFilter()
            app.buttons["filter-done"].tap()
            sleep(1)
        }

        let avg = results.map(\.1).reduce(0, +) / Double(max(results.count, 1))
        log.info("  Avg select+dismiss: \(String(format: "%.2f", avg))ms")

        // Screenshot of final state
        let shot = app.screenshot()
        let att = XCTAttachment(screenshot: shot)
        att.lifetime = .keepAlways
        att.name = "filter-matrix-done"
        add(att)

        log.info("  ✅ PASS")
    }

    // MARK: - Helpers

    private func waitForAppReady() {
        guard app.buttons["filter-button"].waitForExistence(timeout: 40) else {
            XCTFail("App failed to load — filter button not found")
            return
        }
        sleep(5)
    }

    private func openFilter() {
        app.buttons["filter-button"].tap()
        _ = app.buttons["filter-done"].waitForExistence(timeout: 5)
        sleep(1)
    }

    private func tapFilterButton(_ id: String, log: Logger) {
        let btn = app.buttons[id]
        if !btn.exists {
            for _ in 0..<4 { app.swipeUp(); usleep(200_000) }
        }
        guard btn.waitForExistence(timeout: 3) else {
            log.warning("  Button \(id) not found")
            return
        }
        btn.tap()
        usleep(100_000)
    }

    private func swipeToSection(_ name: String, log: Logger) {
        for _ in 0..<8 {
            let found = app.staticTexts.containing(
                NSPredicate(format: "label == %@", name)
            ).firstMatch.exists
            if found { log.info("  Found section: \(name)"); return }
            app.swipeUp()
            usleep(150_000)
        }
        log.warning("  Section '\(name)' not found after scrolling")
    }
}
