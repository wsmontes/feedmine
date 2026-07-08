import Foundation

struct FeedFetchBatch: Sendable {
    let items: [FeedItem]
    let fetchedSourceCount: Int
    let failedSourceCount: Int
    let emptySourceCount: Int
    /// Per-source outcome, keyed by source URL. Lets callers record accurate
    /// health instead of guessing which source failed from aggregate counters.
    let sourceStatuses: [String: FeedFetchStatus]
}
