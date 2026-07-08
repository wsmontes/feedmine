import Foundation
import Observation

// MARK: - Context Enums

enum TimeOfDay: String, CaseIterable {
    case night, dawn, morning, afternoon, evening, lateNight
    static func from(hour: Int) -> TimeOfDay {
        switch hour { case 0..<5: .night; case 5..<7: .dawn; case 7..<12: .morning; case 12..<17: .afternoon; case 17..<21: .evening; default: .lateNight }
    }
    var label: String {
        switch self {
        case .night: String(localized: "Night", comment: "Time of day")
        case .dawn: String(localized: "Dawn", comment: "Time of day")
        case .morning: String(localized: "Morning", comment: "Time of day")
        case .afternoon: String(localized: "Afternoon", comment: "Time of day")
        case .evening: String(localized: "Evening", comment: "Time of day")
        case .lateNight: String(localized: "Late Night", comment: "Time of day")
        }
    }
}

enum Season: String, CaseIterable {
    case spring, summer, autumn, winter
    static func from(month: Int) -> Season {
        switch month { case 3..<6: .spring; case 6..<9: .summer; case 9..<12: .autumn; default: .winter }
    }
    var label: String {
        switch self {
        case .spring: String(localized: "Spring", comment: "Season")
        case .summer: String(localized: "Summer", comment: "Season")
        case .autumn: String(localized: "Autumn", comment: "Season")
        case .winter: String(localized: "Winter", comment: "Season")
        }
    }
}

enum WeatherCondition: String, CaseIterable {
    case clear, partlyCloudy, cloudy, overcast, rain, drizzle, heavyRain, thunderstorm, snow, sleet, hail, fog, windy, tornado, hurricane
    var label: String {
        switch self {
        case .clear: String(localized: "Clear", comment: "Weather condition")
        case .partlyCloudy: String(localized: "Partly Cloudy", comment: "Weather condition")
        case .cloudy: String(localized: "Cloudy", comment: "Weather condition")
        case .overcast: String(localized: "Overcast", comment: "Weather condition")
        case .rain: String(localized: "Rain", comment: "Weather condition")
        case .drizzle: String(localized: "Drizzle", comment: "Weather condition")
        case .heavyRain: String(localized: "Heavy Rain", comment: "Weather condition")
        case .thunderstorm: String(localized: "Thunderstorm", comment: "Weather condition")
        case .snow: String(localized: "Snow", comment: "Weather condition")
        case .sleet: String(localized: "Sleet", comment: "Weather condition")
        case .hail: String(localized: "Hail", comment: "Weather condition")
        case .fog: String(localized: "Fog", comment: "Weather condition")
        case .windy: String(localized: "Windy", comment: "Weather condition")
        case .tornado: String(localized: "Tornado", comment: "Weather condition")
        case .hurricane: String(localized: "Hurricane", comment: "Weather condition")
        }
    }
}

enum TemperatureFeel { case cold, cool, mild, warm, hot, scorching
    static func from(f: Double) -> TemperatureFeel {
        switch f { case ..<32: .cold; case 32..<50: .cool; case 50..<65: .mild; case 65..<80: .warm; case 80..<95: .hot; default: .scorching }
    }
    var label: String {
        switch self {
        case .cold: String(localized: "Cold", comment: "Temperature feel")
        case .cool: String(localized: "Cool", comment: "Temperature feel")
        case .mild: String(localized: "Mild", comment: "Temperature feel")
        case .warm: String(localized: "Warm", comment: "Temperature feel")
        case .hot: String(localized: "Hot", comment: "Temperature feel")
        case .scorching: String(localized: "Scorching", comment: "Temperature feel")
        }
    }
}

enum MoonPhase: String { case new, waxingCrescent, firstQuarter, waxingGibbous, full, waningGibbous, thirdQuarter, waningCrescent
    var label: String {
        switch self {
        case .new: String(localized: "New Moon", comment: "Moon phase")
        case .waxingCrescent: String(localized: "Waxing Crescent", comment: "Moon phase")
        case .firstQuarter: String(localized: "First Quarter", comment: "Moon phase")
        case .waxingGibbous: String(localized: "Waxing Gibbous", comment: "Moon phase")
        case .full: String(localized: "Full Moon", comment: "Moon phase")
        case .waningGibbous: String(localized: "Waning Gibbous", comment: "Moon phase")
        case .thirdQuarter: String(localized: "Third Quarter", comment: "Moon phase")
        case .waningCrescent: String(localized: "Waning Crescent", comment: "Moon phase")
        }
    }
}

