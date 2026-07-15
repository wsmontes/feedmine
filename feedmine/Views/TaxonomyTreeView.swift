import SwiftUI

/// Expandable taxonomy tree with checkboxes and search bar.
/// Used inside FilterSheetView and as a standalone drill-down.
///
/// Performance:
/// - Uses `List` for cell reuse (UITableView-backed)
/// - Each level lazy-loads children
/// - Search uses `TaxonomyStore.search` with flat index O(n)
/// - Nodes collapsed by default beyond depth 2
struct TaxonomyTreeView: View {
    @Environment(FeedLoader.self) private var loader
    @State private var store = TaxonomyStore.shared
    @State private var searchText = ""
    @State private var searchResults: [TaxonomyNode] = []
    @State private var searchTask: Task<Void, Never>?

    /// Whether to show in compact mode (sheet) vs full-screen.
    var compact: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search tags...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        searchResults = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if !searchText.isEmpty {
                // Search results — flat list with breadcrumb paths
                List(searchResults) { node in
                    searchResultRow(node)
                }
                .listStyle(.plain)
            } else {
                // Tree view using recursive DisclosureGroup
                List {
                    if let root = store.root {
                        TaxonomyTreeRow(
                            node: root,
                            store: store,
                            loader: loader,
                            icon: icon(for:)
                        )
                    }
                }
                .listStyle(.plain)
            }
        }
        .onChange(of: searchText) { _, query in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                searchResults = store.search(query)
            }
        }
    }

    // MARK: - Search result row

    private func searchResultRow(_ node: TaxonomyNode) -> some View {
        Button {
            loader.toggleNode(node.id)
            searchText = ""
            searchResults = []
        } label: {
            HStack(spacing: 8) {
                Image(systemName: store.selectedNodeIDs.contains(node.id)
                      ? "checkmark.circle.fill"
                      : "circle")
                    .foregroundStyle(store.selectedNodeIDs.contains(node.id) ? .blue : .secondary.opacity(0.3))

                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Text(breadcrumb(for: node))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer()

                Text("\(node.feedCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func breadcrumb(for node: TaxonomyNode) -> String {
        store.ancestors(of: node.id)
            .filter { $0.id != TaxonomyNode.rootID && $0.id != node.id }
            .map(\.name)
            .joined(separator: " > ")
    }

    private func icon(for kind: NodeKind) -> String {
        switch kind {
        case .topic: return "square.grid.2x2"
        case .country: return "flag"
        case .region: return "mappin.and.ellipse"
        case .subcategory: return "folder"
        }
    }
}

// MARK: - Recursive tree row

/// A single row in the taxonomy tree that recursively renders children.
/// Uses `DisclosureGroup` for expand/collapse to match `OutlineGroup` semantics.
private struct TaxonomyTreeRow: View {
    let node: TaxonomyNode
    let store: TaxonomyStore
    let loader: FeedLoader
    let icon: (NodeKind) -> String

    var body: some View {
        let children = store.children(of: node.id)
        if children.isEmpty {
            taxonomyRow
        } else {
            DisclosureGroup {
                ForEach(children) { child in
                    TaxonomyTreeRow(
                        node: child,
                        store: store,
                        loader: loader,
                        icon: icon
                    )
                }
            } label: {
                taxonomyRow
            }
        }
    }

    private var taxonomyRow: some View {
        HStack(spacing: 8) {
            // Checkbox
            Button {
                loader.toggleNode(node.id)
            } label: {
                Image(systemName: store.selectedNodeIDs.contains(node.id)
                      ? "checkmark.circle.fill"
                      : "circle")
                    .foregroundStyle(store.selectedNodeIDs.contains(node.id) ? .blue : .secondary.opacity(0.3))
                    .font(.body)
            }
            .buttonStyle(.plain)

            // Icon based on kind
            Image(systemName: icon(node.kind))
                .font(.caption)
                .foregroundStyle(node.kind == .country ? .green : .secondary)
                .frame(width: 16)

            // Name
            Text(node.name)
                .font(.subheadline)
                .lineLimit(1)

            Spacer()

            // Feed count badge
            Text("\(node.feedCount)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
        .padding(.vertical, 2)
    }
}
