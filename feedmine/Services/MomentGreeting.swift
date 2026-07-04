import Foundation

@MainActor
struct MomentGreeting {
    /// Last raw template index used (anti-repeat)
    private static var lastTemplateIndex: Int = -1
    private static var lastTemplateTime: Date = .distantPast

    static func generate(loader: FeedLoader? = nil) -> String {
        let ctx = AppContext.shared
        let loader = loader
        let slots = fillSlots(ctx, loader: loader)
        let candidates = buildCandidates(slots: slots)
        let pick = selectFrom(candidates)
        let raw = pick ?? "\(slots["greeting"] ?? "Hello"). Here's what's new."
        let cleaned = cleanUnfilledSlots(raw)
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix(".") || trimmed.hasSuffix("?") || trimmed.hasSuffix("!") { return trimmed }
        return trimmed + "."
    }

    // MARK: - Slot Engine

    private static func fillSlots(_ ctx: AppContext, loader: FeedLoader?) -> [String: String] {
        var s: [String: String] = [:]

        // ── Time ──
        s["greeting"] = greetingSlot(ctx)
        s["weekday"] = weekdaySlot(ctx)
        s["season"] = seasonSlot(ctx)
        s["special"] = specialSlot(ctx)

        // ── Feed ──
        s["count"] = countSlot(loader)
        s["sources"] = sourcesSlot(loader)
        s["content"] = contentSlot(loader)
        s["podcast"] = podcastSlot(loader)

        // ── Reading ──
        s["streak"] = streakSlot(ctx)
        s["session"] = sessionSlot(ctx)
        s["pace"] = paceSlot(ctx)
        s["bookmarks"] = bookmarksSlot(loader)

        // ── Patterns ──
        s["routine"] = routineSlot(ctx)

        // ── Tone ──
        s["tone"] = toneSlot(ctx)

        return s
    }

    // MARK: Slot Functions

    private static func greetingSlot(_ ctx: AppContext) -> String {
        let greetings: [String]
        switch ctx.timeOfDay {
        case .night:     greetings = ["Late night", "Still up?", "Past midnight", "The small hours", "Quiet night"]
        case .dawn:      greetings = ["Early morning", "Almost dawn", "The sun's waking up", "Before the world stirs", "Dawn patrol", "First light"]
        case .morning:   greetings = ["Good morning", "Morning", "Rise and read", "Top of the morning", "Bright and early"]
        case .afternoon: greetings = ["Good afternoon", "Afternoon", "Midday check-in", "Peak afternoon", "Afternoon light"]
        case .evening:   greetings = ["Good evening", "Evening light", "Golden hour", "Sundown", "Twilight time"]
        case .lateNight: greetings = ["Late night", "The world is asleep", "Night owl hours", "Burning the midnight oil"]
        }
        return greetings.randomElement() ?? "Hello"
    }

    private static func weekdaySlot(_ ctx: AppContext) -> String {
        if ctx.isWeekend {
            let opts = ctx.weekday == .saturday
                ? ["Saturday unwind", "Weekend mode", "Saturday — slow down", "Lazy Saturday"]
                : ["Lazy Sunday", "Sunday calm", "Slow Sunday", "Sunday — no rush"]
            return opts.randomElement() ?? "Weekend"
        }
        switch ctx.weekday {
        case .monday:    return ["Monday — fresh start", "New week", "Monday momentum", "Here we go"].randomElement()!
        case .tuesday:   return ["Tuesday", "Tuesday groove", "Settling in"].randomElement()!
        case .wednesday: return ["Midweek already", "Wednesday", "Halfway there", "Hump day"].randomElement()!
        case .thursday:  return ["Thursday", "Almost there", "Thursday energy"].randomElement()!
        case .friday:    return ["Friday's here", "Finally Friday", "Friday — wrap it up", "TGIF"].randomElement()!
        default: return String(describing: ctx.weekday).capitalized
        }
    }

    private static func seasonSlot(_ ctx: AppContext) -> String {
        let opts: [String]
        switch ctx.season {
        case .spring: opts = ["Spring light", "Spring blooms", "Spring air", "Fresh spring"]
        case .summer: opts = ["Summer days", "Summer light", "Long summer days", "Sunshine season"]
        case .autumn: opts = ["Autumn crisp", "Fall colors", "Crisp autumn", "Autumn air"]
        case .winter: opts = ["Winter cozy", "Winter light", "Cold and crisp", "Winter days"]
        }
        return opts.randomElement() ?? ""
    }

