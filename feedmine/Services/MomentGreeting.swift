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
        let fallback = "\(slots["greeting"] ?? String(localized: "Hello", comment: "Fallback greeting")). \(slots["count"] ?? String(localized: "Here's what's new.", comment: "Fallback subtext"))"
        let raw = pick ?? fallback
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
        // Pulled from Greetings.json — add languages and variants there.
        GreetingStore.random(for: ctx.timeOfDay)
    }

    private static func weekdaySlot(_ ctx: AppContext) -> String {
        if ctx.isWeekend {
            let opts = ctx.weekday == .saturday
                ? [
                    String(localized: "Saturday unwind", comment: "Weekend label"),
                    String(localized: "Weekend mode", comment: "Weekend label"),
                    String(localized: "Saturday — slow down", comment: "Weekend label"),
                    String(localized: "Lazy Saturday", comment: "Weekend label"),
                ]
                : [
                    String(localized: "Lazy Sunday", comment: "Weekend label"),
                    String(localized: "Sunday calm", comment: "Weekend label"),
                    String(localized: "Slow Sunday", comment: "Weekend label"),
                    String(localized: "Sunday — no rush", comment: "Weekend label"),
                ]
            return opts.randomElement() ?? String(localized: "Weekend", comment: "Weekend fallback")
        }
        switch ctx.weekday {
        case .monday:    return [
            String(localized: "Monday — fresh start", comment: "Weekday label"),
            String(localized: "New week", comment: "Weekday label"),
            String(localized: "Monday momentum", comment: "Weekday label"),
            String(localized: "Here we go", comment: "Weekday label"),
        ].randomElement()!
        case .tuesday:   return [
            String(localized: "Tuesday", comment: "Weekday label"),
            String(localized: "Tuesday groove", comment: "Weekday label"),
            String(localized: "Settling in", comment: "Weekday label"),
        ].randomElement()!
        case .wednesday: return [
            String(localized: "Midweek already", comment: "Weekday label"),
            String(localized: "Wednesday", comment: "Weekday label"),
            String(localized: "Halfway there", comment: "Weekday label"),
            String(localized: "Hump day", comment: "Weekday label"),
        ].randomElement()!
        case .thursday:  return [
            String(localized: "Thursday", comment: "Weekday label"),
            String(localized: "Almost there", comment: "Weekday label"),
            String(localized: "Thursday energy", comment: "Weekday label"),
        ].randomElement()!
        case .friday:    return [
            String(localized: "Friday's here", comment: "Weekday label"),
            String(localized: "Finally Friday", comment: "Weekday label"),
            String(localized: "Friday — wrap it up", comment: "Weekday label"),
            String(localized: "TGIF", comment: "Weekday label"),
        ].randomElement()!
        default: return String(describing: ctx.weekday).capitalized
        }
    }

    private static func seasonSlot(_ ctx: AppContext) -> String {
        let opts: [String]
        switch ctx.season {
        case .spring: opts = [
            String(localized: "Spring light", comment: "Season description"),
            String(localized: "Spring blooms", comment: "Season description"),
            String(localized: "Spring air", comment: "Season description"),
            String(localized: "Fresh spring", comment: "Season description"),
        ]
        case .summer: opts = [
            String(localized: "Summer days", comment: "Season description"),
            String(localized: "Summer light", comment: "Season description"),
            String(localized: "Long summer days", comment: "Season description"),
            String(localized: "Sunshine season", comment: "Season description"),
        ]
        case .autumn: opts = [
            String(localized: "Autumn crisp", comment: "Season description"),
            String(localized: "Fall colors", comment: "Season description"),
            String(localized: "Crisp autumn", comment: "Season description"),
            String(localized: "Autumn air", comment: "Season description"),
        ]
        case .winter: opts = [
            String(localized: "Winter cozy", comment: "Season description"),
            String(localized: "Winter light", comment: "Season description"),
            String(localized: "Cold and crisp", comment: "Season description"),
            String(localized: "Winter days", comment: "Season description"),
        ]
        }
        return opts.randomElement() ?? ""
    }

    private static func specialSlot(_ ctx: AppContext) -> String {
        guard let date = ctx.activeSpecialDates.first else { return "" }
        switch date {
        case .newYearsDay:    return String(localized: "Happy New Year! 🎉", comment: "Special date greeting")
        case .independenceDay: return String(localized: "Happy 4th of July 🇺🇸", comment: "Special date greeting")
        case .christmasEve:   return String(localized: "Christmas Eve 🎄", comment: "Special date greeting")
        case .christmasDay:   return String(localized: "Merry Christmas! 🎄", comment: "Special date greeting")
        case .newYearsEve:    return String(localized: "New Year's Eve 🥂", comment: "Special date greeting")
        case .thanksgiving:   return String(localized: "Happy Thanksgiving 🦃", comment: "Special date greeting")
        case .halloween:      return String(localized: "Happy Halloween 🎃", comment: "Special date greeting")
        case .valentinesDay:  return String(localized: "Happy Valentine's 💝", comment: "Special date greeting")
        case .memorialDay:    return String(localized: "Memorial Day weekend", comment: "Special date greeting")
        case .laborDay:       return String(localized: "Labor Day — take it easy", comment: "Special date greeting")
        case .earthDay:       return String(localized: "Earth Day 🌍", comment: "Special date greeting")
        case .mothersDay:     return String(localized: "Mother's Day 🌸", comment: "Special date greeting")
        case .fathersDay:     return String(localized: "Father's Day", comment: "Special date greeting")
        case .stPatricksDay:  return String(localized: "St. Patrick's Day 🍀", comment: "Special date greeting")
        case .juneteenth:     return String(localized: "Juneteenth", comment: "Special date greeting")
        case .prideMonth:     return String(localized: "Pride Month 🌈", comment: "Special date greeting")
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
            String(localized: "\(total) new stories", comment: "Article count"),
            newCount > 0 ? String(localized: "\(newCount) unread, \(total) total", comment: "Article count") : String(localized: "\(total) articles", comment: "Article count"),
            String(localized: "\(total) things to read", comment: "Article count"),
            String(localized: "\(total) articles waiting", comment: "Article count"),
            String(localized: "\(total) fresh stories", comment: "Article count"),
            newCount > 20 ? String(localized: "A full inbox — \(newCount) unread", comment: "Article count") : String(localized: "\(total) stories", comment: "Article count"),
            newCount > 5 ? String(localized: "\(newCount) new since last time", comment: "Article count") : String(localized: "\(total) articles", comment: "Article count"),
            String(localized: "\(total) pieces today", comment: "Article count"),
        ]
        return opts.randomElement() ?? String(localized: "\(total) articles", comment: "Article count")
    }

    private static func sourcesSlot(_ loader: FeedLoader?) -> String {
        guard let loader else { return "" }
        let count = loader.sourceCount
        if count == 0 { return "" }
        let opts: [String] = [
            String(localized: "from \(count) sources", comment: "Source count"),
            String(localized: "across \(count) publications", comment: "Source count"),
            String(localized: "from \(count) different voices", comment: "Source count"),
            String(localized: "spanning \(count) sources", comment: "Source count"),
            String(localized: "\(count) sources active", comment: "Source count"),
            String(localized: "from your \(count) trusted sources", comment: "Source count"),
        ]
        return opts.randomElement() ?? String(localized: "from \(count) sources", comment: "Source count fallback")
    }

    private static func contentSlot(_ loader: FeedLoader?) -> String {
        guard let loader else { return "" }
        let categories = loader.availableCategories.prefix(3)
        if categories.isEmpty { return "" }
        let names = categories.map { $0.lowercased() }.joined(separator: ", ")
        let opts: [String] = [
            String(localized: "Mostly \(names)", comment: "Content mix description"),
            String(localized: "\(names) — a good mix", comment: "Content mix description"),
            String(localized: "Heavy on \(names)", comment: "Content mix description"),
            String(localized: "\(names) today", comment: "Content mix description"),
            String(localized: "A mix of \(names)", comment: "Content mix description"),
            String(localized: "\(names) and more", comment: "Content mix description"),
        ]
        return opts.randomElement() ?? ""
    }

    private static func podcastSlot(_ loader: FeedLoader?) -> String {
        guard let loader else { return "" }
        let count = loader.podcastItemCount
        if count == 0 { return "" }
        let opts: [String] = [
            String(localized: "\(count) podcasts ready", comment: "Podcast count"),
            String(localized: "🎧 \(count) new episodes", comment: "Podcast count"),
            String(localized: "\(count) podcasts + articles", comment: "Podcast count"),
            String(localized: "Podcast queue: \(count)", comment: "Podcast count"),
            String(localized: "\(count) episodes waiting", comment: "Podcast count"),
        ]
        return opts.randomElement() ?? String(localized: "\(count) podcasts", comment: "Podcast count fallback")
    }

    private static func streakSlot(_ ctx: AppContext) -> String {
        switch ctx.sessionStreak {
        case .firstTime: return ""
        case .newStreak: return String(localized: "New streak started", comment: "Streak status")
        case .days(let n):
            if n <= 1 { return "" }
            let opts: [String] = [
                String(localized: "\(n)-day streak 🔥", comment: "Streak in days"),
                String(localized: "\(n) days in a row", comment: "Streak in days"),
                String(localized: "Day \(n) — on a roll", comment: "Streak in days"),
                String(localized: "\(n)-day streak. Consistency.", comment: "Streak in days"),
            ]
            return opts.randomElement() ?? String(localized: "\(n)-day streak", comment: "Streak fallback")
        case .weeks: return ""
        }
    }

    private static func sessionSlot(_ ctx: AppContext) -> String {
        let min = ctx.sessionMinutes
        switch ctx.sessionLevel {
        case .justOpened: return ""
        case .settlingIn:
            return [
                String(localized: "Just opened", comment: "Session status"),
                String(localized: "A few minutes in", comment: "Session status"),
                String(localized: "Getting started", comment: "Session status"),
                String(localized: "Settling in", comment: "Session status"),
            ].randomElement()!
        case .engaged:
            return [
                String(localized: "\(min) min in", comment: "Session duration"),
                String(localized: "\(min) minutes of reading", comment: "Session duration"),
                String(localized: "\(min) min — in the zone", comment: "Session duration"),
            ].randomElement()!
        case .deep:
            return [
                String(localized: "\(min) min — deep read", comment: "Session duration"),
                String(localized: "\(min) min focused", comment: "Session duration"),
                String(localized: "Deep in it — \(min) min", comment: "Session duration"),
            ].randomElement()!
        case .extended:
            let opts = [
                String(localized: "\(min) min — maybe stretch?", comment: "Session duration"),
                String(localized: "\(min) min. Take a break?", comment: "Session duration"),
                String(localized: "Long session: \(min) min", comment: "Session duration"),
                String(localized: "\(min) min. The world hasn't ended.", comment: "Session duration"),
            ]
            return opts.randomElement()!
        case .marathon:
            let opts = [
                String(localized: "\(min) min — phone down?", comment: "Session duration"),
                String(localized: "Still here? \(min) min 😅", comment: "Session duration"),
                String(localized: "\(min) min. We're flattered.", comment: "Session duration"),
                String(localized: "Marathon session: \(min) min", comment: "Session duration"),
            ]
            return opts.randomElement()!
        }
    }

    private static func paceSlot(_ ctx: AppContext) -> String {
        switch ctx.readingPace {
        case .skimming: return [
            String(localized: "Quick scan today", comment: "Reading pace"),
            String(localized: "Skimming through", comment: "Reading pace"),
            String(localized: "Speed round", comment: "Reading pace"),
            String(localized: "Fast and curious", comment: "Reading pace"),
        ].randomElement()!
        case .steady:   return ""
        case .deep:     return [
            String(localized: "Deep read mode", comment: "Reading pace"),
            String(localized: "Taking your time", comment: "Reading pace"),
            String(localized: "Slow and steady", comment: "Reading pace"),
            String(localized: "Reading deeply", comment: "Reading pace"),
        ].randomElement()!
        case .marathon: return ""
        }
    }

    private static func bookmarksSlot(_ loader: FeedLoader?) -> String {
        guard let loader else { return "" }
        let count = loader.bookmarkedIDs.count
        if count == 0 { return "" }
        let opts: [String] = [
            String(localized: "\(count) saved to read later", comment: "Bookmark count"),
            String(localized: "\(count) in bookmarks", comment: "Bookmark count"),
            String(localized: "\(count) waiting in bookmarks", comment: "Bookmark count"),
            String(localized: "Bookmarks: \(count)", comment: "Bookmark count"),
        ]
        return opts.randomElement() ?? String(localized: "\(count) bookmarked", comment: "Bookmark count fallback")
    }

    private static func routineSlot(_ ctx: AppContext) -> String {
        switch ctx.routineMatch {
        case .exact:      return [
            String(localized: "Right on schedule", comment: "Routine match"),
            String(localized: "Like clockwork", comment: "Routine match"),
            String(localized: "Your usual time", comment: "Routine match"),
            String(localized: "Right on time", comment: "Routine match"),
        ].randomElement()!
        case .approximate: return [
            String(localized: "Around your usual time", comment: "Routine match"),
            String(localized: "Weekday routine ☕", comment: "Routine match"),
            String(localized: "Your reading hour", comment: "Routine match"),
            String(localized: "The usual rhythm", comment: "Routine match"),
        ].randomElement()!
        case .unusual:    return [
            String(localized: "Unusual time for you", comment: "Routine match"),
            String(localized: "Off-schedule today", comment: "Routine match"),
            String(localized: "Mixing it up!", comment: "Routine match"),
            String(localized: "Everything ok?", comment: "Routine match"),
        ].randomElement()!
        case .firstTime:  return ""
        }
    }

    private static func toneSlot(_ ctx: AppContext) -> String {
        let opts: [String]
        switch ctx.timeOfDay {
        case .night, .lateNight:
            opts = [
                String(localized: "No rush", comment: "Tone message"),
                String(localized: "Take your time", comment: "Tone message"),
                String(localized: "The world can wait", comment: "Tone message"),
                String(localized: "Nothing urgent", comment: "Tone message"),
                String(localized: "Just you and the words", comment: "Tone message"),
            ]
        case .dawn:
            opts = [
                String(localized: "The world is still quiet", comment: "Tone message"),
                String(localized: "Perfect time to read", comment: "Tone message"),
                String(localized: "Before the noise starts", comment: "Tone message"),
                String(localized: "Take your time", comment: "Tone message"),
            ]
        case .morning:
            opts = [
                String(localized: "Let's see what's happening", comment: "Tone message"),
                String(localized: "Nothing urgent, just interesting", comment: "Tone message"),
                String(localized: "The news can wait — or not", comment: "Tone message"),
                String(localized: "Here's what matters", comment: "Tone message"),
            ]
        case .afternoon:
            opts = [
                String(localized: "Quick hits, big ideas", comment: "Tone message"),
                String(localized: "No algorithm. No ads.", comment: "Tone message"),
                String(localized: "The internet is loud. This isn't.", comment: "Tone message"),
                String(localized: "Just interesting things", comment: "Tone message"),
            ]
        case .evening:
            opts = [
                String(localized: "The day is winding down", comment: "Tone message"),
                String(localized: "These are worth the slow read", comment: "Tone message"),
                String(localized: "No rush — stay a while", comment: "Tone message"),
                String(localized: "Evening reads hit different", comment: "Tone message"),
            ]
        }
        return opts.randomElement() ?? String(localized: "Take your time", comment: "Default tone")
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
                "[special]. [count] · [tone]",
                "[greeting]. [special]. [count] · [tone]",
                "[special] · [count] · [tone]",
                "[season]. [special]. [tone]",
                "[special]! [count]",
                "[special]. [count] · [sources]",
                "[greeting]. [special] · [count]",
                "[special]. [count], [tone]",
            ]))
        }

        // Priority 1: Night / late night — check time of day, not translated text
        let tod = AppContext.shared.timeOfDay
        if tod == .night || tod == .lateNight {
            groups.append(TemplateGroup(name: "night", priority: 1, templates: [
                "[greeting]. [count]. [tone]",
                "[greeting]. [count] · [tone]",
                "[greeting]. [routine] · [count]",
                "[season] · [greeting]. [count], [tone]",
                "[greeting]. [session]",
            ]))
        }

        // Priority 2: Morning / dawn greeting
        groups.append(TemplateGroup(name: "opening", priority: 2, templates: [
            "[greeting]. [count], [sources]",
            "[weekday]. [count] · [sources]",
            "[greeting]! [count] · [tone]",
            "[weekday]. [count] · [tone]",
            "[greeting]. [routine] · [count]",
            "[season] · [count], [tone]",
            "[greeting]. [streak]. [count]",
            "[weekday]. [sources], [count]",
            "[greeting]! [content]. [tone]",
            "[weekday]. [count]. [tone]",
        ]))

        // Priority 3: Deep session / reading pace
        if !(slots["session"]?.isEmpty ?? true) {
            groups.append(TemplateGroup(name: "reading", priority: 3, templates: [
                "[session]. [pace] · [tone]",
                "[pace]. [count] · [tone]",
                "[session]. [streak]",
                "[bookmarks]. [count] · [tone]",
                "[pace]. [sources]. [streak]",
                "[session]. [count] · [tone]",
                "[routine]. [pace] · [count]",
                "[count]. [tone]",
                "[session] · [count]",
                "[session]. [tone]",
            ]))
        }

        // Priority 4: Podcasts
        if !(slots["podcast"]?.isEmpty ?? true) {
            groups.append(TemplateGroup(name: "podcast", priority: 4, templates: [
                "[greeting]. [podcast] · [count]",
                "[podcast]. [sources] · [count]",
                "[podcast] + [count]",
                "[weekday]. [podcast] · [count]",
                "[podcast] · [count] · [tone]",
                "[count], [podcast]",
                "[podcast]. [tone]",
                "🎧 [podcast] + 📖 [count]",
            ]))
        }

        // Priority 5: Streaks
        if !(slots["streak"]?.isEmpty ?? true) {
            groups.append(TemplateGroup(name: "streak", priority: 5, templates: [
                "[streak]! [count] · [tone]",
                "[routine]. [streak]",
                "[greeting]. [streak]. [count]",
                "[streak]. [weekday] · [count]",
                "[routine]. [pace] · [count]",
                "[streak]. [tone]",
                "[streak]. [sources], [count]",
            ]))
        }

        // Priority 6: Playful / voice
        groups.append(TemplateGroup(name: "voice", priority: 6, templates: [
            "[greeting]! [content] · [tone]",
            "[count]. [sources]. [tone]",
            "[weekday]. [tone] · [count]",
            "[greeting]. [count]. [tone]",
            "[count] · [sources] · [tone]",
            "[greeting]! [count] · [sources]",
            "[greeting]. [content] · [count]",
            "[count] · [tone]",
        ]))

        // Priority 7: Fallback — always available
        groups.append(TemplateGroup(name: "fallback", priority: 7, templates: [
            "[greeting]. [count]",
            "[greeting]. [count] · [tone]",
            "[greeting]. [weekday]. [count]",
            "[greeting]. [tone]",
            "[greeting]. [season]. [count]",
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
