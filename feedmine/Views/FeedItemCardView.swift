import SwiftUI

struct FeedItemCardView: View {
    let item: FeedItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Hero image
            if let imageURL = item.imageURL, let url = URL(string: imageURL) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(height: 180)
                            .clipped()
                    case .failure, .empty:
                        Color.gray.opacity(0.2)
                            .frame(height: 180)
                    @unknown default:
                        Color.gray.opacity(0.2)
                            .frame(height: 180)
                    }
                }
            }

            // Category + source
            HStack(spacing: 4) {
                Text(item.category)
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(categoryColor(item.category).opacity(0.15))
                    .clipShape(Capsule())

                Text("·")
                    .foregroundStyle(.tertiary)

                Text(item.sourceTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // Title
            Text(item.title)
                .font(.headline)
                .lineLimit(2)
                .padding(.horizontal, 16)
                .padding(.top, 8)

            // Excerpt
            Text(item.excerpt)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .padding(.horizontal, 16)
                .padding(.top, 4)

            // Relative date
            Text(item.publishedAt, style: .relative)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 16)
        }
        .background(Color(.systemBackground))
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
