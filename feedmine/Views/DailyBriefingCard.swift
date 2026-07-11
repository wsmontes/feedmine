import SwiftUI

struct DailyBriefingCard: View {
    @Environment(FeedLoader.self) private var loader

    var body: some View {
        // Single fused pass — filteredItems is computed once, todayItems filtered
        // once, then all derived values (newCount, topStory, sourceCount) are
        // extracted in a single scan. The old approach split this across four
        // separate computed properties, each re-calling filteredItems.
        let today = loader.filteredItems.filter { Calendar.current.isDateInToday($0.publishedAt) }
        let brief = Self.brief(today, isRead: { loader.isRead($0) })
        guard !today.isEmpty, loader.loadingState != .initial else { return AnyView(EmptyView()) }

        return AnyView(
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

                        Text(summaryText(items: today, top: brief.topStory, sourceCount: brief.sourceCount))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)

                        HStack(spacing: 12) {
                            if brief.newCount > 0 {
                                Label("\(brief.newCount) new", systemImage: "sparkles")
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                            }
                            if brief.sourceCount > 0 {
                                Label("\(brief.sourceCount) sources", systemImage: "antenna.radiowaves.left.and.right")
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
        )
    }

    // MARK: - Fused single-pass brief

    private struct Brief {
        let newCount: Int
        let topStory: FeedItem?
        let sourceCount: Int
    }

    /// Single scan over today's items — extracts newCount, topStory, and
    /// sourceCount in one pass instead of three separate iterations.
    private static func brief(_ items: [FeedItem], isRead: (String) -> Bool) -> Brief {
        var unread = 0
        var best: FeedItem?
        var sources = Set<String>()
        for item in items {
            if !isRead(item.id) { unread += 1 }
            sources.insert(item.sourceTitle)
            if best == nil || (item.imageURL != nil && best?.imageURL == nil) {
                best = item
            }
        }
        return Brief(newCount: unread, topStory: best, sourceCount: sources.count)
    }

    // MARK: - Greeting

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

    private func summaryText(items: [FeedItem], top: FeedItem?, sourceCount: Int) -> String {
        if let top {
            return "Top story: \(top.title)"
        }
        return "\(items.count) articles from \(sourceCount) sources today."
    }
}