    private static func specialSlot(_ ctx: AppContext) -> String {
        guard let date = ctx.activeSpecialDates.first else { return "" }
        switch date {
        case .newYearsDay:    return "Happy New Year! 🎉"
        case .independenceDay: return "Happy 4th of July 🇺🇸"
        case .christmasEve:   return "Christmas Eve 🎄"
        case .christmasDay:   return "Merry Christmas! 🎄"
        case .newYearsEve:    return "New Year's Eve 🥂"
        case .thanksgiving:   return "Happy Thanksgiving 🦃"
        case .halloween:      return "Happy Halloween 🎃"
        case .valentinesDay:  return "Happy Valentine's 💝"
        case .memorialDay:    return "Memorial Day weekend"
        case .laborDay:       return "Labor Day — take it easy"
        case .earthDay:       return "Earth Day 🌍"
        case .mothersDay:     return "Mother's Day 🌸"
        case .fathersDay:     return "Father's Day"
        case .stPatricksDay:  return "St. Patrick's Day 🍀"
        case .juneteenth:     return "Juneteenth"
        case .prideMonth:     return "Pride Month 🌈"
        default: return ""
        }
    }

    private static func countSlot(_ loader: FeedLoader?) -> String {
        guard let loader else { return "" }
        let total = loader.filteredItems.count
        let unread = loader.items.count - loader.readItemIDs.count
        let newCount = max(0, unread)
        if total == 0 { return "" }
        let opts: [String] = [
            "\(total) new stories",
            newCount > 0 ? "\(newCount) unread, \(total) total" : "\(total) articles",
            "\(total) things to read",
            "\(total) articles waiting",
            "\(total) fresh stories",
            newCount > 20 ? "A full inbox — \(newCount) unread" : "\(total) stories",
            newCount > 5 ? "\(newCount) new since last time" : "\(total) articles",
            "\(total) pieces today",
        ]
        return opts.randomElement() ?? "\(total) articles"
    }

    private static func sourcesSlot(_ loader: FeedLoader?) -> String {
        guard let loader else { return "" }
        let count = loader.sourceCount
        if count == 0 { return "" }
        let opts: [String] = [
            "from \(count) sources",
            "across \(count) publications",
            "from \(count) different voices",
            "spanning \(count) sources",
            "\(count) sources active",
            "from your \(count) trusted sources",
        ]
        return opts.randomElement() ?? "from \(count) sources"
    }

    private static func contentSlot(_ loader: FeedLoader?) -> String {
        guard let loader else { return "" }
        let categories = loader.availableCategories.prefix(3)
        if categories.isEmpty { return "" }
        let names = categories.map { $0.lowercased() }.joined(separator: ", ")
        let opts: [String] = [
            "Mostly \(names)",
            "\(names) — a good mix",
            "Heavy on \(names)",
            "\(names) today",
            "A mix of \(names)",
            "\(names) and more",
        ]
        return opts.randomElement() ?? ""
    }

    private static func podcastSlot(_ loader: FeedLoader?) -> String {
        guard let loader else { return "" }
        let count = loader.podcastItemCount
        if count == 0 { return "" }
        let opts: [String] = [
            "\(count) podcasts ready",
            "🎧 \(count) new episodes",
            "\(count) podcasts + articles",
            "Podcast queue: \(count)",
            "\(count) episodes waiting",
        ]
        return opts.randomElement() ?? "\(count) podcasts"
    }

    private static func streakSlot(_ ctx: AppContext) -> String {
        switch ctx.sessionStreak {
        case .firstTime: return ""
        case .newStreak: return "New streak started"
        case .days(let n):
            if n <= 1 { return "" }
            let opts: [String] = [
                "\(n)-day streak 🔥",
                "\(n) days in a row",
                "Day \(n) — on a roll",
                "\(n)-day streak. Consistency.",
            ]
            return opts.randomElement() ?? "\(n)-day streak"
        case .weeks: return ""
        }
    }

    private static func sessionSlot(_ ctx: AppContext) -> String {
        let min = ctx.sessionMinutes
        switch ctx.sessionLevel {
        case .justOpened: return ""
        case .settlingIn:
            return ["Just opened", "A few minutes in", "Getting started", "Settling in"].randomElement()!
        case .engaged:
            return ["\(min) min in", "\(min) minutes of reading", "\(min) min — in the zone"].randomElement()!
        case .deep:
            return ["\(min) min — deep read", "\(min) min focused", "Deep in it — \(min) min"].randomElement()!
        case .extended:
            let opts = ["\(min) min — maybe stretch?", "\(min) min. Take a break?", "Long session: \(min) min", "\(min) min. The world hasn't ended."]
            return opts.randomElement()!
        case .marathon:
            let opts = ["\(min) min — phone down?", "Still here? \(min) min 😅", "\(min) min. We're flattered.", "Marathon session: \(min) min"]
            return opts.randomElement()!
        }
    }

