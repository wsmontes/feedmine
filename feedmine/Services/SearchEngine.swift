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

    /// Get all active persistent searches (bookmark lists with search_active = 1).
    func activeSearches() async throws -> [ActiveSearch] {
        let records: [BookmarkListRecord] = try await db.read { db in
            try BookmarkListRecord
                .filter(Column("search_active") == 1)
                .fetchAll(db)
        }
        return records.map { r in
            ActiveSearch(
                id: r.id!, name: r.name,
                searchQuery: r.searchQuery ?? "",
                region: r.searchRegion, category: r.searchCategory
            )
        }
    }

    /// Match newly fetched items against all active persistent searches and
    /// auto-bookmark matches. `regionResolver` maps sourceURL → region.
    func matchPersistentSearches(_ items: [FeedItem], regionResolver: (String) -> String) async {
        let searches: [BookmarkListRecord] = (try? await db.read { db in
            try BookmarkListRecord
                .filter(Column("search_active") == 1)
                .fetchAll(db)
        }) ?? []
        guard !searches.isEmpty else { return }

        for search in searches {
            guard let query = search.searchQuery else { continue }
            guard let pattern = FTS5Pattern(matchingAllTokensIn: query) else { continue }
            let candidateIDs = items.filter { item in
                if let region = search.searchRegion,
                   region != regionResolver(item.sourceURL) { return false }
                if let cat = search.searchCategory, cat != item.category { return false }
                return true
            }.map(\.id)
            guard !candidateIDs.isEmpty else { continue }

            let matchedIDs: [String] = (try? await db.read { db in
                try FeedItemRecord
                    .filter(candidateIDs.contains(Column("id")))
                    .matching(pattern)
                    .fetchAll(db)
                    .map(\.id)
            }) ?? []
            guard !matchedIDs.isEmpty else { continue }

            let now = Int(Date().timeIntervalSince1970)
            try? await db.write { db in
                for id in matchedIDs {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO bookmark_item (list_id, item_id, added_at)
                        VALUES (?, ?, ?)
                    """, arguments: [search.id!, id, now])
                }
            }
        }
    }
}
