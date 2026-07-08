import SwiftUI

/// Displays feed sources for a specific sub-region within a country
/// (e.g., "California" within USA, "São Paulo" within Brazil).
struct RegionDetailScreen: View {
    @Environment(FeedLoader.self) private var loader
    let region: Region
    let country: Country

    private var feedsByCategory: [(String, [FeedSource])] {
        let grouped = Dictionary(grouping: loader.regionFeeds(for: region.path), by: \.category)
        return grouped.sorted { $0.key < $1.key }
    }

    var body: some View {
        List {
            // Sub-region toggle
            Section {
                HStack {
                    Label("\(region.name) feeds", systemImage: "mappin.and.ellipse")
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { loader.isRegionEnabled(region.path) },
                        set: { _ in loader.toggleRegion(region.path) }
                    ))
                    .labelsHidden()
                    .tint(.green)
                }
            }

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
        .navigationTitle(region.name)
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
}
