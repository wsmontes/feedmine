import SwiftUI

struct MomentCard: View {
    @Environment(FeedLoader.self) private var loader
    @Environment(\.scenePhase) private var scenePhase
    @State private var engine = CircadianEngine.shared
    @SceneStorage("momentCardGreeting") private var greeting: String = ""
    @SceneStorage("momentCardGeneratedAt") private var greetingGeneratedAt: Double = 0
    @SceneStorage("momentCardGreetingDay") private var greetingGeneratedDay: Double = 0
    @SceneStorage("momentCardSeedItemCount") private var seedItemCount: Int = 0

    private static let greetingLifetime: TimeInterval = 2 * 60 * 60
    private static let earlySeedWindow: TimeInterval = 2 * 60

    var body: some View {
        if !loader.items.isEmpty {
            HStack(alignment: .center, spacing: 0) {
                // Left border anchor — subtle circadian accent
                RoundedRectangle(cornerRadius: 2)
                    .fill(engine.accent.opacity(0.6))
                    .frame(width: 3)
                    .padding(.vertical, 2)

                Text(LocalizedStringKey(greeting))
                    .font(engine.font(for: .momentCard))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .onAppear { updateGreetingIfNeeded() }
            .onChange(of: loader.items.count) { _, _ in
                updateGreetingIfNeeded(allowEarlySeedRefresh: true)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { updateGreetingIfNeeded() }
            }
        }
    }

    private func updateGreetingIfNeeded(allowEarlySeedRefresh: Bool = false) {
        AppContext.shared.refresh()
        let now = Date().timeIntervalSinceReferenceDate
        let isExpired = Self.shouldRefreshGreeting(
            generatedAt: greetingGeneratedAt,
            generatedDay: greetingGeneratedDay,
            now: Date(),
            lifetime: Self.greetingLifetime
        )
        let wasSeededTooEarly = allowEarlySeedRefresh
            && seedItemCount < 5
            && loader.items.count >= 10
            && now - greetingGeneratedAt < Self.earlySeedWindow
        guard greeting.isEmpty || isExpired || wasSeededTooEarly else { return }
        greeting = MomentGreeting.generate(loader: loader)
        greetingGeneratedAt = now
        greetingGeneratedDay = Self.greetingDayStamp(for: Date())
        seedItemCount = loader.items.count
    }

    static func greetingDayStamp(for date: Date, calendar: Calendar = .autoupdatingCurrent) -> Double {
        calendar.startOfDay(for: date).timeIntervalSinceReferenceDate
    }

    static func shouldRefreshGreeting(
        generatedAt: Double,
        generatedDay: Double,
        now: Date,
        lifetime: TimeInterval,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Bool {
        generatedAt == 0
            || generatedDay != greetingDayStamp(for: now, calendar: calendar)
            || now.timeIntervalSinceReferenceDate - generatedAt > lifetime
    }
}
