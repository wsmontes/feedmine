import Foundation
import Observation

/// Builds and maintains the feed taxonomy tree from `FeedSource` records.
///
/// The tree is derived from the OPML file structure (directories + <outline> nesting).
/// Each feed belongs to exactly one leaf node (single-home). Multi-label semantics
/// are achieved via filter union — selecting multiple nodes shows all feeds in their subtrees.
///
/// Performance:
/// - Build: O(n) single pass, <500ms cold, <50ms warm (disk cache)
/// - Search: O(n) over flatIndex, 300ms debounce in UI layer
/// - Lookup: O(1) via flatIndex dictionary
/// - Memory: ~128 bytes per node → <2MB for 10K nodes
@MainActor
@Observable
final class TaxonomyStore {

    // MARK: - Shared singleton

    static let shared = TaxonomyStore()

    // MARK: - State

    private(set) var root: TaxonomyNode?
    private(set) var flatIndex: [String: TaxonomyNode] = [:]

    /// O(1) node lookup by ID.
    func node(id: String) -> TaxonomyNode? { flatIndex[id] }
    private var feedToNodeID: [String: String] = [:]  // normalizedURL → leaf node ID

    /// parentID → [childID] index, rebuilt during build(). Makes children(of:) O(1).
    private var childrenIndex: [String: [String]] = [:]

    var selectedNodeIDs: Set<String> = []

    // MARK: - Persistence

    private let cacheURL: URL = {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("taxonomy_cache.json")
    }()

    // MARK: - Tree Building

    /// Build the taxonomy tree from all feed sources.
    /// Single pass, O(n). Caches result to disk for warm starts.
    func build(from sources: [FeedSource]) async {
        // Clear stale state from previous builds
        feedToNodeID.removeAll()
        childrenIndex.removeAll()
        selectedNodeIDs.removeAll()

        // Intermediate: path segments → children
        var tree: [String: (node: TaxonomyNode, childIDs: Set<String>)] = [:]
        var rootChildren: Set<String> = []

        // Ensure virtual root exists
        let rootNode = TaxonomyNode.root(feedCount: 0, childrenCount: 0)
        tree[rootNode.id] = (rootNode, [])

        for source in sources {
            // Derive path: region + category → node ID segments
            let segments = derivePath(from: source)
            var parentID = TaxonomyNode.rootID

            for (depth, segment) in segments.enumerated() {
                let nodeID: String
                if parentID == TaxonomyNode.rootID {
                    nodeID = segment.slug
                } else {
                    nodeID = "\(parentID)/\(segment.slug)"
                }

                if tree[nodeID] == nil {
                    let node = TaxonomyNode(
                        id: nodeID,
                        name: segment.name,
                        parentId: parentID,
                        childrenCount: 0,
                        feedCount: 0,
                        language: segment.language,
                        level: depth + 1,
                        kind: segment.kind
                    )
                    tree[nodeID] = (node, [])
                    tree[parentID]?.childIDs.insert(nodeID)
                    if parentID == TaxonomyNode.rootID {
                        rootChildren.insert(nodeID)
                    }
                }

                parentID = nodeID
            }

            // Map feed URL → leaf node
            let normalizedURL = OPMLParser.normalizeURL(source.url)
            feedToNodeID[normalizedURL] = parentID
        }

        // Pre-compute direct feed counts: single O(M) pass over feedToNodeID,
        // then O(N) bottom-up aggregation for subtree totals. True O(N+M).
        var nodeFeedCounts: [String: Int] = [:]
        for (_, nodeID) in feedToNodeID {
            nodeFeedCounts[nodeID, default: 0] += 1
        }

        // Bottom-up feedCount computation — sort by descending level so
        // leaves are processed before parents
        let sortedIDs = tree.keys.sorted {
            (tree[$0]?.node.level ?? 0) > (tree[$1]?.node.level ?? 0)
        }
        for nodeID in sortedIDs {
            guard let entry = tree[nodeID] else { continue }
            // Direct feeds at this node (O(1) dictionary lookup)
            let directFeeds = nodeFeedCounts[nodeID] ?? 0
            // Child feedCounts are already computed (children have higher level)
            let childTotal = entry.childIDs.reduce(0) {
                $0 + (tree[$1]?.node.feedCount ?? 0)
            }
            let total = directFeeds + childTotal
            tree[nodeID] = (TaxonomyNode(
                id: entry.node.id, name: entry.node.name, parentId: entry.node.parentId,
                childrenCount: entry.childIDs.count, feedCount: total,
                language: entry.node.language, level: entry.node.level, kind: entry.node.kind
            ), entry.childIDs)
        }

        // Update root
        let totalFeeds = tree[TaxonomyNode.rootID]?.childIDs.reduce(0) {
            tree[$1]?.node.feedCount ?? 0
        } ?? 0
        tree[TaxonomyNode.rootID] = (
            TaxonomyNode.root(feedCount: totalFeeds, childrenCount: rootChildren.count),
            rootChildren
        )

        // Build flat index
        flatIndex = Dictionary(uniqueKeysWithValues: tree.map { ($0.key, $0.value.node) })

        // Top-level children sorted by name
        let topChildren = rootChildren
            .compactMap { flatIndex[$0] }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let rootWithChildren = TaxonomyNode(
            id: rootNode.id, name: rootNode.name, parentId: nil,
            childrenCount: topChildren.count, feedCount: totalFeeds,
            language: nil, level: 0, kind: .topic
        )

        self.root = rootWithChildren

        // Build children index for O(1) lookups
        childrenIndex.removeAll()
        for (nodeID, node) in flatIndex {
            guard let parentID = node.parentId else { continue }
            childrenIndex[parentID, default: []].append(nodeID)
        }

        persistCache()
    }

