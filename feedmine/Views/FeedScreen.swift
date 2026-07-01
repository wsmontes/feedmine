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
    @State private var previewItem: FeedItem?
    @State private var appearedItemIDs: Set<String> = []
    @State private var showScrollButton = false
    @State private var showSettings = false
    @State private var showSources = false
    @State private var showFilters = false
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastIcon = "checkmark"
    @State private var headerCompact = false
    @AppStorage("showDebugBar") private var showDebugBar = true
    @AppStorage("nightMode") private var nightMode = false
    @AppStorage("accentColorName") private var accentColorName = "blue"

    private var accentColor: Color {
        switch accentColorName {
        case "indigo": return .indigo
        case "purple": return .purple
        case "pink": return .pink
        case "orange": return .orange
        case "green": return .green
        case "teal": return .teal
        default: return .blue
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Full-bleed feed content
            if loader.loadingState == .initial && loader.items.isEmpty {
                SkeletonLoadingView()
            } else if loader.items.isEmpty && loader.loadingState != .initial {
                FeedEmptyStateView()
            } else {
                feedScrollView
            }

            // Floating compact header
            VStack(spacing: 0) {
                compactHeader
                Spacer()
            }

            // Toast + Onboarding overlays
            toastOverlay
            OnboardingTipsView()
        }
        .task { await loader.start(); updateBadge() }
        .onChange(of: loader.readItemIDs.count) { _, _ in updateBadge() }
        .sheet(item: $selectedArticle) { route in SafariView(url: route.url) }
        .sheet(item: $previewItem) { item in ArticlePreviewSheet(item: item) }
        .sheet(isPresented: $showSettings) { SettingsSheetView() }
        .sheet(isPresented: $showSources) { SourceManagementView() }
        .sheet(isPresented: $showFilters) { FilterSheetView() }
        .tint(accentColor)
        .overlay { if nightMode { nightOverlay } }
    }

    // MARK: - Compact Header

    private var compactHeader: some View {
        VStack(spacing: 0) {
            // Status bar area padding
            Color.clear.frame(height: 0)

            // Error banners
            CompactErrorBanner()

            // Main control bar: debug + greeting + buttons
            HStack(spacing: 8) {
                if showDebugBar {
                    CompactDebugInfo()
                } else {
                    CompactGreeting()
                }

                Spacer()

                // Filter + action buttons
                HStack(spacing: 4) {
                    filterButton
                    sourcesButton
                    settingsButton
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
        }
    }

    private var filterButton: some View {
        Button {
            showFilters = true
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "line.3.horizontal.decrease")
                    .frame(width: 36, height: 36)
                    .background(Color(.systemGray6))
                    .clipShape(Circle())
                if loader.selectedCategory != nil || loader.selectedMood != .all {
                    Circle().fill(.blue).frame(width: 8, height: 8)
                        .offset(x: 2, y: -2)
                }
            }
        }
    }

    private var sourcesButton: some View {
        Button { showSources = true } label: {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .frame(width: 36, height: 36)
                .background(Color(.systemGray6))
                .clipShape(Circle())
        }
    }

    private var settingsButton: some View {
        Button { showSettings = true } label: {
            Image(systemName: "gearshape")
                .frame(width: 36, height: 36)
                .background(Color(.systemGray6))
                .clipShape(Circle())
        }
    }

    // MARK: - Feed Scroll

    private var feedScrollView: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        // Daily Briefing + Carousel (only when unfiltered)
                        if loader.selectedCategory == nil && loader.selectedMood == .all && loader.searchQuery.isEmpty {
                            DailyBriefingCard()
                                .padding(.horizontal, 12)
                                .padding(.top, 4)
                            TopStoriesCarousel()
                                .padding(.top, 8)
                        }

                        // Date sections with cards
                        ForEach(loader.dateSections) { section in
                            Section {
                                ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                                    FeedItemView(item: item, index: index,
                                        onOpen: { previewItem = item },
                                        onCopy: { toastMessage = "Link copied"; toastIcon = "doc.on.doc"; withAnimation { showToast = true } }
                                    )
                                    .padding(.horizontal, 8)
                                    .contentShape(Rectangle())
                                    .onAppear {
                                        appearedItemIDs.insert(item.id)
                                        showScrollButton = index > 20
                                        Task { await loader.loadMoreIfNeeded(currentItem: item) }
                                    }
                                }
                            } header: {
                                sectionHeader(section.title)
                            }
                        }
                    }
                    .padding(.top, 48)
                    .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 20) }
                }
                .overlay(alignment: .top) { Color.clear.frame(height: 0).id("top") }

                // Floating action buttons
                if showScrollButton { floatingButtons(proxy: proxy) }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    // MARK: - Floating Buttons

    private func floatingButtons(proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 12) {
            Button {
                let impact = UIImpactFeedbackGenerator(style: .soft)
                impact.impactOccurred()
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo("top", anchor: .top)
                }
                showScrollButton = false
            } label: {
                Image(systemName: "arrow.up")
                    .font(.title3).fontWeight(.semibold).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.blue.opacity(0.9)).shadow(color: .black.opacity(0.2), radius: 8, y: 4))
            }
            .accessibilityLabel("Scroll to top")
        }
        .padding(.trailing, 16)
        .padding(.bottom, 32)
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: - Overlays

    private var toastOverlay: some View {
        VStack {
            Spacer()
            if showToast {
                HStack(spacing: 8) {
                    Image(systemName: toastIcon).font(.subheadline)
                    Text(toastMessage).font(.subheadline).fontWeight(.medium)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(.black.opacity(0.8), in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
                .padding(.bottom, 100)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation(.easeOut(duration: 0.3)) { showToast = false }
                }}
            }
        }
    }

    private var nightOverlay: some View {
        Color.black.opacity(0.35).ignoresSafeArea().allowsHitTesting(false)
    }

    // MARK: - Helpers

    private func updateBadge() {
        let unread = loader.items.count - loader.readItemIDs.count
        Task { @MainActor in UIApplication.shared.applicationIconBadgeNumber = max(0, unread) }
    }
}

