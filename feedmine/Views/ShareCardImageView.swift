import SwiftUI

struct ShareCardImageView: View {
    let item: FeedItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: App branding
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.blue)
                Text("Feedmine")
                    .font(.caption)
                    .fontWeight(.bold)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            // Hero image — uses CachedAsyncImage for disk cache + downsampling
            if item.hasPotentialImage {
                CachedAsyncImage(
                    url: item.bestImageURL.flatMap(URL.init(string:)),
                    articleURL: item.canResolveArticleImage ? URL(string: item.url) : nil
                )
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 220)
                    .clipped()
            } else {
                shareGradient
            }

            // Content
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(item.category)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(categoryColor)
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(item.sourceTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(item.title)
                    .font(.title3)
                    .fontWeight(.bold)
                    .lineLimit(3)

                Text(item.excerpt)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)

                HStack {
                    Text(item.publishedAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text("via Feedmine")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(20)
        }
        .background(Color(.systemBackground))
        .frame(width: 360)
    }

    private var shareGradient: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [categoryColor.opacity(0.2), categoryColor.opacity(0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(height: 180)
            .overlay {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary.opacity(0.3))
            }
    }

    private var categoryColor: Color {
        ComponentToken.categoryColor(for: item.category)
    }
}

// MARK: - Image Renderer Helper

@MainActor
func renderCardAsImage(item: FeedItem) -> UIImage? {
    let view = ShareCardImageView(item: item)
        .environment(\.colorScheme, .light)
    let renderer = ImageRenderer(content: view)
    renderer.scale = UIScreen.main.scale
    return renderer.uiImage
}
