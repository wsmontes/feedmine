import Foundation

/// Represents a persistent search that is currently active (search_active = 1).
/// Used to build the composite feed with multi-search scoring.
struct ActiveSearch: Identifiable, Hashable {
    let id: Int64
    let name: String
    let searchQuery: String
    let region: String?
    let category: String?

    /// How many dimensions this search contributes (1-3).
    /// Text = 1, region = 1, category = 1.
    var dimensionCount: Int {
        var count = 0
        if !searchQuery.isEmpty { count += 1 }
        if region != nil { count += 1 }
        if category != nil { count += 1 }
        return count
    }

    /// Returns the number of dimensions this search matches for a given item.
    func matches(_ item: FeedItem, itemRegion: String) -> Int {
        var score = 0
        if let r = region, itemRegion == r { score += 1 }
        if let c = category, item.category == c { score += 1 }
        // Text match is checked separately via FTS5 at query time
        return score
    }
}
