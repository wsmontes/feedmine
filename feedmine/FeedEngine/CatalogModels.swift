import Foundation

// MARK: - FeedEngine Catalog Models
//
// Lightweight Sendable structs for catalog browsing and search.
// SourceSummary carries enough editorial context for a useful search row.
// SourceDetails is loaded on demand when the user taps a source.

/// Lightweight summary for catalog listing — one per source in a page.
/// Does NOT include the full request URL or all placements; use
/// `sourceDetails(id:)` to load those on demand.
struct SourceSummary: Equatable, Identifiable, Sendable {
    let id: SourceID
    let title: String
    /// Display-only host for presentation/search.
    let displayHost: String?
    let mediaKind: MediaKind
    let language: String?
    let sourceDescription: String?
    let tags: [String]
    let nature: String?
    let activity: String?
    let qualityScore: Int?
    let defaultEnabled: Bool

    init(
        id: SourceID,
        title: String,
        displayHost: String?,
        mediaKind: MediaKind,
        language: String?,
        sourceDescription: String? = nil,
        tags: [String] = [],
        nature: String? = nil,
        activity: String? = nil,
        qualityScore: Int? = nil,
        defaultEnabled: Bool = true
    ) {
        self.id = id
        self.title = title
        self.displayHost = displayHost
        self.mediaKind = mediaKind
        self.language = language
        self.sourceDescription = sourceDescription
        self.tags = tags
        self.nature = nature
        self.activity = activity
        self.qualityScore = qualityScore
        self.defaultEnabled = defaultEnabled
    }
}

/// Full metadata for a single source, loaded on demand.
struct SourceDetails: Equatable, Identifiable, Sendable {
    let id: SourceID
    let title: String
    let declaredURL: URL
    let requestURL: URL
    let mediaKind: MediaKind
    let language: String?
    let siteURL: URL?
    let sourceDescription: String?
    let tags: [String]
    let nature: String?
    let activity: String?
    let latestItemAt: String?
    let qualityScore: Int?
    let defaultEnabled: Bool
    /// Every editorial placement of this source across OPML files.
    let placements: [SourcePlacementSummary]

    init(
        id: SourceID,
        title: String,
        declaredURL: URL,
        requestURL: URL,
        mediaKind: MediaKind,
        language: String?,
        siteURL: URL? = nil,
        sourceDescription: String? = nil,
        tags: [String] = [],
        nature: String? = nil,
        activity: String? = nil,
        latestItemAt: String? = nil,
        qualityScore: Int? = nil,
        defaultEnabled: Bool = true,
        placements: [SourcePlacementSummary]
    ) {
        self.id = id
        self.title = title
        self.declaredURL = declaredURL
        self.requestURL = requestURL
        self.mediaKind = mediaKind
        self.language = language
        self.siteURL = siteURL
        self.sourceDescription = sourceDescription
        self.tags = tags
        self.nature = nature
        self.activity = activity
        self.latestItemAt = latestItemAt
        self.qualityScore = qualityScore
        self.defaultEnabled = defaultEnabled
        self.placements = placements
    }
}

/// Summary of one editorial placement — which OPML file, which node,
/// and any per-placement metadata overrides.
struct SourcePlacementSummary: Equatable, Identifiable, Sendable {
    let id: Int64
    let nodeID: CatalogNodeID
    let nodeName: String
    let opmlFile: String
    let sortOrder: Int
    let titleOverride: String?
    let languageOverride: String?
    let mediaKindOverride: MediaKind?
}

/// Summary of a catalog taxonomy node for browsing.
struct CatalogNodeSummary: Equatable, Identifiable, Sendable {
    let id: CatalogNodeID
    let name: String
    let kind: CatalogNodeKind
    /// Total feed sources in this subtree.
    let sourceCount: Int
    /// Direct child nodes (not feeds).
    let childCount: Int
    /// ISO 639-1 language code if this node has an explicit language.
    let language: String?
}

/// Lightweight timeline row returned by the new engine.
///
/// This intentionally does not reuse legacy `FeedItem`, whose shape is tied
/// to the current UI/reservoir pipeline.
struct TimelineItemSummary: Equatable, Identifiable, Sendable {
    let id: String
    let sourceID: SourceID?
    let sourceTitle: String
    let title: String
    let excerpt: String
    let url: URL
    let publishedAt: Date
    let mediaKind: MediaKind
    let imageURL: URL?
    let audioURL: URL?
    let language: String?
}

/// Query used by UI catalog browsing. Passing `nil` browses from the root.
struct CatalogBrowseQuery: Equatable, Sendable {
    let parentID: CatalogNodeID?
    let includeSources: Bool
    let language: String?

    init(
        parentID: CatalogNodeID? = nil,
        includeSources: Bool = true,
        language: String? = nil
    ) {
        self.parentID = parentID
        self.includeSources = includeSources
        self.language = language
    }
}

/// Query used by catalog full-text search.
struct CatalogSearchQuery: Equatable, Sendable {
    let text: String
    let filters: CatalogSearchFilters

    init(text: String, filters: CatalogSearchFilters = CatalogSearchFilters()) {
        self.text = text
        self.filters = filters
    }
}

/// Query used by timeline loading.
///
/// Broad source scopes are resolved by repositories, not expanded into large
/// Swift collections at the UI boundary.
struct ContentQuery: Equatable, Sendable {
    let scope: SourceScope
    let mediaKinds: [MediaKind]
    let languages: [String]
    let searchText: String?
    let unreadOnly: Bool
    let since: Date?

    init(
        scope: SourceScope = .allEnabled,
        mediaKinds: [MediaKind] = [],
        languages: [String] = [],
        searchText: String? = nil,
        unreadOnly: Bool = true,
        since: Date? = nil
    ) {
        self.scope = scope
        self.mediaKinds = mediaKinds
        self.languages = languages
        self.searchText = searchText
        self.unreadOnly = unreadOnly
        self.since = since
    }
}
