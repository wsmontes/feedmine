import Foundation

// MARK: - MomentGreeting (Data-Driven)
// Templates live in greeting_templates.json. Slot data comes from
// AppContext + FeedLoader. This file is engine-only (~120 lines vs 567).

@MainActor
struct MomentGreeting {
    private static var lastTemplateIndex: Int = -1
    private static var lastTemplateTime: Date = .distantPast

    // MARK: - Public API

    static func generate(loader: FeedLoader? = nil) -> String {
        let ctx = AppContext.shared
        let slots = fillSlots(ctx, loader: loader)
        let templates = loadTemplates()
        let candidates = buildCandidates(templates: templates, slots: slots, ctx: ctx)
        let pick = selectFrom(candidates)
        let fallback = "\(slots["greeting"] ?? "Hello"). \(slots["count"] ?? "Here's what's new.")"
        let raw = pick ?? fallback
        let cleaned = cleanUnfilledSlots(raw)
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix(".") || trimmed.hasSuffix("?") || trimmed.hasSuffix("!") { return trimmed }
        return trimmed + "."
    }

    // MARK: - Slot Engine

    private static func fillSlots(_ ctx: AppContext, loader: FeedLoader?) -> [String: String] {
        var s: [String: String] = [:]
        s["greeting"] = GreetingStore.random(for: ctx.timeOfDay)
        s["weekday"] = weekdayName()
        s["season"] = ctx.season.label
        s["special"] = specialDayText(ctx)
        s["count"] = countText(loader)
        s["sources"] = sourcesText(loader)
        s["content"] = contentText(loader)
        s["podcast"] = podcastText(loader)
        s["streak"] = streakText(ctx)
        s["session"] = sessionText(ctx)
        s["pace"] = paceText(ctx)
        s["bookmarks"] = bookmarksText(loader)
        s["routine"] = routineText(ctx)
        s["tone"] = toneText(ctx)
        return s
    }

    // MARK: - Compact Slot Fillers

