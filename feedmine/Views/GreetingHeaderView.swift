import SwiftUI

struct GreetingHeaderView: View {
    @Environment(FeedLoader.self) private var loader
    var onSurpriseMe: (() -> Void)?
    @AppStorage("lastOpenDate") private var lastOpenDate = Date.timeIntervalSinceReferenceDate
    @AppStorage("streakCount") private var streakCount = 0
    @AppStorage("accentColorName") private var accentColorName = "blue"

    private var currentStreak: Int {
        let calendar = Calendar.current
        let last = Date(timeIntervalSinceReferenceDate: lastOpenDate)

        if calendar.isDateInToday(last) {
            return streakCount
        } else if calendar.isDateInYesterday(last) {
            return streakCount + 1
        } else {
            return 1
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Good night"
        }
    }

    private var emoji: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "sunrise.fill"
        case 12..<17: return "sun.max.fill"
        case 17..<22: return "sunset.fill"
        default: return "moon.stars.fill"
        }
    }

    private var unreadCount: Int {
        loader.items.count - loader.readItemIDs.count
    }

    var body: some View {
        if loader.loadingState != .initial && !loader.items.isEmpty {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: emoji)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text(greeting)
                            .font(.title3)
                            .fontWeight(.bold)

                        if currentStreak > 1 {
                            HStack(spacing: 2) {
                                Image(systemName: "flame.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                Text("\(currentStreak)")
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.orange)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.1))
                            .clipShape(Capsule())
                        }
                    }

                    HStack(spacing: 8) {
                        if unreadCount > 0 {
                            Label("\(unreadCount) unread", systemImage: "circle.fill")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                        if loader.bookmarkedIDs.count > 0 {
                            Label("\(loader.bookmarkedIDs.count) saved", systemImage: "bookmark.fill")
                                .font(.caption)
                                .foregroundStyle(.yellow)
                        }
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text("\(loader.sourceCount) sources")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Surprise Me button
                if !loader.items.isEmpty {
                    Button {
                        onSurpriseMe?()
                    } label: {
                        Image(systemName: "dice.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                            .background(Color(.systemGray6))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }

                if unreadCount > 0 {
                    Button {
                        loader.markAllAsRead()
                    } label: {
                        Text("Mark all read")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                // Quick action: refresh
                Button {
                    Task { await loader.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .background(Color(.systemGray6))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .onAppear { updateStreak() }
        }
    }

    private func updateStreak() {
        let calendar = Calendar.current
        let today = Date()
        let last = Date(timeIntervalSinceReferenceDate: lastOpenDate)

        if calendar.isDateInToday(last) {
            // Already logged today
            return
        } else if calendar.isDateInYesterday(last) {
            streakCount = currentStreak
        } else {
            streakCount = 1
        }
        lastOpenDate = today.timeIntervalSinceReferenceDate
    }
}
