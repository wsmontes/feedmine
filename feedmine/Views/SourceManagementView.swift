import SwiftUI

struct SourceManagementView: View {
    @Environment(FeedLoader.self) private var loader
    @State private var isTesting = false
    @State private var testResults: [String: SourceStatus] = [:]
    @State private var showFileImporter = false
    @State private var importError: String?

    enum SourceStatus {
        case ok, failed, testing
        var icon: String {
            switch self { case .ok: "checkmark.circle.fill"; case .failed: "xmark.circle.fill"; case .testing: "circle.dashed" }
        }
        var color: Color {
            switch self { case .ok: .green; case .failed: .red; case .testing: .gray }
        }
        var label: String {
            switch self { case .ok: "OK"; case .failed: "Failed"; case .testing: "Testing..." }
        }
    }

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

                // Category toggles
                Section("Categories") {
                    ForEach(sourcesByCategory, id: \.0) { category, sources in
                        HStack {
                            Label("\(category) (\(sources.count))", systemImage: categoryIcon(category))
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { loader.isCategoryEnabled(category) },
                                set: { _ in loader.toggleCategory(category) }
                            ))
                            .labelsHidden()
                            .tint(.green)
                        }
                    }
                }

                ForEach(sourcesByCategory, id: \.0) { category, sources in
                    Section {
                        ForEach(sources, id: \.url) { source in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text(source.title)
                                            .font(.subheadline)
                                        let health = loader.healthFor(source)
                                        if health.isStale {
                                            Image(systemName: "exclamationmark.triangle.fill")
                                                .font(.caption2)
                                                .foregroundStyle(.orange)
                                        }
                                        if health.consecutiveFailures > 0 {
                                            Text("\(health.consecutiveFailures) fails")
                                                .font(.caption2)
                                                .foregroundStyle(.red)
                                        }
                                    }
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

                Section {
                    Button {
                        Task { await testSources() }
                    } label: {
                        HStack {
                            Label("Test All Sources", systemImage: "checkmark.circle")
                            Spacer()
                            if isTesting {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isTesting)

                    if !testResults.isEmpty {
                        ForEach(testResults.sorted(by: { $0.key < $1.key }), id: \.key) { name, status in
                            HStack {
                                Image(systemName: status.icon)
                                    .font(.caption)
                                    .foregroundStyle(status.color)
                                Text(name)
                                    .font(.caption)
                                Spacer()
                                Text(status.label)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Health Check")
                } footer: {
                    if !testResults.isEmpty {
                        let ok = testResults.values.filter { $0 == .ok }.count
                        Text("\(ok)/\(testResults.count) sources responding")
                    }
                }

                Section {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Import OPML File", systemImage: "doc.badge.plus")
                    }
                    if let error = importError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    ShareLink(item: opmlString) {
                        Label("Export as OPML", systemImage: "square.and.arrow.up")
                    }
                } header: {
                    Text("Import & Export")
                } footer: {
                    Text("Import an OPML file to add new sources, or export your current sources to share or back up.")
                }
            }
            .navigationTitle("Sources")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.xml, .init(filenameExtension: "opml")!]) { result in
            switch result {
            case .success(let url):
                do {
                    let newSources = try OPMLParser.parseImportedFile(url: url)
                    loader.addSources(newSources)
                    importError = nil
                } catch {
                    importError = "Failed to parse: \(error.localizedDescription)"
                }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
    }

    private var opmlString: String {
        OPMLParser.exportOPML(sources: loader.sources)
    }

    private func testSources() async {
        isTesting = true
        testResults = [:]

        for source in loader.sources {
            testResults[source.title] = .testing
        }

        // Bound concurrency with a sliding window. loader.sources can hold
        // thousands of feeds; firing that many simultaneous URLSession requests
        // exhausts the connection pool and produces mass false failures. Keep
        // at most `cap` in flight, refilling each slot as it completes.
        let cap = 10
        await withTaskGroup(of: (String, SourceStatus).self) { group in
            var iterator = loader.sources.makeIterator()
            var started = 0
            while started < cap, let source = iterator.next() {
                group.addTask { await Self.testSource(source) }
                started += 1
            }
            while let (name, status) = await group.next() {
                testResults[name] = status
                if let source = iterator.next() {
                    group.addTask { await Self.testSource(source) }
                }
            }
        }

        isTesting = false
    }

    private static func testSource(_ source: FeedSource) async -> (String, SourceStatus) {
        guard let url = URL(string: source.url) else {
            return (source.title, .failed)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("FeedminePrototype/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                return (source.title, .ok)
            }
            return (source.title, .failed)
        } catch {
            return (source.title, .failed)
        }
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
