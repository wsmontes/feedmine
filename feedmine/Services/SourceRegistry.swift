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
    struct LookupSnapshot: Sendable {
        let sourcesByNormalizedURL: [String: FeedSource]
        let explicitlyDisabledURLs: Set<String>
    }
    struct LanguageCountSnapshot {
        let sourceRevision: UInt64
        let enablementRevision: UInt64
        let enabled: [String: Int]
        let total: [String: Int]
    }
    var sources: [FeedSource] = [] {
        didSet {
            // Source replacements must not leave stale exclusions for URLs
            // that no longer exist in the current catalog.
            sharedCountrySourceURLs.formIntersection(Set(sources.map {
                OPMLParser.normalizeURL($0.url)
            }))
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
    /// Captured before OPML URL deduplication. A shared syndicated feed is
    /// still fetchable once, but cannot be shown as a country-local source.
    private(set) var sharedCountrySourceURLs: Set<String> = []
    /// Feed URL keys explicitly turned ON despite a disabled parent group.
    var enabledOverrides: Set<String> = []

    /// Cached count of active sources under each region/category key.
    /// Recomputed after every toggle.
    private var activeCount: [String: Int] = [:]

    private(set) var sourceRevision: UInt64 = 0
    private(set) var enablementRevision: UInt64 = 0
    private(set) var totalLanguageCounts: [String: Int] = [:]
    private(set) var enabledLanguageCounts: [String: Int] = [:]
    private(set) var availableLanguageCodes: Set<String> = []
    private(set) var availableCategories: [String] = []

    @ObservationIgnored private var _enabledSources: [FeedSource]?
    @ObservationIgnored private var _allTopicRegions: [String]?
    @ObservationIgnored private var _availableCountries: [Country]?
    @ObservationIgnored private var _sourcesByRegion: [String: [FeedSource]]?
    @ObservationIgnored private var _uniqueRegions: Set<String>?
    @ObservationIgnored private var _countrySources: [FeedSource]?
    @ObservationIgnored private var _countryRegionKeys: Set<String>?
    @ObservationIgnored private var _countrySourceKeys: Set<String>?
    @ObservationIgnored private var _topicSourceKeys: Set<String>?
    @ObservationIgnored private var _sourceKeysByCategory: [String: Set<String>] = [:]
    @ObservationIgnored private var activeCountsAreCurrent = false
    @ObservationIgnored private var saveStateTask: Task<Void, Never>?
    @ObservationIgnored private var activeCountsGeneration: UInt64 = 0
    /// Group states changed in a bulk action. They can render immediately
    /// while the full derived-count snapshot is rebuilt after the interaction.
    @ObservationIgnored private var pendingDisabledGroupKeys: Set<String> = []

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
                source.defaultEnabled ? "1" : "0",
                source.activity ?? "",
            ].joined(separator: "\u{1F}")
        })
    }

    private func rebuildCaches() {
        var byURL: [String: FeedSource] = [:]
        var languageCounts: [String: Int] = [:]
        var topicRegions = Set<String>()
        var countrySourceKeys = Set<String>()
        var topicSourceKeys = Set<String>()
        var sourceKeysByCategory: [String: Set<String>] = [:]
        byURL.reserveCapacity(sources.count)
        for source in sources {
            let normalizedURL = OPMLParser.normalizeURL(source.url)
            if byURL[normalizedURL] == nil { byURL[normalizedURL] = source }
            let sourceKey = Self.sourceKey(source.url)
            sourceKeysByCategory[source.category, default: []].insert(sourceKey)
            if source.isCountryFeed { countrySourceKeys.insert(sourceKey) }
            if source.region.hasPrefix("topic/") { topicSourceKeys.insert(sourceKey) }
            if let language = FeedStore.normalizedLanguageCode(source.language) {
                languageCounts[language, default: 0] += 1
            }
            if source.region.hasPrefix("topic/") {
                topicRegions.insert(source.region)
            }
        }
        sourceByURL = byURL
        totalLanguageCounts = languageCounts
        availableLanguageCodes = Set(languageCounts.keys)
        _allTopicRegions = topicRegions.sorted()
        _regionMap = nil
        _languageMap = nil
        _enabledSources = nil
        _availableCountries = nil
        _sourcesByRegion = nil
        _uniqueRegions = nil
        _countrySources = nil
        _countryRegionKeys = nil
        _countrySourceKeys = countrySourceKeys
        _topicSourceKeys = topicSourceKeys
        _sourceKeysByCategory = sourceKeysByCategory
        activeCount.removeAll()
        activeCountsAreCurrent = false
        activeCountsGeneration &+= 1
        pendingDisabledGroupKeys.removeAll()
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

    private var countrySourceKeys: Set<String> {
        if let cached = _countrySourceKeys { return cached }
        let keys = Set(countrySources.map { Self.sourceKey($0.url) })
        _countrySourceKeys = keys
        return keys
    }

    private var topicSourceKeys: Set<String> {
        if let cached = _topicSourceKeys { return cached }
        let keys = Set(sources.lazy
            .filter { $0.region.hasPrefix("topic/") }
            .map { Self.sourceKey($0.url) })
        _topicSourceKeys = keys
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
        if !source.defaultEnabled { return false }              // curated freshness default
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

    func lookupSnapshot() -> LookupSnapshot {
        let prefix = "url:"
        let explicitlyDisabled = Set(disabled.compactMap { key -> String? in
            guard key.hasPrefix(prefix) else { return nil }
            return String(key.dropFirst(prefix.count))
        })
        return LookupSnapshot(
            sourcesByNormalizedURL: sourceByURL,
            explicitlyDisabledURLs: explicitlyDisabled
        )
    }

    func source(forURL sourceURL: String) -> FeedSource? {
        sourceByURL[OPMLParser.normalizeURL(sourceURL)]
    }

    /// Materializes lazy enablement caches before returning their revisions and
    /// language counts, so callers never cache an empty pre-materialization view.
    func languageCountSnapshot() -> LanguageCountSnapshot {
        ensureActiveCounts()
        return LanguageCountSnapshot(
            sourceRevision: sourceRevision,
            enablementRevision: enablementRevision,
            enabled: enabledLanguageCounts,
            total: totalLanguageCounts
        )
    }

    // MARK: - Group status (O(1) cached)

    func status(of key: String) -> NodeStatus {
        if !disabled.contains(key) { return .on }
        // A bulk action has already changed the source decision. Returning the
        // final off state here lets every row redraw before derived counts are
        // rebuilt in the background.
        if pendingDisabledGroupKeys.contains(key) { return .off }
        ensureActiveCounts()
        let count = activeCount[key] ?? 0
        return count > 0 ? .partial(activeCount: count) : .off
    }

    func activeCount(for key: String) -> Int {
        if pendingDisabledGroupKeys.contains(key) { return 0 }
        ensureActiveCounts()
        return activeCount[key] ?? 0
    }

    // MARK: - Toggle actions

    func toggleRegion(_ region: String) {
        let key = Self.regionKey(region)
        setRegionEnabled(region, enabled: disabled.contains(key))
    }

    func setRegionEnabled(_ region: String, enabled: Bool) {
        let key = Self.regionKey(region)
        let prefix = "\(region)/"
        let affectedRegions = uniqueRegions.filter { $0 == region || $0.hasPrefix(prefix) }
        let affectedRegionKeys = Set(affectedRegions.map(Self.regionKey)).union([key])
        if enabled {
            // Enabling — cascade down to sub-regions
            disabled.subtract(affectedRegionKeys)
            pendingDisabledGroupKeys.subtract(affectedRegionKeys)
        } else {
            // Disabling — cascade down to sub-regions
            disabled.formUnion(affectedRegionKeys)
            // Disabling a group clears per-feed overrides beneath it, so the
            // whole region really goes dark.
            for source in affectedRegions.flatMap({ sourcesByRegion[$0] ?? [] }) {
                enabledOverrides.remove(Self.sourceKey(source.url))
            }
            pendingDisabledGroupKeys.formUnion(affectedRegionKeys)
        }
        invalidateActiveCounts()
        scheduleSaveState()
    }

    func toggleCategory(_ category: String) {
        setCategoryEnabled(category, enabled: disabled.contains(Self.categoryKey(category)))
    }

    func setCategoryEnabled(_ category: String, enabled: Bool) {
        let key = Self.categoryKey(category)
        if enabled {
            disabled.remove(key)
            pendingDisabledGroupKeys.remove(key)
        } else {
            disabled.insert(key)
            enabledOverrides.subtract(_sourceKeysByCategory[category] ?? [])
            pendingDisabledGroupKeys.insert(key)
        }
        invalidateActiveCounts()
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
            if let language = FeedStore.normalizedLanguageCode(source.language) {
                let updated = (enabledLanguageCounts[language] ?? 0) + (isEnabled ? 1 : -1)
                if updated > 0 {
                    enabledLanguageCounts[language] = updated
                } else {
                    enabledLanguageCounts.removeValue(forKey: language)
                }
            }
            if isEnabled {
                if !availableCategories.contains(source.category) {
                    availableCategories.append(source.category)
                    availableCategories.sort()
                }
            } else if activeCount[Self.categoryKey(source.category)] == nil {
                availableCategories.removeAll { $0 == source.category }
            }
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
            pendingDisabledGroupKeys.subtract(topicKeys)
        } else {
            disabled.formUnion(topicKeys)
            // Clear per-feed overrides for all topic sources so the group
            // disable takes full effect.
            enabledOverrides.subtract(topicSourceKeys)
            pendingDisabledGroupKeys.formUnion(topicKeys)
        }
        // Also toggle legacy "global" region
        let globalKey = Self.regionKey("global")
        if enabled {
            disabled.remove(globalKey)
            pendingDisabledGroupKeys.remove(globalKey)
        } else {
            disabled.insert(globalKey)
            enabledOverrides.subtract(Set((sourcesByRegion["global"] ?? []).map { Self.sourceKey($0.url) }))
            pendingDisabledGroupKeys.insert(globalKey)
        }
        invalidateActiveCounts()
        scheduleSaveState()
    }

    func toggleAllCountries() {
        setAllCountriesEnabled(!isAnyCountryEnabled)
    }

    func setAllCountriesEnabled(_ enabled: Bool) {
        let countryKeys = countryRegionKeys
        if enabled {
            disabled.subtract(countryKeys)
            pendingDisabledGroupKeys.subtract(countryKeys)
        } else {
            disabled.formUnion(countryKeys)
            enabledOverrides.subtract(countrySourceKeys)
            pendingDisabledGroupKeys.formUnion(countryKeys)
        }
        invalidateActiveCounts()
        scheduleSaveState()
    }

    var isAnyCountryEnabled: Bool {
        countryRegionKeys.contains { !disabled.contains($0) }
            || !enabledOverrides.isDisjoint(with: countrySourceKeys)
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
        var languageCounts: [String: Int] = [:]
        var categories = Set<String>()
        enabled.reserveCapacity(sources.count)
        for source in sources where isSourceEnabled(source.url) {
            enabled.append(source)
            categories.insert(source.category)
            if let language = FeedStore.normalizedLanguageCode(source.language) {
                languageCounts[language, default: 0] += 1
            }
            applyActiveCountDelta(for: source, delta: 1)
        }
        _enabledSources = enabled
        enabledLanguageCounts = languageCounts
        availableCategories = categories.sorted()
        activeCountsAreCurrent = true
        pendingDisabledGroupKeys.removeAll()
        enablementRevision &+= 1
    }

    private func invalidateActiveCounts() {
        _enabledSources = nil
        activeCountsAreCurrent = false
        activeCountsGeneration &+= 1
        let generation = activeCountsGeneration
        // Coalesce rapid changes so the switch and haptic render immediately.
        // The full cached count rebuild is delayed until the user pauses.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, generation == self.activeCountsGeneration else { return }
            self.recomputeActiveCounts()
        }
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

    /// Materialize every derived model used by the filter sheet while the
    /// catalog is already in its loading phase. Reads during interaction are
    /// then dictionary/array lookups only.
    func prepareFilterCaches() {
        ensureActiveCounts()
        _ = allTopicRegions
        _ = availableCountries
    }

    // MARK: - Load

    func loadFromOPML() async {
        let result = await OPMLParser.parseAll()
        sharedCountrySourceURLs = result.sharedCountrySourceURLs
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
        prepareFilterCaches()
    }
}
