import SwiftUI
import UIKit

struct FeedItemCardView: View, Equatable {
    /// Skips action closures (not Equatable) and @State/@AppStorage/
    /// @Environment properties (tracked independently by SwiftUI).
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item
        && lhs.isRead == rhs.isRead
        && lhs.isBookmarked == rhs.isBookmarked
        && lhs.isInBookmarkBox == rhs.isInBookmarkBox
    }
    let item: FeedItem
    let isRead: Bool
    let isBookmarked: Bool
    var onBookmark: (() -> Void)? = nil
    var onViewSource: (() -> Void)? = nil
    var onAddSourceToCollection: (() -> Void)? = nil
    var isInBookmarkBox: Bool = false
    @State private var imageLoadFailed = false
    @AppStorage("fontSize") private var fontSize = "medium"
    @State private var engine = CircadianEngine.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isLandscape: Bool { horizontalSizeClass == .regular }
    /// Structural: does this item have an image URL at all? Drives whether the
    /// card reserves a hero/thumb slot. Deliberately does NOT depend on
    /// `imageLoadFailed` — a failed load must NOT remove the slot and collapse
    /// the card, or content below jumps. On failure the slot stays; the image
    /// area just shows the placeholder. (Feed is sacred: layout never shifts
    /// from async image state.)
    private var hasImage: Bool { item.hasPotentialImage }

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
        .opacity(isRead ? 0.92 : 1)
    }

    // MARK: - Portrait Card

    private var portraitCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Hero image — native media or a bounded article-page candidate.
            if hasImage {
                Color.clear
                    .aspectRatio(16/9, contentMode: .fit)
                    .overlay {
                        if imageLoadFailed {
                            imageFailurePlaceholder
                        } else {
                            CachedAsyncImage(url: item.bestImageURL.flatMap(URL.init(string:)), articleURL: item.canResolveArticleImage ? URL(string: item.url) : nil, onResult: { success in
                                if !success { imageLoadFailed = true }
                            })
                            .scaledToFill()
                            .overlay(isRead ? Color.black.opacity(0.15) : nil)
                        }
                    }
                    .clipped()
                    .overlay(alignment: .topTrailing) {
                        cardOverlays
                    }
                    .overlay {
                        mediaOverlay
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                // Source row after image
                sourceRow
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
            } else {
                // No image — source row directly at top with extra top padding
                sourceRow
                    .padding(.horizontal, 12)
                    .padding(.top, 14)
            }

            // Title
            Text(item.title)
                .font(titleFont)
                .fontWeight(engine.activeFontWeight ?? .semibold)
                .lineLimit(2)
                .foregroundStyle(isRead ? .secondary : .primary)
                .padding(.horizontal, 12)
                .padding(.top, hasImage ? 10 : 6)

            // Excerpt
            Text(item.excerpt)
                .font(bodyFont)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .padding(.horizontal, 12)
                .padding(.top, 6)

            // Meta row — date only
            HStack {
                Text(formattedDate(item.publishedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, engine.cardPadding)
        }
        .frame(maxWidth: .infinity)
        .background(engine.accent.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: engine.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: engine.cardRadius)
                .stroke(engine.accent.opacity(0.06), lineWidth: 0.5)
        )
        .overlay(alignment: .leading) {
            // Left border accent — category color, dimmed when read
            RoundedRectangle(cornerRadius: 2)
                .fill(categoryColor(item.category).opacity(isRead ? 0.25 : 0.8))
                .frame(width: 3)
                .padding(.vertical, 12)
                .padding(.leading, 1)
        }
        .contextMenu { cardContextMenu }
    }

    // MARK: - Landscape Card

    private var landscapeCard: some View {
        HStack(spacing: 12) {
            // Thumb — honest: only show when image exists
            if hasImage {
                Color.clear
                    .frame(width: 90, height: 90)
                    .overlay {
                        if imageLoadFailed {
                            imageFailurePlaceholder
                        } else {
                            CachedAsyncImage(url: item.bestImageURL.flatMap(URL.init(string:)), articleURL: item.canResolveArticleImage ? URL(string: item.url) : nil, onResult: { success in
                                if !success { imageLoadFailed = true }
                            })
                            .scaledToFill()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Content
            VStack(alignment: .leading, spacing: 0) {
                // Source name
                Text(item.sourceTitle)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)

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
                    Text(formattedDate(item.publishedAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.top, 4)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(engine.accent.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(engine.accent.opacity(0.06), lineWidth: 0.5)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(categoryColor(item.category).opacity(isRead ? 0.25 : 0.8))
                .frame(width: 3)
                .padding(.vertical, 10)
                .padding(.leading, 1)
        }
        .contextMenu { cardContextMenu }
    }

    private var imageFailurePlaceholder: some View {
        Rectangle()
            .fill(categoryColor(item.category).opacity(0.14))
            .overlay {
                Image(systemName: "newspaper")
                    .font(.title2)
                    .foregroundStyle(categoryColor(item.category).opacity(0.55))
            }
    }

    // MARK: - Source Row (portrait only)

    private var sourceRow: some View {
        HStack(spacing: 4) {
            Text(item.sourceTitle)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .lineLimit(1)

            if item.isPodcast {
                mediaBadge("Podcast", color: .purple)
                if let dur = item.durationFormatted {
                    Text(dur).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if item.isYouTube {
                mediaBadge("Video", color: .red)
            } else if isNew && !item.isPodcast {
                mediaBadge("New", color: .blue)
            }

            Spacer()

            // Bookmark on text-only cards
            if !hasImage {
                if isInBookmarkBox {
                    Menu {
                        BookmarkBoxContextMenu(itemID: item.id)
                        Divider()
                        Button(role: .destructive) {
                            onBookmark?()
                        } label: {
                            Label("Remove from Box", systemImage: "bookmark.slash")
                        }
                    } label: {
                        Image(systemName: "bookmark.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        onBookmark?()
                    } label: {
                        Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                            .font(.caption)
                            .foregroundStyle(isBookmarked ? .yellow : .secondary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isBookmarked)
                }
            }
        }
    }

    // MARK: - Shared

    @ViewBuilder
    private var cardOverlays: some View {
        if isInBookmarkBox {
            Menu {
                BookmarkBoxContextMenu(itemID: item.id)
                Divider()
                Button(role: .destructive) {
                    onBookmark?()
                } label: {
                    Label("Remove from Box", systemImage: "bookmark.slash")
                }
            } label: {
                Image(systemName: "bookmark.fill")
                    .font(.title3)
                    .foregroundStyle(.yellow)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
                    .shadow(color: .black.opacity(0.15), radius: 4)
                    .padding(12)
            }
            .buttonStyle(.plain)
        } else {
            Button {
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                onBookmark?()
            } label: {
                Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                    .font(.title3)
                    .foregroundStyle(isBookmarked ? .yellow : .white)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
                    .shadow(color: .black.opacity(0.15), radius: 4)
                    .padding(12)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isBookmarked)
        }
    }

    @ViewBuilder
    private var mediaOverlay: some View {
        if item.isYouTube {
            Image(systemName: "play.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.black.opacity(0.35), in: Circle())
        } else if item.isPodcast {
            Image(systemName: "headphones")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.black.opacity(0.35), in: Circle())
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
        BookmarkBoxContextMenu(itemID: item.id)
        if let onViewSource {
            Button(action: onViewSource) {
                Label("View Source", systemImage: "rectangle.stack")
            }
        }
        if let onAddSourceToCollection {
            Button(action: onAddSourceToCollection) {
                Label("Add Source to Collection", systemImage: "rectangle.stack.badge.plus")
            }
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

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()
    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    private func formattedDate(_ date: Date) -> String {
        let relative = Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
        if Date().timeIntervalSince(date) < 7 * 24 * 3600 { return relative }
        return Self.shortDateFormatter.string(from: date)
    }

    private func categoryColor(_ category: String) -> Color {
        ComponentToken.categoryColor(for: category)
    }
}
