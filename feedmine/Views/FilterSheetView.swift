import SwiftUI

struct FilterSheetView: View {
    @Environment(FeedLoader.self) private var loader
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let countries = loader.availableCountries
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
                    .disabled(!loader.hasActiveFilters && loader.searchQuery.isEmpty)
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
                            let enabled = countries.filter { loader.isRegionEnabled($0.region) }.count
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
                    NavigationLink {
                        TaxonomyBrowseView()
                    } label: {
                        HStack {
                            Label("Browse Topics", systemImage: "list.bullet.rectangle")
                            Spacer()
                            if !loader.selectedNodeNames.isEmpty {
                                Text(loader.selectedNodeNames.prefix(3).joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .accessibilityIdentifier("browse-topics")
                }

                Section("Language") {
                    let languages = loader.availableLanguages
                    if languages.isEmpty {
                        Text("No language data available")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(languages) { lang in
                            Button {
                                loader.toggleLanguage(lang.code)
                            } label: {
                                HStack {
                                    Text(lang.flag)
                                    Text(lang.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if loader.selectedLanguages.contains(lang.code) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.blue)
                                    }
                                    Text("\(lang.feedCount)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
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
                        .accessibilityIdentifier("filter-done")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

}
