# MomentCard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development

**Goal:** Replace DailyBriefingCard + TopStoriesCarousel with MomentCard — contextual greeting with weather, time, session tracking, and dynamic template messages.

**Architecture:** AppContext (@Observable singleton) → SessionTracker + WeatherService populate it → MomentGreeting reads flags → MomentCard renders.

**Tech Stack:** SwiftUI, Observation, CoreLocation, Open-Meteo API (free, no key), Calendar.current

**Files:** 5 new + 2 modified. Total ~800 LOC.

## Task 1: AppContext — All 12 Context Flag Categories

**Files:** Create `feedmine/Services/AppContext.swift`

**Produces:** `AppContext.shared` — @MainActor @Observable singleton with all enums + stored properties.

- [ ] Create `feedmine/Services/AppContext.swift` with all enums and the AppContext class:

```swift
import Foundation
import Observation

// MARK: - Context Enums

enum TimeOfDay: String, CaseIterable {
    case night, dawn, morning, afternoon, evening, lateNight
    static func from(hour: Int) -> TimeOfDay {
        switch hour { case 0..<5: .night; case 5..<7: .dawn; case 7..<12: .morning; case 12..<17: .afternoon; case 17..<21: .evening; default: .lateNight }
    }
}

enum Season: String, CaseIterable { case spring, summer, autumn, winter
    static func from(month: Int) -> Season {
        switch month { case 3..<6: .spring; case 6..<9: .summer; case 9..<12: .autumn; default: .winter }
    }
}

enum WeatherCondition: String, CaseIterable { case clear, partlyCloudy, cloudy, overcast, rain, drizzle, heavyRain, thunderstorm, snow, sleet, hail, fog, windy, tornado, hurricane }

enum Temperature { case cold, cool, mild, warm, hot, scorching
    static func from(f: Double) -> Temperature {
        switch f { case ..<32: .cold; case 32..<50: .cool; case 50..<65: .mild; case 65..<80: .warm; case 80..<95: .hot; default: .scorching }
    }
}

enum MoonPhase: String { case new, waxingCrescent, firstQuarter, waxingGibbous, full, waningGibbous, thirdQuarter, waningCrescent }

enum Weekday: Int, CaseIterable { case sunday=1, monday, tuesday, wednesday, thursday, friday, saturday
    var isWeekend: Bool { self == .sunday || self == .saturday }
}

enum Month: Int, CaseIterable { case january=1, february, march, april, may, june, july, august, september, october, november, december }

enum SpecialDate: String, CaseIterable {
    case newYearsDay, mlkDay, presidentsDay, memorialDay, juneteenth, independenceDay, laborDay, columbusDay, veteransDay, thanksgiving, christmasEve, christmasDay, newYearsEve, valentinesDay, stPatricksDay, earthDay, mothersDay, fathersDay, halloween, diwali, eid, hanukkah, lunarNewYear, cincoDeMayo, womensDay, prideMonth, userAnniversary
}

enum Holiday: String, CaseIterable { case none, today, tomorrow, thisWeek }

enum SessionLevel: String, CaseIterable { case justOpened, settlingIn, engaged, deep, extended, marathon
    static func from(minutes: Int) -> SessionLevel {
        switch minutes { case 0..<2: .justOpened; case 2..<10: .settlingIn; case 10..<20: .engaged; case 20..<45: .deep; case 45..<90: .extended; default: .marathon }
    }
}

enum SessionStreak { case firstTime, newStreak, days(Int), weeks(Int) }

enum RoutineMatch: String { case exact, approximate, unusual, firstTime }

enum ReadingPace: String { case skimming, steady, deep, marathon }

enum BatteryState: String { case charging, full, low, critical, normal }

enum Connectivity: String { case wifi, cellular, offline }

// MARK: - AppContext Singleton

@MainActor @Observable final class AppContext {
    static let shared = AppContext()
    private init() { refresh() }

    // Time
    var timeOfDay: TimeOfDay = .morning
    var hour: Int = 0; var minute: Int = 0
    var weekday: Weekday = .monday; var month: Month = .january
    var dayOfMonth: Int = 1; var dayOfYear: Int = 1
    var season: Season = .summer; var isDaylightSaving: Bool = false

    // Special dates
    var activeSpecialDates: [SpecialDate] = []
    var holiday: Holiday = .none
    var isWeekend: Bool { weekday.isWeekend }
    var isHoliday: Bool { holiday != .none }

    // Weather
    var weatherCondition: WeatherCondition?
    var temperature: Double?; var feelsLike: Double?
    var hiTemp: Double?; var loTemp: Double?
    var humidity: Double?; var windSpeed: Double?
    var uvIndex: Int?
    var moonPhase: MoonPhase = .new
    var temperatureFeel: Temperature = .mild

    // Session
    var sessionLevel: SessionLevel = .justOpened
    var sessionMinutes: Int = 0
    var sessionStreak: SessionStreak = .firstTime
    var readingPace: ReadingPace = .steady
    var articlesReadThisSession: Int = 0

    // User patterns
    var routineMatch: RoutineMatch = .firstTime
    var avgOpeningHour: Int?; var daysWithApp: Int = 0

    // Device
    var batteryState: BatteryState = .normal
    var connectivity: Connectivity = .wifi
    var isLowPowerMode: Bool = false

    /// Populate time/calendar flags from system clock
    func refresh() {
        let now = Date(); let cal = Calendar.current; let comps = cal.dateComponents([.hour,.minute,.weekday,.month,.day,.year], from: now)
        hour = comps.hour ?? 12; minute = comps.minute ?? 0
        weekday = Weekday(rawValue: comps.weekday ?? 2) ?? .monday
        month = Month(rawValue: comps.month ?? 1) ?? .january
        dayOfMonth = comps.day ?? 1; dayOfYear = cal.ordinality(of: .day, in: .year, for: now) ?? 1
        timeOfDay = TimeOfDay.from(hour: hour)
        season = Season.from(month: comps.month ?? 6)
        isDaylightSaving = cal.timeZone.isDaylightSavingTime(for: now)
        activeSpecialDates = SpecialDate.allCases.filter { matchesSpecialDate($0, cal: cal, now: now) }
        holiday = computeHoliday(cal: cal, now: now)
        moonPhase = computeMoonPhase(now: now)
        isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    private func matchesSpecialDate(_ d: SpecialDate, cal: Calendar, now: Date) -> Bool { /* TODO: implement per-date logic */ return false }
    private func computeHoliday(cal: Calendar, now: Date) -> Holiday { return activeSpecialDates.isEmpty ? .none : .today }
    private func computeMoonPhase(now: Date) -> MoonPhase { return .full /* TODO: proper moon phase calculation */ }
}
```

