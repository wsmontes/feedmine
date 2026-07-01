import Foundation

struct OPMLParseResult: Sendable {
    let sources: [FeedSource]
    let fileCount: Int
    let failedFileCount: Int
    let invalidSourceCount: Int
    let duplicateSourceCount: Int
}
