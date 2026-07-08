import Foundation

/// A sub-region within a country (e.g., "California" within "USA", "São Paulo" within "Brazil").
/// Discovered automatically from the filesystem: any OPML file inside a country directory
/// whose name matches `{country}-{region}.opml` is treated as a sub-region feed.
struct Region: Identifiable, Hashable {
    var id: String { path }
    /// Full region path, e.g. "countries/brazil/acre"
    let path: String
    /// Country slug this region belongs to, e.g. "brazil"
    let countrySlug: String
    /// Region slug, e.g. "acre"
    let slug: String
    /// Human-readable display name
    let name: String
    /// Number of feed sources in this region
    let feedCount: Int
    /// Unique categories across all feeds in this region
    let categories: [String]
}
