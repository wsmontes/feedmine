import XCTest
@testable import feedmine

@MainActor
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
        // Fill reservoir with many items across all content types
        var reservoir = [FeedItem]()
        for i in 0..<400 {
            reservoir.append(FeedItem(
                id: "item\(i)", sourceTitle: "S", sourceURL: "https://x.com/feed",
                category: "Tech", title: "T", excerpt: "E", url: "https://x.com/\(i)",
                imageURL: nil, publishedAt: Date(),
                audioURL: nil, duration: nil, region: "global"
            ))
        }
        // Add video items (URL must contain "youtu" to trigger isYouTube)
        for i in 0..<100 {
            reservoir.append(FeedItem(
                id: "vid\(i)", sourceTitle: "S", sourceURL: "https://youtube.com/feed",
                category: "Tech", title: "V", excerpt: "E", url: "https://youtube.com/watch?v=vid\(i)",
                imageURL: nil, publishedAt: Date(),
                audioURL: nil, duration: nil, region: "global"
            ))
        }
        // Add podcast items (must have audioURL to trigger isPodcast)
        for i in 0..<100 {
            reservoir.append(FeedItem(
                id: "pod\(i)", sourceTitle: "S", sourceURL: "https://podcast.com/feed",
                category: "Tech", title: "P", excerpt: "E", url: "https://podcast.com/\(i)",
                imageURL: nil, publishedAt: Date(),
                audioURL: "https://audio.com/ep\(i).mp3", duration: 1800, region: "global"
            ))
        }
        let batch = s.nextBatch(reservoir: reservoir, sourcesByRegion: sources, activeRegion: nil, activeCategory: nil)
        XCTAssertTrue(batch.isEmpty, "Should skip when all buffers are full")
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

    func testVideoFilterFetchesOnlyVideoSources() {
        let scheduler = SourceScheduler()
        let sources: [String: [FeedSource]] = [
            "global": [
                FeedSource(title: "YouTube", url: "https://youtube.com/feeds/videos.xml?channel_id=UC123", category: "Tech", region: "global", mediaKind: .video),
                FeedSource(title: "Video RSS", url: "https://video.example/feed", category: "Tech", region: "global", mediaKind: .video),
                FeedSource(title: "Blog", url: "https://blog.example/feed", category: "Tech", region: "global"),
                FeedSource(title: "Podcast", url: "https://podcast.example/feed", category: "Tech", region: "global", mediaKind: .audio),
            ]
        ]

        let batch = scheduler.nextBatch(
            reservoir: [],
            sourcesByRegion: sources,
            activeRegion: nil,
            activeCategory: nil,
            activeContentType: "video"
        )

        XCTAssertEqual(Set(batch.map(\.url)), [
            "https://youtube.com/feeds/videos.xml?channel_id=UC123",
            "https://video.example/feed",
        ])
    }

    func testVideoFilterKeepsFetchingWhenOneProviderFillsBuffer() {
        let scheduler = SourceScheduler()
        let existingURL = "https://youtube.com/feeds/videos.xml?channel_id=existing"
        let newURL = "https://youtube.com/feeds/videos.xml?channel_id=new"
        let reservoir = (0..<80).map { index in
            FeedItem(
                id: "video-\(index)", sourceTitle: "Existing",
                sourceURL: existingURL, category: "Video",
                title: "Video \(index)", excerpt: "E",
                url: "https://youtube.com/watch?v=video\(index)", imageURL: nil,
                publishedAt: Date(), region: "global"
            )
        }

        let batch = scheduler.nextBatch(
            reservoir: reservoir,
            sourcesByRegion: [
                "global": [
                    FeedSource(title: "Existing", url: existingURL, category: "Video", mediaKind: .video),
                    FeedSource(title: "New", url: newURL, category: "Video", mediaKind: .video),
                ]
            ],
            activeRegion: nil,
            activeCategory: nil,
            activeContentType: "video"
        )

        XCTAssertTrue(batch.contains { $0.url == newURL })
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

    func testPriorityURLsJumpToFront() {
        let scheduler = SourceScheduler()
        let priorityURL = "https://priority.com/feed"
        let normalURL = "https://normal.com/feed"

        let sourcesByRegion: [String: [FeedSource]] = [
            "global": [
                FeedSource(title: "Priority", url: priorityURL, category: "News", region: "global"),
                FeedSource(title: "Normal", url: normalURL, category: "News", region: "global"),
            ]
        ]

        let batch = scheduler.nextBatch(
            reservoir: [],
            sourcesByRegion: sourcesByRegion,
            activeRegion: nil,
            activeCategory: nil,
            prioritySourceURLs: [priorityURL]
        )

        XCTAssertEqual(batch.first?.url, priorityURL, "Priority URL must be first in batch")
    }

    func testDiverseSourcesAvoidsColdStartCategoryClustering() {
        let scored: [(source: FeedSource, score: Double)] = [
            FeedSource(title: "Coffee 1", url: "https://coffee1.com/feed", category: "Coffee", region: "global"),
            FeedSource(title: "Coffee 2", url: "https://coffee2.com/feed", category: "Coffee", region: "global"),
            FeedSource(title: "Coffee 3", url: "https://coffee3.com/feed", category: "Coffee", region: "global"),
            FeedSource(title: "Coffee 4", url: "https://coffee4.com/feed", category: "Coffee", region: "global"),
            FeedSource(title: "Tech", url: "https://tech.com/feed", category: "Tech", region: "global"),
            FeedSource(title: "Science", url: "https://science.com/feed", category: "Science", region: "global"),
        ].map { (source: $0, score: 1.0) }

        let selected = SourceScheduler.diverseSources(from: scored, limit: 3)

        XCTAssertEqual(Set(selected.map(\.category)).count, 3)
    }

    func testLanguageFilterExcludesNonMatchingSources() {
        let scheduler = SourceScheduler()
        let ptURL = "https://pt.com/feed"
        let enURL = "https://en.com/feed"
        let noLangURL = "https://nolang.com/feed"

        let sourcesByRegion: [String: [FeedSource]] = [
            "global": [
                FeedSource(title: "PT", url: ptURL, category: "News", region: "global", language: "pt"),
                FeedSource(title: "EN", url: enURL, category: "News", region: "global", language: "en"),
                FeedSource(title: "NoLang", url: noLangURL, category: "News", region: "global", language: nil),
            ]
        ]

        let batch = scheduler.nextBatch(
            reservoir: [],
            sourcesByRegion: sourcesByRegion,
            activeRegion: nil,
            activeCategory: nil,
            prioritySourceURLs: [],
            activeLanguages: ["pt"]
        )

        // EN source with known language != pt → excluded (not penalised)
        let urls = batch.map(\.url)
        XCTAssertFalse(urls.contains(enURL), "English source must be excluded when Portuguese is selected")
        // PT source → included (matching language)
        XCTAssertTrue(urls.contains(ptURL), "Portuguese source must be included")
        // No-language source → included (can't determine, err on inclusion)
        XCTAssertTrue(urls.contains(noLangURL), "Source without language tag must be included")
    }
}
