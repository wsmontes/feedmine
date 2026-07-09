import XCTest
@testable import feedmine

final class SourceSchedulerTests: XCTestCase {

    func testNextBatchReturnsSourcesWhenBufferEmpty() {
        let s = SourceScheduler()
        let sources: [String: [FeedSource]] = [
            "global": [
                FeedSource(title: "Blog A", url: "https://a.com/feed", category: "Tech", region: "global"),
                FeedSource(title: "Blog B", url: "https://b.com/feed", category: "Science", region: "global")
            ]
        ]
        let batch = s.nextBatch(reservoir: [], sourcesByRegion: sources, activeRegion: nil, activeCategory: nil)
        XCTAssertFalse(batch.isEmpty, "Should select sources when reservoir is empty")
    }

    func testNextBatchReturnsEmptyWhenBufferFull() {
        let s = SourceScheduler()
        let sources: [String: [FeedSource]] = [
            "global": [FeedSource(title: "A", url: "https://a.com/feed", category: "Tech", region: "global")]
        ]
        // Fill reservoir with many text items
        var reservoir = [FeedItem]()
        for i in 0..<400 {
            reservoir.append(FeedItem(
                id: "item\(i)", sourceTitle: "S", sourceURL: "https://x.com/feed",
                category: "Tech", title: "T", excerpt: "E", url: "https://x.com/\(i)",
                imageURL: nil, publishedAt: Date(),
                audioURL: nil, duration: nil, region: "global"
            ))
        }
        let batch = s.nextBatch(reservoir: reservoir, sourcesByRegion: sources, activeRegion: nil, activeCategory: nil)
        XCTAssertTrue(batch.isEmpty, "Should skip when text buffer is full")
    }

    func testNextBatchPicksYouTubeWhenVideoBufferEmpty() {
        let s = SourceScheduler()
        let sources: [String: [FeedSource]] = [
            "global": [
                FeedSource(title: "YT Channel", url: "https://youtube.com/feeds/videos.xml?channel_id=UC123", category: "Tech", region: "global", mediaKind: .video),
                FeedSource(title: "Blog", url: "https://blog.com/feed", category: "Tech", region: "global")
            ]
        ]
        // Fill with text items so text buffer is full, but video buffer is empty
        var reservoir = [FeedItem]()
        for i in 0..<400 {
            reservoir.append(FeedItem(
                id: "t\(i)", sourceTitle: "S", sourceURL: "https://x.com/feed",
                category: "Tech", title: "T", excerpt: "E", url: "https://x.com/\(i)",
                imageURL: nil, publishedAt: Date(),
                audioURL: nil, duration: nil, region: "global"
            ))
        }
        let batch = s.nextBatch(reservoir: reservoir, sourcesByRegion: sources, activeRegion: nil, activeCategory: nil)
        // Should still pick the YouTube source because video buffer is empty
        let hasYouTube = batch.contains { $0.isYouTube }
        XCTAssertTrue(hasYouTube, "Should select YouTube when video buffer is empty")
    }

    func testCooldownApplies() {
        let s = SourceScheduler()
        let source = FeedSource(title: "A", url: "https://a.com/feed", category: "Tech", region: "global")
        s.recordFetch(sourceURL: "https://a.com/feed", success: true)
        // Immediately requesting again — cooldown should reduce priority but not exclude
        let sources: [String: [FeedSource]] = ["global": [source]]
        let batch = s.nextBatch(reservoir: [], sourcesByRegion: sources, activeRegion: nil, activeCategory: nil)
        // With empty reservoir and only one source, it should still be picked
        XCTAssertEqual(batch.count, 1)
    }

    func testRecordFetchTracksConsecutiveFailures() {
        let s = SourceScheduler()
        s.recordFetch(sourceURL: "https://a.com/feed", success: false)
        s.recordFetch(sourceURL: "https://a.com/feed", success: false)
        let health = s.healthSnapshot(for: "https://a.com/feed")
        XCTAssertEqual(health.consecutiveFailures, 2)
        XCTAssertEqual(health.lastStatus, "error")
    }
}
