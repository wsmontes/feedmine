import SwiftUI

struct SourceManagementView: View {
    @Environment(FeedLoader.self) private var loader

    private var sourcesByCategory: [(String, [FeedSource])] {
        let grouped = Dictionary(grouping: loader.sources, by: \.category)
        return grouped.sorted { $0.key < $1.key }
    }

    var body: some View {
        NavigationStack {
            List {
                if loader.sources.isEmpty {
                    ContentUnavailableView(
                        "No Sources",
                        systemImage: "antenna.radiowaves.left.and.right",
                        description: Text("Add .opml files to Resources/Feeds/ to populate sources.")
                    )
                }

                ForEach(sourcesByCategory, id: \.0) { category, sources in
                    Section {
                        ForEach(sources, id: \.url) { source in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.title)
                                        .font(.subheadline)
                                    Text(source.url)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                Toggle("", isOn: Binding(
                                    get: { loader.isSourceEnabled(source.url) },
                                    set: { _ in
                                        loader.toggleSource(source.url)
                                    }
                                ))
                                .labelsHidden()
                                .tint(.green)
                            }
                        }
                    } header: {
                        Label(category, systemImage: categoryIcon(category))
                            .font(.subheadline)
                    }
                }

                Section {
                    HStack {
                        Text("Enabled")
                        Spacer()
                        Text("\(loader.enabledSources.count) of \(loader.sources.count)")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Disabled")
                        Spacer()
                        Text("\(loader.disabledSourceIDs.count)")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Disabled sources are skipped during feed fetching. Changes take effect on next refresh.")
                }
            }
            .navigationTitle("Sources")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private func categoryIcon(_ category: String) -> String {
        switch category.lowercased() {
        case "tech": return "laptopcomputer"
        case "news": return "newspaper.fill"
        case "science": return "flask.fill"
        case "design": return "paintpalette.fill"
        case "culture": return "theatermasks.fill"
        default: return "dot.radiowaves.left.and.right"
        }
    }
}