- [ ] Build and verify: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination "platform=iOS,id=00008110-00067D861486201E" -allowProvisioningUpdates build 2>&1 | grep "BUILD"`
- [ ] Commit: `git add feedmine/Services/AppContext.swift && git commit -m "feat: AppContext — 12 categories of context flags"`

## Task 2: SessionTracker — Track Reading Time & Patterns

**Files:** Create `feedmine/Services/SessionTracker.swift`
**Consumes:** AppContext.shared (sessionLevel, sessionMinutes, sessionStreak, readingPace, articlesReadThisSession, routineMatch, daysWithApp, avgOpeningHour)
**Produces:** `SessionTracker.start()`, `SessionTracker.onForeground()`, `SessionTracker.onBackground()`, `SessionTracker.onArticleRead()`

- [ ] Create `feedmine/Services/SessionTracker.swift`:

```swift
import Foundation

@MainActor final class SessionTracker {
    static let shared = SessionTracker()
    private var sessionStart: Date?
    private var backgroundTime: Date?
    private var openTimestamps: [Date] = [] // last 7 days, used for routine detection
    private let defaults = UserDefaults.standard

    private init() { loadHistory() }

    /// Call on app foreground
    func onForeground() {
        let now = Date()
        openTimestamps.append(now)
        pruneOldTimestamps()
        saveHistory()

        sessionStart = now
        AppContext.shared.refresh()
        updateRoutine()

        let cal = Calendar.current
        let lastOpen = Date(timeIntervalSinceReferenceDate: defaults.double(forKey: "lastOpenDate"))
        if cal.isDateInToday(lastOpen) {
            // Resuming same day — sessionMinutes persists
            AppContext.shared.sessionMinutes = defaults.integer(forKey: "sessionMinutesToday")
        } else {
            // New day — reset
            AppContext.shared.sessionMinutes = 0
            defaults.set(0, forKey: "sessionMinutesToday")
        }
        AppContext.shared.sessionLevel = SessionLevel.from(minutes: AppContext.shared.sessionMinutes)
        defaults.set(now.timeIntervalSinceReferenceDate, forKey: "lastOpenDate")
        AppContext.shared.daysWithApp = defaults.integer(forKey: "daysWithAppTotal") + 1
        defaults.set(AppContext.shared.daysWithApp, forKey: "daysWithAppTotal")

        // Session streak
        let yesterday = cal.date(byAdding: .day, value: -1, to: now)!
        if cal.isDateInYesterday(lastOpen) || cal.isDateInToday(lastOpen) {
            let streak = defaults.integer(forKey: "sessionStreak") + (cal.isDateInYesterday(lastOpen) ? 1 : 0)
            defaults.set(streak, forKey: "sessionStreak")
            AppContext.shared.sessionStreak = .days(streak)
        } else {
            defaults.set(1, forKey: "sessionStreak")
            AppContext.shared.sessionStreak = .newStreak
        }

        startTimer()
    }

