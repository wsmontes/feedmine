import Foundation

enum FeedFetchStatus: Sendable, Equatable, CaseIterable {
    case success
    case empty
    case failed
}

struct FeedFetchResult: Sendable {
    let source: FeedSource
    let items: [FeedItem]
    let status: FeedFetchStatus
}
