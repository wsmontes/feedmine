# MomentCard — The Greeting Card That Grounds You

## Concept

A single card at the top of the feed that replaces the current `DailyBriefingCard` + `TopStoriesCarousel` area. It draws from device context — time, weather, season, reading patterns — to greet the user like a thoughtful friend who's happy to see them, but also looks out for them.

**Tone:** warm, personal, humble. Like a friend who brings you coffee and also tells you to go outside.

## Architecture

```
AppContext (single source of truth — powers MomentCard + future curation)
├── TimeContext (hour, timeOfDay, weekday, month, dayOfYear, season)
├── WeatherContext (condition, temp, hiTemp, loTemp)
├── SessionContext (minutesToday, isFirstOpen, isRoutine)
└── UserPatterns (avgOpenHour, commonWeekdays, streakDays)

MomentCard (View)
├── MomentGreeting (greeting engine)
│   ├── Templates (30+)
│   └── reads from AppContext flags
├── WeatherService (Open-Meteo via CoreLocation)
│   └── populates AppContext.weather
├── SessionTracker (time with app open today)
│   └── populates AppContext.session
└── TimeContext
    └── populated from Calendar.current + persisted patterns
```

### Context Flags (`AppContext`)

A single `@Observable` class that holds all context. Services update it; views and curation read it.

```swift
// ── Time ──
enum TimeOfDay: String, CaseIterable {
    case night       // 0-5
    case dawn        // 5-7
    case morning     // 7-12
    case afternoon   // 12-17
    case evening     // 17-21
    case lateNight   // 21-24
}

// ── Calendar ──
enum Weekday: Int, CaseIterable {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday
    var isWeekend: Bool { self == .sunday || self == .saturday }
    var isWeekday: Bool { !isWeekend }
}
enum Month: Int, CaseIterable {
    case january = 1, february, march, april, may, june,
         july, august, september, october, november, december
    var season: Season { ... }
}
enum Season: String, CaseIterable {
    case spring, summer, autumn, winter
}

// ── Special Dates ──
enum SpecialDate: String, CaseIterable {
    // US Federal Holidays
    case newYearsDay, mlkDay, presidentsDay, memorialDay, juneteenth,
         independenceDay, laborDay, columbusDay, veteransDay, thanksgiving,
         christmasEve, christmasDay, newYearsEve
    // Cultural / Observances
    case valentinesDay, stPatricksDay, earthDay, mothersDay, fathersDay,
         halloween, diwali, eid, hanukkah, lunarNewYear, cincoDeMayo,
         womensDay, prideMonth_start, blackHistoryMonth_start
    // Personal milestones (computed from persisted data)
    case userAnniversary  // day user first opened Feedmine
}
enum Holiday: String, CaseIterable {
    case none, today, tomorrow, thisWeek
}

// ── Weather ──
enum WeatherCondition: String, CaseIterable {
    case clear, partlyCloudy, cloudy, overcast,
         rain, drizzle, heavyRain, thunderstorm,
         snow, sleet, hail, fog, windy, tornado, hurricane
}
enum Temperature: Equatable {
    case cold, cool, mild, warm, hot, scorching
    // computed from temp + season context
}
enum MoonPhase: String { case new, waxingCrescent, firstQuarter, waxingGibbous,
    full, waningGibbous, thirdQuarter, waningCrescent }

// ── Session ──
enum SessionLevel: String, CaseIterable {
    case justOpened     // 0-2 min — "Just opened"
    case settlingIn     // 2-10 min — "Getting comfortable"
    case engaged        // 10-20 min — "In the zone"
    case deep           // 20-45 min — "Deep read"
    case extended       // 45-90 min — "Long session"
    case marathon       // 90+ min — gentle nudge: "Time for a walk?"
}
enum SessionStreak: Equatable {
    case firstTime, newStreak
    case days(Int)  // consecutive days opened
    case weeks(Int) // consecutive weeks
}

// ── User Patterns ──
enum RoutineMatch: String {
    case exact        // opened within ±10 min of usual time
    case approximate   // within ±30 min
    case unusual      // different time than usual
    case firstTime    // no pattern data yet
}
enum ReadingPace: Equatable {
    case skimming, steady, deep, marathon
}

// ── Device ──
enum BatteryState: Equatable { case charging, full, low, critical, normal }
enum Connectivity: String { case wifi, cellular, offline }
enum Timezone: Equatable { ... }  // for travel detection
```

