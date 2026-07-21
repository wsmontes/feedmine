import SwiftUI

struct DailyBriefingCard: View {
    @Environment(FeedLoader.self) private var loader

    private var todayItems: [FeedItem] {
        loader.filteredItems.filter { Calendar.current.isDateInToday($0.publishedAt) }
    }

    private var newCount: Int {
        todayItems.filter { !loader.isRead($0.id) }.count
    }

    private var topStory: FeedItem? {
        todayItems.max(by: { a, b in
            (a.hasPotentialImage ? 1 : 0) < (b.hasPotentialImage ? 1 : 0)
        })
    }

    private var sourceCount: Int {
        Set(todayItems.map(\.sourceTitle)).count
    }

    var body: some View {
        if !todayItems.isEmpty && loader.loadingState != .initial {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 16) {
                    // Icon
                    VStack(spacing: 0) {
                        Image(systemName: greetingIcon)
                            .font(.title)
                            .foregroundStyle(.blue)
                            .frame(width: 48, height: 48)
                            .background(Color.blue.opacity(0.1))
                            .clipShape(Circle())
                    }

                    // Content
                    VStack(alignment: .leading, spacing: 6) {
                        Text(greetingText)
                            .font(.headline)
                            .fontWeight(.bold)

                        Text(summaryText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)

                        HStack(spacing: 12) {
                            if newCount > 0 {
                                Label("\(newCount) new", systemImage: "sparkles")
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                            }
                            if sourceCount > 0 {
                                Label("\(sourceCount) sources", systemImage: "antenna.radiowaves.left.and.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 2)
                    }

                    Spacer()
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color(.systemBackground))
                        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(
                            LinearGradient(
                                colors: [.blue.opacity(0.3), .purple.opacity(0.15)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var greetingText: String {
        GreetingStore.primary(for: TimeOfDay.from(hour: Calendar.current.component(.hour, from: Date())))
    }

    private var greetingIcon: String {
        switch TimeOfDay.from(hour: Calendar.current.component(.hour, from: Date())) {
        case .dawn, .morning: return "sunrise.fill"
        case .afternoon: return "sun.max.fill"
        case .evening, .night, .lateNight: return "moon.stars.fill"
        }
    }

    private var summaryText: String {
        if let top = topStory {
            return "Top story: \(top.title)"
        }
        return "\(todayItems.count) articles from \(sourceCount) sources today."
    }
}
