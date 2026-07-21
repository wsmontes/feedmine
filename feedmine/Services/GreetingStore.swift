import Foundation

/// Loads greeting variants from Greetings.json so they can be expanded
/// without touching Swift code. Add languages or variants in the JSON freely.
@MainActor
enum GreetingStore {
    private static var cache: GreetingData?
    private static var lastLanguage: String?

    // MARK: - Public API

    /// Pick a random greeting variant for the given time-of-day period.
    /// Falls back to English if the current language isn't in the JSON.
    static func random(for period: TimeOfDay) -> String {
        let variants = greetings(for: period)
        return variants.randomElement() ?? fallback(for: period)
    }

    /// First (default) greeting for the period — used by simple header views.
    static func primary(for period: TimeOfDay) -> String {
        greetings(for: period).first ?? fallback(for: period)
    }

    /// All variants for the period in the current language.
    static func variants(for period: TimeOfDay) -> [String] {
        greetings(for: period)
    }

    /// Current app language reduced to the base code used by Greetings.json.
    static var currentLanguageCode: String { currentLanguage() }

    // MARK: - Private

    private static func greetings(for period: TimeOfDay) -> [String] {
        let data = load()
        let lang = currentLanguage()
        let key = period.rawValue
        if let variants = data.greetings[lang]?[key], !variants.isEmpty {
            return variants
        }
        // Fallback to English
        return data.greetings["en"]?[key] ?? []
    }

    private static func fallback(for period: TimeOfDay) -> String {
        switch period {
        case .night:     return "Hello"
        case .dawn:      return "Good morning"
        case .morning:   return "Good morning"
        case .afternoon: return "Good afternoon"
        case .evening:   return "Good evening"
        case .lateNight: return "Hello"
        }
    }

    private static func load() -> GreetingData {
        let lang = currentLanguage()
        if let cached = cache, lastLanguage == lang { return cached }
        guard let url = Bundle.main.url(forResource: "Greetings", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(GreetingData.self, from: data)
        else {
            return GreetingData(greetings: [:])
        }
        cache = decoded
        lastLanguage = lang
        return decoded
    }

    private static func currentLanguage() -> String {
        if let saved = UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first {
            return String(saved.prefix(2))
        }
        return Locale.current.language.languageCode?.identifier ?? "en"
    }
}

// MARK: - JSON Model

struct GreetingData: Codable {
    let greetings: [String: [String: [String]]]  // lang → period → variants
}
