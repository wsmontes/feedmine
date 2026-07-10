import SwiftUI

/// Context menu content with all bookmark boxes for saving an item.
struct BookmarkBoxContextMenu: View {
    @Environment(FeedLoader.self) private var loader
    let itemID: String

    var body: some View {
        let boxes = loader.bookmarkLists
        Group {
            if boxes.isEmpty {
                Button {
                    loader.toggleBookmark(itemID)
                } label: {
                    Label("Save to Favorites", systemImage: "bookmark")
                }
            }
            ForEach(Array(boxes.prefix(5))) { box in
                Button {
                    loader.toggleBookmark(itemID, listID: box.id)
                } label: {
                    Label(box.name, systemImage: box.id == (loader.preferredBookmarkListID ?? boxes.first(where: { $0.isDefault })?.id) ? "folder.fill" : "folder")
                }
            }
        }
    }
}

struct BookmarkBoxPickerView: View {
    @Environment(FeedLoader.self) private var loader
    let itemID: String
    var onDismiss: () -> Void

    @State private var boxes: [BookmarkList] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(boxes) { box in
                    Button {
                        loader.toggleBookmark(itemID, listID: box.id)
                        onDismiss()
                    } label: {
                        HStack {
                            Label(box.name, systemImage: "folder")
                                .fontWeight(box.id == (loader.preferredBookmarkListID ?? boxes.first(where: { $0.isDefault })?.id) ? .bold : .regular)
                            Spacer()
                            Text("\(box.itemCount)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Save to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { onDismiss() }
                }
            }
            .task {
                do { boxes = try await loader.loadBookmarkLists() }
                catch {}
            }
        }
        .presentationDetents([.medium])
    }
}