    private static func paceSlot(_ ctx: AppContext) -> String {
        switch ctx.readingPace {
        case .skimming: return ["Quick scan today", "Skimming through", "Speed round", "Fast and curious"].randomElement()!
        case .steady:   return ""
        case .deep:     return ["Deep read mode", "Taking your time", "Slow and steady", "Reading deeply"].randomElement()!
        case .marathon: return ""
        }
    }

    private static func bookmarksSlot(_ loader: FeedLoader?) -> String {
        guard let loader else { return "" }
        let count = loader.bookmarkedIDs.count
        if count == 0 { return "" }
        let opts: [String] = [
            "\(count) saved to read later",
            "\(count) in bookmarks",
            "\(count) waiting in bookmarks",
            "Bookmarks: \(count)",
        ]
        return opts.randomElement() ?? "\(count) bookmarked"
    }

    private static func routineSlot(_ ctx: AppContext) -> String {
        switch ctx.routineMatch {
        case .exact:      return ["Right on schedule", "Like clockwork", "Your usual time", "Right on time"].randomElement()!
        case .approximate: return ["Around your usual time", "Weekday routine ☕", "Your reading hour", "The usual rhythm"].randomElement()!
        case .unusual:    return ["Unusual time for you", "Off-schedule today", "Mixing it up!", "Everything ok?"].randomElement()!
        case .firstTime:  return ""
        }
    }

    private static func toneSlot(_ ctx: AppContext) -> String {
        let opts: [String]
        switch ctx.timeOfDay {
        case .night, .lateNight:
            opts = ["No rush", "Take your time", "The world can wait", "Nothing urgent", "Just you and the words"]
        case .dawn:
            opts = ["The world is still quiet", "Perfect time to read", "Before the noise starts", "Take your time"]
        case .morning:
            opts = ["Let's see what's happening", "Nothing urgent, just interesting", "The news can wait — or not", "Here's what matters"]
        case .afternoon:
            opts = ["Quick hits, big ideas", "No algorithm. No ads.", "The internet is loud. This isn't.", "Just interesting things"]
        case .evening:
            opts = ["The day is winding down", "These are worth the slow read", "No rush — stay a while", "Evening reads hit different"]
        }
        return opts.randomElement() ?? "Take your time"
    }

    // MARK: - Template System

    private struct TemplateGroup {
        let name: String
        let priority: Int  // lower = checked first
        let templates: [String]
    }

    private static func buildCandidates(slots: [String: String]) -> [(String, Int)] {
        let groups = templateGroups(slots: slots)
        var results: [(String, Int)] = []

        for group in groups.sorted(by: { $0.priority < $1.priority }) {
            for template in group.templates {
                let filled = fillTemplate(template, slots: slots)
                let score = slots.filter { filled.contains($0.value) && !$0.value.isEmpty }.count
                if score > 0 {
                    results.append((filled, score + (100 - group.priority)))
                }
            }
            if !results.isEmpty { break } // Use highest-priority group that has matches
        }

        return results.sorted { $0.1 > $1.1 }
    }

