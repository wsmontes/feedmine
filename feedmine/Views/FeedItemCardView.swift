import SwiftUI
import UIKit

struct FeedItemCardView: View {
    let item: FeedItem
    let isRead: Bool
    let isBookmarked: Bool
    let appearDelay: Double
    var onBookmark: (() -> Void)?
    @State private var appeared = false
    @State private var imageLoadFailed = false
    @AppStorage("fontSize") private var fontSize = "medium"
    @State private var engine = CircadianEngine.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isLandscape: Bool { horizontalSizeClass == .regular }

    private var titleFont: Font {
        switch fontSize {
        case "small": return engine.font(for: .cardTitle, size: 14)
        case "large": return engine.font(for: .cardTitle, size: 20)
        default: return engine.font(for: .cardTitle)
        }
    }

    private var bodyFont: Font {
        switch fontSize {
        case "small": return .system(size: 12)
        case "large": return .system(size: 15)
        default: return .system(size: 13)
        }
    }

    var body: some View {
        Group {
            if isLandscape {
                landscapeCard
            } else {
                portraitCard
            }
        }
        .opacity(appeared ? (isRead ? 0.85 : 1) : 0)
        .offset(y: appeared ? 0 : 16)
        .onAppear {
            withAnimation(.easeOut(duration: 0.4).delay(appearDelay)) {
                appeared = true
            }
        }
    }

    // MARK: - Portrait Card (vertical, hero image)

    private var portraitCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Hero image
            if let imageURL = item.bestImageURL ?? item.imageURL, !imageLoadFailed {
                Color.clear
                    .aspectRatio(16/9, contentMode: .fit)
                    .overlay {
                        CachedAsyncImage(url: URL(string: imageURL), onResult: { success in
                            if !success { imageLoadFailed = true }
                        })
                        .scaledToFill()
                        .overlay(isRead ? Color.black.opacity(0.15) : nil)
                    }
                    .clipped()
                    .overlay(alignment: .topTrailing) {
                        cardOverlays
                    }
                    .overlay {
                        mediaOverlay
                    }
            }

            // Category + source row
            HStack(spacing: 4) {
                Text(item.category)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(categoryColor(item.category))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(categoryColor(item.category).opacity(0.12))
                    .clipShape(Capsule())

                Text("·").foregroundStyle(.tertiary)
                Text(item.sourceTitle).font(.caption).foregroundStyle(.secondary)

                if item.isPodcast {
                    mediaBadge("PODCAST", color: .purple)
                    if let dur = item.durationFormatted {
                        Text(dur).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if item.isYouTube {
                    mediaBadge("VIDEO", color: .red)
                } else if isNew && !item.isPodcast {
                    mediaBadge("NEW", color: .blue)
                }

                Spacer()

                unreadDot
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            // Title
            Text(item.title)
                .font(titleFont)
                .fontWeight(engine.activeFontWeight ?? .semibold)
                .lineLimit(2)
                .foregroundStyle(isRead ? .secondary : .primary)
                .padding(.horizontal, 12)
                .padding(.top, 10)

            // Excerpt
            Text(item.excerpt)
                .font(bodyFont)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .padding(.horizontal, 12)
                .padding(.top, 6)

            // Meta row
            HStack {
                Text(formattedDate(item.publishedAt)).font(.caption).foregroundStyle(.tertiary)
                Text("·").font(.caption).foregroundStyle(.tertiary)
                Text(readingTime).font(.caption).foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, engine.cardPadding)
        }
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: engine.cardRadius))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
        .contextMenu { cardContextMenu }
    }

    // MARK: - Landscape Card (horizontal, thumb left)

    private var landscapeCard: some View {
        HStack(spacing: 12) {
            // Thumb
            if let imageURL = item.bestImageURL ?? item.imageURL, !imageLoadFailed {
                Color.clear
                    .frame(width: 90, height: 90)
                    .overlay {
                        CachedAsyncImage(url: URL(string: imageURL), onResult: { success in
                            if !success { imageLoadFailed = true }
                        })
                        .scaledToFill()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(categoryColor(item.category).opacity(0.15))
                    .frame(width: 90, height: 90)
                    .overlay {
                        Text(String(item.sourceTitle.prefix(1)))
                            .font(.title2).fontWeight(.bold)
                            .foregroundStyle(categoryColor(item.category).opacity(0.5))
                    }
            }

            // Content
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(item.category)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(categoryColor(item.category))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(categoryColor(item.category).opacity(0.12))
                        .clipShape(Capsule())
                    Text("·").font(.caption2).foregroundStyle(.tertiary)
                    Text(item.sourceTitle).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    unreadDot
                }

                Text(item.title)
                    .font(titleFont)
                    .fontWeight(engine.activeFontWeight ?? .semibold)
                    .lineLimit(2)
                    .foregroundStyle(isRead ? .secondary : .primary)
                    .padding(.top, 4)

                Text(item.excerpt)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.top, 3)

                HStack {
                    Text(formattedDate(item.publishedAt)).font(.caption2).foregroundStyle(.tertiary)
                    Text("·").font(.caption2).foregroundStyle(.tertiary)
                    Text(readingTime).font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.top, 4)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
        .contextMenu { cardContextMenu }
    }

    // MARK: - Shared Elements

    private var unreadDot: some View {
        Group {
            if !isRead {
                Circle()
                    .fill(engine.accent)
                    .frame(width: 5, height: 5)
            }
        }
    }

    private var cardOverlays: some View {
        Button {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            onBookmark?()
        } label: {
            Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                .font(.title3)
                .foregroundStyle(isBookmarked ? .yellow : .white)
                .shadow(color: .black.opacity(0.4), radius: 4)
                .padding(12)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var mediaOverlay: some View {
        if item.isYouTube {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
        } else if item.isPodcast {
            Image(systemName: "headphones.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
        }
    }

    private func mediaBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2).fontWeight(.heavy)
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.1))
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var cardContextMenu: some View {
        Button {
            onBookmark?()
        } label: {
            Label(isBookmarked ? "Remove Bookmark" : "Bookmark",
                  systemImage: isBookmarked ? "bookmark.slash" : "bookmark")
        }
        Button {
            UIPasteboard.general.url = URL(string: item.url)
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
        } label: {
            Label("Copy Link", systemImage: "doc.on.doc")
        }
        Button {
            if let url = URL(string: item.url) { UIApplication.shared.open(url) }
        } label: {
            Label("Open in Safari", systemImage: "safari")
        }
        ShareLink(item: URL(string: item.url) ?? URL(string: "https://feedmine.app")!) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }

    // MARK: - Helpers

    private var isNew: Bool { Date().timeIntervalSince(item.publishedAt) < 3600 }

    private var readingTime: String {
        let wordCount = item.excerpt.split(separator: " ").count
        let minutes = max(1, Int(ceil(Double(wordCount) / 200.0)))
        return "\(minutes) min read"
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: date, relativeTo: Date())
        if Date().timeIntervalSince(date) < 7 * 24 * 3600 { return relative }
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .none
        return dateFormatter.string(from: date)
    }

    private func categoryColor(_ category: String) -> Color {
        ComponentToken.categoryColor(for: category)
    }
}
