import Foundation

@MainActor
struct MomentGreeting {
    static func generate() -> String {
        let ctx = AppContext.shared
        let slots = fillSlots(ctx)
        let candidates = templates.compactMap { template -> (String, Int)? in
            let filled = fillTemplate(template, slots: slots)
            let score = slots.filter { filled.contains($0.value) }.count
            return score > 0 ? (filled, score) : nil
        }.sorted { $0.1 > $1.1 }

        // Night → prefer night templates
        if ctx.hour < 5 || ctx.hour >= 23 {
            let night = candidates.filter { t in
                t.0.contains("sleep") || t.0.contains("late") || t.0.contains("tea")
                || t.0.contains("night") || t.0.contains("3 AM")
            }
            if let pick = night.randomElement() { return pick.0 }
        }
        // Long session → prefer check-in
        if ctx.sessionLevel == .extended || ctx.sessionLevel == .marathon {
            let checkins = candidates.filter { t in
                t.0.contains("stretch") || t.0.contains("break") || t.0.contains("walk")
                || t.0.contains("phone down") || t.0.contains("eyes") || t.0.contains("outside")
            }
            if let pick = checkins.randomElement() { return pick.0 }
        }

        return candidates.first?.0 ?? "\(slots["time"] ?? "Hello"). Here's what's new."
    }

    private static func fillSlots(_ ctx: AppContext) -> [String: String] {
        var s: [String: String] = [:]

        s["time"] = ctx.timeOfDay == .night ? "Late night" :
                    ctx.timeOfDay == .dawn ? "Early morning" :
                    ctx.timeOfDay == .morning ? "Good morning" :
                    ctx.timeOfDay == .afternoon ? "Good afternoon" :
                    ctx.timeOfDay == .evening ? "Good evening" : "Still up"

        if let cond = ctx.weatherCondition {
            s["weather"] = weatherText(cond)
        }

        s["weekday"] = ctx.isWeekend
            ? (ctx.weekday == .saturday ? "Saturday unwind" : "Lazy Sunday")
            : "\(ctx.weekday)"

        s["session"] = ctx.sessionLevel == .justOpened ? "Just opened" :
            ctx.sessionLevel == .settlingIn ? "Getting comfortable" :
            ctx.sessionLevel == .engaged ? "\(ctx.sessionMinutes) min in" :
            ctx.sessionLevel == .deep ? "\(ctx.sessionMinutes) min — deep read" :
            ctx.sessionLevel == .extended ? "\(ctx.sessionMinutes) min — maybe stretch?" :
            "\(ctx.sessionMinutes) min — phone down?"

        s["season"] = ctx.season == .spring ? "Spring blooms" :
            ctx.season == .summer ? "Summer light" :
            ctx.season == .autumn ? "Autumn crisp" : "Winter cozy"

        s["personal"] = [
            "We saved you a seat", "The world can wait", "Take your time",
            "No rush", "Good to see you", "Right on time", "Welcome back",
            "Here you are", "Ready when you are"
        ].randomElement()!

        return s
    }

    private static func weatherText(_ cond: WeatherCondition) -> String {
        switch cond {
        case .clear: "Sun's out"
        case .partlyCloudy: "Partly cloudy"
        case .cloudy, .overcast: "Cloudy skies"
        case .rain, .drizzle: "Rain's falling"
        case .heavyRain, .thunderstorm: "Stormy out there"
        case .snow, .sleet, .hail: "Snow day"
        case .fog: "Foggy morning"
        case .windy: "Windy out there"
        case .tornado, .hurricane: "Stay safe"
        }
    }

    private static func fillTemplate(_ template: String, slots: [String: String]) -> String {
        var result = template
        for (key, value) in slots { result = result.replacingOccurrences(of: "[\(key)]", with: value) }
        return result
    }

    private static let templates: [String] = [
        // Warm & welcoming
        "[time]. [weather] outside — perfect reading weather.",
        "[time]! [weather] means a good day to stay curious.",
        "[weekday]. [weather]. We saved you a seat.",
        "[time]. [season] air, fresh stories.",
        "[weekday]. The coffee's hot, the news is fresh.",
        "[time]. [personal] — here's what's happening.",
        "[time]. [weather]. [personal]",
        "[time]. Nothing urgent, just interesting.",

        // Gentle check-in
        "[time]. [session] — everything ok?",
        "[session]. Maybe time for a stretch? ☕",
        "[weekday]. [session] — the world isn't going anywhere.",
        "[session]. We love having you, but the sun's still out.",
        "[time]. Your eyes called. They want a break after [session].",
        "[session] on a [weekday]. Just checking in.",
        "Still here? [session]. No judgment — we get it.",
        "[session]. Pause. Breathe. The news will be here.",

        // Late night
        "It's late. [weather]. Maybe sleep soon?",
        "[time]. Insomnia? A warm tea might help. 🍵",
        "Burning the midnight oil? [session] — but rest matters too.",
        "The night is quiet. [weather]. Perfect for thinking.",
        "3 AM thoughts? We've got you. But tomorrow-you needs sleep.",

        // Quick & playful
        "[time]! [weekday] — let's see what the world's up to.",
        "[weather]. So naturally, you're reading. Respect.",
        "[weekday]. [session] — just a quick one or settling in?",
        "[time]. [weather]. The algorithm can't replicate this.",
        "You again. [session]. We're flattered, honestly.",

        // Deep focus
        "[time]. Quiet hours. Deep reading time.",
        "[session] of focused reading. Your brain says thanks.",
        "[weekday]. Slow down. Read deeply.",
        "[weather] outside, but in here it's just you and the words.",
    ]
}
