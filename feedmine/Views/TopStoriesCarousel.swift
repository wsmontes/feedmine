import SwiftUI

struct TopStoriesCarousel: View {
    @Environment(FeedLoader.self) private var loader

    private var topStories: [FeedItem] {
        Array(loader.filteredItems.prefix(5))
    }

    var body: some View {
        if !topStories.isEmpty && loader.loadingState != .initial {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Top Stories")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 16)
                    Spacer()
                }
                .padding(.vertical, 8)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(topStories.enumerated()), id: \.element.id) { index, item in
                            TopStoryCard(item: item, rank: index + 1)
                                .containerRelativeFrame(.horizontal, count: 1, span: 1, spacing: 12)
                                .scrollTransition(.animated) { content, phase in
                                    content
                                        .opacity(phase == .identity ? 1 : 0.6)
                                        .scaleEffect(phase == .identity ? 1 : 0.92)
                                }
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 16)
                }
                .scrollTargetBehavior(.viewAligned)
                .frame(height: 240)
            }
        }
    }
}

struct TopStoryCard: View {
    let item: FeedItem
    let rank: Int

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Background — uses CachedAsyncImage for disk cache + downsampling
            if let imageURL = item.imageURL, let url = URL(string: imageURL) {
                CachedAsyncImage(url: url)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 300, height: 220)
                    .clipped()
                    .overlay(
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.7)],
                            startPoint: .center,
                            endPoint: .bottom
                        )
                    )
            } else {
                gradientBackground
            }

            // Content overlay
            VStack(alignment: .leading, spacing: 6) {
                // Rank badge
                Text("#\(rank)")
                    .font(.caption)
                    .fontWeight(.heavy)
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())

                Text(item.title)
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .lineLimit(3)

                HStack(spacing: 4) {
                    Text(item.sourceTitle)
                        .font(.caption)
                    Text("·")
                    Text(item.publishedAt, style: .relative)
                        .font(.caption)
                }
                .foregroundStyle(.white.opacity(0.8))
            }
            .padding(16)
        }
        .frame(width: 300, height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private var gradientBackground: some View {
        ZStack {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.blue.opacity(0.6), .purple.opacity(0.4), .black.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.5)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                )
        }
        .frame(width: 300, height: 220)
    }
}
