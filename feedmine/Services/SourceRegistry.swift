import Foundation
import Observation

enum NodeStatus: Equatable {
    case on
    case off
    case partial(activeCount: Int)
}

/// Manages feed source toggles with a two-set model.
///
/// `disabled` tracks what's explicitly OFF (a feed, region, country, or
/// category key). `enabledOverrides` tracks individual feeds explicitly turned
/// ON so they show even while a parent group is OFF — without this, a single
/// `disabled` set cannot represent "country off, but keep this one feed."
///
/// Three states per group node:
/// - ON — not in disabled
/// - OFF — in disabled, zero active children
/// - PARTIAL — in disabled, but has ≥1 active child (an enabledOverride)
///
/// Resolution for a feed (O(1) — a handful of Set lookups):
/// 1. Feed's own key in disabled? → OFF (explicit off wins over everything)
/// 2. Feed's own key in enabledOverrides? → ON (explicit on beats a parent off)
/// 3. Feed's region / country / category key in disabled? → OFF
/// 4. Otherwise → ON
@MainActor
@Observable
final class SourceRegistry {
    var sources: [FeedSource] = [] {
        // Keep the url→source and region caches in sync no matter who assigns
        // `sources` — FeedLoader.addSources sets it directly, bypassing
        // loadFromOPML. Without this, imported feeds are missing from
        // sourceByURL and isSourceEnabled wrongly reports them as disabled.
        didSet { rebuildCaches() }
    }
    var disabled: Set<String> = []
    /// Feed URL keys explicitly turned ON despite a disabled parent group.
    var enabledOverrides: Set<String> = []

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

    // MARK: - Feed resolution (O(1) — all Dict/Set lookups)

    /// url → FeedSource, rebuilt when sources change
    private var sourceByURL: [String: FeedSource] = [:]

    private func rebuildCaches() {
        sourceByURL = Dictionary(uniqueKeysWithValues: sources.map { ($0.url, $0) })
        _regionMap = nil
    }

    func isSourceEnabled(_ sourceURL: String) -> Bool {
        guard let source = sourceByURL[sourceURL] else { return false }
        let ownKey = Self.sourceKey(sourceURL)
        if disabled.contains(ownKey) { return false }          // explicit OFF wins
        if enabledOverrides.contains(ownKey) { return true }   // explicit ON beats a disabled parent
        // YouTube and podcast sources bypass region/country/category disable.
        // Their country tag in the OPML is a language overlay for filtering,
        // not an opt-in gate — they're globally available unless explicitly
        // toggled off via their source key above.
        if source.isYouTube || source.mediaKind == .audio { return true }
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
        let prefix = "\(region)/"
        if disabled.contains(key) {
            // Enabling — cascade down to sub-regions
            disabled.remove(key)
            for sub in sources.map(\.region) where sub.hasPrefix(prefix) {
                disabled.remove(Self.regionKey(sub))
            }
        } else {
            // Disabling — cascade down to sub-regions
            disabled.insert(key)
            for sub in sources.map(\.region) where sub.hasPrefix(prefix) {
                disabled.insert(Self.regionKey(sub))
            }
            // Disabling a group clears per-feed overrides beneath it, so the
            // whole region really goes dark.
            for source in sources where source.region == region || source.region.hasPrefix(prefix) {
                enabledOverrides.remove(Self.sourceKey(source.url))
            }
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
            for source in sources where source.category == category {
                enabledOverrides.remove(Self.sourceKey(source.url))
            }
        }
        recomputeActiveCounts()
        saveState()
    }

    func toggleSource(_ sourceURL: String) {
        let key = Self.sourceKey(sourceURL)
        if isSourceEnabled(sourceURL) {
            // Turn OFF — drop any override, mark explicitly disabled.
            enabledOverrides.remove(key)
            disabled.insert(key)
        } else {
            // Turn ON — clear an explicit off first; if a parent group still
            // disables it, record an explicit override so it shows anyway.
            disabled.remove(key)
            if !isSourceEnabled(sourceURL) {
                enabledOverrides.insert(key)
            }
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
            for source in sources where source.region.hasPrefix("countries/") {
                enabledOverrides.remove(Self.sourceKey(source.url))
            }
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
        UserDefaults.standard.set(Array(enabledOverrides), forKey: "toggleEnabledOverrides")
    }

    func loadState() {
        if let arr = UserDefaults.standard.stringArray(forKey: "toggleDisabled") {
            disabled = Set(arr)
        }
        if let arr = UserDefaults.standard.stringArray(forKey: "toggleEnabledOverrides") {
            enabledOverrides = Set(arr)
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
        sources = result.sources   // didSet rebuilds caches
        opmlFileCount = result.fileCount
        opmlErrorCount = result.failedFileCount
        invalidSourceCount = result.invalidSourceCount
        duplicateSourceCount = result.duplicateSourceCount

        // Restore persisted toggle state
        loadState()

        // Countries off by default on first launch only.
        // Uses a flag so re-enabling all countries doesn't reset on next launch.
        let hasInitializedKey = "hasInitializedSourceDefaults"
        if !UserDefaults.standard.bool(forKey: hasInitializedKey) {
            for source in sources where source.isCountryFeed {
                disabled.insert(Self.regionKey(source.region))
            }
            saveState()
            UserDefaults.standard.set(true, forKey: hasInitializedKey)
        }

        recomputeActiveCounts()
    }
}
