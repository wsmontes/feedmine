import Foundation

struct OPMLParseResult: Sendable {
    let sources: [FeedSource]
    /// URLs that occur under more than one country in the raw OPML catalog.
    /// They are deduplicated for fetching, but must not masquerade as local
    /// sources in any individual country taxonomy.
    let sharedCountrySourceURLs: Set<String>
    let fileCount: Int
    let failedFileCount: Int
    let invalidSourceCount: Int
    let duplicateSourceCount: Int
}
