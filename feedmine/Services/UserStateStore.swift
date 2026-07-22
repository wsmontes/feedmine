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

        migrator.registerMigration("v2_source_collections") { db in
            try db.create(table: "source_collection") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("created_at", .integer).notNull()
            }

            try db.create(table: "source_collection_member") { t in
                t.column("collection_id", .integer).notNull()
                    .references("source_collection", onDelete: .cascade)
                t.column("source_url", .text).notNull()
                t.column("title_snapshot", .text).notNull()
                t.column("media_kind", .text).notNull().defaults(to: MediaKind.text.rawValue)
                t.column("added_at", .integer).notNull()
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.primaryKey(["collection_id", "source_url"])
            }
            try db.create(index: "idx_source_collection_order",
                          on: "source_collection", columns: ["sort_order", "created_at"])
            try db.create(index: "idx_source_collection_member_order",
                          on: "source_collection_member", columns: ["collection_id", "sort_order"])
            try db.create(index: "idx_source_collection_member_source",
                          on: "source_collection_member", columns: ["source_url"])
        }

        migrator.registerMigration("v3_user_metadata") { db in
            try db.create(table: "user_metadata") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
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

// MARK: - Personal source collections

struct SourceCollection: Identifiable, Equatable, Sendable {
    let id: Int64
    let name: String
    let sortOrder: Int
    let createdAt: Date
    let memberCount: Int
}

struct SourceCollectionMember: Identifiable, Equatable, Sendable {
    var id: String { sourceURL }
    let sourceURL: String
    let title: String
    let mediaKind: MediaKind
    let addedAt: Date
    let sortOrder: Int
}

/// Many-to-many personal playlists of sources. Membership never mutates a
/// FeedSource's OPML category/region and deleting a collection never deletes a
/// source from the catalog.
@MainActor
final class SourceCollectionStore {
    private static let importedCategoryMigrationKey = "imported_categories_to_collections_v1"
    private let db: DatabaseQueue

    init(db: DatabaseQueue) {
        self.db = db
    }

    func allCollections() async throws -> [SourceCollection] {
        try await db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT c.id, c.name, c.sort_order, c.created_at,
                       COUNT(m.source_url) AS member_count
                FROM source_collection c
                LEFT JOIN source_collection_member m ON m.collection_id = c.id
                GROUP BY c.id
                ORDER BY c.sort_order, c.created_at, c.id
                """).map { row in
                    SourceCollection(
                        id: row["id"],
                        name: row["name"],
                        sortOrder: row["sort_order"],
                        createdAt: Date(timeIntervalSince1970: TimeInterval(row["created_at"] as Int)),
                        memberCount: row["member_count"]
                    )
                }
        }
    }

    @discardableResult
    func createCollection(name: String) async throws -> Int64 {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw SourceCollectionError.emptyName }
        return try await db.write { db in
            let order = (try Int.fetchOne(db,
                sql: "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM source_collection")) ?? 0
            try db.execute(sql: """
                INSERT INTO source_collection (name, sort_order, created_at)
                VALUES (?, ?, ?)
                """, arguments: [cleanName, order, Int(Date().timeIntervalSince1970)])
            return db.lastInsertedRowID
        }
    }

    func renameCollection(id: Int64, name: String) async throws {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw SourceCollectionError.emptyName }
        try await db.write { db in
            try db.execute(sql: "UPDATE source_collection SET name = ? WHERE id = ?",
                           arguments: [cleanName, id])
        }
    }

    func deleteCollection(id: Int64) async throws {
        try await db.write { db in
            try db.execute(sql: "DELETE FROM source_collection WHERE id = ?", arguments: [id])
        }
    }

    func reorderCollections(ids: [Int64]) async throws {
        try await db.write { db in
            for (index, id) in ids.enumerated() {
                try db.execute(sql: "UPDATE source_collection SET sort_order = ? WHERE id = ?",
                               arguments: [index, id])
            }
        }
    }

    func members(collectionID: Int64) async throws -> [SourceCollectionMember] {
        try await db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT source_url, title_snapshot, media_kind, added_at, sort_order
                FROM source_collection_member
                WHERE collection_id = ?
                ORDER BY sort_order, added_at, source_url
                """, arguments: [collectionID]).map { row in
                    let rawKind: String = row["media_kind"]
                    return SourceCollectionMember(
                        sourceURL: row["source_url"],
                        title: row["title_snapshot"],
                        mediaKind: MediaKind(rawValue: rawKind) ?? .text,
                        addedAt: Date(timeIntervalSince1970: TimeInterval(row["added_at"] as Int)),
                        sortOrder: row["sort_order"]
                    )
                }
        }
    }

    func add(_ source: SourceReference, to collectionID: Int64) async throws {
        try await add([source], to: collectionID)
    }

    func add(_ sources: [SourceReference], to collectionID: Int64) async throws {
        guard !sources.isEmpty else { return }
        try await db.write { db in
            var order = (try Int.fetchOne(db, sql: """
                SELECT COALESCE(MAX(sort_order), -1) + 1
                FROM source_collection_member WHERE collection_id = ?
                """, arguments: [collectionID])) ?? 0
            for source in sources {
                try db.execute(sql: """
                    INSERT INTO source_collection_member
                        (collection_id, source_url, title_snapshot, media_kind, added_at, sort_order)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(collection_id, source_url) DO UPDATE SET
                        title_snapshot = excluded.title_snapshot,
                        media_kind = excluded.media_kind
                    """, arguments: [
                        collectionID, OPMLParser.normalizeURL(source.feedURL), source.title,
                        source.mediaKind.rawValue, Int(Date().timeIntervalSince1970), order,
                    ])
                if db.changesCount > 0 { order += 1 }
            }
        }
    }

    /// Repairs destinations created by the old Add Feed screen. That screen
    /// stored its picker value in FeedSource.category instead of creating a
    /// personal collection, leaving imported sources filed under invisible
    /// pseudo-collections. Run once after imported_sources.json is restored.
    func migrateImportedCategoriesToCollections(_ importedSources: [FeedSource]) async throws -> Int {
        let migrationKey = Self.importedCategoryMigrationKey
        return try await db.write { db in
            let completed = try String.fetchOne(
                db,
                sql: "SELECT value FROM user_metadata WHERE key = ?",
                arguments: [migrationKey]
            ) == "1"
            guard !completed else { return 0 }

            let grouped = Dictionary(grouping: importedSources) { source in
                let name = source.category.trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? "Imported" : name
            }
            var migratedCount = 0

            for name in grouped.keys.sorted() {
                let collectionID: Int64
                if let existingID = try Int64.fetchOne(
                    db,
                    sql: "SELECT id FROM source_collection WHERE name = ? COLLATE NOCASE ORDER BY id LIMIT 1",
                    arguments: [name]
                ) {
                    collectionID = existingID
                } else {
                    let collectionOrder = (try Int.fetchOne(
                        db,
                        sql: "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM source_collection"
                    )) ?? 0
                    try db.execute(sql: """
                        INSERT INTO source_collection (name, sort_order, created_at)
                        VALUES (?, ?, ?)
                        """, arguments: [name, collectionOrder, Int(Date().timeIntervalSince1970)])
                    collectionID = db.lastInsertedRowID
                }

                var memberOrder = (try Int.fetchOne(db, sql: """
                    SELECT COALESCE(MAX(sort_order), -1) + 1
                    FROM source_collection_member WHERE collection_id = ?
                    """, arguments: [collectionID])) ?? 0
                for source in grouped[name] ?? [] {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO source_collection_member
                            (collection_id, source_url, title_snapshot, media_kind, added_at, sort_order)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """, arguments: [
                            collectionID, OPMLParser.normalizeURL(source.url), source.title,
                            source.mediaKind.rawValue, Int(Date().timeIntervalSince1970), memberOrder,
                        ])
                    if db.changesCount > 0 {
                        migratedCount += 1
                        memberOrder += 1
                    }
                }
            }

            try db.execute(sql: """
                INSERT INTO user_metadata (key, value) VALUES (?, '1')
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """, arguments: [migrationKey])
            return migratedCount
        }
    }

    func remove(sourceURL: String, from collectionID: Int64) async throws {
        try await db.write { db in
            try db.execute(sql: """
                DELETE FROM source_collection_member
                WHERE collection_id = ? AND source_url = ?
                """, arguments: [collectionID, OPMLParser.normalizeURL(sourceURL)])
        }
    }

    func reorderMembers(collectionID: Int64, sourceURLs: [String]) async throws {
        try await db.write { db in
            for (index, sourceURL) in sourceURLs.enumerated() {
                try db.execute(sql: """
                    UPDATE source_collection_member SET sort_order = ?
                    WHERE collection_id = ? AND source_url = ?
                    """, arguments: [index, collectionID, OPMLParser.normalizeURL(sourceURL)])
            }
        }
    }

    func collectionIDs(containing sourceURL: String) async throws -> Set<Int64> {
        try await db.read { db in
            try Set(Int64.fetchAll(db, sql: """
                SELECT collection_id FROM source_collection_member WHERE source_url = ?
                """, arguments: [OPMLParser.normalizeURL(sourceURL)]))
        }
    }
}

enum SourceCollectionError: LocalizedError {
    case emptyName

    var errorDescription: String? {
        switch self {
        case .emptyName: return "Collection name cannot be empty."
        }
    }
}