enum Weekday: Int, CaseIterable { case sunday=1, monday, tuesday, wednesday, thursday, friday, saturday
    var isWeekend: Bool { self == .sunday || self == .saturday }
    var label: String {
        switch self {
        case .sunday: String(localized: "Sunday", comment: "Weekday")
        case .monday: String(localized: "Monday", comment: "Weekday")
        case .tuesday: String(localized: "Tuesday", comment: "Weekday")
        case .wednesday: String(localized: "Wednesday", comment: "Weekday")
        case .thursday: String(localized: "Thursday", comment: "Weekday")
        case .friday: String(localized: "Friday", comment: "Weekday")
        case .saturday: String(localized: "Saturday", comment: "Weekday")
        }
    }
}

enum Month: Int, CaseIterable { case january=1, february, march, april, may, june, july, august, september, october, november, december
    var label: String {
        switch self {
        case .january: String(localized: "January", comment: "Month")
        case .february: String(localized: "February", comment: "Month")
        case .march: String(localized: "March", comment: "Month")
        case .april: String(localized: "April", comment: "Month")
        case .may: String(localized: "May", comment: "Month")
        case .june: String(localized: "June", comment: "Month")
        case .july: String(localized: "July", comment: "Month")
        case .august: String(localized: "August", comment: "Month")
        case .september: String(localized: "September", comment: "Month")
        case .october: String(localized: "October", comment: "Month")
        case .november: String(localized: "November", comment: "Month")
        case .december: String(localized: "December", comment: "Month")
        }
    }
}

enum SpecialDate: String, CaseIterable {
    case newYearsDay, mlkDay, presidentsDay, memorialDay, juneteenth, independenceDay, laborDay, columbusDay, veteransDay, thanksgiving, christmasEve, christmasDay, newYearsEve, valentinesDay, stPatricksDay, earthDay, mothersDay, fathersDay, halloween, diwali, eid, hanukkah, lunarNewYear, cincoDeMayo, womensDay, prideMonth, userAnniversary
    var label: String {
        switch self {
        case .newYearsDay: String(localized: "New Year's Day", comment: "Special date")
        case .mlkDay: String(localized: "Martin Luther King Jr. Day", comment: "Special date")
        case .presidentsDay: String(localized: "Presidents' Day", comment: "Special date")
        case .memorialDay: String(localized: "Memorial Day", comment: "Special date")
        case .juneteenth: String(localized: "Juneteenth", comment: "Special date")
        case .independenceDay: String(localized: "Independence Day", comment: "Special date")
        case .laborDay: String(localized: "Labor Day", comment: "Special date")
        case .columbusDay: String(localized: "Columbus Day", comment: "Special date")
        case .veteransDay: String(localized: "Veterans Day", comment: "Special date")
        case .thanksgiving: String(localized: "Thanksgiving", comment: "Special date")
        case .christmasEve: String(localized: "Christmas Eve", comment: "Special date")
        case .christmasDay: String(localized: "Christmas Day", comment: "Special date")
        case .newYearsEve: String(localized: "New Year's Eve", comment: "Special date")
        case .valentinesDay: String(localized: "Valentine's Day", comment: "Special date")
        case .stPatricksDay: String(localized: "St. Patrick's Day", comment: "Special date")
        case .earthDay: String(localized: "Earth Day", comment: "Special date")
        case .mothersDay: String(localized: "Mother's Day", comment: "Special date")
        case .fathersDay: String(localized: "Father's Day", comment: "Special date")
        case .halloween: String(localized: "Halloween", comment: "Special date")
        case .diwali: String(localized: "Diwali", comment: "Special date")
        case .eid: String(localized: "Eid", comment: "Special date")
        case .hanukkah: String(localized: "Hanukkah", comment: "Special date")
        case .lunarNewYear: String(localized: "Lunar New Year", comment: "Special date")
        case .cincoDeMayo: String(localized: "Cinco de Mayo", comment: "Special date")
        case .womensDay: String(localized: "Women's Day", comment: "Special date")
        case .prideMonth: String(localized: "Pride Month", comment: "Special date")
        case .userAnniversary: String(localized: "Your Anniversary", comment: "Special date")
        }
    }
}