    private static func templateGroups(slots: [String: String]) -> [TemplateGroup] {
        var groups: [TemplateGroup] = []

        // Priority 0: Special dates
        if !(slots["special"]?.isEmpty ?? true) {
            groups.append(TemplateGroup(name: "special", priority: 0, templates: [
                "[special] [count] — [tone].",
                "[greeting]. [special]. [count] for the holiday.",
                "[special] — no rush today. [count] when you're ready.",
                "[season]. [special] is here. [tone].",
                "[special]! [count] if you feel like it.",
                "[special] reading. [count].",
                "Almost [special]. [count] to wrap up the week.",
                "[special] vibes. [count], [tone].",
            ]))
        }

        // Priority 1: Night / late night
        if slots["greeting"]?.contains("Late") == true || slots["greeting"]?.contains("night") == true || slots["greeting"]?.contains("midnight") == true || slots["greeting"]?.contains("asleep") == true || slots["greeting"]?.contains("owl") == true {
            groups.append(TemplateGroup(name: "night", priority: 1, templates: [
                "[greeting]. [count]. [tone].",
                "[greeting]. Insomnia? [count] — gentle reads only.",
                "Quiet hours. [count], no rush.",
                "Almost tomorrow. [count] before sleep?",
                "[greeting]. [routine] — the night reader's club.",
                "[season] night. [count], [tone].",
                "Burning the midnight oil? [session].",
                "The world's asleep. [count] for you.",
            ]))
        }

        // Priority 2: Morning / dawn greeting
        groups.append(TemplateGroup(name: "opening", priority: 2, templates: [
            "[greeting]. [count], [sources].",
            "[weekday]. [count] — let's see what the world's up to.",
            "[greeting]! [season] light, [count] waiting.",
            "[weekday]. The coffee's hot, [count].",
            "[greeting]. [routine] — [count].",
            "[season] morning. [count], [tone].",
            "[greeting]. [streak]. [count] to catch up on.",
            "[weekday]. [sources], [count].",
            "[greeting]! [content]. [tone].",
            "[weekday]. [count]. [tone] — here's what matters.",
        ]))

        // Priority 3: Deep session / reading pace
        if !(slots["session"]?.isEmpty ?? true) {
            groups.append(TemplateGroup(name: "reading", priority: 3, templates: [
                "[session]. [count] later, you're [pace].",
                "[pace]. [count] — [tone].",
                "[session] into your reading. [streak]",
                "[bookmarks]. [count] new — [tone].",
                "[pace]. [sources]. [streak].",
                "[session]. [count] more won't hurt.",
                "[routine]. [pace] — your usual rhythm.",
                "First read of the day? [count]. [tone].",
                "[session] deep. Your brain says thanks.",
                "[session]. Just checking in.",
            ]))
        }

        // Priority 4: Podcasts
        if !(slots["podcast"]?.isEmpty ?? true) {
            groups.append(TemplateGroup(name: "podcast", priority: 4, templates: [
                "[greeting]. [podcast] and [count] to read.",
                "[podcast]. [sources] — eyes or ears, your call.",
                "Queue up: [podcast] + [count].",
                "[weekday]. [podcast] for your commute.",
                "Listening mode? [podcast]. Reading mode? [count].",
                "[count] to read, [podcast] — full plate.",
                "New episodes. [podcast]. [tone].",
                "🎧 + 📖 = [podcast] + [count]",
            ]))
        }

        // Priority 5: Streaks
        if !(slots["streak"]?.isEmpty ?? true) {
            groups.append(TemplateGroup(name: "streak", priority: 5, templates: [
                "[streak]! [count] for you today.",
                "[routine]. [streak].",
                "[greeting]. [streak]. [count].",
                "[streak]. [weekday] — keeping the habit alive.",
                "[routine]. [pace] at your usual hour.",
                "First time this early? [count]. Mixing it up!",
                "[streak]. Consistency is the superpower.",
                "[streak]. [tone].",
            ]))
        }

        // Priority 6: Playful / voice
        groups.append(TemplateGroup(name: "voice", priority: 6, templates: [
            "You again. [session]. We're flattered, honestly.",
            "[count] articles. The algorithm can't replicate this.",
            "[greeting]! [content] — we know you.",
            "No algorithm. No ads. Just [count] from [sources].",
            "[weekday]. The internet is loud. This isn't.",
            "[greeting]. [tone]. Seriously — nothing urgent here.",
            "Feedmine doesn't know everything. But it knows [count] things.",
            "[count] stories, zero notifications. You're welcome.",
        ]))

        // Priority 7: Fallback — always available
        groups.append(TemplateGroup(name: "fallback", priority: 7, templates: [
            "[greeting]. [count].",
            "[greeting]. Here's what's new.",
            "[greeting]. [weekday]. [count].",
            "[greeting]. Nothing urgent, just interesting.",
            "[greeting]. [season]. [count].",
        ]))

        return groups
    }

    // MARK: - Selection

    private static func selectFrom(_ candidates: [(String, Int)]) -> String? {
        guard !candidates.isEmpty else { return nil }

        // Take top 3 by score, pick one that isn't the last used
        let top = candidates.prefix(3).map { $0.0 }
        let now = Date()

        // If last template was more than 2 hours ago, any is fine
        if now.timeIntervalSince(lastTemplateTime) > 7200 {
            let pick = top.randomElement()!
            if let idx = candidates.firstIndex(where: { $0.0 == pick }) {
                lastTemplateIndex = idx
            }
            lastTemplateTime = now
            return pick
        }

        // Otherwise avoid the last index
        let filtered = top.enumerated().filter { $0.offset != lastTemplateIndex || top.count == 1 }
        let pick = filtered.randomElement()?.element ?? top.randomElement()!
        if let idx = candidates.firstIndex(where: { $0.0 == pick }) {
            lastTemplateIndex = idx
        }
        lastTemplateTime = now
        return pick
    }

    // MARK: - Helpers

    private static func fillTemplate(_ template: String, slots: [String: String]) -> String {
        var result = template
        for (key, value) in slots where !value.isEmpty {
            result = result.replacingOccurrences(of: "[\(key)]", with: value)
        }
        return result
    }

    private static func cleanUnfilledSlots(_ text: String) -> String {
        text.replacingOccurrences(of: #"\[\w+\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "  ", with: " ")
    }
}