    /// Call on app background — saves accumulated time
    func onBackground() {
        accumulateSession()
        sessionStart = nil
        saveHistory()
    }

    func onArticleRead() {
        AppContext.shared.articlesReadThisSession += 1
        updateReadingPace()
    }

    private var timer: Timer?
    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        accumulateSession()
        AppContext.shared.sessionLevel = SessionLevel.from(minutes: AppContext.shared.sessionMinutes)
        AppContext.shared.refresh()
        updateReadingPace()
    }

    private func accumulateSession() {
        guard let start = sessionStart else { return }
        let elapsed = Int(Date().timeIntervalSince(start) / 60)
        if elapsed > 0 {
            AppContext.shared.sessionMinutes += elapsed
            sessionStart = Date()
            defaults.set(AppContext.shared.sessionMinutes, forKey: "sessionMinutesToday")
        }
    }

    private func updateReadingPace() {
        let mins = AppContext.shared.sessionMinutes
        let arts = AppContext.shared.articlesReadThisSession
        if mins == 0 { AppContext.shared.readingPace = .steady }
        else if arts == 0 { AppContext.shared.readingPace = .steady }
        else {
            let ppm = Double(arts) / max(Double(mins), 1)
            if ppm > 2 { AppContext.shared.readingPace = .skimming }
            else if ppm > 0.8 { AppContext.shared.readingPace = .steady }
            else if ppm > 0.3 { AppContext.shared.readingPace = .deep }
            else { AppContext.shared.readingPace = .marathon }
        }
    }

    // MARK: - Routine detection

    private func updateRoutine() {
        let cal = Calendar.current; let nowHour = cal.component(.hour, from: Date())
        var matches = 0; var total = 0
        for ts in openTimestamps.prefix(7) {
            let h = cal.component(.hour, from: ts)
            if abs(h - nowHour) <= 1 { matches += 1 }
            total += 1
        }
        if total >= 3 {
            AppContext.shared.avgOpeningHour = nowHour
            if matches >= total - 1 { AppContext.shared.routineMatch = .exact }
            else if Double(matches) / Double(total) >= 0.5 { AppContext.shared.routineMatch = .approximate }
            else { AppContext.shared.routineMatch = .unusual }
        } else { AppContext.shared.routineMatch = .firstTime }
    }

    private func loadHistory() {
        if let data = defaults.data(forKey: "openTimestamps"),
           let timestamps = try? JSONDecoder().decode([Date].self, from: data) {
            openTimestamps = timestamps
        }
    }
    private func saveHistory() {
        if let data = try? JSONEncoder().encode(openTimestamps) {
            defaults.set(data, forKey: "openTimestamps")
        }
    }
    private func pruneOldTimestamps() {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        openTimestamps = openTimestamps.filter { $0 > cutoff }
    }
}
```

- [ ] Build and verify: `xcodebuild ... | grep "BUILD"`
- [ ] Commit: `git add feedmine/Services/SessionTracker.swift && git commit -m "feat: SessionTracker — foreground time, routine detection, reading pace"`

## Task 3: WeatherService — Open-Meteo Integration

**Files:** Create `feedmine/Services/WeatherService.swift`
**Consumes:** AppContext.shared (weatherCondition, temperature, feelsLike, hiTemp, loTemp, humidity, windSpeed, uvIndex, temperatureFeel)
**Produces:** `WeatherService.fetch()` — async, populates AppContext weather flags

- [ ] Create `feedmine/Services/WeatherService.swift`:

```swift
import Foundation
import CoreLocation

@MainActor final class WeatherService {
    static let shared = WeatherService()
    private var lastFetch: Date?
    private let cacheInterval: TimeInterval = 900 // 15 min

