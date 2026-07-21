import SwiftUI

struct CountryDetailScreen: View {
    @Environment(FeedLoader.self) private var loader
    let country: Country
    @State private var pendingRegionIDs = Set<String>()
    @State private var enabledPendingRegionIDs = Set<String>()

    private var feedsByCategory: [(String, [FeedSource])] {
        let grouped = Dictionary(grouping: loader.countryFeeds(for: country.region), by: \.category)
        return grouped.sorted { $0.key < $1.key }
    }

    var body: some View {
        List {
            // Sub-regions section — shown when the country has region-level OPML files
            if country.hasRegions {
                Section {
                    ForEach(country.regions) { region in
                        HStack(spacing: 12) {
                            NavigationLink {
                                RegionDetailScreen(region: region, country: country)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "mappin.and.ellipse")
                                        .font(.title3)
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(region.name).font(.body)
                                        Text("\(region.feedCount) feeds")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Toggle("", isOn: Binding(
                                get: {
                                    pendingRegionIDs.contains(region.path)
                                        ? enabledPendingRegionIDs.contains(region.path)
                                        : loader.isRegionEnabled(region.path)
                                },
                                set: { setRegionEnabled(region.path, enabled: $0) }
                            ))
                            .labelsHidden()
                            .tint(.green)
                        }
                    }
                } header: {
                    Label("Regions (\(country.regions.count))", systemImage: "map.fill")
                }
            }

            // Country-level feeds grouped by category
            ForEach(feedsByCategory, id: \.0) { category, sources in
                Section {
                    ForEach(sources, id: \.url) { source in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.title).font(.subheadline)
                                Text(source.url)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { loader.isSourceEnabled(source.url) },
                                set: { _ in loader.toggleSource(source.url) }
                            ))
                            .labelsHidden()
                            .tint(.green)
                        }
                    }
                } header: {
                    Label("\(category) (\(sources.count))", systemImage: categoryIcon(category))
                }
            }
        }
        .navigationTitle("\(country.flag) \(country.name)")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func categoryIcon(_ category: String) -> String {
        let lower = category.lowercased()
        if lower.contains("news") { return "newspaper.fill" }
        if lower.contains("sport") { return "sportscourt.fill" }
        if lower.contains("tech") || lower.contains("programming") { return "laptopcomputer" }
        if lower.contains("science") { return "flask.fill" }
        if lower.contains("movie") || lower.contains("film") || lower.contains("cinema") { return "film.fill" }
        if lower.contains("music") { return "music.note.list" }
        if lower.contains("food") { return "fork.knife" }
        if lower.contains("travel") { return "airplane" }
        if lower.contains("culture") || lower.contains("art") { return "theatermasks.fill" }
        if lower.contains("business") || lower.contains("economy") { return "chart.bar.fill" }
        if lower.contains("design") || lower.contains("architecture") { return "paintbrush.fill" }
        if lower.contains("environment") || lower.contains("nature") { return "leaf.fill" }
        if lower.contains("history") { return "book.fill" }
        if lower.contains("photo") { return "camera.fill" }
        if lower.contains("podcast") || lower.contains("audio") { return "headphones" }
        if lower.contains("youtube") || lower.contains("video") { return "play.rectangle.fill" }
        if lower.contains("blog") { return "pencil.and.outline" }
        if lower.contains("apple") { return "apple.logo" }
        if lower.contains("diy") || lower.contains("craft") { return "hammer.fill" }
        if lower.contains("game") || lower.contains("gaming") { return "gamecontroller.fill" }
        return "antenna.radiowaves.left.and.right"
    }

    private func setRegionEnabled(_ region: String, enabled: Bool) {
        pendingRegionIDs.insert(region)
        if enabled {
            enabledPendingRegionIDs.insert(region)
        } else {
            enabledPendingRegionIDs.remove(region)
        }
        let feedback = UIImpactFeedbackGenerator(style: .light)
        feedback.impactOccurred()

        DispatchQueue.main.async {
            guard pendingRegionIDs.contains(region), enabledPendingRegionIDs.contains(region) == enabled else { return }
            loader.setRegionEnabled(region, enabled: enabled)
            if enabledPendingRegionIDs.contains(region) == enabled {
                pendingRegionIDs.remove(region)
            }
        }
    }
}
