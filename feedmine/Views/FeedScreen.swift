import SwiftUI
import SafariServices

struct ArticleRoute: Identifiable {
    let id = UUID()
    let url: URL
}

struct FeedScreen: View {
    @Environment(FeedLoader.self) private var loader
    @State private var selectedArticle: ArticleRoute?

    var body: some View {
        VStack(spacing: 0) {
            DebugStatusBar()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(loader.items) { item in
                        FeedItemCardView(item: item)
                            .onTapGesture {
                                if let url = URL(string: item.url) {
                                    selectedArticle = ArticleRoute(url: url)
                                }
                            }
                            .onAppear {
                                Task {
                                    await loader.loadMoreIfNeeded(currentItem: item)
                                }
                            }
                    }
                }
            }
        }
        .task {
            await loader.start()
        }
        .refreshable {
            await loader.refresh()
        }
        .sheet(item: $selectedArticle) { route in
            SafariView(url: route.url)
        }
    }
}

// MARK: - SFSafariViewController wrapper

private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