enum Holiday: String, CaseIterable { case none, today, tomorrow, thisWeek
    var label: String {
        switch self {
        case .none: String(localized: "None", comment: "Holiday status")
        case .today: String(localized: "Today", comment: "Holiday status")
        case .tomorrow: String(localized: "Tomorrow", comment: "Holiday status")
        case .thisWeek: String(localized: "This Week", comment: "Holiday status")
        }
    }
}

enum SessionLevel: String, CaseIterable { case justOpened, settlingIn, engaged, deep, extended, marathon
    static func from(minutes: Int) -> SessionLevel {
        switch minutes { case 0..<2: .justOpened; case 2..<10: .settlingIn; case 10..<20: .engaged; case 20..<45: .deep; case 45..<90: .extended; default: .marathon }
    }
    var label: String {
        switch self {
        case .justOpened: String(localized: "Just Opened", comment: "Session level")
        case .settlingIn: String(localized: "Settling In", comment: "Session level")
        case .engaged: String(localized: "Engaged", comment: "Session level")
        case .deep: String(localized: "Deep Read", comment: "Session level")
        case .extended: String(localized: "Extended", comment: "Session level")
        case .marathon: String(localized: "Marathon", comment: "Session level")
        }
    }
}

enum SessionStreak { case firstTime, newStreak, days(Int), weeks(Int)
    var label: String {
        switch self {
        case .firstTime: String(localized: "First Time", comment: "Session streak")
        case .newStreak: String(localized: "New Streak", comment: "Session streak")
        case .days(let n): String(localized: "\(n)-Day Streak", comment: "Session streak in days")
        case .weeks(let n): String(localized: "\(n)-Week Streak", comment: "Session streak in weeks")
        }
    }
}

enum RoutineMatch: String { case exact, approximate, unusual, firstTime
    var label: String {
        switch self {
        case .exact: String(localized: "Right on Time", comment: "Routine match")
        case .approximate: String(localized: "Approximate", comment: "Routine match")
        case .unusual: String(localized: "Unusual Time", comment: "Routine match")
        case .firstTime: String(localized: "First Time", comment: "Routine match")
        }
    }
}

enum ReadingPace: String { case skimming, steady, deep, marathon
    var label: String {
        switch self {
        case .skimming: String(localized: "Skimming", comment: "Reading pace")
        case .steady: String(localized: "Steady", comment: "Reading pace")
        case .deep: String(localized: "Deep Reading", comment: "Reading pace")
        case .marathon: String(localized: "Marathon", comment: "Reading pace")
        }
    }
}

enum BatteryState: String { case charging, full, low, critical, normal
    var label: String {
        switch self {
        case .charging: String(localized: "Charging", comment: "Battery state")
        case .full: String(localized: "Full", comment: "Battery state")
        case .low: String(localized: "Low", comment: "Battery state")
        case .critical: String(localized: "Critical", comment: "Battery state")
        case .normal: String(localized: "Normal", comment: "Battery state")
        }
    }
}

enum Connectivity: String { case wifi, cellular, offline
    var label: String {
        switch self {
        case .wifi: String(localized: "Wi-Fi", comment: "Connectivity")
        case .cellular: String(localized: "Cellular", comment: "Connectivity")
        case .offline: String(localized: "Offline", comment: "Connectivity")
        }
    }
}

// MARK: - AppContext Singleton

@MainActor
@Observable
final class AppContext {
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
    var temperatureFeel: TemperatureFeel = .mild

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

