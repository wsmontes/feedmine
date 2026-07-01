import SwiftUI

struct SettingsSheetView: View {
    @Environment(FeedLoader.self) private var loader
    @AppStorage("showDebugBar") private var showDebugBar = true
    @AppStorage("nightMode") private var nightMode = false
    @AppStorage("fontSize") private var fontSize = FontSize.medium.rawValue
    @AppStorage("accentColorName") private var accentColorName = "blue"

    @State private var showClearReadConfirmation = false
    @State private var showClearBookmarksConfirmation = false
    @State private var showResetConfirmation = false

    private var topCategory: String? {
        let readItems = loader.items.filter { loader.isRead($0.id) }
        let grouped = Dictionary(grouping: readItems, by: \.category)
        return grouped.max(by: { $0.value.count < $1.value.count })?.key
    }

    enum FontSize: String, CaseIterable {
        case small, medium, large
    }

    private let accentColors: [(name: String, color: Color)] = [
        ("blue", .blue),
        ("indigo", .indigo),
        ("purple", .purple),
        ("pink", .pink),
        ("orange", .orange),
        ("green", .green),
        ("teal", .teal)
    ]

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Appearance
                Section("Appearance") {
                    HStack {
                        Text("Font Size")
                        Spacer()
                        Picker("", selection: $fontSize) {
                            Text("Small").tag(FontSize.small.rawValue)
                            Text("Medium").tag(FontSize.medium.rawValue)
                            Text("Large").tag(FontSize.large.rawValue)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 200)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Accent Color")
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 7), spacing: 8) {
                            ForEach(accentColors, id: \.name) { item in
                                Circle()
                                    .fill(item.color)
                                    .frame(width: 32, height: 32)
                                    .overlay(
                                        accentColorName == item.name ?
                                        Circle().stroke(Color.primary, lineWidth: 3) : nil
                                    )
                                    .onTapGesture {
                                        accentColorName = item.name
                                    }
                            }
                        }
                    }
                }

                // MARK: - Reading
                Section("Reading") {
                    Toggle("Night Mode", systemImage: "moon.stars.fill", isOn: $nightMode)
                        .tint(.orange)
                }

                // MARK: - Debug
                Section("Debug") {
                    Toggle("Show Debug Status Bar", isOn: $showDebugBar)
                }

                // MARK: - Data
                Section("Data") {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(loader.readItemIDs.count) articles read")
                                .font(.subheadline)
                            Text("\(loader.bookmarkedIDs.count) bookmarks")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    Button(role: .destructive) {
                        showClearReadConfirmation = true
                    } label: {
                        Label("Clear Read History", systemImage: "eye.slash")
                    }
                    .disabled(loader.readItemIDs.isEmpty)
                    .confirmationDialog(
                        "Clear all read history?",
                        isPresented: $showClearReadConfirmation
                    ) {
                        Button("Clear All", role: .destructive) {
                            withAnimation {
                                loader.readItemIDs.removeAll()
                            }
                        }
                    }

                    Button(role: .destructive) {
                        showClearBookmarksConfirmation = true
                    } label: {
                        Label("Clear All Bookmarks", systemImage: "bookmark.slash")
                    }
                    .disabled(loader.bookmarkedIDs.isEmpty)
                    .confirmationDialog(
                        "Remove all bookmarks?",
                        isPresented: $showClearBookmarksConfirmation
                    ) {
                        Button("Clear All", role: .destructive) {
                            withAnimation {
                                loader.bookmarkedIDs.removeAll()
                            }
                        }
                    }
                }

                // MARK: - Data Management
                Section("Data") {
                    Button {
                        let state = loader.buildState()
                        let json = (try? JSONEncoder().encode(state)) ?? Data()
                        let url = FileManager.default.temporaryDirectory.appendingPathComponent("feedmine_data.json")
                        try? json.write(to: url)
                        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                           let root = windowScene.windows.first?.rootViewController {
                            root.present(av, animated: true)
                        }
                    } label: {
                        Label("Export My Data", systemImage: "arrow.up.doc.fill")
                    }

                    Button(role: .destructive) {
                        showResetConfirmation = true
                    } label: {
                        Label("Reset All Data", systemImage: "trash")
                    }
                    .confirmationDialog(
                        "This will delete all bookmarks, read history, and source configuration. This cannot be undone.",
                        isPresented: $showResetConfirmation
                    ) {
                        Button("Reset Everything", role: .destructive) {
                            withAnimation {
                                loader.readItemIDs.removeAll()
                                loader.bookmarkedIDs.removeAll()
                                loader.disabledSourceIDs.removeAll()
                                PersistenceManager.shared.save(loader.buildState())
                            }
                        }
                    }

                    if let date = loader.lastRefreshDate {
                        HStack {
                            Text("Last saved")
                            Spacer()
                            Text(date, style: .relative)
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                }

                // MARK: - Share Stats
                Section {
                    Button {
                        let topCat = topCategory ?? "None"
                        if let image = renderStatsCard(
                            readCount: loader.readItemIDs.count,
                            bookmarkCount: loader.bookmarkedIDs.count,
                            streakCount: 1,
                            topCategory: topCat,
                            sourceCount: loader.sourceCount
                        ) {
                            let av = UIActivityViewController(activityItems: [image], applicationActivities: nil)
                            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                               let root = windowScene.windows.first?.rootViewController {
                                root.present(av, animated: true)
                            }
                        }
                    } label: {
                        Label("Share My Stats", systemImage: "chart.bar.fill")
                    }
                } header: {
                    Text("Share")
                }

                // MARK: - About
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0 (Prototype)")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Sources")
                        Spacer()
                        Text("\(loader.sourceCount) feeds · \(loader.opmlFileCount) files")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Built with")
                        Spacer()
                        Text("SwiftUI · FeedKit · Claude Code")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Link(destination: URL(string: "mailto:wmontes@gmail.com?subject=Feedmine%20Feedback")!) {
                        Label("Send Feedback", systemImage: "envelope.fill")
                    }
                    Link(destination: URL(string: "https://github.com/nmdias/FeedKit")!) {
                        Label("FeedKit on GitHub", systemImage: "link")
                    }
                } header: {
                    Text("Feedback")
                } footer: {
                    Text("Feedmine is an independent RSS reader built for curious minds.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Public helpers for font size

extension SettingsSheetView.FontSize {
    var titleSize: Font {
        switch self {
        case .small: return .subheadline
        case .medium: return .headline
        case .large: return .title3
        }
    }

    var bodySize: Font {
        switch self {
        case .small: return .caption
        case .medium: return .subheadline
        case .large: return .body
        }
    }
}
