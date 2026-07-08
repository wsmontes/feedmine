import Foundation
import Observation

enum NodeStatus: Equatable {
    case on
    case off
    case partial(activeCount: Int)
}

/// Manages feed source toggles with a single-set model.
///
/// One set: `disabled` tracks what's explicitly OFF.
/// Everything not in `disabled` is ON by default.
///
/// Three states per node:
/// - ON — not in disabled
/// - OFF — in disabled, zero active children
/// - PARTIAL — in disabled, but has ≥1 active child (individual override)
///
/// Resolution for a feed (O(1) — 4 Set lookups):
/// 1. Feed's own key in disabled? → OFF
/// 2. Feed's region key in disabled? → OFF
/// 3. Feed's country key in disabled? → OFF
/// 4. Feed's category key in disabled? → OFF
/// 5. Otherwise → ON
@MainActor
@Observable
final class SourceRegistry {
    var sources: [FeedSource] = []
    var disabled: Set<String> = []

    /// Cached count of active sources under each region/category key.
    /// Recomputed after every toggle.
    private var activeCount: [String: Int] = [:]

    // Debug counters
    private(set) var opmlFileCount = 0
    private(set) var invalidSourceCount = 0
    private(set) var duplicateSourceCount = 0
    private(set) var opmlErrorCount = 0

    // MARK: - Key constructors

    static func regionKey(_ path: String) -> String { "region:\(path)" }
    static func categoryKey(_ name: String) -> String { "cat:\(name)" }
    static func sourceKey(_ url: String) -> String { "url:\(url)" }

    // MARK: - Feed resolution (O(1))

    func isSourceEnabled(_ sourceURL: String) -> Bool {
        guard let source = sources.first(where: { $0.url == sourceURL }) else { return false }
        if disabled.contains(Self.sourceKey(sourceURL)) { return false }
        if disabled.contains(Self.regionKey(source.region)) { return false }
        // Country check — parent of region
        let parts = source.region.split(separator: "/").map(String.init)
        if parts.count >= 2, parts[0] == "countries" {
            let countryKey = Self.regionKey(parts.prefix(2).joined(separator: "/"))
            if disabled.contains(countryKey) { return false }
        }
        if disabled.contains(Self.categoryKey(source.category)) { return false }
        return true
    }

    // MARK: - Group status (O(1) cached)

    func status(of key: String) -> NodeStatus {
        if !disabled.contains(key) { return .on }
        let count = activeCount[key] ?? 0
        return count > 0 ? .partial(activeCount: count) : .off
    }

    func activeCount(for key: String) -> Int {
        activeCount[key] ?? 0
    }

    // MARK: - Toggle actions

    func toggleRegion(_ region: String) {
        let key = Self.regionKey(region)
        if disabled.contains(key) {
            disabled.remove(key)
        } else {
            disabled.insert(key)
        }
        recomputeActiveCounts()
        saveState()
    }

    func toggleCategory(_ category: String) {
        let key = Self.categoryKey(category)
        if disabled.contains(key) {
            disabled.remove(key)
        } else {
            disabled.insert(key)
        }
        recomputeActiveCounts()
        saveState()
    }

    func toggleSource(_ sourceURL: String) {
        let key = Self.sourceKey(sourceURL)
        if disabled.contains(key) {
            disabled.remove(key)
        } else {
            disabled.insert(key)
        }
        recomputeActiveCounts()
        saveState()
    }

    func toggleAllCountries() {
        let countryKeys = Set(sources
            .filter { $0.isCountryFeed }
            .map { $0.region }
            .map { Self.regionKey($0) })
        let anyOn = countryKeys.contains { !disabled.contains($0) }
        if anyOn {
            disabled.formUnion(countryKeys)
        } else {
            disabled.subtract(countryKeys)
        }
        recomputeActiveCounts()
        saveState()
    }

    var isAnyCountryEnabled: Bool {
        sources.contains { $0.isCountryFeed && isSourceEnabled($0.url) }
    }

    // MARK: - Enabled sources

    var enabledSources: [FeedSource] {
        sources.filter { isSourceEnabled($0.url) }
    }

    var sourceCount: Int { sources.count }

    // MARK: - Cache

    private func recomputeActiveCounts() {
        activeCount.removeAll()
        for source in sources where isSourceEnabled(source.url) {
            activeCount[Self.regionKey(source.region), default: 0] += 1
            let parts = source.region.split(separator: "/").map(String.init)
            if parts.count >= 2, parts[0] == "countries" {
                activeCount[Self.regionKey(parts.prefix(2).joined(separator: "/")), default: 0] += 1
            }
            activeCount[Self.categoryKey(source.category), default: 0] += 1
        }
    }

    // MARK: - Persistence

    private func saveState() {
        UserDefaults.standard.set(Array(disabled), forKey: "toggleDisabled")
    }

    func loadState() {
        if let arr = UserDefaults.standard.stringArray(forKey: "toggleDisabled") {
            disabled = Set(arr)
        }
        recomputeActiveCounts()
    }

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

    // MARK: - Load

    func loadFromOPML() async {
        let result = await OPMLParser.parseAll()
        sources = result.sources
        opmlFileCount = result.fileCount
        opmlErrorCount = result.failedFileCount
        invalidSourceCount = result.invalidSourceCount
        duplicateSourceCount = result.duplicateSourceCount
        _regionMap = nil

        // Restore persisted toggle state
        loadState()

        // Countries off by default on first launch
        if disabled.isEmpty {
            for source in sources where source.isCountryFeed {
                disabled.insert(Self.regionKey(source.region))
            }
            saveState()
        }

        recomputeActiveCounts()
    }
}
