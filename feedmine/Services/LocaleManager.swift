import Foundation
import Observation

// MARK: - Language Model

struct Language: Identifiable, Equatable, Hashable {
    let code: String            // BCP-47: "en", "pt-BR", "zh-Hans"
    let displayName: String     // Native name: "English", "Português (Brasil)", "简体中文"

    var id: String { code }

    /// Match a system preference string (e.g. "pt-BR" or "pt") against this language code.
    func matches(_ systemPref: String) -> Bool {
        code == systemPref || systemPref.hasPrefix(code) || code.hasPrefix(systemPref)
    }
}

// MARK: - LocaleManager

@MainActor
@Observable
final class LocaleManager {
    static let shared = LocaleManager()

    /// All languages available in the app.
    /// Ordered alphabetically by display name within script/region groups.
    static let supportedLanguages: [Language] = [
        Language(code: "ar",         displayName: "العربية"),
        Language(code: "ca",         displayName: "Català"),
        Language(code: "zh-Hans",    displayName: "简体中文"),
        Language(code: "zh-Hant",    displayName: "繁體中文"),
        Language(code: "hr",         displayName: "Hrvatski"),
        Language(code: "cs",         displayName: "Čeština"),
        Language(code: "da",         displayName: "Dansk"),
        Language(code: "nl",         displayName: "Nederlands"),
        Language(code: "en",         displayName: "English"),
        Language(code: "en-AU",      displayName: "English (Australia)"),
        Language(code: "en-GB",      displayName: "English (UK)"),
        Language(code: "en-IN",      displayName: "English (India)"),
        Language(code: "fi",         displayName: "Suomi"),
        Language(code: "fr",         displayName: "Français"),
        Language(code: "fr-CA",      displayName: "Français (Canada)"),
        Language(code: "de",         displayName: "Deutsch"),
        Language(code: "el",         displayName: "Ελληνικά"),
        Language(code: "he",         displayName: "עברית"),
        Language(code: "hi",         displayName: "हिन्दी"),
        Language(code: "hu",         displayName: "Magyar"),
        Language(code: "id",         displayName: "Indonesia"),
        Language(code: "it",         displayName: "Italiano"),
        Language(code: "ja",         displayName: "日本語"),
        Language(code: "ko",         displayName: "한국어"),
        Language(code: "ms",         displayName: "Melayu"),
        Language(code: "nb",         displayName: "Norsk Bokmål"),
        Language(code: "pl",         displayName: "Polski"),
        Language(code: "pt-BR",      displayName: "Português (Brasil)"),
        Language(code: "pt-PT",      displayName: "Português (Portugal)"),
        Language(code: "ro",         displayName: "Română"),
        Language(code: "ru",         displayName: "Русский"),
        Language(code: "sk",         displayName: "Slovenčina"),
        Language(code: "es",         displayName: "Español"),
        Language(code: "es-419",     displayName: "Español (Latinoamérica)"),
        Language(code: "sv",         displayName: "Svenska"),
        Language(code: "th",         displayName: "ไทย"),
        Language(code: "tr",         displayName: "Türkçe"),
        Language(code: "uk",         displayName: "Українська"),
        Language(code: "vi",         displayName: "Tiếng Việt"),
    ]

    /// English fallback (always first match for unsupported system languages).
    private static let english: Language = supportedLanguages.first(where: { $0.code == "en" })!

    // MARK: - State

    /// The currently selected language.
    var selectedLanguage: Language

    private init() {
        selectedLanguage = Self.resolveLanguage()
    }

    // MARK: - Language Resolution

    /// Resolve the effective language at launch:
    /// 1. UserDefaults "AppleLanguages" (user's explicit in-app choice)
    /// 2. System preferred languages chain
    /// 3. English fallback
    private static func resolveLanguage() -> Language {
        // 1. Explicit user choice (saved via AppleLanguages)
        if let saved = UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first {
            if let match = supportedLanguages.first(where: { $0.matches(saved) }) {
                return match
            }
        }

        // 2. System preferred languages chain
        for pref in Locale.preferredLanguages {
            if let match = supportedLanguages.first(where: { $0.matches(pref) }) {
                return match
            }
        }

        // 3. Fallback
        return english
    }

    // MARK: - Actions

    /// Persist a new language selection. The change takes effect on next app launch.
    func selectLanguage(_ language: Language) {
        selectedLanguage = language
        UserDefaults.standard.set([language.code], forKey: "AppleLanguages")
        UserDefaults.standard.synchronize()
    }
}
