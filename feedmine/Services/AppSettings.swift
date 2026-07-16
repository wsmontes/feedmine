import Foundation

// MARK: - UserDefaults Key Registry
// Every key used anywhere in the app is defined here.
// Views use @AppStorage(Keys.x) for reactive reads.
// Services use Settings.x for typed get/set.

enum Keys {
    // Filters
    static let filterRegion = "filterRegion"
    static let filterTaxonomyNodes = "filterTaxonomyNodes"
    static let filterContentType = "filterContentType"
    static let filterMood = "filterMood"
    static let filterSetAt = "filterSetAt"
    static let filterAutoExpire = "filterAutoExpire"
    static let filterLanguages = "filterLanguages"
    static let hasInitializedLanguageDefault = "hasInitializedLanguageDefault"

    // Appearance
    static let circadianPaletteOn = "circadianPaletteOn"
    static let paletteFamily = "paletteFamily"
    static let circadianTypographyOn = "circadianTypographyOn"
    static let fontStyle = "fontStyle"
    static let fontSize = "fontSize"
    static let nightMode = "nightMode"

    // Behavior
    static let prefetchImages = "prefetchImages"
    static let showDebugBar = "showDebugBar"
    static let hasSeenOnboarding = "hasSeenOnboarding"
    static let contentFiltersEnabled = "contentFiltersEnabled"

    // Session & Streaks
    static let sessionStreak = "sessionStreak"
    static let sessionMinutesToday = "sessionMinutesToday"
    static let daysWithAppTotal = "daysWithAppTotal"
    static let lastOpenDate = "lastOpenDate"

    // Source registry
    static let toggleDisabled = "toggleDisabled"
    static let toggleEnabledOverrides = "toggleEnabledOverrides"
    static let hasInitializedSourceDefaults = "hasInitializedSourceDefaults"

    // What's New
    static let lastWhatsNewSeenAt = "last_whats_new_seen_at"

    // Maintenance
    static let lastHeavyMaintenance = "lastHeavyMaintenance"

    // Audio
    static let lastPodcastItemID = "lastPodcastItemID"
    static let lastPodcastPosition = "lastPodcastPosition"
}

// MARK: - Typed Settings Accessor
// Convenience for non-view code. Reads/writes UserDefaults with type safety.

enum Settings {
    private static nonisolated(unsafe) let d = UserDefaults.standard

    // MARK: Filters
    static var filterRegion: String? {
        get { d.string(forKey: Keys.filterRegion) }
        set { d.set(newValue, forKey: Keys.filterRegion) }
    }
    static var filterTaxonomyNodes: [String] {
        get { d.stringArray(forKey: Keys.filterTaxonomyNodes) ?? [] }
        set { d.set(newValue, forKey: Keys.filterTaxonomyNodes) }
    }
    static var filterContentType: String {
        get { d.string(forKey: Keys.filterContentType) ?? "All" }
        set { d.set(newValue, forKey: Keys.filterContentType) }
    }
    static var filterAutoExpire: Bool {
        get { d.bool(forKey: Keys.filterAutoExpire) }
        set { d.set(newValue, forKey: Keys.filterAutoExpire) }
    }
    static var filterSetAt: TimeInterval {
        get { d.double(forKey: Keys.filterSetAt) }
        set { d.set(newValue, forKey: Keys.filterSetAt) }
    }
    static var filterLanguages: [String] {
        get { d.stringArray(forKey: Keys.filterLanguages) ?? [] }
        set { d.set(newValue, forKey: Keys.filterLanguages) }
    }
    static var filterMood: String {
        get { d.string(forKey: Keys.filterMood) ?? FeedLoader.MoodFilter.all.rawValue }
        set { d.set(newValue, forKey: Keys.filterMood) }
    }
    static var hasInitializedLanguageDefault: Bool {
        get { d.bool(forKey: Keys.hasInitializedLanguageDefault) }
        set { d.set(newValue, forKey: Keys.hasInitializedLanguageDefault) }
    }

    // MARK: Appearance
    static var circadianPaletteOn: Bool {
        get { d.object(forKey: Keys.circadianPaletteOn) as? Bool ?? true }
        set { d.set(newValue, forKey: Keys.circadianPaletteOn) }
    }
    static var paletteFamily: String {
        get { d.string(forKey: Keys.paletteFamily) ?? "warmEarth" }
        set { d.set(newValue, forKey: Keys.paletteFamily) }
    }
    static var prefetchImages: Bool {
        get { d.object(forKey: Keys.prefetchImages) as? Bool ?? true }
        set { d.set(newValue, forKey: Keys.prefetchImages) }
    }
    static var showDebugBar: Bool {
        get { d.bool(forKey: Keys.showDebugBar) }
        set { d.set(newValue, forKey: Keys.showDebugBar) }
    }

    // MARK: Session
    static var sessionStreak: Int {
        get { d.integer(forKey: Keys.sessionStreak) }
        set { d.set(newValue, forKey: Keys.sessionStreak) }
    }
    static var sessionMinutesToday: Int {
        get { d.integer(forKey: Keys.sessionMinutesToday) }
        set { d.set(newValue, forKey: Keys.sessionMinutesToday) }
    }
    static var daysWithAppTotal: Int {
        get { d.integer(forKey: Keys.daysWithAppTotal) }
        set { d.set(newValue, forKey: Keys.daysWithAppTotal) }
    }
    static var lastOpenDate: TimeInterval {
        get { d.double(forKey: Keys.lastOpenDate) }
        set { d.set(newValue, forKey: Keys.lastOpenDate) }
    }

    // MARK: Sources
    static var hasInitializedSourceDefaults: Bool {
        get { d.bool(forKey: Keys.hasInitializedSourceDefaults) }
        set { d.set(newValue, forKey: Keys.hasInitializedSourceDefaults) }
    }

    // MARK: Maintenance
    static var lastHeavyMaintenance: TimeInterval {
        get { d.double(forKey: Keys.lastHeavyMaintenance) }
        set { d.set(newValue, forKey: Keys.lastHeavyMaintenance) }
    }

    // MARK: Content Filters
    static var contentFiltersEnabled: Bool {
        get { d.object(forKey: Keys.contentFiltersEnabled) as? Bool ?? true }
        set { d.set(newValue, forKey: Keys.contentFiltersEnabled) }
    }
}
