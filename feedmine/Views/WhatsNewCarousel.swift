import SwiftUI

struct WhatsNewCarousel: View {
    @Environment(FeedLoader.self) private var loader

    private var items: [FeedItem] { loader.whatIsNewItems }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(.blue)
                    .symbolEffect(.pulse)
                Text("What's New")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                if !items.isEmpty {
                    Text("\(items.count)")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.blue))
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            // Content
            if items.isEmpty {
                emptyCarousel
            } else {
                populatedCarousel
            }
        }
    }

    // MARK: - Populated Carousel

    private var populatedCarousel: some View {
        GeometryReader { geo in
            let aspect: CGFloat = 0.52
            let cardWidth = max(geo.size.width - 48, 200)
            let cardHeight = cardWidth * aspect

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    Color.clear.frame(width: 2)
                    ForEach(items) { item in
                        WhatsNewCard(item: item)
                            .frame(width: cardWidth, height: cardHeight)
                            .scrollTransition(.interactive.threshold(.visible(0.3))) { content, phase in
                                content
                                    .opacity(phase == .identity ? 1 : 0.45)
                                    .scaleEffect(phase == .identity ? 1 : 0.93)
                                    .blur(radius: phase == .identity ? 0 : 6)
                                    .rotation3DEffect(
                                        .degrees(phase.value * 8),
                                        axis: (x: 0, y: 1, z: 0),
                                        anchor: .center
                                    )
                            }
                    }
                    Color.clear.frame(width: 2)
                }
                .scrollTargetLayout()
                .padding(.horizontal, 14)
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollClipDisabled()
        }
        .aspectRatio(1 / 0.52, contentMode: .fit)
    }

    // MARK: - Empty State

    /// Mini-card data: image URL + category for fallback coloring
    struct MiniCardData: Identifiable {
        let id = UUID()
        let imageURL: String
        let category: String
    }

    /// Smart selection: valid URLs with categories, up to 16 unique images. CACHED.
    @State private var cachedBrowsingCards: [MiniCardData] = []
    @State private var browsingCardsHash = 0

    private var browsingCards: [MiniCardData] {
        // Use filteredItems count as cheap invalidation signal
        let currentHash = loader.filteredItems.count
        if currentHash != browsingCardsHash {
            cachedBrowsingCards = Array(loader.filteredItems
                .lazy
                .compactMap { item -> MiniCardData? in
                    guard let url = item.imageURL,
                          !url.isEmpty, url.hasPrefix("http"), url.count > 10
                    else { return nil }
                    return MiniCardData(imageURL: url, category: item.category)
                }
                .prefix(16))
            browsingCardsHash = currentHash
        }
        return cachedBrowsingCards
    }

    private var emptyCarousel: some View {
        let miniW: CGFloat = 72
        let miniH: CGFloat = 48

        return ZStack {
            // Dreamy animated gradient backdrop — reliable, no image loading issues
            DreamyGradient()
                .clipShape(RoundedRectangle(cornerRadius: 22))

            // Darkened overlay so mini cards pop
            RoundedRectangle(cornerRadius: 22)
                .fill(.black.opacity(0.06))

            // Mini film-strip rows
            VStack(spacing: 6) {
                if !browsingCards.isEmpty {
                    // Top row — drifts left
                    MiniFilmRow(cards: browsingCards, cardSize: CGSize(width: miniW, height: miniH), direction: .driftLeft, speed: 18)
                    // Bottom row — drifts right, slower
                    MiniFilmRow(cards: Array(browsingCards.reversed()), cardSize: CGSize(width: miniW, height: miniH), direction: .driftRight, speed: 24)
                } else {
                    // Fallback: gradient mini cards
                    MiniFilmRow(cards: [], cardSize: CGSize(width: miniW, height: miniH), direction: .driftLeft, speed: 18)
                    MiniFilmRow(cards: [], cardSize: CGSize(width: miniW, height: miniH), direction: .driftRight, speed: 24)
                }
            }
            .mask(
                // Fade edges so cards dissolve at the margins
                LinearGradient(
                    colors: [.clear, .black, .black, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )

            // Scanning beam
            ScanningBeam()
                .frame(height: miniH * 2 + 6)

            // Message capsule
            VStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .symbolEffect(.pulse)
                Text("Finding new stories…")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .aspectRatio(1 / 0.52, contentMode: .fit)
        .padding(.horizontal, 16)
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }

    /// Animated gradient — GPU-efficient via TimelineView (pauses when off-screen)
    struct DreamyGradient: View {
        var body: some View {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let phase = CGFloat(t.truncatingRemainder(dividingBy: 10) / 10)
                GeometryReader { geo in
                    ZStack {
                        Color(.systemGray6).opacity(0.25)
                        Circle()
                            .fill(.indigo.opacity(0.18))
                            .frame(width: geo.size.width * 0.7)
                            .blur(radius: 20)
                            .offset(x: geo.size.width * 0.25 * cos(phase * .pi * 2),
                                    y: geo.size.height * 0.2 * sin(phase * .pi * 1.6))
                        Circle()
                            .fill(.blue.opacity(0.15))
                            .frame(width: geo.size.width * 0.55)
                            .blur(radius: 20)
                            .offset(x: geo.size.width * -0.15 * sin(phase * .pi * 1.8),
                                    y: geo.size.height * -0.15 * cos(phase * .pi * 2.2))
                        Circle()
                            .fill(.purple.opacity(0.1))
                            .frame(width: geo.size.width * 0.5)
                            .blur(radius: 18)
                            .offset(x: geo.size.width * 0.1 * sin(phase * .pi * 1.4),
                                    y: geo.size.height * 0.3 * cos(phase * .pi * 1.9))
                    }
                }
            }
        }
    }
}

// MARK: - Mini Film Row

enum FilmDirection { case driftLeft, driftRight }

struct MiniFilmRow: View {
    let cards: [WhatsNewCarousel.MiniCardData]
    let cardSize: CGSize
    let direction: FilmDirection
    let speed: Double

    @State private var offset: CGFloat = 0

    private var displayCards: [WhatsNewCarousel.MiniCardData] {
        cards.isEmpty ? (0..<5).map { _ in WhatsNewCarousel.MiniCardData(imageURL: "", category: "news") } : cards
    }
    private let spacing: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let totalItemWidth = cardSize.width + spacing
            let setWidth = CGFloat(displayCards.count) * totalItemWidth

            HStack(spacing: spacing) {
                ForEach(0..<(displayCards.count * 2), id: \.self) { i in
                    MiniThumb(card: displayCards[i % displayCards.count], size: cardSize)
                }
            }
            .offset(x: offset)
            .onAppear {
                let distance = direction == .driftLeft ? -setWidth : setWidth
                offset = direction == .driftLeft ? 0 : -setWidth
                withAnimation(.linear(duration: speed).repeatForever(autoreverses: false)) {
                    offset = distance
                }
            }
        }
        .frame(height: cardSize.height)
    }
}

