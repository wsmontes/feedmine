import Foundation
import GRDB

struct SourceSearchResult: Equatable, Identifiable, Sendable {
    let id: Int64
    let title: String
    let feedURL: String
    let siteURL: String?
    let displayHost: String?
    let mediaKind: MediaKind
    let language: String?
    let sourceDescription: String?
    let tags: [String]
    let nature: String?
    let activity: String?
    let qualityScore: Int?
    let defaultEnabled: Bool

    var sourceReference: SourceReference {
        SourceReference(
            title: title,
            feedURL: feedURL,
            siteURL: siteURL,
            displayHost: displayHost,
            mediaKind: mediaKind,
            language: language,
            sourceDescription: sourceDescription,
            tags: tags,
            nature: nature,
            activity: activity,
            qualityScore: qualityScore,
            defaultEnabled: defaultEnabled
        )
    }
}

struct UnifiedSearchResults: Equatable, Sendable {
    var sources: [SourceSearchResult]
    var savedItems: [FeedItem]
    var localItems: [FeedItem]

    static let empty = UnifiedSearchResults(sources: [], savedItems: [], localItems: [])
    var isEmpty: Bool { sources.isEmpty && savedItems.isEmpty && localItems.isEmpty }
}

@MainActor
final class SearchEngine {
    let db: DatabaseQueue
    private let userDB: DatabaseQueue?
    private var catalogDB: DatabaseQueue?

    init(db: DatabaseQueue, userDB: DatabaseQueue? = nil, catalogURL: URL? = nil) {
        self.db = db
        self.userDB = userDB
        if let catalogURL {
            var configuration = Configuration()
            configuration.readonly = true
            self.catalogDB = try? DatabaseQueue(path: catalogURL.path, configuration: configuration)
        } else {
            self.catalogDB = nil
        }
    }

    /// Switch source search to a newly activated local catalog. Existing
    /// searches retain their queue until they finish; subsequent searches use
    /// the new snapshot.
    func replaceCatalog(at catalogURL: URL?) {
        guard let catalogURL else {
            catalogDB = nil
            return
        }
        var configuration = Configuration()
        configuration.readonly = true
        catalogDB = try? DatabaseQueue(path: catalogURL.path, configuration: configuration)
    }

    /// Search is intentionally tiered by user value:
    /// 1. content-analyzed sources and their tags;
    /// 2. items explicitly saved by the user;
    /// 3. everything still present in the local content database, including
    ///    previously opened items, without the old 30-day search cutoff.
    func unifiedSearch(_ query: String) async -> UnifiedSearchResults {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return .empty
        }

