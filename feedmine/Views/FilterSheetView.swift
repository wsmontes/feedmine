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
                        Label("Global Feeds", systemImage: "antenna.radiowaves.left.and.right")
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
                        Label("Countries", systemImage: "globe")
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

                Section("Category") {
                    Button { loader.selectCategory(nil) } label: {
                        HStack {
                            Label("All Categories", systemImage: "square.grid.2x2")
                            Spacer()
                            if loader.selectedCategory == nil { Image(systemName: "checkmark").foregroundStyle(.blue) }
                        }
                    }
                    ForEach(loader.availableCategories, id: \.self) { cat in
                        Button { loader.selectCategory(cat) } label: {
                            HStack {
                                Label(cat, systemImage: categoryIcon(cat))
                                Spacer()
                                if loader.selectedCategory == cat { Image(systemName: "checkmark").foregroundStyle(.blue) }
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
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func categoryIcon(_ cat: String) -> String {
        switch cat.lowercased() {
        case "tech": return "laptopcomputer"
        case "news": return "newspaper.fill"
        case "science": return "flask.fill"
        case "design": return "paintpalette.fill"
        case "culture": return "theatermasks.fill"
        default: return "dot.radiowaves.left.and.right"
        }
    }
}
