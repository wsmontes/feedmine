import SwiftUI
import UIKit

struct ExportView: View {
    @Environment(FeedLoader.self) private var loader
    @Environment(\.dismiss) private var dismiss
    @State private var engine = CircadianEngine.shared
    @State private var selectedScope: ExportScope = .all
    @State private var selectedFormat: ExportFormat = .opml
    @State private var selectedCollection: String?
    @State private var preview: String = ""
    @State private var showDocumentPicker = false
    @State private var exportFileURL: URL?
    @State private var bookmarkedArticles: [FeedItem] = []

    private var scopedSources: [FeedSource] {
        switch selectedScope {
        case .all: return loader.sources
        case .enabledOnly: return loader.enabledSources
        case .collection:
            guard let col = selectedCollection else { return loader.sources }
            return loader.sources.filter { $0.category == col }
        case .country:
            guard let col = selectedCollection else { return loader.sources }
            return loader.sources.filter { $0.region == col || $0.region.hasPrefix(col + "/") }
        case .bookmarks: return loader.sources  // Bookmarks export uses articles, not sources
        case .fullBackup: return loader.sources
        }
    }

    private var enabledURLs: Set<String> {
        Set(loader.enabledSources.map(\.url))
    }

    private var collections: [String] {
        Set(loader.sources.map(\.category)).sorted()
    }

