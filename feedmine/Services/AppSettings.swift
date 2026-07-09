import Foundation

/// Single source of truth for persisted app configuration.
/// Replaces scattered UserDefaults string-key access with a typed Codable struct.
/// Thin persistence layer — load on init, save on mutation.
struct AppSettings: Codable {
    // MARK: - Filter state (was: raw UserDefaults strings in FeedStore)
    var filterRegion: String?
    var filterCategory: String?
    var filterContentType: String = "All"
    var filterMood: String = "All"

    // MARK: - Toggle state (was: UserDefaults arrays in SourceRegistry)
    var toggleDisabled: Set<String> = []
    var toggleEnabledOverrides: Set<String> = []

    // MARK: - Session (was: scattered UserDefaults)
    var hasInitializedSourceDefaults: Bool = false
    var sessionStreak: Int = 1
    var sessionMinutesToday: Int = 0
    var daysWithAppTotal: Int = 1
    var lastOpenDate: TimeInterval = 0
    var openTimestamps: [TimeInterval] = []
    var lastHeavyMaintenance: TimeInterval = 0

    // MARK: - What's New
    var lastWhatsNewSeenAt: Date?

    // MARK: - Persistence

    private static let storeKey = "app_settings"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storeKey)
    }
}
