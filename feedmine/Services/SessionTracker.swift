import Foundation
import Observation

@MainActor
@Observable
final class SessionTracker {
    static let shared = SessionTracker()
    private var sessionStart: Date?
    private var openTimestamps: [Date] = []
    private let defaults = UserDefaults.standard
    private var timer: Timer?

    private init() { loadHistory() }

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
            AppContext.shared.sessionMinutes = defaults.integer(forKey: "sessionMinutesToday")
        } else {
            AppContext.shared.sessionMinutes = 0
            defaults.set(0, forKey: "sessionMinutesToday")
        }
        AppContext.shared.sessionLevel = .justOpened
        defaults.set(now.timeIntervalSinceReferenceDate, forKey: "lastOpenDate")
        AppContext.shared.daysWithApp = defaults.integer(forKey: "daysWithAppTotal") + 1
        defaults.set(AppContext.shared.daysWithApp, forKey: "daysWithAppTotal")

        let yesterday = cal.date(byAdding: .day, value: -1, to: now)!
        if cal.isDateInYesterday(lastOpen) {
            let streak = defaults.integer(forKey: "sessionStreak") + 1
            defaults.set(streak, forKey: "sessionStreak")
            AppContext.shared.sessionStreak = .days(streak)
        } else if cal.isDateInToday(lastOpen) {
            let streak = defaults.integer(forKey: "sessionStreak")
            AppContext.shared.sessionStreak = .days(max(streak, 1))
        } else {
            defaults.set(1, forKey: "sessionStreak")
            AppContext.shared.sessionStreak = .newStreak
        }

        startTimer()
    }

    func onBackground() {
        accumulateSession()
        sessionStart = nil
        timer?.invalidate()
        timer = nil
        saveHistory()
    }

    func onArticleRead() {
        AppContext.shared.articlesReadThisSession += 1
        updateReadingPace()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        accumulateSession()
        AppContext.shared.sessionLevel = SessionLevel.from(minutes: AppContext.shared.sessionMinutes)
        updateReadingPace()
    }

    private func accumulateSession() {
        guard let start = sessionStart else { return }
        let elapsed = Int(Date().timeIntervalSince(start) / 60)
        if elapsed > 0 {
            AppContext.shared.sessionMinutes += elapsed
            // Advance by the whole minutes just counted, not to "now": resetting
            // to Date() discarded the sub-minute remainder every tick, steadily
            // undercounting session time.
            sessionStart = start.addingTimeInterval(TimeInterval(elapsed * 60))
            defaults.set(AppContext.shared.sessionMinutes, forKey: "sessionMinutesToday")
        }
    }

    private func updateReadingPace() {
        let mins = AppContext.shared.sessionMinutes
        let arts = AppContext.shared.articlesReadThisSession
        guard mins > 0, arts > 0 else { AppContext.shared.readingPace = .steady; return }
        let ppm = Double(arts) / Double(mins)
        if ppm > 2 { AppContext.shared.readingPace = .skimming }
        else if ppm > 0.8 { AppContext.shared.readingPace = .steady }
        else if ppm > 0.3 { AppContext.shared.readingPace = .deep }
        else { AppContext.shared.readingPace = .marathon }
    }

    private func updateRoutine() {
        let cal = Calendar.current; let nowHour = cal.component(.hour, from: Date())
        // suffix, not prefix: timestamps are appended newest-last, so the most
        // recent opens are at the end. prefix(7) would sample the oldest opens.
        var matches = 0; let recent = Array(openTimestamps.suffix(7))
        for ts in recent {
            let h = cal.component(.hour, from: ts)
            if abs(h - nowHour) <= 1 { matches += 1 }
        }
        AppContext.shared.avgOpeningHour = nowHour
        if recent.count < 3 { AppContext.shared.routineMatch = .firstTime }
        else if Double(matches) / Double(recent.count) >= 0.75 { AppContext.shared.routineMatch = .exact }
        else if Double(matches) / Double(recent.count) >= 0.5 { AppContext.shared.routineMatch = .approximate }
        else { AppContext.shared.routineMatch = .unusual }
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