    private var countries: [String] {
        Set(loader.sources.map(\.region).filter { $0.hasPrefix("countries/") }
            .map { $0.components(separatedBy: "/").prefix(2).joined(separator: "/") }).sorted()
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Scope
                Section("What to export") {
                    Picker("Scope", selection: $selectedScope) {
                        ForEach(ExportScope.allCases) { scope in
                            Label(scope.rawValue, systemImage: scope.icon).tag(scope)
                        }
                    }
                    .pickerStyle(.menu)

                    if selectedScope == .collection {
                        Picker("Collection", selection: $selectedCollection) {
                            Text("All").tag(nil as String?)
                            ForEach(collections, id: \.self) { col in
                                Text(col).tag(col as String?)
                            }
                        }
                    }
                    if selectedScope == .country {
                        Picker("Country", selection: $selectedCollection) {
                            Text("All").tag(nil as String?)
                            ForEach(countries, id: \.self) { country in
                                Text(CountryStore.countryName(for: country.replacingOccurrences(of: "countries/", with: "")))
                                    .tag(country as String?)
                            }
                        }
                    }

                    HStack {
                        Text("Sources")
                        Spacer()
                        Text("\(scopedSources.count) feeds")
                            .foregroundStyle(.secondary)
                    }
                }

                // MARK: - Format
                Section("Format") {
                    ForEach(availableFormats) { format in
                        Button {
                            selectedFormat = format
                            updatePreview()
                        } label: {
                            HStack {
                                Label(format.rawValue, systemImage: format.icon)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if selectedFormat == format {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(engine.accent)
                                }
                            }
                        }
                    }
                }

                // MARK: - Preview
                if !preview.isEmpty {
                    Section("Preview") {
                        Text(preview)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(12)
                            .foregroundStyle(.secondary)
                    }
                }

                // MARK: - Actions
                Section {
                    Button {
                        shareExport()
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .foregroundStyle(engine.accent)
                    }

                    Button {
                        saveToFiles()
                    } label: {
                        Label("Save to Files", systemImage: "folder.badge.plus")
                            .foregroundStyle(engine.accent)
                    }

                    Button {
                        copyToClipboard()
                    } label: {
                        Label("Copy to Clipboard", systemImage: "doc.on.doc")
                            .foregroundStyle(engine.accent)
                    }
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { updatePreview() }
            .onChange(of: selectedScope) { _, newScope in
                if newScope == .bookmarks { loadBookmarks() }
                updatePreview()
            }
            .onChange(of: selectedCollection) { _, _ in updatePreview() }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Available formats per scope

    private var availableFormats: [ExportFormat] {
        switch selectedScope {
        case .bookmarks:
            return [.text, .markdown, .csv, .html]  // Articles, not OPML
        case .fullBackup:
            return [.json]  // Only JSON for full backup
        default:
            return ExportFormat.allCases
        }
    }

    // MARK: - Actions

    private func loadBookmarks() {
        Task {
            do {
                let lists = try await loader.loadBookmarkLists()
                let defaultID = lists.first(where: \.isDefault)?.id ?? lists.first?.id ?? 1
                bookmarkedArticles = try await loader.loadBookmarkedItems(listID: defaultID)
            } catch {
                bookmarkedArticles = []
            }
        }
    }

    private func updatePreview() {
        // Reset format if not available for current scope
        if !availableFormats.contains(selectedFormat) {
            selectedFormat = availableFormats.first ?? .opml
        }

        let sources = scopedSources
        switch selectedFormat {
        case .opml:
            preview = String(data: ExportEngine.opml(sources: sources).prefix(500), encoding: .utf8) ?? ""
        case .json:
            let filters = ContentFilterStore.shared.filters
            let bookmarkIDs = Array(loader.bookmarkedIDs)
            preview = String(data: ExportEngine.jsonBackup(sources: sources, contentFilters: filters, bookmarkIDs: bookmarkIDs).prefix(500), encoding: .utf8) ?? ""
        case .csv:
            if selectedScope == .bookmarks {
                preview = String(data: ExportEngine.csvArticles(items: bookmarkedArticles).prefix(500), encoding: .utf8) ?? ""
            } else {
                preview = String(data: ExportEngine.csv(sources: sources, enabledURLs: enabledURLs).prefix(500), encoding: .utf8) ?? ""
            }
        case .text:
            if selectedScope == .bookmarks {
                preview = String(ExportEngine.plainTextArticles(items: bookmarkedArticles).prefix(500))
            } else {
                preview = String(ExportEngine.plainText(sources: sources).prefix(500))
            }
        case .markdown:
            if selectedScope == .bookmarks {
                preview = String(ExportEngine.markdownArticles(items: bookmarkedArticles).prefix(500))
            } else {
                preview = String(ExportEngine.markdown(sources: sources).prefix(500))
            }
        case .html:
            if selectedScope == .bookmarks {
                preview = "HTML reading list (\(bookmarkedArticles.count) articles). Dark mode ready."
            } else {
                preview = "HTML blogroll (\(sources.count) feeds, \(Set(sources.map(\.category)).count) collections). Dark mode ready."
            }
        case .shareLink:
            let result = ExportEngine.shareLink(sources: sources)
            switch result {
            case .text(let s): preview = s
            case .file(_, let desc): preview = desc
            }
        case .socialCard:
            let stats = ExportEngine.SocialCardStats(
                streak: Settings.sessionStreak,
                articlesRead: loader.readItemIDs.count
            )
            preview = ExportEngine.socialCard(sources: sources, stats: stats)
        }
    }

    private func generateExportData() -> (data: Data, filename: String)? {
        let sources = scopedSources
        let name = "feedmine-export-\(Int(Date().timeIntervalSince1970))"

        // Bookmarks scope exports articles, not sources
        if selectedScope == .bookmarks {
            let articles = bookmarkedArticles
            switch selectedFormat {
            case .csv: return (ExportEngine.csvArticles(items: articles), "\(name)-bookmarks.csv")
            case .text: return (Data(ExportEngine.plainTextArticles(items: articles).utf8), "\(name)-bookmarks.txt")
            case .markdown: return (Data(ExportEngine.markdownArticles(items: articles).utf8), "\(name)-bookmarks.md")
            case .html: return (ExportEngine.htmlArticles(items: articles), "\(name)-bookmarks.html")
            default: return nil
            }
        }

        switch selectedFormat {
        case .opml: return (ExportEngine.opml(sources: sources), "\(name).opml")
        case .json:
            let filters = ContentFilterStore.shared.filters
            let bookmarkIDs = Array(loader.bookmarkedIDs)
            return (ExportEngine.jsonBackup(sources: sources, contentFilters: filters, bookmarkIDs: bookmarkIDs), "\(name).json")
        case .csv: return (ExportEngine.csv(sources: sources, enabledURLs: enabledURLs), "\(name).csv")
        case .text: return (Data(ExportEngine.plainText(sources: sources).utf8), "\(name).txt")
        case .markdown: return (Data(ExportEngine.markdown(sources: sources).utf8), "\(name).md")
        case .html: return (ExportEngine.htmlBlogroll(sources: sources), "\(name).html")
        case .shareLink, .socialCard: return nil
        }
    }

    private func shareExport() {
        if selectedFormat == .shareLink {
            let result = ExportEngine.shareLink(sources: scopedSources)
            presentShareSheet(items: result.activityItems)
            return
        }
        if selectedFormat == .socialCard {
            let stats = ExportEngine.SocialCardStats(
                streak: Settings.sessionStreak,
                articlesRead: loader.readItemIDs.count
            )
            let text = ExportEngine.socialCard(sources: scopedSources, stats: stats)
            presentShareSheet(items: [text])
            return
        }
        guard let (data, filename) = generateExportData() else { return }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? data.write(to: tempURL)
        presentShareSheet(items: [tempURL])
    }

    private func saveToFiles() {
        // Use Share Sheet which includes "Save to Files" as an option.
        // This is the standard iOS pattern — UIDocumentPickerViewController
        // is for opening files, not saving. The Share Sheet's "Save to Files"
        // action uses the proper system file saver.
        shareExport()
    }

    private func copyToClipboard() {
        let text: String
        switch selectedFormat {
        case .socialCard:
            let stats = ExportEngine.SocialCardStats(
                streak: Settings.sessionStreak,
                articlesRead: loader.readItemIDs.count
            )
            text = ExportEngine.socialCard(sources: scopedSources, stats: stats)
        case .shareLink:
            let result = ExportEngine.shareLink(sources: scopedSources)
            if case .text(let s) = result { text = s } else { text = "" }
        case .text:
            text = ExportEngine.plainText(sources: scopedSources)
        case .markdown:
            text = ExportEngine.markdown(sources: scopedSources)
        default:
            if let (data, _) = generateExportData() {
                text = String(data: data, encoding: .utf8) ?? ""
            } else { text = "" }
        }
        UIPasteboard.general.string = text
    }

    private func presentShareSheet(items: [Any]) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = windowScene.windows.first?.rootViewController else { return }
        let av = UIActivityViewController(activityItems: items, applicationActivities: nil)
        root.present(av, animated: true)
    }
}
