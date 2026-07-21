import SwiftUI

struct FilterSheetView: View {
    @Environment(FeedLoader.self) private var loader
    @Environment(\.dismiss) private var dismiss
    @State private var draftContentType: FeedLoader.ContentType = .all
    @State private var draftLanguages: Set<String> = []
    @State private var draftMood: FeedLoader.MoodFilter = .all
    @State private var draftIsDirty = false
    @State private var isGlobalFeedsChangePending = false
    @State private var pendingGlobalFeedsValue = false

    private var hasDraftFilters: Bool {
        draftContentType != .all
            || !draftLanguages.isEmpty
            || draftMood != .all
            || loader.hasRegionSelection
            || loader.hasTaxonomySelection
    }

    var body: some View {
        let countries = loader.availableCountries
        NavigationStack {
            List {
                // Clear at top
                Section {
                    Button(role: .destructive) {
                        draftContentType = .all
                        draftLanguages = []
                        draftMood = .all
                        draftIsDirty = false
                        loader.clearAllFilters()
                        dismiss()
                    } label: {
                        Label("Clear All Filters", systemImage: "xmark.circle")
                    }
                    .disabled(!hasDraftFilters && loader.searchQuery.isEmpty)
                }

                Section("Feeds") {
                    HStack {
                        Label("Selected Feeds", systemImage: "antenna.radiowaves.left.and.right")
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { isGlobalFeedsChangePending ? pendingGlobalFeedsValue : loader.isGlobalFeedsEnabled },
                            set: { setGlobalFeedsEnabled($0) }
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
                        Button {
                            draftContentType = draftContentType == type ? .all : type
                            draftIsDirty = true
                            UISelectionFeedbackGenerator().selectionChanged()
                        } label: {
                            HStack {
                                Label(type.rawValue, systemImage: type.icon)
                                Spacer()
                                if draftContentType == type {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                        .accessibilityIdentifier("content-type-\(type.rawValue.lowercased())-selected")
                                }
                            }
                        }
                        .accessibilityIdentifier("content-type-\(type.rawValue.lowercased())")
                        .accessibilityValue(draftContentType == type ? "selected" : "not selected")
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
                    .accessibilityValue("\(loader.selectedNodeIDs.count)")
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
                                if draftLanguages.contains(lang.code) {
                                    draftLanguages.remove(lang.code)
                                } else {
                                    draftLanguages.insert(lang.code)
                                }
                                draftIsDirty = true
                                UISelectionFeedbackGenerator().selectionChanged()
                            } label: {
                                HStack {
                                    Text(lang.flag)
                                    Text(lang.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if draftLanguages.contains(lang.code) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.blue)
                                    }
                                    VStack(alignment: .trailing, spacing: 1) {
                                        Text("\(lang.feedCount) on")
                                        if lang.totalFeedCount > lang.feedCount {
                                            Text("\(lang.totalFeedCount) total")
                                        }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                }
                            }
                            .accessibilityIdentifier("language-\(lang.code)")
                            .accessibilityValue(draftLanguages.contains(lang.code) ? "selected" : "not selected")
                        }
                    }
                }

                Section("Mood") {
                    ForEach(FeedLoader.MoodFilter.allCases) { mood in
                        Button {
                            draftMood = draftMood == mood ? .all : mood
                            draftIsDirty = true
                            UISelectionFeedbackGenerator().selectionChanged()
                        } label: {
                            HStack {
                                Label(mood.rawValue, systemImage: mood.icon)
                                Spacer()
                                if draftMood == mood { Image(systemName: "checkmark").foregroundStyle(.blue) }
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
        .onAppear {
            draftContentType = loader.selectedContentType
            draftLanguages = loader.selectedLanguages
            draftMood = loader.selectedMood
            draftIsDirty = false
            loader.beginFilterEditing()
        }
        .onDisappear {
            if draftIsDirty {
                loader.applyFilterDraft(
                    type: draftContentType,
                    mood: draftMood,
                    languages: draftLanguages
                )
            }
            loader.endFilterEditing()
        }
    }

    private func setGlobalFeedsEnabled(_ enabled: Bool) {
        pendingGlobalFeedsValue = enabled
        isGlobalFeedsChangePending = true
        let feedback = UIImpactFeedbackGenerator(style: .light)
        feedback.impactOccurred()

        DispatchQueue.main.async {
            guard isGlobalFeedsChangePending, pendingGlobalFeedsValue == enabled else { return }
            loader.setGlobalFeedsEnabled(enabled)
            if pendingGlobalFeedsValue == enabled {
                isGlobalFeedsChangePending = false
            }
        }
    }
}
