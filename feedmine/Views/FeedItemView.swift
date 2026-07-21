import SwiftUI

/// Wraps a single feed item with all its modifiers,
/// extracted from FeedScreen to reduce type-checking complexity.
struct FeedItemView: View {
    @Environment(FeedLoader.self) private var loader
    let item: FeedItem
    var onOpen: (() -> Void)? = nil
    var onCopy: (() -> Void)? = nil
    var onPlaybackFailed: (() -> Void)? = nil
    var onViewSource: (() -> Void)? = nil
    var onAddSourceToCollection: (() -> Void)? = nil

    var body: some View {
        Group {
            if loader.layout == .card {
                FeedItemCardView(
                    item: item,
                    isRead: item.isRead,
                    isBookmarked: item.isBookmarked,
                    onBookmark: { loader.toggleBookmark(item.id) },
                    onViewSource: onViewSource,
                    onAddSourceToCollection: onAddSourceToCollection,
                    isInBookmarkBox: loader.selectedBookmarkListID != nil
                )
                .equatable()
                .padding(.horizontal, 12)
            } else {
                FeedItemRowView(
                    item: item,
                    isRead: item.isRead,
                    isBookmarked: item.isBookmarked
                )
                Divider()
            }
        }
        .id(item.id)
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
                if item.isRead {
                    loader.markAsUnread(item.id)
                } else {
                    loader.markAsRead(item.id)
                }
            } label: {
                Label(
                    item.isRead ? "Unread" : "Read",
                    systemImage: item.isRead ? "eye.slash" : "eye"
                )
            }
            .tint(item.isRead ? .gray : .green)
        }
        .swipeActions(edge: .trailing) {
            Button {
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                loader.toggleBookmark(item.id)
            } label: {
                Label(
                    item.isBookmarked ? "Remove" : "Save",
                    systemImage: item.isBookmarked ? "bookmark.slash.fill" : "bookmark.fill"
                )
            }
            .tint(.yellow)
        }
        .contextMenu {
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
        .accessibilityIdentifier("feed-item-\(item.language ?? "und")-\(item.id)")
        .accessibilityLabel("\(item.title) from \(item.sourceTitle)")
        .accessibilityAddTraits(item.isRead ? [] : .isHeader)
    }
}
