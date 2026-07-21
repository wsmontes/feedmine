import SwiftUI

/// One compact row for every active feed lens: search, source region,
/// content type, topics, languages and mood. The top bar owns only the
/// filter button; this view owns the visible active state.
struct FilterLensBar: View {
    @Environment(FeedLoader.self) private var loader
    let onDismiss: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if !searchQuery.isEmpty {
                    FilterLensChip(
                        title: "Search: \(searchQuery)",
                        systemImage: "magnifyingglass",
                        tint: .indigo
                    ) {
                        loader.searchQuery = ""
                        loader.searchQueryChanged()
                    }
                }

                if let region = loader.selectedRegion {
                    FilterLensChip(
                        title: regionDisplayName(region),
                        systemImage: "globe.americas.fill",
                        tint: .cyan
                    ) {
                        loader.clearRegionFilter()
                    }
                }

                if loader.selectedContentType != .all {
                    FilterLensChip(
                        title: loader.selectedContentType.rawValue,
                        systemImage: loader.selectedContentType.icon,
                        tint: .blue
                    ) {
                        loader.selectContentType(loader.selectedContentType)
                    }
                }

                ForEach(selectedTopics) { topic in
                    FilterLensChip(
                        title: topic.title,
                        systemImage: "tag.fill",
                        tint: .purple
                    ) {
                        loader.toggleNode(topic.id)
                    }
                }

                ForEach(Array(loader.selectedLanguages).sorted(), id: \.self) { code in
                    FilterLensChip(
                        title: languageDisplayName(code),
                        systemImage: "character.bubble.fill",
                        tint: .green
                    ) {
                        loader.toggleLanguage(code)
                    }
                }

                if loader.selectedMood != .all {
                    FilterLensChip(
                        title: loader.selectedMood.rawValue,
                        systemImage: loader.selectedMood.icon,
                        tint: .orange
                    ) {
                        loader.selectMood(loader.selectedMood)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.18)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 16)
                .onEnded { value in
                    let horizontalDismiss = abs(value.translation.width) > 80
                        && abs(value.translation.width) > abs(value.translation.height) * 1.4
                    let upwardDismiss = value.translation.height < -22
                    if horizontalDismiss || upwardDismiss {
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        onDismiss()
                    }
                }
        )
        .accessibilityHint("Swipe up or sideways to hide this filter bar")
    }

    private var searchQuery: String {
        loader.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedTopics: [FilterLensTopic] {
        loader.selectedNodeIDs.compactMap { id in
            guard let node = TaxonomyStore.shared.node(id: id) else { return nil }
            return FilterLensTopic(id: id, title: node.name)
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func languageDisplayName(_ code: String) -> String {
        if let language = loader.availableLanguages.first(where: { $0.code == code }) {
            return "\(language.flag) \(code.uppercased())"
        }
        return code.uppercased()
    }

    private func regionDisplayName(_ region: String) -> String {
        if region == "global" { return "Global" }

        if region.hasPrefix("countries/") {
            let path = region.replacingOccurrences(of: "countries/", with: "")
            let parts = path.split(separator: "/").map(String.init)
            guard let countrySlug = parts.first else { return "Country" }

            let country = "\(CountryStore.countryFlag(for: countrySlug)) \(CountryStore.countryName(for: countrySlug))"
            guard parts.count > 1 else { return country }

            let area = parts.dropFirst()
                .joined(separator: " ")
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
            return "\(country) · \(area)"
        }

        if region.hasPrefix("topic/") {
            return region.replacingOccurrences(of: "topic/", with: "")
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
        }

        return region.replacingOccurrences(of: "-", with: " ").capitalized
    }
}

private struct FilterLensTopic: Identifiable {
    let id: String
    let title: String
}

private struct FilterLensChip: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            action()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .imageScale(.small)
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(tint.opacity(0.7))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(tint.opacity(0.12))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(title)")
    }
}
