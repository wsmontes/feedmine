import Foundation
import Observation

/// Manages the feed source catalog: OPML parsing, enabled/disabled state,
/// country/region groupings. Extracted from FeedLoader.
@MainActor
@Observable
final class SourceRegistry {
    var sources: [FeedSource] = []
    var disabledRegions: Set<String> = []
    var disabledSourceIDs: Set<String> = []
    var disabledCategories: Set<String> = []

    // Debug counters
    private(set) var opmlFileCount = 0
    private(set) var invalidSourceCount = 0
    private(set) var duplicateSourceCount = 0
    private(set) var opmlErrorCount = 0

    // MARK: - Enabled sources

    var enabledSources: [FeedSource] {
        sources.filter { source in
            if disabledSourceIDs.contains(source.url) { return false }
            if disabledRegions.contains(source.region) { return false }
            if disabledCategories.contains(source.category) { return false }
            return true
        }
    }

    var sourceCount: Int { sources.count }

    // MARK: - Region lookup

    private var _regionMap: [String: String]?
    var regionMap: [String: String] {
        if let cached = _regionMap { return cached }
        let map = Dictionary(sources.map { ($0.url, $0.region) }, uniquingKeysWith: { first, _ in first })
        _regionMap = map
        return map
    }

    func regionFor(sourceURL: String) -> String {
        regionMap[sourceURL] ?? "global"
    }

    // MARK: - Countries

    var availableCountries: [Country] {
        let grouped = Dictionary(grouping: sources, by: \.region)
        let countryRegions = grouped.keys.filter { key in
            guard key.hasPrefix("countries/") else { return false }
            let remainder = key.replacingOccurrences(of: "countries/", with: "")
            return !remainder.contains("/")
        }
        return countryRegions.compactMap { region -> Country? in
            let slug = region.replacingOccurrences(of: "countries/", with: "")
            let countryFeeds = grouped[region] ?? []
            let regionPrefix = "\(region)/"
            let subRegions = grouped
                .filter { $0.key.hasPrefix(regionPrefix) }
                .compactMap { subRegionPath, feeds -> Region? in
                    let regionSlug = subRegionPath.replacingOccurrences(of: regionPrefix, with: "")
                    guard !regionSlug.isEmpty else { return nil }
                    return Region(
                        path: subRegionPath,
                        countrySlug: slug,
                        slug: regionSlug,
                        name: regionSlug.replacingOccurrences(of: "-", with: " ").capitalized,
                        feedCount: feeds.count,
                        categories: Array(Set(feeds.map(\.category))).sorted()
                    )
                }
                .sorted { $0.name < $1.name }
            return Country(
                region: region,
                name: CountryStore.countryName(for: slug),
                flag: CountryStore.countryFlag(for: slug),
                feedCount: countryFeeds.count,
                categories: Array(Set(countryFeeds.map(\.category))).sorted(),
                regions: subRegions
            )
        }
        .sorted { $0.name < $1.name }
    }

    // MARK: - Toggle actions

    func toggleRegion(_ region: String) {
        if disabledRegions.contains(region) {
            disabledRegions.remove(region)
            let prefix = "\(region)/"
            for subRegion in sources.map(\.region) where subRegion.hasPrefix(prefix) {
                disabledRegions.remove(subRegion)
            }
        } else {
            disabledRegions.insert(region)
            let prefix = "\(region)/"
            for subRegion in sources.map(\.region) where subRegion.hasPrefix(prefix) {
                disabledRegions.insert(subRegion)
            }
        }
    }

    func toggleAllCountries() {
        let allCountryRegions = Set(sources.filter { $0.isCountryFeed }.map(\.region))
        let anyEnabled = allCountryRegions.contains { !disabledRegions.contains($0) }
        if anyEnabled {
            disabledRegions.formUnion(allCountryRegions)
        } else {
            disabledRegions.subtract(allCountryRegions)
        }
    }

    var isAnyCountryEnabled: Bool {
        sources.contains { $0.isCountryFeed && !disabledRegions.contains($0.region) }
    }

    func toggleSource(_ sourceURL: String) {
        if disabledSourceIDs.contains(sourceURL) {
            disabledSourceIDs.remove(sourceURL)
        } else {
            disabledSourceIDs.insert(sourceURL)
        }
    }

    func toggleCategory(_ category: String) {
        if disabledCategories.contains(category) {
            disabledCategories.remove(category)
        } else {
            disabledCategories.insert(category)
        }
    }

    func isSourceEnabled(_ sourceURL: String) -> Bool {
        !disabledSourceIDs.contains(sourceURL)
    }

    func isCategoryEnabled(_ category: String) -> Bool {
        !disabledCategories.contains(category)
    }

    func isRegionEnabled(_ region: String) -> Bool {
        !disabledRegions.contains(region)
    }

    // MARK: - Load

    func loadFromOPML() async {
        let result = await OPMLParser.parseAll()
        sources = result.sources
        opmlFileCount = result.fileCount
        opmlErrorCount = result.failedFileCount
        invalidSourceCount = result.invalidSourceCount
        duplicateSourceCount = result.duplicateSourceCount
        _regionMap = nil

        // Countries off by default on first launch
        if disabledRegions.isEmpty {
            let allCountryRegions = Set(sources.filter { $0.isCountryFeed }.map(\.region))
            disabledRegions.formUnion(allCountryRegions)
        }
    }
}
