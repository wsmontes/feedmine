import SwiftUI

struct FeedItemCardView: View {
    let item: FeedItem
    @State private var appeared = false

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
                        gradientPlaceholder
                            .frame(height: 180)
                    @unknown default:
                        gradientPlaceholder
                            .frame(height: 180)
                    }
                }
            }

            // Category + source
            HStack(spacing: 4) {
                Text(item.category)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(categoryColor(item.category))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(categoryColor(item.category).opacity(0.12))
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
                .fontWeight(.semibold)
                .lineLimit(2)
                .padding(.horizontal, 16)
                .padding(.top, 10)

            // Excerpt
            Text(item.excerpt)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .padding(.horizontal, 16)
                .padding(.top, 6)

            // Relative date
            HStack {
                Text(item.publishedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text("ago")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 16)
        .onAppear {
            withAnimation(.easeOut(duration: 0.35)) {
                appeared = true
            }
        }
    }

    private var gradientPlaceholder: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color(.systemGray5),
                        Color(.systemGray4)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
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