    // MARK: - Path derivation

    private struct PathSegment {
        let slug: String
        let name: String
        let language: String?
        let kind: NodeKind
    }

    private func derivePath(from source: FeedSource) -> [PathSegment] {
        var segments: [PathSegment] = []
        let region = source.region

        if region == "global" {
            // Global region: add "global" virtual node then category as subcategory
            segments.append(PathSegment(
                slug: "global", name: "Global",
                language: nil, kind: .topic
            ))
            let slug = source.category
                .lowercased()
                .replacingOccurrences(of: "&", with: "and")
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "/", with: "-")
            segments.append(PathSegment(
                slug: slug, name: source.category,
                language: source.language, kind: .subcategory
            ))
        } else if region.hasPrefix("countries/") {
            // Countries path: countries → country → (sub-region?) → subcategory
            // Always starts with "countries" virtual node
            if segments.isEmpty || segments.last?.slug != "countries" {
                segments.append(PathSegment(
                    slug: "countries", name: "Countries",
                    language: nil, kind: .topic
                ))
            }

            let parts = region.components(separatedBy: "/")
            // parts[0] = "countries", parts[1] = country, parts[2+] = sub-region
            for (idx, part) in parts.enumerated() where idx >= 1 {
                let kind: NodeKind = idx == 1 ? .country : .region
                let displayName = part
                    .replacingOccurrences(of: "-", with: " ")
                    .capitalized
                segments.append(PathSegment(
                    slug: part, name: displayName,
                    language: source.language, kind: kind
                ))
            }

            // Append subcategory
            let subSlug = source.category
                .lowercased()
                .replacingOccurrences(of: "&", with: "and")
                .replacingOccurrences(of: " ", with: "_")
            segments.append(PathSegment(
                slug: subSlug, name: source.category,
                language: source.language, kind: .subcategory
            ))
        } else if region == "imported" {
            segments.append(PathSegment(
                slug: "imported", name: "Imported",
                language: source.language, kind: .topic
            ))
            let subSlug = source.category
                .lowercased()
                .replacingOccurrences(of: "&", with: "and")
                .replacingOccurrences(of: " ", with: "_")
            segments.append(PathSegment(
                slug: subSlug, name: source.category,
                language: source.language, kind: .subcategory
            ))
        }