    private init() {}

    /// Fetch current weather from Open-Meteo. No API key needed.
    func fetch() async {
        if let last = lastFetch, Date().timeIntervalSince(last) < cacheInterval { return }

        let location = await currentLocation()
        guard let lat = location?.coordinate.latitude,
              let lon = location?.coordinate.longitude else { return }

        let urlStr = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,relative_humidity_2m,weather_code,wind_speed_10m,apparent_temperature&daily=temperature_2m_max,temperature_2m_min,uv_index_max&timezone=auto&forecast_days=1"
        guard let url = URL(string: urlStr) else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
            AppContext.shared.temperature = decoded.current.temperature2m
            AppContext.shared.feelsLike = decoded.current.apparentTemperature
            AppContext.shared.humidity = decoded.current.relativeHumidity2m
            AppContext.shared.windSpeed = decoded.current.windSpeed10m
            AppContext.shared.weatherCondition = weatherCodeToCondition(decoded.current.weatherCode)
            AppContext.shared.temperatureFeel = Temperature.from(f: decoded.current.temperature2m)
            if let daily = decoded.daily {
                AppContext.shared.hiTemp = daily.temperature2mMax.first
                AppContext.shared.loTemp = daily.temperature2mMin.first
                AppContext.shared.uvIndex = daily.uvIndexMax.first.map { Int($0) }
            }
            lastFetch = Date()
        } catch {
            // Silent fail — weather slot stays empty, greeting adapts
        }
    }

    private func currentLocation() async -> CLLocation? {
        let manager = CLLocationManager()
        guard manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways else { return nil }
        return manager.location
    }

    // WMO weather codes → condition
    private func weatherCodeToCondition(_ code: Int) -> WeatherCondition {
        switch code { case 0: .clear; case 1,2,3: .partlyCloudy; case 45,48: .fog; case 51,53,55: .drizzle; case 56,57: .sleet; case 61,63,65: .rain; case 66,67: .sleet; case 71,73,75: .snow; case 77: .snow; case 80,81,82: .heavyRain; case 85,86: .snow; case 95: .thunderstorm; case 96,99: .hail; default: .partlyCloudy }
    }

    private struct OpenMeteoResponse: Codable {
        let current: Current; let daily: Daily?
        struct Current: Codable { let temperature2m: Double; let relativeHumidity2m: Double; let weatherCode: Int; let windSpeed10m: Double; let apparentTemperature: Double
            enum CodingKeys: String, CodingKey { case temperature2m = "temperature_2m"; case relativeHumidity2m = "relative_humidity_2m"; case weatherCode = "weather_code"; case windSpeed10m = "wind_speed_10m"; case apparentTemperature = "apparent_temperature" }
        }
        struct Daily: Codable { let temperature2mMax: [Double]; let temperature2mMin: [Double]; let uvIndexMax: [Double]
            enum CodingKeys: String, CodingKey { case temperature2mMax = "temperature_2m_max"; case temperature2mMin = "temperature_2m_min"; case uvIndexMax = "uv_index_max" }
        }
    }
}
```

- [ ] Build and verify
- [ ] Commit: `git add feedmine/Services/WeatherService.swift && git commit -m "feat: WeatherService — Open-Meteo integration via CoreLocation"`

## Task 4: MomentGreeting — Template Engine

**Files:** Create `feedmine/Services/MomentGreeting.swift`
**Consumes:** AppContext.shared (all flags)
**Produces:** `MomentGreeting.generate() -> String`

- [ ] Create `feedmine/Services/MomentGreeting.swift` with 30 templates and slot filling logic:

```swift
import Foundation

struct MomentGreeting {
    static func generate() -> String {
        let ctx = AppContext.shared
        let slots = fillSlots(ctx)
        let candidates = templates.compactMap { template -> (String, Int)? in
            let filled = fillTemplate(template, slots: slots)
            // Count how many slots were actually filled
            let score = slots.filter { filled.contains($0.value) }.count
            return score > 0 ? (filled, score) : nil
        }
        .sorted { $0.1 > $1.1 } // highest score first

        // Night hours → prefer night templates
        if ctx.hour < 5 || ctx.hour >= 23 {
            let night = candidates.filter { $0.0.contains("sleep") || $0.0.contains("late") || $0.0.contains("tea") || $0.0.contains("night") || $0.0.contains("midnight") || $0.0.contains("3 AM") }
            if let pick = night.randomElement() { return pick.0 }
        }
        // Session > 45 min → prefer check-in templates
        if ctx.sessionLevel == .extended || ctx.sessionLevel == .marathon {
            let checkins = candidates.filter { $0.0.contains("stretch") || $0.0.contains("break") || $0.0.contains("walk") || $0.0.contains("phone down") || $0.0.contains("eyes") || $0.0.contains("outside") }
            if let pick = checkins.randomElement() { return pick.0 }
        }

        return candidates.first?.0 ?? "\(slots["time"] ?? "Hello"). Here's what's new."
    }

