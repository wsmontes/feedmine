import Foundation
import GRDB

@MainActor
final class SearchEngine {
    let db: DatabaseQueue

    init(db: DatabaseQueue) {
        self.db = db
    }

    /// Epoch-seconds cutoff for the 30-day retention window.
    private var thirtyDayCutoffEpoch: Int {
        Int(Date().addingTimeInterval(-2592000).timeIntervalSince1970)
    }

    /// Execute an FTS5 search against feed_item, filtered by region/category.
    /// Returns matching items (max 100), sorted by published_at DESC.
    func search(_ query: String, region: String?, category: String?) async -> [FeedItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        guard let pattern = FTS5Pattern(matchingAllTokensIn: q) else { return [] }

        let results: [FeedItemRecord] = (try? await db.read { [thirtyDayCutoffEpoch] db in
            var request = FeedItemRecord
                .filter(Column("fetched_at") > thirtyDayCutoffEpoch)
                .matching(pattern)
            if let r = region { request = request.filter(Column("region") == r) }
            if let c = category { request = request.filter(Column("category") == c) }
            return try request
                .order(Column("published_at").desc)
                .limit(100)
                .fetchAll(db)
        }) ?? []
        return results.map { $0.toFeedItem() }
    }

    /// Execute an FTS5 search with taxonomy-based post-filter.
    /// Searches the full 30-day window, then filters results by taxonomy node subtree.
    func search(_ query: String, region: String?, taxonomyNodeIDs: Set<String>) async -> [FeedItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        guard let pattern = FTS5Pattern(matchingAllTokensIn: q) else { return [] }

        let results: [FeedItemRecord] = (try? await db.read { [thirtyDayCutoffEpoch] db in
            var request = FeedItemRecord
                .filter(Column("fetched_at") > thirtyDayCutoffEpoch)
                .matching(pattern)
            if let r = region { request = request.filter(Column("region") == r) }
            return try request
                .order(Column("published_at").desc)
                .limit(100)
                .fetchAll(db)
        }) ?? []
        var feedItems = results.map { $0.toFeedItem() }
        if !taxonomyNodeIDs.isEmpty {
            feedItems = feedItems.filter { item in
                taxonomyNodeIDs.contains(where: { nodeID in
                    TaxonomyStore.shared.isFeedInSubtree(feedURL: item.sourceURL, nodeID: nodeID)
                })
            }
        }
        return feedItems
    }
}