### Context Flags (full `AppContext`)

```swift
@Observable
final class AppContext {
    // Time
    var timeOfDay: TimeOfDay = .morning
    var hour: Int = 0
    var minute: Int = 0
    var weekday: Weekday = .monday
    var month: Month = .january
    var dayOfMonth: Int = 1
    var dayOfYear: Int = 1
    var season: Season = .summer
    var isDaylightSaving: Bool = false

    // Special dates
    var activeSpecialDates: [SpecialDate] = []
    var holiday: Holiday = .none
    var isWeekend: Bool { weekday.isWeekend }
    var isHoliday: Bool { holiday != .none }

    // Weather
    var weatherCondition: WeatherCondition?
    var temperature: Double?          // F
    var feelsLike: Double?            // F
    var hiTemp: Double?
    var loTemp: Double?
    var humidity: Double?             // 0-100
    var windSpeed: Double?            // mph
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
    var isRoutine: Bool { routineMatch == .exact || routineMatch == .approximate }
    var avgOpeningHour: Int?          // from 7-day history
    var daysWithApp: Int = 0          // lifetime count

    // Device
    var batteryState: BatteryState = .normal
    var connectivity: Connectivity = .wifi
    var isLowPowerMode: Bool = false
}
```

Each flag becomes a queryable dimension for curation:
- `if context.timeOfDay == .morning && context.weather == .rain` → "Rainy morning reads"
- `if context.sessionLevel >= .deep && context.isWeekend` → "Weekend deep dive"
- `if context.season == .winter && context.timeOfDay == .night` → "Cozy winter night picks"
- `if context.isHoliday` → "Holiday reading — take it slow"
- `if context.batteryState == .low && context.sessionLevel >= .engaged` → nudge: "Battery's low — maybe save some for later?"
- `if context.routineMatch == .unusual` → "You're here at an unusual time — everything ok?"

## Slot System

6 context slots feed into 30+ templates. Each template combines 2-3 slots. The engine evaluates available context and picks the best template.

### Slot types:

| Slot | Key | Values (examples) |
|---|---|---|
| `[time]` | hour-based | "Good morning", "Late night", "Almost dawn", "Early bird", "Afternoon", "Evening light" |
| `[weather]` | condition | "Rain's falling", "Perfect outside", "That heat", "Cold and crisp", "Foggy morning", "Snow day" |
| `[weekday]` | day of week | "Monday — fresh start", "Midweek already", "Friday's here", "Lazy Sunday", "Saturday unwind" |
| `[session]` | minutes today | "Just opened", "A few minutes in", "{N} min reading", "{N} min — maybe stretch?", "+{N} min — phone down?" |
| `[season]` | month-based | "Spring blooms", "Summer light", "Autumn crisp", "Winter cozy" |
| `[personal]` | always available | "We saved you a seat", "The world can wait", "Take your time", "No rush" |

### Templates (30+, grouped by tone):

**Warm & welcoming (8):**
1. `[time]. [weather] outside — perfect reading weather.`
2. `[time]! [weather] means a good day to stay curious.`
3. `[weekday]. [weather]. We saved you a seat.`
4. `[time]. [season] air, fresh stories.`
5. `[weekday]. The coffee's hot, the news is fresh.`
6. `[time]. [personal] — here's what's happening.`
7. `[time]. [weather]. [personal]`
8. `[time]. Nothing urgent, just interesting.`