    // MARK: - Slot filling

    private static func fillSlots(_ ctx: AppContext) -> [String: String] {
        var s: [String: String] = [:]

        // [time]
        s["time"] = ctx.timeOfDay == .night ? "Late night" :
                    ctx.timeOfDay == .dawn ? "Early morning" :
                    ctx.timeOfDay == .morning ? "Good morning" :
                    ctx.timeOfDay == .afternoon ? "Good afternoon" :
                    ctx.timeOfDay == .evening ? "Good evening" : "Still up"

        // [weather]
        if let cond = ctx.weatherCondition {
            s["weather"] = switch cond { case .clear: "Sun's out"; case .partlyCloudy: "Partly cloudy"; case .cloudy, .overcast: "Cloudy skies"; case .rain, .drizzle: "Rain's falling"; case .heavyRain, .thunderstorm: "Stormy out there"; case .snow, .sleet, .hail: "Snow day"; case .fog: "Foggy morning"; case .windy: "Windy out there"; case .tornado, .hurricane: "Stay safe out there" }
        }

        // [weekday]
        s["weekday"] = ctx.isWeekend ? (ctx.weekday == .saturday ? "Saturday" : "Lazy Sunday") : "\(ctx.weekday) already"

        // [session]
        s["session"] = ctx.sessionLevel == .justOpened ? "Just opened" :
                        ctx.sessionLevel == .settlingIn ? "Getting comfortable" :
                        ctx.sessionLevel == .engaged ? "\(ctx.sessionMinutes) min in" :
                        ctx.sessionLevel == .deep ? "\(ctx.sessionMinutes) min — deep read" :
                        ctx.sessionLevel == .extended ? "\(ctx.sessionMinutes) min — maybe stretch?" :
                        "\(ctx.sessionMinutes) min — phone down?"

        // [season]
        s["season"] = ctx.season == .spring ? "Spring blooms" : ctx.season == .summer ? "Summer light" : ctx.season == .autumn ? "Autumn crisp" : "Winter cozy"

        // [personal]
        s["personal"] = ["We saved you a seat", "The world can wait", "Take your time", "No rush", "Good to see you"].randomElement()!

        return s
    }

    private static func fillTemplate(_ template: String, slots: [String: String]) -> String {
        var result = template
        for (key, value) in slots { result = result.replacingOccurrences(of: "[\(key)]", with: value) }
        return result
    }

    // MARK: - Templates (30+)

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
```

- [ ] Build and verify
- [ ] Commit: `git add feedmine/Services/MomentGreeting.swift && git commit -m "feat: MomentGreeting — 30 templates × 6 context slots → 200+ variations"`

## Task 5: MomentCard — SwiftUI View

**Files:** Create `feedmine/Views/MomentCard.swift`, Modify `feedmine/Views/FeedScreen.swift`

- [ ] Create `feedmine/Views/MomentCard.swift`:

```swift
import SwiftUI

struct MomentCard: View {
    @Environment(FeedLoader.self) private var loader
    @State private var greeting: String = ""
    @State private var timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var ctx: AppContext { AppContext.shared }

