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

    // MARK: - Slot Fillers
    // Design principles:
    // - Slots about the USER are interesting (streak, routine, time)
    // - Slots about the APP are boring (source count, content mix)
    // - Humor: subtle, self-aware, never try-hard
    // - Less is more: a great 6-word greeting beats a mediocre 15-word one

    private static func weekdayName() -> String {
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: Date())
        let hour = cal.component(.hour, from: Date())

        switch weekday {
        case 2: // Monday
            return [
                String(localized: "Monday. We meet again", comment: ""),
                String(localized: "New week, new you. Just kidding", comment: ""),
                String(localized: "Monday", comment: ""),
                String(localized: "Another Monday, another chance", comment: ""),
            ].randomElement()!
        case 3: // Tuesday
            return [
                String(localized: "Tuesday", comment: ""),
                String(localized: "Tuesday. The forgotten weekday", comment: ""),
            ].randomElement()!
        case 4: // Wednesday
            return [
                String(localized: "Midweek", comment: ""),
                String(localized: "Wednesday. Halfway there", comment: ""),
                String(localized: "Hump day", comment: ""),
            ].randomElement()!
        case 5: // Thursday
            return [
                String(localized: "Thursday. Almost", comment: ""),
                String(localized: "Thursday", comment: ""),
            ].randomElement()!
        case 6: // Friday
            return [
                String(localized: "It's Friday", comment: ""),
                String(localized: "Friday. Finally", comment: ""),
                String(localized: "TGIF", comment: ""),
            ].randomElement()!
        case 7: // Saturday
            return hour < 11
                ? String(localized: "Slow Saturday", comment: "")
                : [
                    String(localized: "Saturday", comment: ""),
                    String(localized: "Weekend mode", comment: ""),
                ].randomElement()!
        case 1: // Sunday
            return hour < 11
                ? String(localized: "Lazy Sunday", comment: "")
                : [
                    String(localized: "Sunday", comment: ""),
                    String(localized: "Sunday scaries? Not here", comment: ""),
                ].randomElement()!
        default:
            return ""
        }
    }

    private static func specialDayText(_ ctx: AppContext) -> String {
        guard let date = ctx.activeSpecialDates.first else { return "" }
        return date.label
    }

    private static func countText(_ loader: FeedLoader?) -> String {
        guard let loader, !loader.items.isEmpty else { return "" }
        let n = loader.items.count
        if n > 200 {
            return [
                String(localized: "\(n) stories. You're gonna need a bigger boat", comment: ""),
                String(localized: "\(n) stories. The internet was busy", comment: ""),
                String(localized: "\(n) stories. Nobody said you had to read them all", comment: ""),
            ].randomElement()!
        }
        if n > 80 {
            return [
                String(localized: "\(n) stories — take your pick", comment: ""),
                String(localized: "\(n) stories. Plenty to choose from", comment: ""),
                String(localized: "\(n) stories. The world didn't stop", comment: ""),
            ].randomElement()!
        }
        if n > 30 {
            return [
                String(localized: "\(n) stories", comment: ""),
                String(localized: "\(n) good reads", comment: ""),
                String(localized: "\(n) things worth your time", comment: ""),
            ].randomElement()!
        }
        if n > 10 {
            return [
                String(localized: "\(n) stories", comment: ""),
                String(localized: "\(n) new reads", comment: ""),
            ].randomElement()!
        }
        if n <= 3 {
            return [
                String(localized: "Just \(n). Quality over quantity", comment: ""),
                String(localized: "\(n) stories. Slow news day", comment: ""),
            ].randomElement()!
        }
        return String(localized: "\(n) stories today", comment: "")
    }

    private static func sourcesText(_ loader: FeedLoader?) -> String {
        // Source count is only interesting as a social proof flex
        // at high numbers, or as context when low
        guard let loader else { return "" }
        let n = loader.sourceCount
        if n > 500 { return String(localized: "\(n) sources, zero algorithms", comment: "") }
        if n > 100 { return String(localized: "\(n) sources", comment: "") }
        return ""  // Low counts aren't interesting
    }

    private static func contentText(_ loader: FeedLoader?) -> String {
        // Only mention content mix when it's genuinely noteworthy
        guard let loader, !loader.items.isEmpty else { return "" }
        let videoCount = loader.items.filter(\.isYouTube).count
        let podCount = loader.items.filter(\.isPodcast).count
        if videoCount > 5 && podCount > 5 {
            return String(localized: "Videos, podcasts, and articles", comment: "")
        }
        return ""  // Don't enumerate small numbers
    }

    private static func podcastText(_ loader: FeedLoader?) -> String {
        guard let loader, loader.podcastItemCount > 5 else { return "" }
        let n = loader.podcastItemCount
        return [
            String(localized: "\(n) episodes queued up", comment: ""),
            String(localized: "\(n) podcasts to listen", comment: ""),
        ].randomElement()!
    }

    private static func streakText(_ ctx: AppContext) -> String {
        // Streaks deserve celebration that scales with achievement
        switch ctx.sessionStreak {
        case .days(let n) where n >= 60:
            return [
                String(localized: "\(n) days. At this point it's a lifestyle", comment: ""),
                String(localized: "\(n)-day streak. Honestly, we're impressed", comment: ""),
            ].randomElement()!
        case .days(let n) where n >= 30:
            return [
                String(localized: "\(n) days. Unstoppable 🔥", comment: ""),
                String(localized: "\(n)-day streak. This is commitment", comment: ""),
            ].randomElement()!
        case .days(let n) where n >= 14:
            return [
                String(localized: "\(n)-day streak 🔥", comment: ""),
                String(localized: "\(n) days straight. Not bad", comment: ""),
            ].randomElement()!
        case .days(let n) where n >= 7:
            return [
                String(localized: "\(n) days in a row", comment: ""),
                String(localized: "Week \(n / 7) of your streak", comment: ""),
            ].randomElement()!
        case .days(let n) where n >= 3:
            return String(localized: "Day \(n). Keep going", comment: "")
        default: return ""
        }
    }

    private static func sessionText(_ ctx: AppContext) -> String {
        // Only show if meaningfully deep — never judge the user's pace
        guard ctx.sessionMinutes > 20 else { return "" }
        let min = ctx.sessionMinutes
        if min > 60 {
            return String(localized: "\(min) minutes in. Impressed", comment: "")
        }
        return String(localized: "\(min) min today", comment: "")
    }

    private static func paceText(_ ctx: AppContext) -> String {
        // Removed — judging the user's reading speed is weird
        return ""
    }

    private static func bookmarksText(_ loader: FeedLoader?) -> String {
        // Only interesting at high counts (backlog awareness)
        guard let loader, loader.bookmarkedIDs.count > 10 else { return "" }
        let n = loader.bookmarkedIDs.count
        return String(localized: "\(n) bookmarks waiting", comment: "")
    }

    private static func routineText(_ ctx: AppContext) -> String {
        // The app noticing you — with personality
        switch ctx.routineMatch {
        case .exact: return [
            String(localized: "Right on schedule", comment: ""),
            String(localized: "Like clockwork", comment: ""),
            String(localized: "You're predictable. In a good way", comment: ""),
            String(localized: "Same time as always. Respect", comment: ""),
        ].randomElement()!
        case .approximate: return [
            String(localized: "Around your usual time", comment: ""),
            String(localized: "Close enough to a routine", comment: ""),
            String(localized: "We won't tell your calendar", comment: ""),
        ].randomElement()!
        case .unusual: return [
            String(localized: "You're up late", comment: ""),
            String(localized: "This is new", comment: ""),
            String(localized: "Plot twist", comment: ""),
            String(localized: "Off-script today", comment: ""),
            String(localized: "Well, this is unexpected", comment: ""),
        ].randomElement()!
        case .firstTime: return ""
        }
    }

    private static func toneText(_ ctx: AppContext) -> String {
        // The voice of the app. Brief, wry, never preachy.
        // Think: Seinfeld observing your reading habits.
        let opts: [String]
        switch ctx.timeOfDay {
        case .night, .lateNight:
            opts = [
                String(localized: "No rush", comment: ""),
                String(localized: "The world can wait", comment: ""),
                String(localized: "Can't sleep?", comment: ""),
                String(localized: "We don't judge", comment: ""),
                String(localized: "Tomorrow's problems are tomorrow's", comment: ""),
                String(localized: "Netflix can wait", comment: ""),
                String(localized: "This is between us", comment: ""),
            ]
        case .dawn:
            opts = [
                String(localized: "Before the world wakes up", comment: ""),
                String(localized: "The quiet hour", comment: ""),
                String(localized: "Overachievers anonymous", comment: ""),
                String(localized: "Coffee first. Then this", comment: ""),
                String(localized: "You're up before your notifications", comment: ""),
            ]
        case .morning:
            opts = [
                String(localized: "Here's what happened while you slept", comment: ""),
                String(localized: "The world didn't wait for you", comment: ""),
                String(localized: "Better than a meeting", comment: ""),
                String(localized: "No Zoom required", comment: ""),
                String(localized: "Still cheaper than therapy", comment: ""),
                String(localized: "At least it's not email", comment: ""),
            ]
        case .afternoon:
            opts = [
                String(localized: "No algorithms here", comment: ""),
                String(localized: "Procrastination with purpose", comment: ""),
                String(localized: "Your 3pm escape plan", comment: ""),
                String(localized: "Better than doomscrolling", comment: ""),
                String(localized: "Technically research", comment: ""),
                String(localized: "Just look busy", comment: ""),
                String(localized: "Your boss doesn't need to know", comment: ""),
            ]
        case .evening:
            opts = [
                String(localized: "Nowhere to be", comment: ""),
                String(localized: "The long read hour", comment: ""),
                String(localized: "Couch mode activated", comment: ""),
                String(localized: "You've earned this", comment: ""),
                String(localized: "Better than whatever's on TV", comment: ""),
                String(localized: "The internet, but curated by you", comment: ""),
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
                case "routine": if slots["routine"]?.isEmpty ?? true { continue }
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
