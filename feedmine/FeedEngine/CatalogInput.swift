import Foundation

struct CatalogInputNode: Equatable, Sendable {
    let keyComponent: String
    let name: String
    let kind: CatalogNodeKind
    let language: String?

    init(name: String, kind: CatalogNodeKind, keyComponent: String? = nil, language: String? = nil) {
        self.name = name
        self.kind = kind
        self.keyComponent = keyComponent ?? CatalogIdentity.slug(name)
        self.language = language
    }
}

struct CatalogSourceOccurrence: Equatable, Sendable {
    let title: String
    let declaredURL: String
    let requestURL: String
    let mediaKind: MediaKind
    let language: String?
    let nodePath: [CatalogInputNode]
    let opmlFile: String
    let sortOrder: Int
    let titleOverride: String?
    let languageOverride: String?
    let mediaKindOverride: MediaKind?
    let siteURL: String?
    let sourceDescription: String?
    let tags: [String]
    let nature: String?
    let activity: String?
    let latestItemAt: String?
    let qualityScore: Int?
    let defaultEnabled: Bool

    init(
        title: String,
        declaredURL: String,
        requestURL: String? = nil,
        mediaKind: MediaKind,
        language: String? = nil,
        nodePath: [CatalogInputNode],
        opmlFile: String,
        sortOrder: Int,
        titleOverride: String? = nil,
        languageOverride: String? = nil,
        mediaKindOverride: MediaKind? = nil,
        siteURL: String? = nil,
        sourceDescription: String? = nil,
        tags: [String] = [],
        nature: String? = nil,
        activity: String? = nil,
        latestItemAt: String? = nil,
        qualityScore: Int? = nil,
        defaultEnabled: Bool = true
    ) {
        self.title = title
        self.declaredURL = declaredURL
        self.requestURL = requestURL ?? declaredURL
        self.mediaKind = mediaKind
        self.language = language
        self.nodePath = nodePath
        self.opmlFile = opmlFile
        self.sortOrder = sortOrder
        self.titleOverride = titleOverride
        self.languageOverride = languageOverride
        self.mediaKindOverride = mediaKindOverride
        self.siteURL = siteURL
        self.sourceDescription = sourceDescription
        self.tags = tags
        self.nature = nature
        self.activity = activity
        self.latestItemAt = latestItemAt
        self.qualityScore = qualityScore
        self.defaultEnabled = defaultEnabled
    }

    static func legacySource(_ source: FeedSource, sortOrder: Int) -> CatalogSourceOccurrence {
        CatalogSourceOccurrence(
            title: source.title,
            declaredURL: source.url,
            mediaKind: source.mediaKind,
            language: source.language,
            nodePath: Self.nodePath(region: source.region, category: source.category, language: source.language),
            opmlFile: "legacy://OPMLParser.parseAll",
            sortOrder: sortOrder,
            languageOverride: source.language,
            sourceDescription: source.sourceDescription,
            tags: source.tags,
            nature: source.nature,
            activity: source.activity,
            qualityScore: source.qualityScore,
            defaultEnabled: source.defaultEnabled
        )
    }

    static func nodePath(region: String, category: String, language: String?) -> [CatalogInputNode] {
        if region.hasPrefix("topic/") {
            let parts = region.components(separatedBy: "/").dropFirst()
            var nodes = parts.enumerated().map { index, part in
                CatalogInputNode(
                    name: displayName(fromSlug: part),
                    kind: index == 0 ? .topic : .subcategory,
                    keyComponent: part,
                    language: language
                )
            }
            appendCategoryIfNeeded(category, language: language, to: &nodes)
            return nodes
        }

        if region == "global" {
            return [
                CatalogInputNode(name: "Global", kind: .topic, keyComponent: "global"),
                CatalogInputNode(name: category, kind: .subcategory, language: language),
            ]
        }

        if region.hasPrefix("countries/") {
            var nodes = [
                CatalogInputNode(name: "Countries", kind: .topic, keyComponent: "countries"),
            ]
            let parts = region.components(separatedBy: "/").dropFirst()
            for (index, part) in parts.enumerated() {
                nodes.append(CatalogInputNode(
                    name: displayName(fromSlug: part),
                    kind: index == 0 ? .country : .region,
                    keyComponent: part,
                    language: language
                ))
            }
            appendCategoryIfNeeded(category, language: language, to: &nodes)
            return nodes
        }

        return [
            CatalogInputNode(name: displayName(fromSlug: region), kind: .topic, keyComponent: region),
            CatalogInputNode(name: category, kind: .subcategory, language: language),
        ]
    }

    private static func appendCategoryIfNeeded(
        _ category: String,
        language: String?,
        to nodes: inout [CatalogInputNode]
    ) {
        let key = CatalogIdentity.slug(category)
        if nodes.last?.keyComponent != key {
            nodes.append(CatalogInputNode(name: category, kind: .subcategory, keyComponent: key, language: language))
        }
    }

    private static func displayName(fromSlug slug: String) -> String {
        slug
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }
}