    var body: some View {
        if loader.loadingState != .initial && !loader.items.isEmpty {
            ZStack {
                // Time-of-day gradient background
                timeGradient
                    .clipShape(RoundedRectangle(cornerRadius: 20))

                // Content
                VStack(alignment: .leading, spacing: 8) {
                    // Weather + time row
                    HStack(spacing: 12) {
                        if let cond = ctx.weatherCondition {
                            Label("\(Int(ctx.temperature ?? 72))° · \(cond.rawValue)", systemImage: weatherIcon(for: cond))
                                .font(.caption).foregroundStyle(.white.opacity(0.9))
                        }
                        Spacer()
                        Label("\(ctx.hour):\(String(format: "%02d", ctx.minute))", systemImage: "clock")
                            .font(.caption).foregroundStyle(.white.opacity(0.7))
                            .monospacedDigit()
                        if ctx.sessionMinutes > 0 {
                            Label("\(ctx.sessionMinutes)m reading", systemImage: "book.pages")
                                .font(.caption).foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 12)

                    Spacer()

                    // Greeting
                    Text(greeting)
                        .font(.headline).fontWeight(.medium)
                        .foregroundStyle(.white)
                        .lineLimit(4)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                        .shadow(color: .black.opacity(0.2), radius: 2)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16/9, contentMode: .fit)
            .padding(.horizontal, 6)
            .onAppear { refreshGreeting() }
            .onReceive(timer) { _ in refreshGreeting() }
        }
    }

    private func refreshGreeting() {
        AppContext.shared.refresh()
        greeting = MomentGreeting.generate()
    }

    private var timeGradient: some View {
        let colors: [Color] = switch ctx.timeOfDay {
            case .night, .lateNight: [.indigo.opacity(0.8), .black.opacity(0.9)]
            case .dawn: [.orange.opacity(0.6), .pink.opacity(0.4), .blue.opacity(0.5)]
            case .morning: [.blue.opacity(0.5), .cyan.opacity(0.4)]
            case .afternoon: [.cyan.opacity(0.5), .blue.opacity(0.6)]
            case .evening: [.purple.opacity(0.6), .orange.opacity(0.5)]
        }
        return Rectangle().fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private func weatherIcon(for cond: WeatherCondition) -> String {
        switch cond { case .clear: "sun.max.fill"; case .partlyCloudy: "cloud.sun.fill"; case .cloudy, .overcast: "cloud.fill"; case .rain, .drizzle: "cloud.rain.fill"; case .heavyRain: "cloud.heavyrain.fill"; case .thunderstorm: "cloud.bolt.fill"; case .snow, .sleet, .hail: "snowflake"; case .fog: "cloud.fog.fill"; case .windy: "wind"; case .tornado, .hurricane: "tornado" }
    }
}
```

- [ ] Modify `feedmine/Views/FeedScreen.swift` — replace DailyBriefingCard + TopStoriesCarousel with MomentCard:

Find:
```swift
if loader.selectedCategory == nil && loader.selectedMood == .all && loader.searchQuery.isEmpty {
    DailyBriefingCard()
        .padding(.horizontal, 6)
        .padding(.top, 4)
    TopStoriesCarousel()
        .padding(.top, 8)
}
```

Replace with:
```swift
if loader.selectedCategory == nil && loader.selectedMood == .all && loader.searchQuery.isEmpty {
    MomentCard()
        .padding(.top, 4)
}
```

- [ ] Build and verify
- [ ] Commit: `git add feedmine/Views/MomentCard.swift feedmine/Views/FeedScreen.swift && git commit -m "feat: MomentCard — contextual greeting card with weather, time, session"`

## Task 6: Wire Up SessionTracker in FeedScreen

**Files:** Modify `feedmine/Views/FeedScreen.swift`
**Consumes:** SessionTracker.shared, AppContext.shared

- [ ] Add SessionTracker calls to scenePhase and markAsRead in FeedScreen:

In FeedScreen body, add:
```swift
.onChange(of: scenePhase) { _, phase in
    if phase == .active { SessionTracker.shared.onForeground() }
    if phase == .background { SessionTracker.shared.onBackground() }
    if phase == .background {
        PersistenceManager.shared.saveNow(loader.buildStateWithItems())
    }
}
```

And in FeedItemView's tap gesture (or FeedItemView.swift), after `loader.markAsRead(item.id)`:
```swift
SessionTracker.shared.onArticleRead()
```

- [ ] Build and verify
- [ ] Commit: `git add feedmine/Views/FeedScreen.swift feedmine/Views/FeedItemView.swift && git commit -m "feat: wire SessionTracker into app lifecycle"`

## Task 7: Weather Fetch on Launch

**Files:** Modify `feedmine/Services/FeedLoader.swift`

- [ ] In FeedLoader.start(), after networkMonitor.start(), add:
```swift
Task { await WeatherService.shared.fetch() }
```

- [ ] Build and verify
- [ ] Commit: `git add feedmine/Services/FeedLoader.swift && git commit -m "feat: fetch weather on app launch"`

## Verification

1. Build succeeds — all 7 tasks compile
2. Run on device: MomentCard appears at top of feed
3. Greeting changes based on time of day
4. Session counter increments while app is open
5. Weather appears when location is available
6. No crash when location is denied or weather API fails
7. Session resets on new day