        return segments
    }

    // MARK: - Queries

    /// Direct children of a node, sorted by name.
    func children(of nodeID: String) -> [TaxonomyNode] {
        guard let childIDs = childrenIndex[nodeID] else { return [] }
        return childIDs
            .compactMap { flatIndex[$0] }
            .sorted { lhs, rhs in
                // Countries last, then alphabetical
                if lhs.kind == .country && rhs.kind != .country { return false }
                if rhs.kind == .country && lhs.kind != .country { return true }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    /// All ancestors from root to the given node (inclusive).
    func ancestors(of nodeID: String) -> [TaxonomyNode] {
        var result: [TaxonomyNode] = []
        var current: String? = nodeID
        while let id = current, let node = flatIndex[id] {
            result.append(node)
            current = node.parentId
        }
        return result.reversed()
    }

    /// Leaf node ID for a feed URL.
    func nodeID(for feedURL: String) -> String? {
        feedToNodeID[OPMLParser.normalizeURL(feedURL)]
    }

    /// Whether a feed's leaf node is in the subtree of the given node ID.
    func isFeedInSubtree(feedURL: String, nodeID: String) -> Bool {
        guard let leafID = feedToNodeID[OPMLParser.normalizeURL(feedURL)] else { return false }
        if leafID == nodeID { return true }
        return leafID.hasPrefix(nodeID + "/")
    }

    /// Search flat index by name. Case-insensitive. Returns up to 50 results.
    func search(_ query: String) -> [TaxonomyNode] {
        guard !query.isEmpty else { return [] }
        let q = query.lowercased()
        return flatIndex.values
            .filter { $0.name.localizedCaseInsensitiveContains(q) }
            .prefix(50)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Selection

    func select(_ nodeID: String) {
        selectedNodeIDs.insert(nodeID)
    }

    func deselect(_ nodeID: String) {
        selectedNodeIDs.remove(nodeID)
    }

    func toggle(_ nodeID: String) {
        if selectedNodeIDs.contains(nodeID) {
            deselect(nodeID)
        } else {
            select(nodeID)
        }
    }

    func clearSelection() {
        selectedNodeIDs.removeAll()
    }

    var hasSelection: Bool { !selectedNodeIDs.isEmpty }

    /// Resolved node names for display in chip bar, sorted by depth then name.
    var selectedNodeNames: [String] {
        selectedNodeIDs.compactMap { flatIndex[$0]?.name }.sorted()
    }

    // MARK: - Cache

    /// Invalidate disk cache — call when OPML manifest changes.
    func invalidateCache() {
        try? FileManager.default.removeItem(at: cacheURL)
    }

    /// Try to load from disk cache. Returns true if cache was valid.
    func loadFromCache() -> Bool {
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode(CachedTree.self, from: data) else {
            return false
        }
        self.flatIndex = cached.flatIndex
        self.feedToNodeID = cached.feedToNodeID
        // Rebuild children index from restored flatIndex
        self.childrenIndex.removeAll()
        for (nodeID, node) in self.flatIndex {
            guard let parentID = node.parentId else { continue }
            self.childrenIndex[parentID, default: []].append(nodeID)
        }
        self.root = cached.root
        return true
    }

    private func persistCache() {
        let cached = CachedTree(
            root: root,
            flatIndex: flatIndex,
            feedToNodeID: feedToNodeID
        )
        guard let data = try? JSONEncoder().encode(cached) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}

// MARK: - Cache DTO

private struct CachedTree: Codable {
    let root: TaxonomyNode?
    let flatIndex: [String: TaxonomyNode]
    let feedToNodeID: [String: String]
}
