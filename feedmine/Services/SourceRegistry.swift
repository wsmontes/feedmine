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
        didSet {
            // Skip rebuild when sources haven't changed — prevents redundant
            // 7,500-entry dictionary allocation during startup when
            // loadFromOPML then restoreImportedSources both assign.
            // Compare by count first (fast reject), then by source metadata
            // set (O(n)). Language/category/region/title edits must refresh
            // derived caches used by filter sheets and fetch scheduling.
            guard sources.count != oldValue.count
                    || sourceCacheIdentity(sources) != sourceCacheIdentity(oldValue) else { return }
            rebuildCaches()
        }
    }
    var disabled: Set<String> = []
    /// Feed URL keys explicitly turned ON despite a disabled parent group.
    var enabledOverrides: Set<String> = []

    /// Cached count of active sources under each region/category key.
    /// Recomputed after every toggle.
    private var activeCount: [String: Int] = [:]

    private(set) var sourceRevision: UInt64 = 0
    private(set) var enablementRevision: UInt64 = 0

    @ObservationIgnored private var _enabledSources: [FeedSource]?
    @ObservationIgnored private var _allTopicRegions: [String]?
    @ObservationIgnored private var _availableCountries: [Country]?
    @ObservationIgnored private var _sourcesByRegion: [String: [FeedSource]]?
    @ObservationIgnored private var _uniqueRegions: Set<String>?
    @ObservationIgnored private var _countrySources: [FeedSource]?
    @ObservationIgnored private var _countryRegionKeys: Set<String>?
    @ObservationIgnored private var activeCountsAreCurrent = false
    @ObservationIgnored private var saveStateTask: Task<Void, Never>?

    // Debug counters
    private(set) var opmlFileCount = 0
    private(set) var invalidSourceCount = 0
    private(set) var duplicateSourceCount = 0
    private(set) var opmlErrorCount = 0

    // MARK: - Key constructors

    nonisolated static func regionKey(_ path: String) -> String { "region:\(path)" }
    nonisolated static func categoryKey(_ name: String) -> String { "cat:\(name)" }
    nonisolated static func sourceKey(_ url: String) -> String { "url:\(OPMLParser.normalizeURL(url))" }

    // MARK: - Feed resolution (O(1) — all Dict/Set lookups)

    /// url → FeedSource, rebuilt when sources change
    private var sourceByURL: [String: FeedSource] = [:]

    private func sourceCacheIdentity(_ sourceList: [FeedSource]) -> Set<String> {
        Set(sourceList.map { source in
            [
                OPMLParser.normalizeURL(source.url),
                source.title,
                source.category,
                source.region,
                source.language ?? "",
                source.mediaKind.rawValue,
            ].joined(separator: "\u{1F}")
        })
    }

    private func rebuildCaches() {
        sourceByURL = Dictionary(uniqueKeysWithValues: sources.map { (OPMLParser.normalizeURL($0.url), $0) })
        _regionMap = nil
        _languageMap = nil
        _enabledSources = nil
        _allTopicRegions = nil
        _availableCountries = nil
        _sourcesByRegion = nil
        _uniqueRegions = nil
        _countrySources = nil
        _countryRegionKeys = nil
        activeCount.removeAll()
        activeCountsAreCurrent = false
        sourceRevision &+= 1
        enablementRevision &+= 1
    }

    private var sourcesByRegion: [String: [FeedSource]] {
        if let cached = _sourcesByRegion { return cached }
        let grouped = Dictionary(grouping: sources, by: \.region)
        _sourcesByRegion = grouped
        return grouped
    }

    private var uniqueRegions: Set<String> {
        if let cached = _uniqueRegions { return cached }
        let regions = Set(sources.map(\.region))
        _uniqueRegions = regions
        return regions
    }

    private var countrySources: [FeedSource] {
        if let cached = _countrySources { return cached }
        let country = sources.filter(\.isCountryFeed)
        _countrySources = country
        return country
    }

    private var countryRegionKeys: Set<String> {
        if let cached = _countryRegionKeys { return cached }
        let keys = Set(countrySources.map { Self.regionKey($0.region) })
        _countryRegionKeys = keys
        return keys
    }

    func sources(inRegionTree region: String) -> [FeedSource] {
        let prefix = "\(region)/"
        return uniqueRegions
            .filter { $0 == region || $0.hasPrefix(prefix) }
            .flatMap { sourcesByRegion[$0] ?? [] }
    }

    func sourceURLs(inRegionTree region: String) -> [String] {
        sources(inRegionTree: region).map(\.url)
    }

    /// True only when the source itself is explicitly turned off via its own
    /// `url:<sourceURL>` key — NOT because of a parent region or category.
    /// Used by taxonomy override: a taxonomy selection should bypass inherited
    /// disables but still respect per-source opt-outs.
    /// URLs are normalized so trailing-slash, http/https, and www. variants
    /// all map to the same key.
    func isSourceExplicitlyDisabled(_ sourceURL: String) -> Bool {
        disabled.contains(Self.sourceKey(sourceURL))
    }

    func isSourceEnabled(_ sourceURL: String) -> Bool {
        let normalized = OPMLParser.normalizeURL(sourceURL)
        guard let source = sourceByURL[normalized] else { return false }
        let ownKey = Self.sourceKey(sourceURL)
        if disabled.contains(ownKey) { return false }          // explicit OFF wins
        if enabledOverrides.contains(ownKey) { return true }   // explicit ON beats a disabled parent
        // Region/country/category disable applies to ALL source types.
        // YouTube and podcasts are not exempt — disabling a country hides
        // its local-language media alongside its text content.
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
        ensureActiveCounts()
        if !disabled.contains(key) { return .on }
        let count = activeCount[key] ?? 0
        return count > 0 ? .partial(activeCount: count) : .off
    }

    func activeCount(for key: String) -> Int {
        ensureActiveCounts()
        return activeCount[key] ?? 0
    }

    // MARK: - Toggle actions

    func toggleRegion(_ region: String) {
        let key = Self.regionKey(region)
        let prefix = "\(region)/"
        let affectedRegions = uniqueRegions.filter { $0 == region || $0.hasPrefix(prefix) }
        let affectedRegionKeys = Set(affectedRegions.map(Self.regionKey)).union([key])
        if disabled.contains(key) {
            // Enabling — cascade down to sub-regions
            disabled.subtract(affectedRegionKeys)
        } else {
            // Disabling — cascade down to sub-regions
            disabled.formUnion(affectedRegionKeys)
            // Disabling a group clears per-feed overrides beneath it, so the
            // whole region really goes dark.
            for source in affectedRegions.flatMap({ sourcesByRegion[$0] ?? [] }) {
                enabledOverrides.remove(Self.sourceKey(source.url))
            }
        }
        recomputeActiveCounts()
        scheduleSaveState()
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
        scheduleSaveState()
    }

    func toggleSource(_ sourceURL: String) {
        ensureActiveCounts()
        let key = Self.sourceKey(sourceURL)
        let wasEnabled = isSourceEnabled(sourceURL)
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
        let isEnabled = isSourceEnabled(sourceURL)
        if wasEnabled != isEnabled, let source = sourceByURL[OPMLParser.normalizeURL(sourceURL)] {
            applyActiveCountDelta(for: source, delta: isEnabled ? 1 : -1)
            updateEnabledSourcesCache(source: source, isEnabled: isEnabled)
            enablementRevision &+= 1
        }
        scheduleSaveState()
    }

    /// Enable or disable all topic regions in a single batch — one recompute,
    /// one UserDefaults write, instead of N per-region toggles.
    func setTopicRegionsEnabled(_ enabled: Bool) {
        let topicKeys = allTopicRegions.map { Self.regionKey($0) }
        if enabled {
            disabled.subtract(topicKeys)
        } else {
            disabled.formUnion(topicKeys)
            // Clear per-feed overrides for all topic sources so the group
            // disable takes full effect.
            for source in allTopicRegions.flatMap({ sourcesByRegion[$0] ?? [] }) {
                enabledOverrides.remove(Self.sourceKey(source.url))
            }
        }
        // Also toggle legacy "global" region
        let globalKey = Self.regionKey("global")
        if enabled {
            disabled.remove(globalKey)
        } else {
            disabled.insert(globalKey)
            for source in sourcesByRegion["global"] ?? [] {
                enabledOverrides.remove(Self.sourceKey(source.url))
            }
        }
        recomputeActiveCounts()
        scheduleSaveState()
    }

    func toggleAllCountries() {
        let countryKeys = countryRegionKeys
        let anyOn = countryKeys.contains { !disabled.contains($0) }
        if anyOn {
            disabled.formUnion(countryKeys)
            for source in countrySources {
                enabledOverrides.remove(Self.sourceKey(source.url))
            }
        } else {
            disabled.subtract(countryKeys)
        }
        recomputeActiveCounts()
        scheduleSaveState()
    }

    var isAnyCountryEnabled: Bool {
        countrySources.contains { isSourceEnabled($0.url) }
    }

    // MARK: - Enabled sources

    var enabledSources: [FeedSource] {
        if let cached = _enabledSources { return cached }
        recomputeActiveCounts()
        return _enabledSources ?? []
    }

    var sourceCount: Int { sources.count }

    // MARK: - Cache

    private func ensureActiveCounts() {
        guard !activeCountsAreCurrent else { return }
        recomputeActiveCounts()
    }

    private func recomputeActiveCounts() {
        activeCount.removeAll()
        var enabled: [FeedSource] = []
        enabled.reserveCapacity(sources.count)
        for source in sources where isSourceEnabled(source.url) {
            enabled.append(source)
            applyActiveCountDelta(for: source, delta: 1)
        }
        _enabledSources = enabled
        activeCountsAreCurrent = true
        enablementRevision &+= 1
    }

    private func applyActiveCountDelta(for source: FeedSource, delta: Int) {
        for key in activeCountKeys(for: source) {
            let updated = (activeCount[key] ?? 0) + delta
            if updated > 0 {
                activeCount[key] = updated
            } else {
                activeCount.removeValue(forKey: key)
            }
        }
    }

    private func activeCountKeys(for source: FeedSource) -> [String] {
        var keys = [Self.regionKey(source.region), Self.categoryKey(source.category)]
        let parts = source.region.split(separator: "/").map(String.init)
        if parts.count >= 2, parts[0] == "countries" {
            keys.append(Self.regionKey(parts.prefix(2).joined(separator: "/")))
        }
        return keys
    }

    private func updateEnabledSourcesCache(source: FeedSource, isEnabled: Bool) {
        guard var enabledSources = _enabledSources else { return }
        let normalizedURL = OPMLParser.normalizeURL(source.url)
        if isEnabled {
            guard !enabledSources.contains(where: { OPMLParser.normalizeURL($0.url) == normalizedURL }) else { return }
            enabledSources.append(source)
        } else {
            enabledSources.removeAll { OPMLParser.normalizeURL($0.url) == normalizedURL }
        }
        _enabledSources = enabledSources
    }

    // MARK: - Persistence

    private func saveState() {
        UserDefaults.standard.set(Array(disabled), forKey: Keys.toggleDisabled)
        UserDefaults.standard.set(Array(enabledOverrides), forKey: Keys.toggleEnabledOverrides)
    }

    private func scheduleSaveState() {
        saveStateTask?.cancel()
        saveStateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.saveState()
        }
    }

    func loadState() {
        if let arr = UserDefaults.standard.stringArray(forKey: Keys.toggleDisabled) {
            // Normalize legacy keys: old code stored raw URLs; new code uses
            // OPMLParser.normalizeURL. Re-create each key so trailing-slash,
            // http/https, and www. variants converge.
            disabled = Set(arr.map { key in
                if key.hasPrefix("url:") {
                    let raw = String(key.dropFirst(4))
                    return Self.sourceKey(raw)
                }
                return key
            })
        }
        if let arr = UserDefaults.standard.stringArray(forKey: "toggleEnabledOverrides") {
            enabledOverrides = Set(arr.map { key in
                if key.hasPrefix("url:") {
                    let raw = String(key.dropFirst(4))
                    return Self.sourceKey(raw)
                }
                return key
            })
        }
        recomputeActiveCounts()
    }

    // MARK: - Region lookup

    @ObservationIgnored private var _regionMap: [String: String]?
    var regionMap: [String: String] {
        if let cached = _regionMap { return cached }
        let map = Dictionary(sources.map { ($0.url, $0.region) }, uniquingKeysWith: { first, _ in first })
        _regionMap = map
        return map
    }

    func regionFor(sourceURL: String) -> String {
        regionMap[sourceURL] ?? "global"
    }

    // MARK: - Language lookup

    @ObservationIgnored private var _languageMap: [String: String?]?
    var languageMap: [String: String?] {
        if let cached = _languageMap { return cached }
        let map = Dictionary(sources.map { ($0.url, $0.language) }, uniquingKeysWith: { first, _ in first })
        _languageMap = map
        return map
    }

    func languageFor(sourceURL: String) -> String? {
        languageMap[sourceURL] ?? nil
    }

    // MARK: - Topic regions

    /// All topic-based regions (non-country, non-imported, non-global).
    /// Used by Global Feeds toggle to batch-enable/disable all topic groups.
    var allTopicRegions: [String] {
        if let cached = _allTopicRegions { return cached }
        let regions = Set(sources.map(\.region))
        let topicRegions = regions
            .filter { $0.hasPrefix("topic/") }
            .sorted()
        _allTopicRegions = topicRegions
        return topicRegions
    }

    // MARK: - Countries

    var availableCountries: [Country] {
        if let cached = _availableCountries { return cached }
        let grouped = Dictionary(grouping: sources, by: \.region)
        let countryRegions = grouped.keys.filter { key in
            guard key.hasPrefix("countries/") else { return false }
            let remainder = key.replacingOccurrences(of: "countries/", with: "")
            return !remainder.contains("/")
        }
        let countries = countryRegions.compactMap { region -> Country? in
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
        _availableCountries = countries
        return countries
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
        if !Settings.hasInitializedSourceDefaults {
            for source in sources where source.isCountryFeed {
                disabled.insert(Self.regionKey(source.region))
            }
            saveState()
            Settings.hasInitializedSourceDefaults = true
        }

        recomputeActiveCounts()
    }
}