**Gentle check-in (8):**
9. `[time]. [session] — everything ok?`
10. `[session]. Maybe time for a stretch? ☕`
11. `[weekday]. [session] — the world isn't going anywhere.`
12. `[session]. We love having you, but the sun's still out. 🌤`
13. `[time]. Your eyes called. They want a break after [session].`
14. `[session] on a [weekday]. Just checking in.`
15. `Still here? [session]. No judgment — we get it.`
16. `[session]. Pause. Breathe. The news will be here.`

**Late night (5):**
17. `It's late. [weather]. Maybe sleep soon?`
18. `[time]. Insomnia? A warm tea might help. 🍵`
19. `Burning the midnight oil? [session] — but rest matters too.`
20. `The night is quiet. [weather]. Perfect for thinking.`
21. `3 AM thoughts? We've got you. But tomorrow-you needs sleep.`

**Quick & playful (5):**
22. `[time]! [weekday] — let's see what the world's up to.`
23. `[weather]. So naturally, you're reading. Respect.`
24. `[weekday]. [session] — just a quick one or settling in?`
25. `[time]. [weather]. The algorithm can't replicate this.`
26. `You again. [session]. We're flattered, honestly.`

**Deep focus (4):**
27. `[time]. Quiet hours. Deep reading time.`
28. `[session] of focused reading. Your brain says thanks.`
29. `[weekday]. Slow down. Read deeply.`
30. `[weather] outside, but in here it's just you and the words.`

### Selection logic:

1. Gather available context (weather may fail gracefully)
2. Score templates by how many slots they can fill
3. Prioritize session-aware templates at >20 min, >45 min
4. Night hours (0-5) → use late-night templates exclusively
5. Randomize among top matches to keep variety
6. Fallback: simple `[time]. Here's what's new.`

## Weather Service

Option A (preferred): **Open-Meteo** — free, no API key, no entitlement
  - `https://api.open-meteo.com/v1/forecast?latitude=...&longitude=...&current=temperature_2m,weather_code&daily=temperature_2m_max,temperature_2m_min`
  - Parse WMO weather codes → condition (sunny/rain/cloud/snow/fog)
  - No authentication needed. Location from CoreLocation.

Option B (if we want deeper iOS integration): Apple WeatherKit
  - Requires entitlements + capability. 500k calls/month free.
  - Falls back gracefully: if no permission or error → weather slot is empty
  - Cached for 15 minutes
  - Provides: temperature (current F/C), condition (sunny/rain/cloud/snow/etc.), hi/lo

## Session Tracker

- Starts counting when app enters foreground
- Pauses when app enters background
- Resets at midnight (new day)
- Persisted: `sessionMinutesToday` in UserDefaults
- Display format: `< 2 min → "just opened" | < 60 min → "{N} min" | > 60 min → "{hr}h {min}m"`

## Time Context

- Hour, weekday, month, season all from `Calendar.current`
- `isRoutine`: tracks opening times over 7 days → if user opened at ~same hour (±30 min) on 3+ days, it's a routine

## Visual Design

- Same footprint as a regular feed card (full-width, 16:9 ratio)
- Background: animated gradient based on time of day
  - 5-8h: warm sunrise (orange → pink → blue)
  - 8-17h: daytime (light blue → sky blue)
  - 17-21h: sunset (blue → purple → orange)
  - 21-5h: night (dark blue → indigo → black)
- Text: white with subtle shadow overlay
- Weather/hours row: top, small, transparent
- Greeting: centered, medium-large, 2-3 lines max
- Subtle icons inline (weather icon, clock icon, etc.) — not separate blocks

## Integration

- Replaces `DailyBriefingCard` in FeedScreen's LazyVStack
- Appears only when feed is not empty and loading is complete
- WeatherService initialized at app launch (FeedLoader.start)
- SessionTracker updated via scenePhase or onAppear

## Edge Cases

- No weather permission → weather slot empty, template skips it
- WeatherKit error/timeout → slot empty, no retry
- First open of day → session = 0, use "just opened" templates
- User denies location → weather never available
- Midnight reset → session counter clears, new day starts
