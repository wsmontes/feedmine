import SwiftUI
import WebKit

struct ArticleReaderView: View {
    let item: FeedItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ArticleWebView(url: URL(string: item.url))
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(item.sourceTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        if let url = URL(string: item.url) {
                            Link(destination: url) {
                                Image(systemName: "safari")
                                    .font(.title3)
                            }
                        }
                    }
                }
        }
    }
}

// MARK: - WKWebView wrapper

struct ArticleWebView: UIViewRepresentable {
    let url: URL?

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic

        if let url {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
