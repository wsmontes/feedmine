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
}
