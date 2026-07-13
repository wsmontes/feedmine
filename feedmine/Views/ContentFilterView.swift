import SwiftUI

struct ContentFilterView: View {
    @State private var store = ContentFilterStore.shared
    @State private var engine = CircadianEngine.shared
    @State private var showAddCustom = false
    @State private var customKeywords = ""
    @State private var customName = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Master Toggle + Stats
                Section {
                    Toggle(isOn: $store.isEnabled) {
                        Label("Content Filters", systemImage: "eye.slash.fill")
                    }
                    .tint(engine.accent)

                    if store.isEnabled && store.totalHiddenToday > 0 {
                        HStack {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            Text("\(store.totalHiddenToday) items hidden today")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Reset") {
                                store.resetDailyCounts()
                            }
                            .font(.caption)
                            .foregroundStyle(engine.accent)
                        }
                    }
                } footer: {
                    Text("Hide articles containing specific words. Filters apply to titles and excerpts in any language.")
                }

                // MARK: - Templates
                Section {
                    ForEach(templateFilters) { filter in
                        templateRow(filter)
                    }
                } header: {
                    Text("Templates")
                } footer: {
                    Text("Pre-configured filters with keywords translated in 33 languages. Tap to enable.")
                }

                // MARK: - Custom Rules
                Section {
                    ForEach(customFilters) { filter in
                        customRow(filter)
                    }
                    .onDelete(perform: deleteCustom)

                    Button {
                        customName = ""
                        customKeywords = ""
                        showAddCustom = true
                    } label: {
                        Label("Add Keywords…", systemImage: "plus.circle")
                            .foregroundStyle(engine.accent)
                    }
                } header: {
                    Text("Custom Rules")
                } footer: {
                    if customFilters.isEmpty {
                        Text("Add your own keywords to hide specific topics. Separate multiple words with commas.")
                    }
                }
            }
            .navigationTitle("Content Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Add Filter", isPresented: $showAddCustom) {
                TextField("Name (e.g. My Filter)", text: $customName)
                TextField("Keywords (comma-separated)", text: $customKeywords)
                Button("Add") {
                    let keywords = customKeywords
                        .components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                        .filter { !$0.isEmpty }
                    guard !keywords.isEmpty else { return }
                    let name = customName.isEmpty ? keywords.first!.capitalized : customName
                    store.addCustom(name: name, keywords: keywords)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter words separated by commas. Articles containing any of these words will be hidden.")
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Computed

    private var templateFilters: [ContentFilter] {
        store.filters.filter(\.isTemplate)
    }

    private var customFilters: [ContentFilter] {
        store.filters.filter { !$0.isTemplate }
    }

    // MARK: - Template Row

    private func templateRow(_ filter: ContentFilter) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                store.toggle(filter.id)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: templateIcon(filter.templateKey))
                    .font(.body)
                    .foregroundStyle(filter.isEnabled ? engine.accent : .secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(filter.name)
                        .foregroundStyle(.primary)
                    Text(keywordPreview(filter))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer()

                if filter.isEnabled && filter.hiddenCount > 0 {
                    Text("\(filter.hiddenCount)")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(engine.accent.opacity(0.8), in: Capsule())
                }

                Image(systemName: filter.isEnabled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(filter.isEnabled ? engine.accent : Color.secondary.opacity(0.3))
                    .font(.title3)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint(filter.isEnabled ? "Double tap to disable this filter" : "Double tap to enable this filter")
        .accessibilityAddTraits(filter.isEnabled ? .isSelected : [])
    }

    // MARK: - Custom Row

    private func customRow(_ filter: ContentFilter) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "text.word.spacing")
                .foregroundStyle(filter.isEnabled ? engine.accent : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(filter.name)
                Text(filter.keywords.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            if filter.hiddenCount > 0 {
                Text("\(filter.hiddenCount)")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(engine.accent.opacity(0.8), in: Capsule())
            }

            Toggle("", isOn: Binding(
                get: { filter.isEnabled },
                set: { _ in store.toggle(filter.id) }
            ))
            .labelsHidden()
            .tint(engine.accent)
        }
    }

    // MARK: - Helpers

    private func deleteCustom(at offsets: IndexSet) {
        let custom = customFilters
        for offset in offsets {
            store.removeCustom(custom[offset].id)
        }
    }

    private func keywordPreview(_ filter: ContentFilter) -> String {
        let preview = filter.keywords.prefix(5).joined(separator: ", ")
        if filter.keywords.count > 5 {
            return preview + " +\(filter.keywords.count - 5) more"
        }
        return preview
    }

    private func templateIcon(_ key: String?) -> String {
        switch key {
        case "politics": return "building.columns.fill"
        case "violence": return "exclamationmark.shield.fill"
        case "crypto": return "bitcoinsign.circle.fill"
        case "sports": return "sportscourt.fill"
        case "celebrity": return "star.fill"
        case "ai_hype": return "cpu.fill"
        default: return "line.3.horizontal.decrease.circle.fill"
        }
    }
}