    /// Populates time/calendar flags from system clock
    func refresh() {
        let now = Date(); let cal = Calendar.current
        let comps = cal.dateComponents([.hour,.minute,.weekday,.month,.day,.year], from: now)
        hour = comps.hour ?? 12; minute = comps.minute ?? 0
        weekday = Weekday(rawValue: comps.weekday ?? 2) ?? .monday
        month = Month(rawValue: comps.month ?? 1) ?? .january
        dayOfMonth = comps.day ?? 1
        dayOfYear = cal.ordinality(of: .day, in: .year, for: now) ?? 1
        timeOfDay = TimeOfDay.from(hour: hour)
        season = Season.from(month: comps.month ?? 6)
        isDaylightSaving = cal.timeZone.isDaylightSavingTime(for: now)
        activeSpecialDates = SpecialDate.allCases.filter { matchesSpecialDate($0, cal: cal, now: now) }
        holiday = activeSpecialDates.isEmpty ? .none : .today
        moonPhase = computeMoonPhase(now: now)
        isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    private func matchesSpecialDate(_ d: SpecialDate, cal: Calendar, now: Date) -> Bool {
        let comps = cal.dateComponents([.month,.day,.weekday,.weekdayOrdinal,.year], from: now)
        let m = comps.month ?? 0; let day = comps.day ?? 0; let wd = comps.weekday ?? 0
        let wy = comps.year ?? 2026
        switch d {
        case .newYearsDay: return m == 1 && day == 1
        case .mlkDay: return m == 1 && wd == 2 && comps.weekdayOrdinal == 3
        case .presidentsDay: return m == 2 && wd == 2 && comps.weekdayOrdinal == 3
        case .memorialDay: return m == 5 && wd == 2 && (comps.weekdayOrdinal == 5 || day >= 25)
        case .juneteenth: return m == 6 && day == 19
        case .independenceDay: return m == 7 && day == 4
        case .laborDay: return m == 9 && wd == 2 && comps.weekdayOrdinal == 1
        case .columbusDay: return m == 10 && wd == 2 && comps.weekdayOrdinal == 2
        case .veteransDay: return m == 11 && day == 11
        case .thanksgiving: return m == 11 && wd == 5 && comps.weekdayOrdinal == 4
        case .christmasEve: return m == 12 && day == 24
        case .christmasDay: return m == 12 && day == 25
        case .newYearsEve: return m == 12 && day == 31
        case .valentinesDay: return m == 2 && day == 14
        case .stPatricksDay: return m == 3 && day == 17
        case .earthDay: return m == 4 && day == 22
        case .mothersDay: return m == 5 && wd == 1 && comps.weekdayOrdinal == 2
        case .fathersDay: return m == 6 && wd == 1 && comps.weekdayOrdinal == 3
        case .halloween: return m == 10 && day == 31
        case .diwali: fallthrough; case .eid: fallthrough; case .hanukkah: fallthrough
        case .lunarNewYear: fallthrough; case .cincoDeMayo: fallthrough
        case .womensDay: return m == 3 && day == 8
        case .prideMonth: return m == 6
        case .userAnniversary: return false // TODO: track first open date in UserDefaults
        }
    }

    private func computeMoonPhase(now: Date) -> MoonPhase {
        // Julian date based moon phase approximation
        let cal = Calendar.current
        let comps = cal.dateComponents([.year,.month,.day], from: now)
        let y = Double(comps.year ?? 2026); let m = Double(comps.month ?? 7); let d = Double(comps.day ?? 4)
        var jd: Double
        if m <= 2 { jd = (365.25 * (y + 4716)).rounded(.down) + (30.6001 * (m + 13)).rounded(.down) + d - 1524.5 }
        else { jd = (365.25 * (y + 4716)).rounded(.down) + (30.6001 * (m + 1)).rounded(.down) + d - 1524.5 }
        let daysSinceNew = jd - 2451549.5
        let newMoons = daysSinceNew / 29.53
        let phase = newMoons - newMoons.rounded(.down)
        return switch phase {
        case ..<0.0625, 0.9375...: .new
        case 0.0625..<0.1875: .waxingCrescent; case 0.1875..<0.3125: .firstQuarter
        case 0.3125..<0.4375: .waxingGibbous; case 0.4375..<0.5625: .full
        case 0.5625..<0.6875: .waningGibbous; case 0.6875..<0.8125: .thirdQuarter
        default: .waningCrescent
        }
    }
}
