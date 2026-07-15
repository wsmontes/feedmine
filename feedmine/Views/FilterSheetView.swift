import SwiftUI

struct FilterSheetView: View {
    @Environment(FeedLoader.self) private var loader
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // Clear at top
                Section {
                    Button(role: .destructive) {
                        loader.clearAllFilters()
                        dismiss()
                    } label: {
                        Label("Clear All Filters", systemImage: "xmark.circle")
                    }
                    .disabled(loader.selectedCategory == nil && loader.selectedMood == .all && loader.selectedContentType == .all && loader.searchQuery.isEmpty)
                }

                Section("Feeds") {
                    HStack {
                        Label("Selected Feeds", systemImage: "antenna.radiowaves.left.and.right")
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { loader.isGlobalFeedsEnabled },
                            set: { _ in loader.toggleGlobalFeeds() }
                        ))
                        .labelsHidden()
                        .tint(.green)
                    }

                    NavigationLink {
                        CountriesListScreen()
                    } label: {
                        HStack {
                            Label("Countries", systemImage: "globe")
                            Spacer()
                            let enabled = loader.availableCountries.filter { loader.isRegionEnabled($0.region) }.count
                            Text("\(enabled) on")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Content Type") {
                    ForEach(FeedLoader.ContentType.allCases) { type in
                        Button { loader.selectContentType(type) } label: {
                            HStack {
                                Label(type.rawValue, systemImage: type.icon)
                                Spacer()
                                if loader.selectedContentType == type { Image(systemName: "checkmark").foregroundStyle(.blue) }
                            }
                        }
                    }
                }

                Section("Topics") {
                    TaxonomyTreeView()

                    NavigationLink {
                        TaxonomyBrowseView()
                    } label: {
                        Label("Browse All Topics", systemImage: "list.bullet.rectangle")
                    }
                }

                Section("Mood") {
                    ForEach(FeedLoader.MoodFilter.allCases) { mood in
                        Button { loader.selectMood(mood) } label: {
                            HStack {
                                Label(mood.rawValue, systemImage: mood.icon)
                                Spacer()
                                if loader.selectedMood == mood { Image(systemName: "checkmark").foregroundStyle(.blue) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

}
