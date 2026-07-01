import SwiftUI

struct FeedItemRowView: View {
    let item: FeedItem
    let isRead: Bool
    let isBookmarked: Bool
    @State private var appeared = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Thumbnail
            if let imageURL = item.imageURL, let url = URL(string: imageURL) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(isRead ? Color.black.opacity(0.15) : nil)
                    case .failure, .empty:
                        thumbnailPlaceholder
                    @unknown default:
                        thumbnailPlaceholder
                    }
                }
                .frame(width: 56, height: 56)
            }

            // Content
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(item.category)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(categoryColor(item.category))
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(item.sourceTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if isBookmarked {
                        Image(systemName: "bookmark.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }

                Text(item.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .foregroundStyle(isRead ? .secondary : .primary)

                Text(formattedDate(item.publishedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
        .opacity(appeared ? (isRead ? 0.7 : 1) : 0)
        .offset(x: appeared ? 0 : -16)
        .onAppear {
            withAnimation(.easeOut(duration: 0.3)) {
                appeared = true
            }
        }
    }

    private var thumbnailPlaceholder: some View {
        let colors: [Color] = {
            switch item.category.lowercased() {
            case "tech": return [.blue.opacity(0.3), .indigo.opacity(0.2)]
            case "news": return [.red.opacity(0.3), .orange.opacity(0.2)]
            case "science": return [.green.opacity(0.3), .teal.opacity(0.2)]
            case "design": return [.purple.opacity(0.3), .pink.opacity(0.2)]
            case "culture": return [.orange.opacity(0.3), .yellow.opacity(0.2)]
            default: return [Color(.systemGray5), Color(.systemGray4)]
            }
        }()
        return RoundedRectangle(cornerRadius: 8)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 56, height: 56)
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func categoryColor(_ category: String) -> Color {
        switch category.lowercased() {
        case "tech": return .blue
        case "news": return .red
        case "science": return .green
        case "design": return .purple
        case "culture": return .orange
        default: return .gray
        }
    }
}
