import SwiftUI

struct ReadingStatsView: View {
    @Environment(FeedLoader.self) private var loader

    private var readCount: Int { loader.readItemIDs.count }
    private var bookmarkCount: Int { loader.bookmarkedIDs.count }
    private var topCategory: String? {
        let readItems = loader.items.filter { loader.isRead($0.id) }
        let grouped = Dictionary(grouping: readItems, by: \.category)
        return grouped.max(by: { $0.value.count < $1.value.count })?.key
    }
    private var topSource: String? {
        let readItems = loader.items.filter { loader.isRead($0.id) }
        let grouped = Dictionary(grouping: readItems, by: \.sourceTitle)
        return grouped.max(by: { $0.value.count < $1.value.count })?.key
    }

    @State private var isExpanded = false

    var body: some View {
        if loader.loadingState != .initial && !loader.items.isEmpty {
            VStack(spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Image(systemName: "chart.bar.fill")
                            .font(.caption)
                            .foregroundStyle(.blue)
                        Text("Reading Stats")
                            .font(.caption)
                            .fontWeight(.medium)
                        Spacer()
                        HStack(spacing: 8) {
                            if !isExpanded {
                                Text("\(readCount) read · \(bookmarkCount) saved")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)

                if isExpanded {
                    HStack(spacing: 24) {
                        StatItem(value: "\(readCount)", label: "Read", icon: "eye.fill", color: .blue)
                        StatItem(value: "\(bookmarkCount)", label: "Saved", icon: "bookmark.fill", color: .yellow)
                        if let cat = topCategory {
                            StatItem(value: cat, label: "Top Category", icon: "tag.fill", color: categoryColor(cat))
                        }
                        if let src = topSource {
                            StatItem(value: src, label: "Top Source", icon: "newspaper.fill", color: .orange)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Divider()
            }
            .background(.ultraThinMaterial)
        }
    }

    private func categoryColor(_ category: String) -> Color {
        ComponentToken.categoryColor(for: category)
    }
}

struct StatItem: View {
    let value: String
    let label: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(color)
            Text(value)
                .font(.caption)
                .fontWeight(.semibold)
                .lineLimit(1)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
