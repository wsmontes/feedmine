import Foundation

struct FeedFetchBatch: Sendable {
    let items: [FeedItem]
    let fetchedSourceCount: Int
    let failedSourceCount: Int
    let emptySourceCount: Int
}
