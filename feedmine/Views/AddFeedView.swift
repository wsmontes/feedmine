import SwiftUI

struct AddFeedView: View {
    @Environment(FeedLoader.self) private var loader
    @Environment(\.dismiss) private var dismiss
    @State private var engine = CircadianEngine.shared
    @State private var input = ""
    @State private var selectedCollection = "Imported"
    @State private var newCollectionName = ""
    @State private var showNewCollection = false
    @State private var isResolving = false
    @State private var result: ImportResult?
    @State private var resolvedCount = 0
    @State private var totalToResolve = 0
    @FocusState private var inputFocused: Bool

    /// Available collections = existing categories + "Imported" default
    private var collections: [String] {
        var cats = Set(loader.sources.map(\.category))
        cats.insert("Imported")
        return cats.sorted()
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Input
                Section {
                    TextField("Paste URLs, links, or website addresses…",
                              text: $input, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($inputFocused)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()

                    if !input.isEmpty {
                        let parsed = InputParser.parse(input)
                        HStack {
                            Image(systemName: "link")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            Text("\(parsed.count) URL\(parsed.count == 1 ? "" : "s") detected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if parsed.contains(where: { $0.kind == .youtube }) {
                                Label("\(parsed.filter { $0.kind == .youtube }.count)", systemImage: "play.rectangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                            }
                            if parsed.contains(where: { $0.kind == .github }) {
                                Label("\(parsed.filter { $0.kind == .github }.count)", systemImage: "chevron.left.forwardslash.chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.purple)
                            }
                        }
                    }
                } header: {
                    Text("Add Feeds")
                } footer: {
                    Text("Paste any link — websites, YouTube channels, GitHub repos, podcasts, or direct feed URLs. We'll find the feeds automatically.")
                }

                // MARK: - Collection Picker
                Section {
                    Picker("Add to", selection: $selectedCollection) {
                        ForEach(collections, id: \.self) { collection in
                            Text(collection).tag(collection)
                        }
                    }

                    Button {
                        showNewCollection = true
                    } label: {
                        Label("New Collection…", systemImage: "folder.badge.plus")
                            .foregroundStyle(engine.accent)
                    }
                } header: {
                    Text("Collection")
                } footer: {
                    Text("Feeds are grouped by collection. You can move them later.")
                }

                // MARK: - Clipboard
                Section {
                    Button {
                        pasteFromClipboard()
                    } label: {
                        Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                    }
                }

                // MARK: - Result
                // MARK: - Preview (after resolution, before import)
                if !resolvedFeeds.isEmpty && result == nil {
                    Section("Preview (\(resolvedFeeds.count) feeds)") {
                        ForEach(resolvedFeeds.prefix(20), id: \.feedURL) { feed in
                            HStack(spacing: 8) {
                                Image(systemName: mediaIcon(feed.mediaKind))
                                    .font(.caption)
                                    .foregroundStyle(mediaColor(feed.mediaKind))
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(feed.title ?? ImportPipeline.titleFromURL(feed.feedURL))
                                        .font(.caption)
                                        .lineLimit(1)
                                    Text(feed.feedURL)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        if resolvedFeeds.count > 20 {
                            Text("+\(resolvedFeeds.count - 20) more…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let result {
                    Section("Result") {
                        HStack {
                            Label("\(result.importedCount) imported", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Spacer()
                        }
                        if result.duplicateCount > 0 {
                            Label("\(result.duplicateCount) duplicates skipped", systemImage: "arrow.triangle.2.circlepath")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        if result.unreachableCount > 0 {
                            Label("\(result.unreachableCount) unreachable", systemImage: "wifi.slash")
                                .foregroundStyle(.orange)
                                .font(.caption)
                        }
                        if result.invalidCount > 0 {
                            Label("\(result.invalidCount) invalid", systemImage: "xmark.circle")
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("Add Feeds")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await importFeeds() }
                    } label: {
                        if isResolving {
                            ProgressView()
                        } else {
                            Text("Add")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(input.isEmpty || isResolving)
                }
            }
            .alert("New Collection", isPresented: $showNewCollection) {
                TextField("Collection name", text: $newCollectionName)
                Button("Create") {
                    let name = newCollectionName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    selectedCollection = name
                    newCollectionName = ""
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(
                "Import \(resolvedFeeds.count) feeds?",
                isPresented: $showConfirmation,
                titleVisibility: .visible
            ) {
                Button("Import All (\(resolvedFeeds.count))") {
                    Task { await confirmImport() }
                }
                Button("Cancel", role: .cancel) {
                    resolvedFeeds = []
                    pendingOPMLs = []
                }
            } message: {
                let types = feedTypeSummary()
                Text("Found \(resolvedFeeds.count) feeds\(types.isEmpty ? "" : ": \(types)"). Add all to \"\(selectedCollection)\"?")
            }
            .onAppear { inputFocused = true }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - State for preview/confirm step
    @State private var resolvedFeeds: [ResolvedFeed] = []
    @State private var showConfirmation = false
    @State private var pendingOPMLs: [ClassifiedURL] = []

    // MARK: - Actions

    private func pasteFromClipboard() {
        if let string = UIPasteboard.general.string, !string.isEmpty {
            if input.isEmpty {
                input = string
            } else {
                input += "\n" + string
            }
        }
    }

    private func importFeeds() async {
        isResolving = true
        result = nil
        resolvedFeeds = []

        // 1. Parse input
        let classified = InputParser.parse(input)
        guard !classified.isEmpty else {
            isResolving = false
            return
        }

        // 2. Separate OPMLs from regular URLs
        pendingOPMLs = classified.filter { $0.kind == .opml }
        let feedURLs = classified.filter { $0.kind != .opml }

        // 3. Resolve regular URLs to feed URLs
        let resolver = URLResolver()
        let resolved = await resolver.resolveAll(feedURLs)

        // 4. Collect resolved feeds (deduplicate by channel for YouTube)
        var feeds: [ResolvedFeed] = []
        var seenChannels = Set<String>()
        for r in resolved {
            for feed in r.feeds {
                if feed.mediaKind == .video {
                    let normalized = feed.feedURL.lowercased()
                    guard seenChannels.insert(normalized).inserted else { continue }
                }
                feeds.append(feed)
            }
        }
        resolvedFeeds = feeds
        isResolving = false

        // 5. If >5 feeds, show confirmation. Otherwise import directly.
        let totalCount = feeds.count + pendingOPMLs.count
        if totalCount > 5 {
            showConfirmation = true
        } else {
            await confirmImport()
        }
    }

    /// Perform the actual import after preview/confirmation.
    private func confirmImport() async {
        isResolving = true
        let feedURLs = resolvedFeeds.map(\.feedURL)

        // Import resolved feeds
        let importResult = await loader.importFeeds(
            urls: feedURLs,
            category: selectedCollection,
            skipValidation: true
        )

        // Import OPMLs
        var opmlImported = 0
        for opml in pendingOPMLs {
            if let opmlResult = await loader.importOPML(url: opml.url, validate: false) {
                opmlImported += opmlResult.importedCount
            }
        }

        // Combine results
        if opmlImported > 0 {
            let extraItems = (0..<opmlImported).map { _ in
                ImportItemResult(url: "opml", title: nil, status: .imported)
            }
            result = ImportResult(items: importResult.items + extraItems)
        } else {
            result = importResult
        }

        isResolving = false
        input = ""
        resolvedFeeds = []
        pendingOPMLs = []

        // Post toast notification for FeedScreen
        if let r = result, r.importedCount > 0 {
            NotificationCenter.default.post(
                name: .feedImportCompleted,
                object: nil,
                userInfo: ["message": "\(r.importedCount) feed\(r.importedCount == 1 ? "" : "s") added to \(selectedCollection)"]
            )
        }
    }

    // MARK: - Helpers

    private func feedTypeSummary() -> String {
        let video = resolvedFeeds.filter { $0.mediaKind == .video }.count
        let audio = resolvedFeeds.filter { $0.mediaKind == .audio }.count
        let text = resolvedFeeds.filter { $0.mediaKind == .text }.count
        var parts: [String] = []
        if text > 0 { parts.append("\(text) articles") }
        if video > 0 { parts.append("\(video) YouTube") }
        if audio > 0 { parts.append("\(audio) podcasts") }
        return parts.joined(separator: ", ")
    }

    private func mediaIcon(_ kind: MediaKind) -> String {
        switch kind {
        case .text: return "doc.text"
        case .video: return "play.rectangle.fill"
        case .audio: return "headphones"
        }
    }

    private func mediaColor(_ kind: MediaKind) -> Color {
        switch kind {
        case .text: return .blue
        case .video: return .red
        case .audio: return .purple
        }
    }
}

// MARK: - Notification

extension Notification.Name {
    static let feedImportCompleted = Notification.Name("feedImportCompleted")
}

