import SwiftUI

struct MomentCard: View {
    @Environment(FeedLoader.self) private var loader
    @State private var greeting: String = ""
    @State private var tick = 0

    private var ctx: AppContext { AppContext.shared }

    var body: some View {
        if loader.loadingState != .initial && !loader.items.isEmpty {
            ZStack {
                timeGradient
                    .clipShape(RoundedRectangle(cornerRadius: 20))

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        if let cond = ctx.weatherCondition {
                            Label("\(Int(ctx.temperature ?? 72))° · \(cond.rawValue)", systemImage: weatherIcon(for: cond))
                                .font(.caption).foregroundStyle(.white.opacity(0.9))
                        }
                        Spacer()
                        Label(timeString, systemImage: "clock")
                            .font(.caption).foregroundStyle(.white.opacity(0.7)).monospacedDigit()
                        if ctx.sessionMinutes > 0 {
                            Label("\(ctx.sessionMinutes)m reading", systemImage: "book.pages")
                                .font(.caption).foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 12)

                    Spacer()

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
            .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
                refreshGreeting()
            }
        }
    }

    private var timeString: String {
        let h = ctx.hour > 12 ? ctx.hour - 12 : (ctx.hour == 0 ? 12 : ctx.hour)
        let ampm = ctx.hour >= 12 ? "PM" : "AM"
        return "\(h):\(String(format: "%02d", ctx.minute)) \(ampm)"
    }

    private func refreshGreeting() {
        AppContext.shared.refresh()
        greeting = MomentGreeting.generate()
        tick += 1
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
        switch cond {
        case .clear: "sun.max.fill"; case .partlyCloudy: "cloud.sun.fill"
        case .cloudy, .overcast: "cloud.fill"; case .rain, .drizzle: "cloud.rain.fill"
        case .heavyRain: "cloud.heavyrain.fill"; case .thunderstorm: "cloud.bolt.fill"
        case .snow, .sleet, .hail: "snowflake"; case .fog: "cloud.fog.fill"
        case .windy: "wind"; case .tornado, .hurricane: "tornado"
        }
    }
}
