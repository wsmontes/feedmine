import Foundation
import GRDB

/// Owns `user.sqlite` — user-owned state that survives catalog rebuilds.
///
/// Separates bookmark identity (what is bookmarked) from the content database
/// where `feed_item` rows live. Bookmark queries that need `FeedItem` joins
/// fetch IDs from here and hydrate from `feedmine.sqlite` separately.
///
/// Schema version is tracked via GRDB migrator so the database can evolve
/// independently of `feedmine.sqlite`.
@MainActor
final class UserStateStore {
    let db: DatabaseQueue

    private static var dbURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("user.sqlite")
    }

    // MARK: - Init

    init(inMemory: Bool = false) throws {
        if inMemory {
            db = try DatabaseQueue(configuration: UserStateStore.dbConfig)
        } else {
            db = try DatabaseQueue(path: Self.dbURL.path, configuration: UserStateStore.dbConfig)
        }
        try UserStateStore.migrate(db)
    }

    // MARK: - Config

    private static var dbConfig: Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        return config
    }

    // MARK: - Schema

    private static func migrate(_ db: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_bookmarks") { db in
            try db.create(table: "bookmark_list") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("created_at", .integer).notNull()
                t.column("is_default", .integer).notNull().defaults(to: 0)
                t.column("search_query", .text)
                t.column("search_region", .text)
                t.column("search_category", .text)
                t.column("search_active", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "bookmark_item") { t in
                t.column("list_id", .integer).notNull()
                    .references("bookmark_list", onDelete: .cascade)
                t.column("item_id", .text).notNull()
                t.column("added_at", .integer).notNull()
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.primaryKey(["list_id", "item_id"])
            }

            try db.create(index: "idx_user_bookmark_item_list",
                          on: "bookmark_item", columns: ["list_id", "sort_order"])
            try db.create(index: "idx_user_bookmark_item_item",
                          on: "bookmark_item", columns: ["item_id"])

            // Default "Favorites" list
            try db.execute(sql: """
                INSERT INTO bookmark_list (name, sort_order, created_at, is_default)
                VALUES ('Favorites', 0, \(Int(Date().timeIntervalSince1970)), 1)
            """)
        }

        try migrator.migrate(db)
    }

    // MARK: - Legacy Migration

    /// Copy bookmark data from `feedmine.sqlite` into `user.sqlite`.
    /// Idempotent — skips rows whose primary key already exists.
    func migrateFromLegacy(legacyDB: DatabaseQueue) async throws {
        try await legacyDB.read { legacy in
            let lists = try BookmarkListRecord.fetchAll(legacy)
            let items = try BookmarkItemRecord.fetchAll(legacy)

            try self.db.write { user in
                for list in lists {
                    try user.execute(sql: """
                        INSERT OR IGNORE INTO bookmark_list
                            (id, name, sort_order, created_at, is_default,
                             search_query, search_region, search_category, search_active)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        list.id, list.name, list.sortOrder, list.createdAt,
                        list.isDefault, list.searchQuery, list.searchRegion,
                        list.searchCategory, list.searchActive,
                    ])
                }
                for item in items {
                    // Skip items where list_id doesn't exist (orphaned reference)
                    let listExists = try Int.fetchOne(user,
                        sql: "SELECT 1 FROM bookmark_list WHERE id = ? LIMIT 1",
                        arguments: [item.listId]) != nil
                    guard listExists else { continue }
                    try user.execute(sql: """
                        INSERT OR IGNORE INTO bookmark_item
                            (list_id, item_id, added_at, sort_order)
                        VALUES (?, ?, ?, ?)
                    """, arguments: [item.listId, item.itemId, item.addedAt, item.sortOrder])
                }
            }
        }
    }

    /// True if the legacy migration has already been performed.
    func needsLegacyMigration(legacyDB: DatabaseQueue) throws -> Bool {
        let userCount = try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bookmark_list")
        } ?? 0
        // > 1 because the default "Favorites" list is always created at init
        let legacyCount = try legacyDB.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bookmark_list")
        } ?? 0
        return userCount <= 1 && legacyCount > 1
    }

    // MARK: - Convenience

    /// All bookmarked item IDs. Used by FeedStore to stamp `isBookmarked` on
    /// visible items so bookmark indicators render correctly.
    func allBookmarkedItemIDs() -> Set<String> {
        (try? db.read { db in
            try Set(String.fetchAll(db, sql: "SELECT DISTINCT item_id FROM bookmark_item"))
        }) ?? []
    }
}