    private static func weekdayName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        let day = formatter.string(from: Date())
        // Make weekday work as a greeting fragment: "Happy Monday" / "It's Friday"
        let greetings = [
            String(localized: "Happy \(day)", comment: "Weekday greeting"),
            String(localized: "It's \(day)", comment: "Weekday greeting"),
            String(localized: "\(day) vibes", comment: "Weekday greeting"),
        ]
        return greetings.randomElement()!
    }

    private static func specialDayText(_ ctx: AppContext) -> String {
        guard let date = ctx.activeSpecialDates.first else { return "" }
        return date.label
    }

    private static func countText(_ loader: FeedLoader?) -> String {
        guard let loader, !loader.items.isEmpty else { return "" }
        let count = loader.items.count
        let variants: [String] = [
            String(localized: "\(count) stories", comment: "Article count"),
            String(localized: "\(count) things to read", comment: "Article count"),
            String(localized: "\(count) articles waiting", comment: "Article count"),
            String(localized: "\(count) fresh reads", comment: "Article count"),
        ]
        return variants.randomElement()!
    }

    private static func sourcesText(_ loader: FeedLoader?) -> String {
        guard let loader, loader.sourceCount > 0 else { return "" }
        // Capitalized — works as standalone or after separator
        return String(localized: "\(loader.sourceCount) sources", comment: "Source count")
    }

    private static func contentText(_ loader: FeedLoader?) -> String {
        guard let loader, !loader.items.isEmpty else { return "" }
        let videoCount = loader.items.filter(\.isYouTube).count
        let podCount = loader.items.filter(\.isPodcast).count
        if videoCount > 0 && podCount > 0 {
            return String(localized: "\(videoCount) videos + \(podCount) podcasts", comment: "Content mix")
        } else if videoCount > 3 {
            return String(localized: "\(videoCount) videos today", comment: "Content type")
        } else if podCount > 3 {
            return String(localized: "\(podCount) new episodes", comment: "Content type")
        }
        return ""  // Only show if there's meaningful variety
    }

    private static func podcastText(_ loader: FeedLoader?) -> String {
        guard let loader, loader.podcastItemCount > 3 else { return "" }
        return String(localized: "\(loader.podcastItemCount) episodes ready", comment: "Podcast count")
    }

    private static func streakText(_ ctx: AppContext) -> String {
        switch ctx.sessionStreak {
        case .days(let n) where n >= 7:
            return String(localized: "\(n)-day streak 🔥", comment: "Long streak")
        case .days(let n) where n >= 3:
            return String(localized: "\(n) days in a row", comment: "Reading streak")
        default: return ""
        }
    }

    private static func sessionText(_ ctx: AppContext) -> String {
        guard ctx.sessionMinutes > 10 else { return "" }
        let min = ctx.sessionMinutes
        if min > 30 {
            return String(localized: "\(min) min deep dive", comment: "Long session")
        }
        return String(localized: "\(min) min so far", comment: "Session time")
    }

    private static func paceText(_ ctx: AppContext) -> String {
        switch ctx.readingPace {
        case .skimming: return String(localized: "Quick reads mode", comment: "Pace")
        case .steady: return ""
        case .deep: return String(localized: "Deep reading", comment: "Pace")
        case .marathon: return ""
        }
    }

    private static func bookmarksText(_ loader: FeedLoader?) -> String {
        guard let loader, loader.bookmarkedIDs.count > 2 else { return "" }
        return String(localized: "\(loader.bookmarkedIDs.count) saved for later", comment: "Bookmark count")
    }

    private static func routineText(_ ctx: AppContext) -> String {
        switch ctx.routineMatch {
        case .exact: return [
            String(localized: "Right on time", comment: "Routine"),
            String(localized: "Like clockwork", comment: "Routine"),
        ].randomElement()!
        case .approximate: return [
            String(localized: "Your usual time", comment: "Routine"),
            String(localized: "The usual rhythm", comment: "Routine"),
        ].randomElement()!
        case .unusual: return String(localized: "Different time today", comment: "Routine")
        case .firstTime: return ""
        }
    }

    private static func toneText(_ ctx: AppContext) -> String {
        let opts: [String]
        switch ctx.timeOfDay {
        case .night, .lateNight:
            opts = [
                String(localized: "No rush", comment: "Tone"),
                String(localized: "Take your time", comment: "Tone"),
                String(localized: "The world can wait", comment: "Tone"),
            ]
        case .dawn:
            opts = [
                String(localized: "Before the noise starts", comment: "Tone"),
                String(localized: "The quiet hour", comment: "Tone"),
                String(localized: "Early bird reads", comment: "Tone"),
            ]
        case .morning:
            opts = [
                String(localized: "Here's what matters", comment: "Tone"),
                String(localized: "Catch up time", comment: "Tone"),
                String(localized: "The morning brief", comment: "Tone"),
            ]
        case .afternoon:
            opts = [
                String(localized: "Just interesting things", comment: "Tone"),
                String(localized: "No algorithm, no ads", comment: "Tone"),
                String(localized: "Quick hits, big ideas", comment: "Tone"),
            ]
        case .evening:
            opts = [
                String(localized: "Stay a while", comment: "Tone"),
                String(localized: "The slow read", comment: "Tone"),
                String(localized: "Evening unwind", comment: "Tone"),
            ]
        }
        return opts.randomElement()!
    }

    // MARK: - Template Loading

    private struct TemplateGroup: Codable {
        let name: String
        let priority: Int
        let condition: String?
        let templates: [String]
    }

    private static var cachedTemplates: [TemplateGroup]?

    private static func loadTemplates() -> [TemplateGroup] {
        if let cached = cachedTemplates { return cached }
        guard let url = Bundle.main.url(forResource: "greeting_templates", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let groups = try? JSONDecoder().decode([TemplateGroup].self, from: data) else {
            return []
        }
        cachedTemplates = groups
        return groups
    }

    // MARK: - Candidate Builder

    private static func buildCandidates(templates: [TemplateGroup], slots: [String: String], ctx: AppContext) -> [(String, Int)] {
        for group in templates.sorted(by: { $0.priority < $1.priority }) {
            // Check condition
            if let cond = group.condition {
                switch cond {
                case "special": if slots["special"]?.isEmpty ?? true { continue }
                case "night": if ctx.timeOfDay != .night && ctx.timeOfDay != .lateNight { continue }
                case "session": if slots["session"]?.isEmpty ?? true { continue }
                case "podcast": if slots["podcast"]?.isEmpty ?? true { continue }
                case "streak": if slots["streak"]?.isEmpty ?? true { continue }
                default: break
                }
            }

            var results: [(String, Int)] = []
            for template in group.templates {
                let filled = fillTemplate(template, slots: slots)
                let score = slots.filter { !$0.value.isEmpty && filled.contains($0.value) }.count
                if score > 0 { results.append((filled, score + (100 - group.priority))) }
            }
            if !results.isEmpty {
                return results.sorted { $0.1 > $1.1 }
            }
        }
        return []
    }

    // MARK: - Selection (anti-repeat)

    private static func selectFrom(_ candidates: [(String, Int)]) -> String? {
        guard !candidates.isEmpty else { return nil }
        let top = Array(candidates.prefix(3).map(\.0))
        let now = Date()
        if now.timeIntervalSince(lastTemplateTime) > 7200 {
            let pick = top.randomElement()!
            lastTemplateIndex = candidates.firstIndex { $0.0 == pick } ?? 0
            lastTemplateTime = now
            return pick
        }
        let filtered = top.enumerated().filter { $0.offset != lastTemplateIndex || top.count == 1 }
        let pick = filtered.randomElement()?.element ?? top.randomElement()!
        lastTemplateIndex = candidates.firstIndex { $0.0 == pick } ?? 0
        lastTemplateTime = now
        return pick
    }

    // MARK: - Utilities

    private static func fillTemplate(_ template: String, slots: [String: String]) -> String {
        var result = template
        for (key, value) in slots where !value.isEmpty {
            result = result.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return result
    }

    private static func cleanUnfilledSlots(_ text: String) -> String {
        var result = text
        // Remove unfilled slot placeholders
        result = result.replacingOccurrences(of: #"\{[a-z]+\}"#, with: "", options: .regularExpression)
        // Clean orphaned punctuation left behind
        result = result.replacingOccurrences(of: ". .", with: ".")
        result = result.replacingOccurrences(of: "! .", with: "!")
        result = result.replacingOccurrences(of: "· ·", with: "·")
        result = result.replacingOccurrences(of: " · .", with: ".")
        result = result.replacingOccurrences(of: ". ·", with: ".")
        result = result.replacingOccurrences(of: " ·.", with: ".")
        result = result.replacingOccurrences(of: " + .", with: ".")
        result = result.replacingOccurrences(of: ", ,", with: ",")
        result = result.replacingOccurrences(of: " ,", with: ",")
        result = result.replacingOccurrences(of: "  ", with: " ")
        // Trim trailing separators
        while result.hasSuffix(" ·") || result.hasSuffix(" ·") { result = String(result.dropLast(2)) }
        while result.hasSuffix(",") { result = String(result.dropLast()) }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
