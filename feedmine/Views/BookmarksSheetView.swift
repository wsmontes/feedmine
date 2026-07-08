import SwiftUI

struct BookmarksSheetView: View {
    @Environment(FeedLoader.self) private var loader
    @State private var bookmarkLists: [BookmarkList] = []
    @State private var selectedListID: Int64?
    @State private var bookmarkedItems: [FeedItem] = []

    var body: some View {
        NavigationStack {
            Group {
                if bookmarkedItems.isEmpty {
                    ContentUnavailableView(
                        "No Saved Articles",
                        systemImage: "bookmark",
                        description: Text("Swipe left on articles or use the bookmark button to save them for later.")
                    )
                } else {
                    List {
                        if bookmarkLists.count > 1 {
                            Picker("List", selection: $selectedListID) {
                                ForEach(bookmarkLists, id: \.id) { list in
                                    Text(list.name).tag(Optional(list.id))
                                }
                            }
                        }
                        ForEach(bookmarkedItems) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .lineLimit(2)
                                HStack {
                                    Text(item.sourceTitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("·")
                                        .foregroundStyle(.tertiary)
                                    Text(item.publishedAt, style: .relative)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    loader.toggleBookmark(item.id)
                                    bookmarkedItems.removeAll { $0.id == item.id }
                                } label: {
                                    Label("Remove", systemImage: "bookmark.slash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Saved")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                do {
                    bookmarkLists = try await loader.loadBookmarkLists()
                    selectedListID = bookmarkLists.first?.id
                    if let id = selectedListID {
                        bookmarkedItems = try await loader.loadBookmarkedItems(listID: id)
                    }
                } catch { }
            }
            .onChange(of: selectedListID) { _, newID in
                guard let id = newID else { return }
                Task {
                    do {
                        bookmarkedItems = try await loader.loadBookmarkedItems(listID: id)
                    } catch { }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
