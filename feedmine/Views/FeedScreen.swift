import SwiftUI
import SafariServices
import UIKit

struct ArticleRoute: Identifiable {
    let id = UUID()
    let url: URL
}

struct FeedScreen: View {
    @Environment(FeedLoader.self) private var loader
    @State private var selectedArticle: ArticleRoute?
    @State private var appearedItemIDs: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            DebugStatusBar()

            if loader.loadingState == .initial && loader.items.isEmpty {
                SkeletonLoadingView()
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(Array(loader.items.enumerated()), id: \.element.id) { index, item in
                            FeedItemCardView(item: item)
                                .padding(.horizontal, 12)
                                .scrollTransition(.animated(.spring(duration: 0.4))) { content, phase in
                                    content
                                        .opacity(phase == .identity ? 1 : 0.5)
                                        .scaleEffect(phase == .identity ? 1 : 0.95)
                                }
                                .onTapGesture {
                                    let impact = UIImpactFeedbackGenerator(style: .light)
                                    impact.impactOccurred()
                                    if let url = URL(string: item.url) {
                                        selectedArticle = ArticleRoute(url: url)
                                    }
                                }
                                .onAppear {
                                    appearedItemIDs.insert(item.id)
                                    Task {
                                        await loader.loadMoreIfNeeded(currentItem: item)
                                    }
                                }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .task {
            await loader.start()
        }
        .refreshable {
            let impact = UIImpactFeedbackGenerator(style: .medium)
            impact.impactOccurred()
            await loader.refresh()
        }
        .sheet(item: $selectedArticle) { route in
            SafariView(url: route.url)
        }
    }
}

// MARK: - Skeleton Loading View

struct SkeletonLoadingView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(0..<6, id: \.self) { _ in
                    SkeletonCardView()
                        .padding(.horizontal, 12)
                }
            }
            .padding(.vertical, 8)
        }
        .disabled(true)
    }
}

struct SkeletonCardView: View {
    @State private var isAnimating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: 12)
                .fill(shimmerGradient)
                .frame(height: 180)

            RoundedRectangle(cornerRadius: 4)
                .fill(shimmerGradient)
                .frame(width: 120, height: 16)
                .padding(.horizontal, 16)
                .padding(.top, 12)

            RoundedRectangle(cornerRadius: 4)
                .fill(shimmerGradient)
                .frame(height: 20)
                .padding(.horizontal, 16)
                .padding(.top, 8)

            RoundedRectangle(cornerRadius: 4)
                .fill(shimmerGradient)
                .frame(width: 200, height: 20)
                .padding(.horizontal, 16)
                .padding(.top, 4)

            RoundedRectangle(cornerRadius: 4)
                .fill(shimmerGradient)
                .frame(height: 40)
                .padding(.horizontal, 16)
                .padding(.top, 4)

            RoundedRectangle(cornerRadius: 4)
                .fill(shimmerGradient)
                .frame(width: 80, height: 12)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 16)
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }

    private var shimmerGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(.systemGray5),
                Color(.systemGray4),
                Color(.systemGray5)
            ],
            startPoint: isAnimating ? .topTrailing : .topLeading,
            endPoint: isAnimating ? .bottomLeading : .bottomTrailing
        )
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
