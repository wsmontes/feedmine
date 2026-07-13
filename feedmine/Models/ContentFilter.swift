import Foundation

// MARK: - Content Filter Model

struct ContentFilter: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var keywords: [String]
    var isEnabled: Bool
    var isTemplate: Bool
    var templateKey: String?   // e.g. "politics", "crypto" — links to bundled template
    var hiddenCount: Int

    init(id: UUID = UUID(), name: String, keywords: [String], isEnabled: Bool = true,
         isTemplate: Bool = false, templateKey: String? = nil, hiddenCount: Int = 0) {
        self.id = id
        self.name = name
        self.keywords = keywords
        self.isEnabled = isEnabled
        self.isTemplate = isTemplate
        self.templateKey = templateKey
        self.hiddenCount = hiddenCount
    }
}

// MARK: - Template Definition (bundled JSON structure)

struct ContentFilterTemplate: Codable, Sendable {
    let key: String
    let names: [String: String]           // locale → display name
    let keywords: [String: [String]]      // locale → keyword list

    /// Resolve keywords for the current device locale + English fallback.
    func resolvedKeywords() -> [String] {
        let locale = Locale.current.language.languageCode?.identifier ?? "en"
        var resolved = Set(keywords["en"] ?? [])  // English always included
        if let localized = keywords[locale] {
            resolved.formUnion(localized)
        }
        // Also try language-region variants (pt-BR → pt)
        let baseLanguage = String(locale.prefix(2))
        if baseLanguage != locale, let base = keywords[baseLanguage] {
            resolved.formUnion(base)
        }
        return Array(resolved)
    }

    /// Resolve display name for the current locale.
    func resolvedName() -> String {
        let locale = Locale.current.language.languageCode?.identifier ?? "en"
        return names[locale] ?? names[String(locale.prefix(2))] ?? names["en"] ?? key.capitalized
    }
}

// MARK: - Content Filter Store

@MainActor
@Observable
final class ContentFilterStore {
    static let shared = ContentFilterStore()

    private(set) var filters: [ContentFilter] = []
    var isEnabled: Bool = true {
        didSet { persist() }
    }

    /// Total items hidden across all filters (rolling, reset daily).
    var totalHiddenToday: Int {
        filters.reduce(0) { $0 + $1.hiddenCount }
    }

    private let persistURL: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("content_filters.json")
    }()

    private init() {
        restore()
    }

    // MARK: - Templates

    /// Load bundled templates and create filters for any not yet in the user's list.
    func loadTemplates() {
        let templates = Self.loadBundledTemplates()
        let existingKeys = Set(filters.compactMap(\.templateKey))
        for template in templates where !existingKeys.contains(template.key) {
            let filter = ContentFilter(
                name: template.resolvedName(),
                keywords: template.resolvedKeywords(),
                isEnabled: false,  // templates are opt-in
                isTemplate: true,
                templateKey: template.key
            )
            filters.append(filter)
        }
        persist()
    }

    /// Refresh template keywords (e.g. after locale change or app update).
    func refreshTemplateKeywords() {
        let templates = Self.loadBundledTemplates()
        let templateMap = Dictionary(uniqueKeysWithValues: templates.map { ($0.key, $0) })
        for i in filters.indices where filters[i].isTemplate {
            guard let key = filters[i].templateKey,
                  let template = templateMap[key] else { continue }
            filters[i].keywords = template.resolvedKeywords()
            filters[i].name = template.resolvedName()
        }
        persist()
    }

    // MARK: - CRUD

    func toggle(_ id: UUID) {
        guard let idx = filters.firstIndex(where: { $0.id == id }) else { return }
        filters[idx].isEnabled.toggle()
        persist()
    }

    func addCustom(name: String, keywords: [String]) {
        let filter = ContentFilter(
            name: name,
            keywords: keywords.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
        )
        filters.append(filter)
        persist()
    }

    func removeCustom(_ id: UUID) {
        filters.removeAll { $0.id == id && !$0.isTemplate }
        persist()
    }

    func updateKeywords(_ id: UUID, keywords: [String]) {
        guard let idx = filters.firstIndex(where: { $0.id == id }) else { return }
        filters[idx].keywords = keywords.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        persist()
    }

    /// Increment hidden count for a filter. Called by the engine.
    func recordHit(_ id: UUID) {
        guard let idx = filters.firstIndex(where: { $0.id == id }) else { return }
        filters[idx].hiddenCount += 1
    }

    func resetDailyCounts() {
        for i in filters.indices { filters[i].hiddenCount = 0 }
        persist()
    }

    // MARK: - Active filters (pre-computed for hot path)

    /// Returns only enabled filters with their lowercased keywords ready for matching.
    var activeFilters: [(id: UUID, keywords: [String])] {
        filters.filter(\.isEnabled).map { ($0.id, $0.keywords) }
    }

    // MARK: - Persistence

    private func persist() {
        do {
            let data = try JSONEncoder().encode(filters)
            try data.write(to: persistURL, options: .atomic)
            UserDefaults.standard.set(isEnabled, forKey: "contentFiltersEnabled")
        } catch {
            print("[ContentFilterStore] persist error: \(error)")
        }
    }

    private func restore() {
        isEnabled = UserDefaults.standard.object(forKey: "contentFiltersEnabled") as? Bool ?? true
        guard FileManager.default.fileExists(atPath: persistURL.path) else {
            loadTemplates()
            return
        }
        do {
            let data = try Data(contentsOf: persistURL)
            filters = try JSONDecoder().decode([ContentFilter].self, from: data)
        } catch {
            print("[ContentFilterStore] restore error: \(error)")
            loadTemplates()
        }
    }

    // MARK: - Bundle loading

    static func loadBundledTemplates() -> [ContentFilterTemplate] {
        guard let url = Bundle.main.url(forResource: "content_filter_templates", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return []
        }
        return (try? JSONDecoder().decode([ContentFilterTemplate].self, from: data)) ?? []
    }
}
