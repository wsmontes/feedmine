import SwiftUI

/// Wraps a single feed item with all its modifiers,
/// extracted from FeedScreen to reduce type-checking complexity.
struct FeedItemView: View {
    @Environment(FeedLoader.self) private var loader
    let item: FeedItem
    let index: Int
    var isFirstAppearance: Bool = true
    var onOpen: (() -> Void)?
    var onCopy: (() -> Void)?
    var onPlaybackFailed: (() -> Void)?

    var body: some View {
        Group {
            if loader.layout == .card {
                FeedItemCardView(
                    item: item,
                    isRead: loader.isRead(item.id),
                    isBookmarked: loader.isBookmarked(item.id),
                    appearDelay: Double(index % 8) * 0.04,
                    onBookmark: { loader.toggleBookmark(item.id) },
                    isInBookmarkBox: loader.selectedBookmarkListID != nil,
                    isFirstAppearance: isFirstAppearance
                )
                .equatable()
                .padding(.horizontal, 12)
            } else {
                FeedItemRowView(
                    item: item,
                    isRead: loader.isRead(item.id),
                    isBookmarked: loader.isBookmarked(item.id)
                )
                Divider()
            }
        }
        .id(item.id)
        .scrollTransition(.animated(.spring(duration: 0.4))) { content, phase in
            content
                .opacity(phase == .identity ? 1 : 0.5)
                .scaleEffect(phase == .identity ? 1 : 0.95)
        }
        .onTapGesture {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            if item.isPodcast {
                if AudioPlayerManager.shared.play(item: item) {
                    loader.markAsRead(item.id)
                    SessionTracker.shared.onArticleRead()
                } else {
                    onPlaybackFailed?()
                    return
                }
            } else {
                loader.markAsRead(item.id)
                SessionTracker.shared.onArticleRead()
                onOpen?()
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                if loader.isRead(item.id) {
                    loader.markAsUnread(item.id)
                } else {
                    loader.markAsRead(item.id)
                }
            } label: {
                Label(
                    loader.isRead(item.id) ? "Unread" : "Read",
                    systemImage: loader.isRead(item.id) ? "eye.slash" : "eye"
                )
            }
            .tint(loader.isRead(item.id) ? .gray : .green)
        }
        .swipeActions(edge: .trailing) {
            Button {
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                loader.toggleBookmark(item.id)
            } label: {
                Label(
                    loader.isBookmarked(item.id) ? "Remove" : "Save",
                    systemImage: loader.isBookmarked(item.id) ? "bookmark.slash.fill" : "bookmark.fill"
                )
            }
            .tint(.yellow)
        }
        .contextMenu {
            BookmarkBoxContextMenu(itemID: item.id)

            Button {
                loader.searchQuery = item.sourceTitle
                loader.searchQueryChanged()
            } label: {
                Label("Show more from \(item.sourceTitle)", systemImage: "arrow.triangle.branch")
            }

            Button {
                UIPasteboard.general.url = URL(string: item.url)
                onCopy?()
            } label: {
                Label("Copy Link", systemImage: "doc.on.doc")
            }
            Button {
                if let image = renderCardAsImage(item: item) {
                    let av = UIActivityViewController(activityItems: [image], applicationActivities: nil)
                    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                       let root = windowScene.windows.first?.rootViewController {
                        root.present(av, animated: true)
                    }
                }
            } label: {
                Label("Share as Image", systemImage: "photo.artframe")
            }

            ShareLink(item: URL(string: item.url) ?? URL(string: "https://feedmine.app")!) {
                Label("Share Link", systemImage: "link")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title) from \(item.sourceTitle)")
        .accessibilityAddTraits(loader.isRead(item.id) ? [] : .isHeader)
    }
}
