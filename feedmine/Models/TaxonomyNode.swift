import Foundation

/// The type of a node in the taxonomy tree.
enum NodeKind: String, Codable, Sendable, CaseIterable {
    case topic        // global topic OPML (coffee_tea, tech, science)
    case country      // country directory
    case region       // sub-region within a country
    case subcategory  // <outline> group within an OPML
}

/// A single node in the feed taxonomy tree.
///
/// IDs are canonical slug paths (e.g. "countries/brazil/news").
/// The virtual root uses the sentinel ID `__root__`.
/// `feedCount` is the total number of feeds in this subtree (all descendants).
/// `childrenCount` is only direct children (nodes, not feeds).
struct TaxonomyNode: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let name: String
    let parentId: String?
    let childrenCount: Int
    let feedCount: Int
    let language: String?
    let level: Int
    let kind: NodeKind

    /// Sentinel ID for the virtual root node.
    static let rootID = "__root__"

    /// Virtual root — parent of all top-level nodes.
    static func root(feedCount: Int, childrenCount: Int) -> TaxonomyNode {
        TaxonomyNode(
            id: rootID,
            name: "All Feeds",
            parentId: nil,
            childrenCount: childrenCount,
            feedCount: feedCount,
            language: nil,
            level: 0,
            kind: .topic
        )
    }

    /// Whether this node is an ancestor of the given node ID.
    /// O(depth) — walks parent chain via id prefix matching.
    func isAncestor(of leafId: String) -> Bool {
        leafId.hasPrefix(id + "/")
    }
}
