import SwiftUI

struct BookmarksSheetView: View {
    @Environment(FeedLoader.self) private var loader

    var body: some View {
        NavigationStack {
            if loader.bookmarkedItems.isEmpty {
                ContentUnavailableView(
                    "No Saved Articles",
                    systemImage: "bookmark",
                    description: Text("Swipe left on articles or use the bookmark button to save them for later.")
                )
            } else {
                List {
                    ForEach(loader.bookmarkedItems) { item in
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
                            } label: {
                                Label("Remove", systemImage: "bookmark.slash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Saved")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