        let sourceResults = await searchSources(text)
        let savedIDs = await loadBookmarkedIDs()
        let savedRecords = await searchSavedRecords(text, itemIDs: savedIDs)
        let contentRecords = await searchLocalRecords(text)
        let localRecords = contentRecords.filter { !savedIDs.contains($0.id) }
        return UnifiedSearchResults(
            sources: sourceResults,
            savedItems: savedRecords.prefix(40).map {
                $0.toFeedItem().stamped(
                    readItemIDs: $0.isRead ? [$0.id] : [],
                    bookmarkItemIDs: [$0.id]
                )
            },
            localItems: localRecords.prefix(100).map {
                $0.toFeedItem().stamped(
                    readItemIDs: $0.isRead ? [$0.id] : [],
                    bookmarkItemIDs: []
                )
            }
        )
    }

    private func searchSavedRecords(_ query: String, itemIDs: Set<String>) async -> [FeedItemRecord] {
        guard !itemIDs.isEmpty else { return [] }
        let match = Self.ftsQuery(for: query)
        let allIDs = Array(itemIDs)
        return (try? await db.read { db in
            var matches: [FeedItemRecord] = []
            // Stay below SQLite's bound-variable limit even for large bookmark libraries.
            for start in stride(from: 0, to: allIDs.count, by: 400) {
                let chunk = Array(allIDs[start..<min(start + 400, allIDs.count)])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                matches.append(contentsOf: try FeedItemRecord.fetchAll(db, sql: """
                    SELECT fi.*
                    FROM feed_item fi
                    JOIN feed_item_fts ON feed_item_fts.rowid = fi.rowid
                    WHERE feed_item_fts MATCH ? AND fi.id IN (\(placeholders))
                    ORDER BY fi.published_at DESC
                    LIMIT 40
                    """, arguments: StatementArguments([match] + chunk)))
            }
            return Array(matches.sorted { $0.publishedAt > $1.publishedAt }.prefix(40))
        }) ?? []
    }

    private func loadBookmarkedIDs() async -> Set<String> {
        guard let userDB else { return [] }
        return (try? await userDB.read { db in
            try Set(String.fetchAll(db, sql: "SELECT DISTINCT item_id FROM bookmark_item"))
        }) ?? []
    }

    private func searchLocalRecords(_ query: String) async -> [FeedItemRecord] {
        let match = Self.ftsQuery(for: query)
        let records: [FeedItemRecord] = (try? await db.read { db in
            try FeedItemRecord.fetchAll(db, sql: """
                SELECT fi.*
                FROM feed_item fi
                JOIN feed_item_fts ON feed_item_fts.rowid = fi.rowid
                WHERE feed_item_fts MATCH ?
                ORDER BY fi.published_at DESC
                LIMIT 180
                """, arguments: [match])
        }) ?? []
        return records.sorted { lhs, rhs in
            let lhsHistory = lhs.openedAt != nil || lhs.isRead
            let rhsHistory = rhs.openedAt != nil || rhs.isRead
            if lhsHistory != rhsHistory { return lhsHistory }
            return lhs.publishedAt > rhs.publishedAt
        }
    }

    private func searchSources(_ query: String) async -> [SourceSearchResult] {
        guard let catalogDB else { return [] }
        let match = Self.ftsQuery(for: query)
        return (try? await catalogDB.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    s.id, s.title, s.request_url, s.site_url, s.display_host,
                    s.media_kind, s.language, s.description, s.tags, s.nature,
                    s.activity, s.quality_score, s.default_enabled
                FROM catalog_source_fts
                JOIN catalog_source s ON s.id = catalog_source_fts.rowid
                WHERE catalog_source_fts MATCH ?
                ORDER BY
                    bm25(catalog_source_fts, 9.0, 2.5, 6.0, 1.0, 1.0, 1.0, 3.0),
                    s.default_enabled DESC,
                    s.quality_score DESC,
                    s.title COLLATE NOCASE
                LIMIT 40
                """, arguments: [match])
            return rows.map { row in
                let rawTags: String? = row["tags"]
                let kindValue: String = row["media_kind"]
                let enabled: Int = row["default_enabled"] ?? 1
                return SourceSearchResult(
                    id: row["id"],
                    title: row["title"],
                    feedURL: row["request_url"],
                    siteURL: row["site_url"],
                    displayHost: row["display_host"],
                    mediaKind: MediaKind(rawValue: kindValue) ?? .text,
                    language: row["language"],
                    sourceDescription: row["description"],
                    tags: (rawTags ?? "").split(separator: ",").map(String.init),
                    nature: row["nature"],
                    activity: row["activity"],
                    qualityScore: row["quality_score"],
                    defaultEnabled: enabled != 0
                )
            }
        }) ?? []
    }

    private static func ftsQuery(for text: String) -> String {
        let terms = text
            .split(whereSeparator: \.isWhitespace)
            .map { term in
                "\"\(String(term).replacingOccurrences(of: "\"", with: "\"\""))\""
            }
        return terms.isEmpty ? "\"\"" : terms.joined(separator: " ")
    }

    // Legacy entry points remain for persistent-search callers and tests.
    func search(_ query: String, region: String?, category: String?) async -> [FeedItem] {
        let unified = await unifiedSearch(query)
        let results = unified.savedItems + unified.localItems
        return results.filter { item in
            (region == nil || item.region == region) && (category == nil || item.category == category)
        }
    }

    func search(_ query: String, region: String?, taxonomyNodeIDs: Set<String>) async -> [FeedItem] {
        let unified = await unifiedSearch(query)
        let results = unified.savedItems + unified.localItems
        return results.filter { item in
            guard region == nil || item.region == region else { return false }
            guard !taxonomyNodeIDs.isEmpty else { return true }
            return taxonomyNodeIDs.contains { nodeID in
                TaxonomyStore.shared.isFeedInSubtree(feedURL: item.sourceURL, nodeID: nodeID)
            }
        }
    }
}