// MARK: - Mini Thumbnail

struct MiniThumb: View {
    let card: WhatsNewCarousel.MiniCardData
    let size: CGSize

    private var fallbackColor: Color {
        let c = card.category.lowercased()
        if c == "tech" || c == "news" || c == "science" || c == "design" || c == "culture" {
            return ComponentToken.categoryColor(for: c)
        }
        return .indigo
    }

    @State private var miniLoadFailed = false

    var body: some View {
        Group {
            if card.imageURL.isEmpty || miniLoadFailed {
                fallbackGradient
            } else {
                CachedAsyncImage(
                    url: URL(string: card.imageURL),
                    onResult: { success in
                        if !success { miniLoadFailed = true }
                    }
                )
                .scaledToFill()
                .overlay(.black.opacity(0.2))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(.white.opacity(0.25), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.1), radius: 2, y: 1.5)
    }

    private var fallbackGradient: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(
                LinearGradient(
                    colors: [fallbackColor.opacity(0.4), fallbackColor.opacity(0.15)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }
}

// MARK: - Scanning Beam

struct ScanningBeam: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let pos = CGFloat((t.truncatingRemainder(dividingBy: 3.2) / 3.2) * 1.6 - 0.3)
            GeometryReader { geo in
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, .clear, .white.opacity(0.25), .white.opacity(0.08), .clear, .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * 0.25)
                    .blur(radius: 6)
                    .offset(x: pos * geo.size.width)
            }
        }
    }
}

// MARK: - Card

struct WhatsNewCard: View {
    let item: FeedItem
    @Environment(FeedLoader.self) private var loader
    @State private var appeared = false

    private var categoryColor: Color {
        switch item.category.lowercased() {
        case "tech": return .blue
        case "science": return .green
        case "news": return .red
        case "design": return .purple
        case "culture": return .orange
        default: return .indigo
        }
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Background
            cardBackground

            // Gradient overlays
            LinearGradient(
                colors: [.clear, .clear, .black.opacity(0.35), .black.opacity(0.75)],
                startPoint: .top,
                endPoint: .bottom
            )

            // Content
            VStack(alignment: .leading, spacing: 8) {
                // Category + badge row
                HStack(spacing: 6) {
                    // Category tag
                    Text(item.category.uppercased())
                        .font(.system(size: 9, weight: .heavy))
                        .kerning(0.5)
                        .foregroundStyle(categoryColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(categoryColor.opacity(0.15), in: Capsule())

                    // New badge
                    HStack(spacing: 3) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 7))
                        Text("NEW")
                            .font(.system(size: 8, weight: .heavy))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.blue.opacity(0.7), in: Capsule())
                }

                // Title
                Text(item.title)
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)

                // Source + time
                HStack(spacing: 4) {
                    Text(item.sourceTitle)
                        .font(.caption)
                        .fontWeight(.medium)
                    Circle().fill(.white.opacity(0.4)).frame(width: 3, height: 3)
                    Text(item.publishedAt, style: .relative)
                        .font(.caption)
                }
                .foregroundStyle(.white.opacity(0.85))
            }
            .padding(18)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
        .scaleEffect(appeared ? 1 : 0.92)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.05)) {
                appeared = true
            }
        }
        .onTapGesture {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            let url = URL(string: item.url) ?? URL(string: "https://www.google.com")!
            UIApplication.shared.open(url)
            loader.markAsRead(item.id)
        }
    }

    // MARK: Background

    @ViewBuilder
    private var cardBackground: some View {
        if let imageURL = item.imageURL {
            Color.clear
                .overlay {
                    CachedAsyncImage(url: URL(string: imageURL))
                        .scaledToFill()
                }
                .clipped()
        } else {
            gradientFill
        }
    }

    private var gradientFill: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        categoryColor.opacity(0.7),
                        categoryColor.opacity(0.35),
                        Color(.systemGray6).opacity(0.3)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }
}

// MARK: - Skeleton

struct SkeletonWhatsNewCard: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        RoundedRectangle(cornerRadius: 22)
            .fill(
                LinearGradient(
                    colors: [Color(.systemGray5), Color(.systemGray4), Color(.systemGray5)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .fill(
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.25), .clear],
                            startPoint: UnitPoint(x: phase - 0.3, y: 0.5),
                            endPoint: UnitPoint(x: phase + 0.3, y: 0.5)
                        )
                    )
            )
            .clipped()
            .onAppear {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 2
                }
            }
    }
}
