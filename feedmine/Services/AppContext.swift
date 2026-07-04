import Foundation
import Observation

// MARK: - Context Enums

enum TimeOfDay: String, CaseIterable {
    case night, dawn, morning, afternoon, evening, lateNight
    static func from(hour: Int) -> TimeOfDay {
        switch hour { case 0..<5: .night; case 5..<7: .dawn; case 7..<12: .morning; case 12..<17: .afternoon; case 17..<21: .evening; default: .lateNight }
    }
}

enum Season: String, CaseIterable {
    case spring, summer, autumn, winter
    static func from(month: Int) -> Season {
        switch month { case 3..<6: .spring; case 6..<9: .summer; case 9..<12: .autumn; default: .winter }
    }
}

enum WeatherCondition: String, CaseIterable {
    case clear, partlyCloudy, cloudy, overcast, rain, drizzle, heavyRain, thunderstorm, snow, sleet, hail, fog, windy, tornado, hurricane
}

enum TemperatureFeel { case cold, cool, mild, warm, hot, scorching
    static func from(f: Double) -> TemperatureFeel {
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