// MARK: - Compact Subviews

struct CompactDebugInfo: View {
    @Environment(FeedLoader.self) private var loader
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(loader.loadingState == .idle ? Color.green : Color.blue).frame(width: 6, height: 6)
            Text("\(loader.filteredItems.count)")
                .font(.caption).fontWeight(.semibold).contentTransition(.numericText())
            if loader.fetchErrorCount > 0 {
                Text("·\(loader.fetchErrorCount) err").font(.caption2).foregroundStyle(.orange)
            }
        }
    }
}

struct CompactGreeting: View {
    @Environment(FeedLoader.self) private var loader
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "antenna.radiowaves.left.and.right").font(.caption).foregroundStyle(.blue)
            Text("Feedmine").font(.caption).fontWeight(.bold)
            Text("·\(loader.sourceCount) sources").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct CompactErrorBanner: View {
    @Environment(FeedLoader.self) private var loader
    var body: some View {
        if loader.fetchErrorCount > 0 && !loader.networkMonitor.isConnected {
            HStack {
                Image(systemName: "wifi.slash").font(.caption2)
                Text("Offline").font(.caption2)
            }
            .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 4)
            .background(Color.red.opacity(0.85))
        }
    }
}

// MARK: - Safari View

private struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = true
        return SFSafariViewController(url: url, configuration: config)
    }
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

// MARK: - Skeleton Loading (inline version)
struct SkeletonLoadingView: View {
    @State private var messageIndex = 0
    private let messages = ["Brewing coffee...", "Scanning the internet...", "Reading RSS feeds...", "Finding the best stories...", "Loading your feed...", "Checking sources...", "Almost there...", "Curating articles...", "Tuning antennas...", "Gathering news..."]
    var body: some View {
        VStack(spacing: 0) {
            Text(messages[messageIndex]).font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 16).transition(.opacity.combined(with: .move(edge: .top))).id(messageIndex)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(0..<6, id: \.self) { _ in SkeletonCardView().padding(.horizontal, 12) }
                }.padding(.vertical, 8)
            }
        }.disabled(true).accessibilityLabel("Loading articles")
        .onAppear { Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { _ in withAnimation(.easeInOut(duration: 0.4)) { messageIndex = (messageIndex + 1) % messages.count } } }
    }
}
struct SkeletonCardView: View {
    @State private var isAnimating = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: 12).fill(shimmerGradient).frame(height: 180)
            RoundedRectangle(cornerRadius: 4).fill(shimmerGradient).frame(width: 120, height: 16).padding(.horizontal, 16).padding(.top, 12)
            RoundedRectangle(cornerRadius: 4).fill(shimmerGradient).frame(height: 20).padding(.horizontal, 16).padding(.top, 8)
            RoundedRectangle(cornerRadius: 4).fill(shimmerGradient).frame(width: 200, height: 20).padding(.horizontal, 16).padding(.top, 4)
            RoundedRectangle(cornerRadius: 4).fill(shimmerGradient).frame(height: 40).padding(.horizontal, 16).padding(.top, 4)
            RoundedRectangle(cornerRadius: 4).fill(shimmerGradient).frame(width: 80, height: 12).padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 16)
        }
        .background(Color(.systemBackground)).clipShape(RoundedRectangle(cornerRadius: 16)).shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        .onAppear { withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { isAnimating = true } }
        .accessibilityHidden(true)
    }
    private var shimmerGradient: LinearGradient { LinearGradient(colors: [Color(.systemGray5), Color(.systemGray4), Color(.systemGray5)], startPoint: isAnimating ? .topTrailing : .topLeading, endPoint: isAnimating ? .bottomLeading : .bottomTrailing) }
}

// MARK: - Empty Filter
struct EmptyFilterView: View {
    let category: String
    var body: some View {
        ContentUnavailableView("No \(category) articles", systemImage: "rectangle.stack.fill", description: Text("This category has articles in the feed, but they may have been trimmed from the visible buffer. Try scrolling through All first.")).padding(.top, 80)
    }
}
