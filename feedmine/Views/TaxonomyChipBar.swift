import SwiftUI

/// Horizontal scrollable chip bar showing selected taxonomy nodes and languages.
/// Replaces the flat `CategoryFilterBar` with multi-select chip UI.
/// Max 3 visible chips; overflow shows "+N more".
struct TaxonomyChipBar: View {
    @Environment(FeedLoader.self) private var loader
    let onEditTap: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // "All" chip — only visible when filters are active, as quick-reset
                if loader.hasActiveFilters {
                    TaxonomyChip(
                        title: "All",
                        isSelected: false,
                        color: .gray
                    ) {
                        loader.clearAllFilters()
                    }
                }

                // Selected node chips (max 3)
                let names = loader.selectedNodeNames
                ForEach(Array(names.prefix(3)), id: \.self) { name in
                    TaxonomyChip(
                        title: name,
                        isSelected: true,
                        color: .blue
                    ) {
                        // Find the node ID for this name and toggle it off
                        if let nodeID = TaxonomyStore.shared.selectedNodeIDs
                            .first(where: { TaxonomyStore.shared.node(id: $0)?.name == name }) {
                            loader.toggleNode(nodeID)
                        }
                    }
                }

                // Language chips
                ForEach(Array(loader.selectedLanguages).sorted(), id: \.self) { lang in
                    TaxonomyChip(
                        title: langDisplay(lang),
                        isSelected: true,
                        color: .green
                    ) {
                        loader.toggleLanguage(lang)
                    }
                }

                // Overflow indicator
                let totalChips = names.count + loader.selectedLanguages.count + (loader.hasActiveFilters ? 1 : 0)
                let visibleChips = min(names.count, 3) + loader.selectedLanguages.count + (loader.hasActiveFilters ? 1 : 0)
                if totalChips > visibleChips {
                    Text("+\(totalChips - visibleChips) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                }

                // Edit button → opens filter sheet
                Button {
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                    onEditTap()
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private func langDisplay(_ code: String) -> String {
        let name = Locale.current.localizedString(forLanguageCode: code) ?? code
        return "\(name) (\(code.uppercased()))"
    }
}

/// A single selectable chip, reused from the original CategoryPill design.
struct TaxonomyChip: View {
    let title: String
    let isSelected: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            action()
        }) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? .white : .primary)
                if isSelected {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(isSelected ? color : color.opacity(0.1))
            )
            .scaleEffect(isSelected ? 1.0 : 0.97)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
        }
        .buttonStyle(.plain)
    }
}
