import SwiftUI

/// Manage feed collections: rename, delete, move feeds between collections.
struct CollectionManagementView: View {
    @Environment(FeedLoader.self) private var loader
    @Environment(\.dismiss) private var dismiss
    @State private var engine = CircadianEngine.shared
    @State private var editingCollection: String?
    @State private var newName = ""
    @State private var showRename = false
    @State private var showDelete = false
    @State private var deleteTarget: String?
    @State private var showMoveSheet = false
    @State private var moveSource: FeedSource?

    private var collections: [(name: String, count: Int)] {
        let grouped = Dictionary(grouping: loader.sources, by: \.category)
        return grouped.map { ($0.key, $0.value.count) }.sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(collections, id: \.name) { collection in
                    NavigationLink {
                        collectionDetail(collection.name)
                    } label: {
                        HStack {
                            Label(collection.name, systemImage: collectionIcon(collection.name))
                            Spacer()
                            Text("\(collection.count) feeds")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            deleteTarget = collection.name
                            showDelete = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            editingCollection = collection.name
                            newName = collection.name
                            showRename = true
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
            }
            .navigationTitle("Collections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Rename Collection", isPresented: $showRename) {
                TextField("Name", text: $newName)
                Button("Rename") {
                    guard let old = editingCollection, !newName.isEmpty, newName != old else { return }
                    renameCollection(from: old, to: newName)
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(
                "Delete \"\(deleteTarget ?? "")\"?",
                isPresented: $showDelete,
                titleVisibility: .visible
            ) {
                Button("Delete Collection & Feeds", role: .destructive) {
                    if let name = deleteTarget { deleteCollection(name) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All feeds in this collection will be removed. This cannot be undone.")
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Collection Detail

    private func collectionDetail(_ name: String) -> some View {
        let feeds = loader.sources.filter { $0.category == name }
        return List {
            ForEach(feeds, id: \.url) { source in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.title)
                            .font(.subheadline)
                        Text(source.url)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Menu {
                        ForEach(collections.filter { $0.name != name }, id: \.name) { dest in
                            Button("Move to \(dest.name)") {
                                moveFeed(source, to: dest.name)
                            }
                        }
                    } label: {
                        Image(systemName: "folder.badge.gearshape")
                            .font(.caption)
                            .foregroundStyle(engine.accent)
                    }
                }
            }
        }
        .navigationTitle(name)
    }

    // MARK: - Actions

    private func renameCollection(from old: String, to new: String) {
        // Update all sources in this collection
        var updated = loader.sources
        for i in updated.indices where updated[i].category == old {
            updated[i] = FeedSource(
                title: updated[i].title,
                url: updated[i].url,
                category: new,
                region: updated[i].region,
                mediaKind: updated[i].mediaKind
            )
        }
        loader.replaceAllSources(updated)
    }

    private func deleteCollection(_ name: String) {
        var updated = loader.sources
        updated.removeAll { $0.category == name }
        loader.replaceAllSources(updated)
    }

    private func moveFeed(_ source: FeedSource, to collection: String) {
        var updated = loader.sources
        if let idx = updated.firstIndex(where: { $0.url == source.url }) {
            updated[idx] = FeedSource(
                title: source.title,
                url: source.url,
                category: collection,
                region: source.region,
                mediaKind: source.mediaKind
            )
        }
        loader.replaceAllSources(updated)
    }

    private func collectionIcon(_ name: String) -> String {
        switch name.lowercased() {
        case "tech", "programming": return "laptopcomputer"
        case "news": return "newspaper.fill"
        case "science": return "flask.fill"
        case "youtube": return "play.rectangle.fill"
        case "podcasts": return "headphones"
        case "imported": return "square.and.arrow.down"
        default: return "folder.fill"
        }
    }
}
