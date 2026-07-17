import XCTest
@testable import feedmine

@MainActor
final class FeedLoaderCacheTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Keys.toggleDisabled)
        UserDefaults.standard.removeObject(forKey: Keys.toggleEnabledOverrides)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Keys.toggleDisabled)
        UserDefaults.standard.removeObject(forKey: Keys.toggleEnabledOverrides)
        super.tearDown()
    }

    func testAvailableLanguagesUsesCachedRegistryAndInvalidatesAfterSourceToggle() throws {
        let store = try FeedStore(inMemory: true)
        store.registry.sources = [
            FeedSource(title: "English 1", url: "https://en1.example/feed",
                       category: "News", region: "global", language: "en-US"),
            FeedSource(title: "English 2", url: "https://en2.example/feed",
                       category: "News", region: "global", language: "en"),
            FeedSource(title: "Portuguese", url: "https://pt.example/feed",
                       category: "News", region: "global", language: "pt-BR"),
        ]
        let loader = FeedLoader(store: store)

        let initial = Dictionary(uniqueKeysWithValues: loader.availableLanguages.map { ($0.code, $0.feedCount) })
        XCTAssertEqual(initial["en"], 2)
        XCTAssertEqual(initial["pt"], 1)

        store.registry.toggleSource("https://en1.example/feed")

        let afterToggle = Dictionary(uniqueKeysWithValues: loader.availableLanguages.map { ($0.code, $0.feedCount) })
        XCTAssertEqual(afterToggle["en"], 1)
        XCTAssertEqual(afterToggle["pt"], 1)
    }

    func testAvailableLanguagesInvalidatesWhenSourceLanguageMetadataChanges() throws {
        let store = try FeedStore(inMemory: true)
        store.registry.sources = [
            FeedSource(title: "Feed", url: "https://example.com/feed",
                       category: "News", region: "global", language: "en"),
        ]
        let loader = FeedLoader(store: store)

        let initial = Dictionary(uniqueKeysWithValues: loader.availableLanguages.map { ($0.code, $0.feedCount) })
        XCTAssertEqual(initial["en"], 1)

        store.registry.sources = [
            FeedSource(title: "Feed", url: "https://example.com/feed",
                       category: "News", region: "global", language: "pt-BR"),
        ]

        let updated = Dictionary(uniqueKeysWithValues: loader.availableLanguages.map { ($0.code, $0.feedCount) })
        XCTAssertNil(updated["en"])
        XCTAssertEqual(updated["pt"], 1)
    }
}
