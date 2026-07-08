import SwiftUI

struct BookmarksSheetView: View {
    @Environment(FeedLoader.self) private var loader
    @State private var bookmarkLists: [BookmarkList] = []
    @State private var selectedListID: Int64?
    @State private var bookmarkedItems: [FeedItem] = []
    @State private var activeSearchIDs: Set<Int64> = []
    @State private var togglingSearchID: Int64?

    var body: some View {
        NavigationStack {
            Group {
                if bookmarkLists.isEmpty && bookmarkedItems.isEmpty {
                    ContentUnavailableView(
                        "No Saved Articles",
                        systemImage: "bookmark",
                        description: Text("Swipe left on articles or use the bookmark button to save them for later.")
                    )
                } else {
                    List {
                        // List picker
                        if bookmarkLists.count > 1 {
                            Section("Lists") {
                                Picker("List", selection: $selectedListID) {
                                    ForEach(bookmarkLists, id: \.id) { list in
                                        HStack {
                                            Text(list.name)
                                            if list.isPersistentSearch {
                                                Image(systemName: activeSearchIDs.contains(list.id)
                                                      ? "magnifyingglass.circle.fill"
                                                      : "magnifyingglass")
                                                    .foregroundStyle(activeSearchIDs.contains(list.id) ? .blue : .secondary)
                                            }
                                        }
                                        .tag(Optional(list.id))
                                    }
                                }
                            }
                        }

                        // Active search toggle for the selected list
                        if let selected = bookmarkLists.first(where: { $0.id == selectedListID }),
                           selected.isPersistentSearch {
                            Section("Persistent Search") {
                                HStack {
                                    Label(
                                        activeSearchIDs.contains(selected.id)
                                            ? "Active — capturing new matches"
                                            : "Inactive — tap to activate",
                                        systemImage: activeSearchIDs.contains(selected.id)
                                            ? "antenna.radiowaves.left.and.right"
                                            : "antenna.radiowaves.left.and.right.slash"
                                    )
                                    .font(.subheadline)
                                    Spacer()
                                    if togglingSearchID == selected.id {
                                        ProgressView()
                                    } else {
                                        Toggle("", isOn: Binding(
                                            get: { activeSearchIDs.contains(selected.id) },
                                            set: { newValue in
                                                Task {
                                                    togglingSearchID = selected.id
                                                    do {
                                                        try await loader.toggleSearchActive(listID: selected.id)
                                                        if newValue {
                                                            activeSearchIDs.insert(selected.id)
                                                        } else {
                                                            activeSearchIDs.remove(selected.id)
                                                        }
                                                        // Reload items after toggling
                                                        bookmarkedItems = try await loader.loadBookmarkedItems(listID: selected.id)
                                                    } catch {}
                                                    togglingSearchID = nil
                                                }
                                            }
                                        ))
                                        .labelsHidden()
                                        .tint(.blue)
                                    }
                                }
                                if let query = selected.searchQuery {
                                    Text("Query: \"\(query)\"")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        // Items
                        Section("Articles (\(bookmarkedItems.count))") {
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
            }
            .navigationTitle("Saved")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await loadData()
            }
            .onChange(of: selectedListID) { _, newID in
                guard let id = newID else { return }
                Task { await loadItems(listID: id) }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func loadData() async {
        do {
            bookmarkLists = try await loader.loadBookmarkLists()
            selectedListID = bookmarkLists.first?.id
            // Collect which searches are active
            let searches = try await loader.loadActiveSearches()
            activeSearchIDs = Set(searches.map(\.id))
            if let id = selectedListID {
                await loadItems(listID: id)
            }
        } catch {}
    }

    private func loadItems(listID: Int64) async {
        do {
            bookmarkedItems = try await loader.loadBookmarkedItems(listID: listID)
        } catch {}
    }
}
