import SwiftUI
import UIKit

/// Banner that appears when the app detects a URL in the clipboard.
/// Non-invasive: shows once per clipboard content, dismissable.
struct ClipboardBanner: View {
    @Environment(FeedLoader.self) private var loader
    @State private var engine = CircadianEngine.shared
    @State private var clipboardURL: String?
    @State private var dismissed = false
    @State private var importing = false
    @State private var lastCheckedContent: String?

    var body: some View {
        if let url = clipboardURL, !dismissed, !importing {
            HStack(spacing: 10) {
                Image(systemName: "doc.on.clipboard")
                    .font(.caption)
                    .foregroundStyle(engine.accent)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Add from clipboard?")
                        .font(.caption)
                        .fontWeight(.medium)
                    Text(displayURL(url))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    importing = true
                    Task {
                        _ = await loader.importFeeds(urls: [url])
                        importing = false
                        dismissed = true
                    }
                } label: {
                    Text("Add")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(engine.accent, in: Capsule())
                }

                Button {
                    withAnimation(.easeOut(duration: 0.2)) { dismissed = true }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// Check clipboard on appear and when app becomes active.
    func checkClipboard() {
        // Only check once per unique clipboard content
        guard let content = UIPasteboard.general.string,
              !content.isEmpty,
              content != lastCheckedContent else { return }
        lastCheckedContent = content

        // Parse and check if it looks like a feed-worthy URL
        let classified = InputParser.parse(content)
        guard let first = classified.first,
              classified.count <= 3 else {  // Don't show banner for bulk pastes
            clipboardURL = nil
            return
        }

        // Don't offer if it's already in our sources
        let normalized = OPMLParser.normalizeURL(first.url.absoluteString)
        let existing = Set(loader.sources.map { OPMLParser.normalizeURL($0.url) })
        guard !existing.contains(normalized) else {
            clipboardURL = nil
            return
        }

        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            clipboardURL = first.url.absoluteString
            dismissed = false
        }
    }

    private func displayURL(_ url: String) -> String {
        guard let parsed = URL(string: url) else { return url }
        let host = parsed.host?.replacingOccurrences(of: "www.", with: "") ?? url
        return host
    }
}

extension ClipboardBanner {
    /// Modifier to trigger clipboard check on appear and foreground.
    func autoCheck() -> some View {
        self
            .onAppear { checkClipboard() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                checkClipboard()
            }
    }
}
