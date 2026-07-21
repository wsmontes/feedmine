import XCTest
@testable import feedmine

@MainActor
final class MomentGreetingTests: XCTestCase {

    func testGenerateReturnsNonEmptyString() {
        let result = MomentGreeting.generate()
        XCTAssertFalse(result.isEmpty)
        XCTAssertTrue(result.hasSuffix(".") || result.hasSuffix("?") || result.hasSuffix("!"))
    }

    func testGenerateDoesNotReturnSameConsecutively() {
        let a = MomentGreeting.generate()
        let b = MomentGreeting.generate()
        // With 3,361 templates, extremely unlikely to get same twice
        // But the anti-repeat logic should guarantee it
        XCTAssertNotEqual(a, b, "Anti-repeat should prevent same greeting twice")
    }

    func testGenerateHandlesNilLoader() {
        let result = MomentGreeting.generate(loader: nil)
        XCTAssertFalse(result.isEmpty)
        // Should still produce a valid greeting even without feed data
    }

    func testCleanedOutputHasNoUnfilledSlots() {
        let result = MomentGreeting.generate()
        XCTAssertFalse(result.contains("{{"), "Should not contain unfilled template slots")
        XCTAssertFalse(result.contains("}}"), "Should not contain unfilled template slots")
    }

    func testNonEnglishMomentUsesLocalizedGreetingOnly() {
        let originalLanguages = UserDefaults.standard.stringArray(forKey: "AppleLanguages")
        UserDefaults.standard.set(["pt-BR"], forKey: "AppleLanguages")
        defer {
            if let originalLanguages {
                UserDefaults.standard.set(originalLanguages, forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            }
        }

        AppContext.shared.refresh()
        let result = MomentGreeting.generate()
        let expected = Set(GreetingStore.variants(for: AppContext.shared.timeOfDay).map(finishedSentence))
        XCTAssertTrue(expected.contains(result),
                      "Non-English moments should use localized greeting variants without English template fragments")
    }

    func testGreetingRefreshesAcrossLocalMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let friday = calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 17,
            hour: 23,
            minute: 59
        ))!
        let saturday = calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 18,
            hour: 0,
            minute: 1
        ))!

        XCTAssertTrue(
            MomentCard.shouldRefreshGreeting(
                generatedAt: friday.timeIntervalSinceReferenceDate,
                generatedDay: MomentCard.greetingDayStamp(for: friday, calendar: calendar),
                now: saturday,
                lifetime: 2 * 60 * 60,
                calendar: calendar
            )
        )
    }

    private func finishedSentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(".") || trimmed.hasSuffix("?") || trimmed.hasSuffix("!") {
            return trimmed
        }
        return trimmed + "."
    }
}
