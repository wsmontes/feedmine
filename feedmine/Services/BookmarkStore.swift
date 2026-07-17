import Foundation
import GRDB

@MainActor
final class BookmarkStore {
    /// Bookmark identity database (user.sqlite). Owns `bookmark_list` and
    /// `bookmark_item` — the canonical source for "what is bookmarked."
    let userDB: DatabaseQueue
    /// Content database (feedmine.sqlite). Owns `feed_item` — used only for
    /// queries that join bookmark identity with feed content.
    let contentDB: DatabaseQueue
    private var _defaultListID: Int64?

    init(userDB: DatabaseQueue, contentDB: DatabaseQueue) {
        self.userDB = userDB
        self.contentDB = contentDB
    }

    // MARK: - Default List

    func defaultListID() -> Int64 {
        if let cached = _defaultListID { return cached }
        let id: Int64 = (try? userDB.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM bookmark_list WHERE is_default = 1 LIMIT 1")
        }) ?? 1
        _defaultListID = id
        return id
    }

    // MARK: - CRUD

    func allBookmarkLists() async throws -> [BookmarkList] {
        try await userDB.read { db in
            let records = try BookmarkListRecord.order(Column("sort_order")).fetchAll(db)
            return try records.map { r in
                let count = try BookmarkItemRecord.filter(Column("list_id") == r.id!).fetchCount(db)
                return BookmarkList(
                    id: r.id!, name: r.name, sortOrder: r.sortOrder,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(r.createdAt)),
                    isDefault: r.isDefault,
                    searchQuery: r.searchQuery, searchRegion: r.searchRegion,
                    searchCategory: r.searchCategory, searchActive: r.searchActive,
                    itemCount: count
                )
            }
        }
    }

    func createBookmarkList(name: String, searchQuery: String? = nil,
                            region: String? = nil, category: String? = nil) async throws -> Int64 {
        try await userDB.write { db in
            try db.execute(sql: """
                INSERT INTO bookmark_list (name, sort_order, created_at, is_default,
                    search_query, search_region, search_category, search_active)
                VALUES (?, 0, ?, 0, ?, ?, ?, ?)
            """, arguments: [
                name,
                Int(Date().timeIntervalSince1970),
                searchQuery,
                region,
                category,
                searchQuery != nil
            ])
            return db.lastInsertedRowID
        }
    }

    func toggleBookmark(itemID: String, listID: Int64? = nil) async throws {
        let targetListID = listID ?? defaultListID()
        try await userDB.write { db in
            let existing = try BookmarkItemRecord
                .filter(Column("list_id") == targetListID && Column("item_id") == itemID)
                .fetchCount(db)
            if existing > 0 {
                try db.execute(sql: "DELETE FROM bookmark_item WHERE list_id = ? AND item_id = ?",
                              arguments: [targetListID, itemID])
            } else {
                try db.execute(sql: """
                    INSERT INTO bookmark_item (list_id, item_id, added_at) VALUES (?, ?, ?)
                """, arguments: [targetListID, itemID, Int(Date().timeIntervalSince1970)])
            }
        }
    }

    func isBookmarked(itemID: String, listID: Int64? = nil) async throws -> Bool {
        let targetListID = listID ?? defaultListID()
        return try await userDB.read { db in
            try BookmarkItemRecord
                .filter(Column("list_id") == targetListID && Column("item_id") == itemID)
                .fetchCount(db) > 0
        }
    }

    /// All bookmarked item IDs across every list. Used by FeedStore to stamp
    /// `isBookmarked` on visible items so bookmark indicators render correctly.
    func allBookmarkedItemIDs() -> Set<String> {
        (try? userDB.read { db in
            try Set(String.fetchAll(db, sql: "SELECT DISTINCT item_id FROM bookmark_item"))
        }) ?? []
    }

    func bookmarkedItems(listID: Int64? = nil) async throws -> [FeedItem] {
        let targetListID = listID ?? defaultListID()
        // Fetch item IDs from user.sqlite, then hydrate from content (feedmine.sqlite)
        let itemIDs: [String] = try await userDB.read { db in
            try String.fetchAll(db, sql: """
                SELECT item_id FROM bookmark_item WHERE list_id = ? ORDER BY sort_order
            """, arguments: [targetListID])
        }
        guard !itemIDs.isEmpty else { return [] }
        return try await contentDB.read { db in
            try FeedItemRecord
                .filter(itemIDs.contains(Column("id")))
                .order(Column("published_at").desc)
                .fetchAll(db)
                .map { $0.toFeedItem() }
        }
    }

    func renameBookmarkList(_ id: Int64, name: String) async throws {
        try await userDB.write { db in
            try db.execute(sql: "UPDATE bookmark_list SET name = ? WHERE id = ?", arguments: [name, id])
        }
    }

    func reorderBookmarkList(_ id: Int64, sortOrder: Int) async throws {
        try await userDB.write { db in
            try db.execute(sql: "UPDATE bookmark_list SET sort_order = ? WHERE id = ?",
                          arguments: [sortOrder, id])
        }
    }

    func deleteBookmarkList(_ id: Int64) async throws {
        try await userDB.write { db in
            let isDefault = try Bool.fetchOne(db, sql: "SELECT is_default FROM bookmark_list WHERE id = ?", arguments: [id]) ?? false
            guard !isDefault else { return }
            try db.execute(sql: "DELETE FROM bookmark_list WHERE id = ?", arguments: [id])
        }
    }

    func toggleSearchActive(listID: Int64) async throws {
        let wasActive: Bool = try await userDB.read { db in
            try Bool.fetchOne(db, sql: "SELECT search_active FROM bookmark_list WHERE id = ?", arguments: [listID]) ?? false
        }
        let newState = !wasActive
        try await userDB.write { db in
            try db.execute(sql: "UPDATE bookmark_list SET search_active = ? WHERE id = ?",
                          arguments: [newState, listID])
        }
        // If activating, retroactively match existing items in SQLite
        if newState {
            try await retroMatchSearch(listID: listID)
        }
    }

    func clearAllBookmarks() {
        Task {
            try await userDB.write { db in
                try db.execute(sql: "DELETE FROM bookmark_item")
            }
        }
    }

    // MARK: - Retro Match

    /// Retroactively add all existing items in SQLite that match a persistent search.
    func retroMatchSearch(listID: Int64) async throws {
        let search: BookmarkListRecord? = try await userDB.read { db in
            try BookmarkListRecord.fetchOne(db, key: listID)
        }
        guard let search, let query = search.searchQuery,
              let pattern = FTS5Pattern(matchingAllTokensIn: query) else { return }

        let cutoff = Int(Date().addingTimeInterval(-2592000).timeIntervalSince1970)
        let records: [FeedItemRecord] = try await contentDB.read { db in
            var request = FeedItemRecord
                .filter(Column("fetched_at") > cutoff)
                .matching(pattern)
            if let region = search.searchRegion {
                request = request.filter(Column("region") == region)
            }
            if let cat = search.searchCategory {
                request = request.filter(Column("category") == cat)
            }
            return try request.fetchAll(db)
        }

        guard !records.isEmpty else { return }
        let now = Int(Date().timeIntervalSince1970)
        try await userDB.write { db in
            for record in records {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO bookmark_item (list_id, item_id, added_at)
                    VALUES (?, ?, ?)
                """, arguments: [listID, record.id, now])
            }
        }
    }

    // MARK: - Composite Search Feed

    func compositeSearchFeed(regionResolver: (String) -> String) async throws -> [FeedItem] {
        let searches = try await activeSearches()
        guard !searches.isEmpty else { return [] }

        let cutoff = Int(Date().addingTimeInterval(-2592000).timeIntervalSince1970)
        var scored: [(FeedItem, Int)] = []
        for search in searches {
            guard let pattern = FTS5Pattern(matchingAllTokensIn: search.searchQuery) else { continue }
            let records: [FeedItemRecord] = try await contentDB.read { db in
                var request = FeedItemRecord
                    .filter(Column("fetched_at") > cutoff)
                    .matching(pattern)
                if let r = search.region {
                    request = request.filter(Column("region") == r)
                }
                if let c = search.category {
                    request = request.filter(Column("category") == c)
                }
                return try request.limit(50).fetchAll(db)
            }
            for record in records {
                let item = record.toFeedItem()
                let score = search.matches(item, itemRegion: regionResolver(item.sourceURL))
                scored.append((item, score + 1))
            }
        }

        // Deduplicate and sum scores
        var bestScore: [String: (FeedItem, Int)] = [:]
        for (item, score) in scored {
            if let existing = bestScore[item.id] {
                bestScore[item.id] = (item, existing.1 + score)
            } else {
                bestScore[item.id] = (item, score)
            }
        }

        let sorted = bestScore.values.sorted { a, b in
            a.1 > b.1
        }
        return sorted.map { $0.0 }
    }

    // MARK: - Active Searches

    func activeSearches() async throws -> [ActiveSearch] {
        let records: [BookmarkListRecord] = try await userDB.read { db in
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

    /// Match newly fetched items against all active persistent searches and auto-bookmark matches.
    func matchPersistentSearches(_ items: [FeedItem], regionResolver: (String) -> String) async {
        let searches: [BookmarkListRecord] = (try? await userDB.read { db in
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

            let matchedIDs: [String] = (try? await contentDB.read { db in
                try FeedItemRecord
                    .filter(candidateIDs.contains(Column("id")))
                    .matching(pattern)
                    .fetchAll(db)
                    .map(\.id)
            }) ?? []
            guard !matchedIDs.isEmpty else { continue }

            let now = Int(Date().timeIntervalSince1970)
            try? await userDB.write { db in
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
