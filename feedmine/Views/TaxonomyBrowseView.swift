import SwiftUI

/// Full-screen taxonomy browser with NavigationStack drill-down.
/// Each level shows direct children of the current node with checkboxes.
/// Tapping a row with children navigates deeper.
struct TaxonomyBrowseView: View {
    @Environment(FeedLoader.self) private var loader
    @State private var store = TaxonomyStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            if let root = store.root {
                TaxonomyLevelView(node: root)
                    .navigationTitle("Topics")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { dismiss() }
                        }
                    }
            }
        }
    }
}

/// A single level of the taxonomy browse — shows children of one node.
private struct TaxonomyLevelView: View {
    @Environment(FeedLoader.self) private var loader
    @State private var store = TaxonomyStore.shared
    let node: TaxonomyNode

    var body: some View {
        let children = store.children(of: node.id)
        List {
            if node.id != TaxonomyNode.rootID {
                // "All in this category" toggle
                Button {
                    loader.toggleNode(node.id)
                } label: {
                    HStack {
                        Image(systemName: store.selectedNodeIDs.contains(node.id)
                              ? "checkmark.circle.fill"
                              : "circle")
                            .foregroundStyle(store.selectedNodeIDs.contains(node.id) ? .blue : .secondary)
                        Text("All \(node.name)")
                            .fontWeight(.medium)
                        Spacer()
                        Text("\(node.feedCount) feeds")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }

            ForEach(children) { child in
                let grandchildCount = store.children(of: child.id).count
                if grandchildCount > 0 {
                    // Has children — navigate deeper
                    NavigationLink {
                        TaxonomyLevelView(node: child)
                            .navigationTitle(child.name)
                    } label: {
                        HStack {
                            Image(systemName: store.selectedNodeIDs.contains(child.id)
                                  ? "checkmark.circle.fill"
                                  : "circle")
                                .foregroundStyle(store.selectedNodeIDs.contains(child.id) ? .blue : .secondary)
                            Text(child.name)
                            Spacer()
                            Text("\(child.feedCount)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    // Leaf — no children, just toggle
                    Button {
                        loader.toggleNode(child.id)
                    } label: {
                        HStack {
                            Image(systemName: store.selectedNodeIDs.contains(child.id)
                                  ? "checkmark.circle.fill"
                                  : "circle")
                                .foregroundStyle(store.selectedNodeIDs.contains(child.id) ? .blue : .secondary)
                            Text(child.name)
                            Spacer()
                            Text("\(child.feedCount)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.plain)
    }
}
