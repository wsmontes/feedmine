import SwiftUI
import UIKit

/// Non-reactive impression counter — mutated on every card `.onAppear`
/// without triggering SwiftUI body re-evaluation.
private final class ImpressionTracker {
    var seen = Set<String>()
    var count: Int { seen.count }
    func mark(_ id: String) { seen.insert(id) }
}

struct FeedScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(FeedLoader.self) private var loader
    @State private var articleItem: FeedItem?
    private let impressions = ImpressionTracker()
    @State private var showScrollButton = false
    @State private var lastScrollIndex: Int = 0
    @State private var searchText = ""
    @State private var isSearching = false
    @FocusState private var searchFocused: Bool
    @State private var showSettings = false
    @State private var showSources = false
    @State private var showFilters = false
    @State private var showBookmarks = false
    @State private var showAddFeed = false
    @State private var showCollections = false
    @State private var showExport = false
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastIcon = "checkmark"
    @State private var headerCompact = false
    @State private var engine = CircadianEngine.shared
    @AppStorage("showDebugBar") private var showDebugBar = false
    @AppStorage("nightMode") private var nightMode = false
    @AppStorage("lastScrollItemID") private var lastScrollItemID = ""
    @State private var scrollTargetID: String? = nil
    /// True once the user has actually scrolled the feed. Gates the one-shot
    /// cold-start position restore so it can never yank a user who already
    /// started reading. (Feed is sacred: it doesn't move on its own.)
    @State private var userHasScrolled = false
    @State private var didRestoreScroll = false
    @State private var player = AudioPlayerManager.shared

    private var emptyMode: FeedEmptyMode {
        if loader.sources.isEmpty || (!loader.isGlobalFeedsEnabled && !loader.isAnyCountryEnabled) {
            return .noSourcesEnabled
        }
        if loader.hasActiveFilters && loader.items.isEmpty && loader.loadingState == .refreshing {
            return .fetching(
                topic: loader.selectedNodeNames.joined(separator: ", "),
                fetched: 0,
                total: loader.selectedNodeIDs.reduce(0) { $0 + (TaxonomyStore.shared.node(id: $1)?.feedCount ?? 0) }
            )
        }
        if loader.hasActiveFilters && loader.items.isEmpty && loader.loadingState == .idle {
            return .noResults(topic: loader.selectedNodeNames.joined(separator: ", "))
        }
        return .generic
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Full-bleed feed content with circadian page tint
            engine.pageBackground.ignoresSafeArea()

            if loader.loadingState == .initial && loader.items.isEmpty {
                SkeletonLoadingView()
            } else if loader.items.isEmpty && loader.loadingState != .initial {
                FeedEmptyStateView(mode: emptyMode)
            } else {
                feedScrollView
            }

            // Floating compact header
            VStack(spacing: 0) {
                compactHeader
                if isSearching { searchBar.transition(.move(edge: .top).combined(with: .opacity)) }
                Spacer()
            }

            // Tap-to-dismiss search
            if isSearching && searchFocused {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { searchFocused = false }
            }

            // Shake detector
            ShakeDetector { loader.shakeToRefresh() }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)

            // Mini player bar — full-width bottom bar, always on top
            VStack {
                Spacer()
                MiniPlayerBar()
                    .background(.ultraThinMaterial)
            }

            // Clipboard banner (below header)
            VStack {
                Spacer().frame(height: 90)
                ClipboardBanner().autoCheck()
                Spacer()
            }

            // Toast + Onboarding overlays
            toastOverlay
            OnboardingTipsView()
        }
        .task {
            await loader.start()
            await loader.refreshBookmarkState()
            updateBadge()
            engine.refresh()
            // Restore scroll position once on cold start — but never if the
            // user already started scrolling (a delayed restore would yank them).
            if !didRestoreScroll && !userHasScrolled
                && !lastScrollItemID.isEmpty && !loader.items.isEmpty {
                scrollTargetID = lastScrollItemID
            }
            didRestoreScroll = true
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                SessionTracker.shared.onForeground()
                engine.refresh()
                // Do NOT restore scroll on foreground: SwiftUI already preserves
                // the position across background, so re-scrolling here only makes
                // the feed jump under the user. (Feed is sacred.)
            }
            if phase == .background {
                SessionTracker.shared.onBackground()
                loader.flushWhatsNewQueue()
                AudioPlayerManager.shared.savePosition()
                // Save scroll position for restoration on next foreground
                let allItems = loader.dateSections.flatMap(\.items)
                let idx = min(lastScrollIndex, allItems.count - 1)
                if idx >= 0, idx < allItems.count {
                    lastScrollItemID = allItems[idx].id
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task {
                engine.refresh()
                await loader.refreshIfStale()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            loader.emergencyTrim()
        }
        .onChange(of: searchText) { _, query in
            loader.searchQuery = query
            loader.searchQueryChanged()
        }
        .onChange(of: loader.searchQuery) { _, query in
            // Reverse sync: context menu or external change → update UI (#44)
            if searchText != query { searchText = query }
        }
        .onChange(of: searchFocused) { _, focused in
            if !focused && searchText.isEmpty { isSearching = false }
        }
        .onChange(of: loader.readItemIDs.count) { _, _ in updateBadge() }
        .onChange(of: loader.lastToggleMessage) { _, msg in
            if let msg {
                toastMessage = msg; toastIcon = "antenna.radiowaves.left.and.right"
                withAnimation { showToast = true }
                loader.clearToggleMessage()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .feedImportCompleted)) { notification in
            if let msg = notification.userInfo?["message"] as? String {
                toastMessage = msg; toastIcon = "plus.circle.fill"
                withAnimation { showToast = true }
            }
        }
        .onChange(of: player.lastPlaybackError) { _, error in
            if let error {
                toastMessage = error; toastIcon = "exclamationmark.triangle"
                withAnimation { showToast = true }
                player.clearPlaybackError()
            }
        }
        .onChange(of: loader.networkMonitor.isConnected) { _, connected in
            if connected && loader.fetchErrorCount > 0 {
                // Only fetch new content into reservoir — don't clear visible items
                Task { await loader.refreshIfStale() }
            }
        }
        .sheet(item: $articleItem) { item in ArticleReaderView(item: item) }
        .sheet(isPresented: $showSettings) { SettingsSheetView() }
        .sheet(isPresented: $showSources) { SourceManagementView() }
        .sheet(isPresented: $showFilters) { FilterSheetView() }
        .sheet(isPresented: $showBookmarks) { BookmarkBoxesView() }
        .sheet(isPresented: $showAddFeed) { AddFeedView() }
        .sheet(isPresented: $showCollections) { CollectionManagementView() }
        .sheet(isPresented: $showExport) { ExportView() }
        .tint(engine.accent)
        .animation(.easeInOut(duration: 2.0), value: engine.period)
        .overlay { if nightMode { nightOverlay } }
    }

    // MARK: - Compact Header

    private var compactHeader: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 0)
            CompactErrorBanner()
            HStack(spacing: 8) {
                if showDebugBar {
                    CompactDebugInfo()
                } else {
                    CompactGreeting()
                }

                Spacer()

                // Active filter chips — inline, tappable to dismiss
                filterChips

                HStack(spacing: 4) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) { isSearching.toggle() }
                        if isSearching { searchText = "" }
                    } label: {
                        Image(systemName: isSearching ? "magnifyingglass.circle.fill" : "magnifyingglass")
                            .headerButtonStyle(accent: engine.accent)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    Button {
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        showBookmarks = true
                    } label: {
                        Image(systemName: loader.selectedBookmarkListID != nil ? "bookmark.fill" : "bookmark")
                            .headerButtonStyle(accent: engine.accent)
                    }
                    .overlay(alignment: .topTrailing) {
                        if loader.selectedBookmarkListID != nil {
                            Circle().fill(engine.accent).frame(width: 6, height: 6)
                        }
                    }
                    filterButton
                    Menu {
                        Button { showAddFeed = true } label: {
                            Label("Add Feed", systemImage: "plus.circle")
                        }
                        Button { showExport = true } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                        Button { showCollections = true } label: {
                            Label("Collections", systemImage: "folder.fill")
                        }
                        Button { showSources = true } label: {
                            Label("Sources", systemImage: "antenna.radiowaves.left.and.right")
                        }
                        Button { showSettings = true } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .headerButtonStyle(accent: engine.accent)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .overlay(alignment: .bottom) {
                Divider().opacity(0.3)
            }

            // Taxonomy chip bar — only visible when filters are active
            if loader.hasActiveFilters {
                TaxonomyChipBar {
                    showFilters = true
                }
            }

            // Active filter banner — shows what's being filtered and offers clear
            if loader.hasActiveFilters {
                filterActiveBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private var filterActiveBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.caption2)
            Text(filterBannerLabel)
                .font(.caption2)
                .fontWeight(.medium)
            Spacer()
            Button("Clear") {
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                withAnimation(.easeInOut(duration: 0.25)) {
                    loader.clearAllFilters()
                }
            }
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(engine.accent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(engine.accent.opacity(0.08))
    }

    private var filterBannerLabel: String {
        var parts: [String] = []
        if loader.hasTaxonomySelection {
            parts.append(contentsOf: loader.selectedNodeNames)
        }
        if loader.hasLanguageSelection {
            parts.append(contentsOf: loader.selectedLanguages.map { lang in
                Locale.current.localizedString(forLanguageCode: lang) ?? lang
            })
        }
        if loader.selectedMood != .all { parts.append(loader.selectedMood.rawValue) }
        if loader.selectedContentType != .all { parts.append(loader.selectedContentType.rawValue) }
        return parts.joined(separator: " · ")
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $searchText)
                .focused($searchFocused)
                .textFieldStyle(.plain)
                .onSubmit { searchFocused = false }
            if !searchText.isEmpty {
                Button {
                    searchText = ""; isSearching = false; searchFocused = false
                    loader.searchQuery = ""; loader.searchQueryChanged()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
            if searchFocused {
                Button("Cancel") {
                    searchText = ""; isSearching = false; searchFocused = false
                    loader.searchQuery = ""; loader.searchQueryChanged()
                }
                .font(.caption).foregroundStyle(engine.accent)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 8)
        .onAppear { searchFocused = true }
    }

    private var filterChips: some View {
        let mood = loader.selectedMood
        let type = loader.selectedContentType
        let hasFilters = loader.hasActiveFilters

        guard hasFilters else { return AnyView(EmptyView()) }

        return AnyView(
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(loader.selectedNodeNames, id: \.self) { name in
                        chip(name, action: {})
                    }
                    ForEach(Array(loader.selectedLanguages).sorted(), id: \.self) { lang in
                        chip(Locale.current.localizedString(forLanguageCode: lang) ?? lang,
                             action: { loader.toggleLanguage(lang) })
                    }
                    if mood != .all {
                        chip(mood.rawValue, action: { loader.selectMood(mood) })
                    }
                    if type != .all {
                        chip(type.rawValue, action: { loader.selectContentType(type) })
                    }
                }
            }
        )
    }

    private func chip(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Text(label).font(.caption2).fontWeight(.medium)
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(CircadianEngine.shared.accent.opacity(0.12)))
            .foregroundStyle(CircadianEngine.shared.accent)
        }
    }

    private var filterButton: some View {
        let activeCount = (loader.hasTaxonomySelection ? loader.selectedNodeIDs.count : 0) + (loader.selectedMood != .all ? 1 : 0) + (loader.selectedContentType != .all ? 1 : 0) + (loader.hasLanguageSelection ? loader.selectedLanguages.count : 0) + (!loader.searchQuery.isEmpty ? 1 : 0)
        return Button {
            showFilters = true
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "line.3.horizontal.decrease")
                    .headerButtonStyle(accent: engine.accent)
                if activeCount > 0 {
                    Text("\(activeCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(engine.accent))
                        .offset(x: 2, y: -2)
                }
            }
        }
    }

    // MARK: - Feed Scroll

    private var feedScrollView: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(spacing: engine.cardGap) {
                        Color.clear.frame(height: 0).id("top")
                        // MomentCard — contextual greeting
                        MomentCard()
                            .padding(.top, 12)
                        // Bookmark box header — replaces What's New in bookmark mode
                        if loader.selectedBookmarkListID != nil {
                            HStack {
                                Image(systemName: "bookmark.fill")
                                    .foregroundStyle(engine.accent)
                                Text(loader.selectedBookmarkListName ?? "Bookmarks")
                                    .font(.headline)
                                    .fontWeight(.semibold)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                        }
                        // What's New carousel — hidden in bookmark mode
                        if loader.selectedBookmarkListID == nil
                            && !loader.hasActiveFilters
                            && loader.searchQuery.isEmpty {
                            WhatsNewCarousel(onOpen: { articleItem = $0 })
                                .padding(.top, 8)
                        }

                        ForEach(loader.dateSections) { section in
                            Section {
                                ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                                    let isFirst = !impressions.seen.contains(item.id)
                                    FeedItemView(item: item, index: index,
                                        isFirstAppearance: isFirst,
                                        onOpen: { articleItem = item },
                                        onCopy: { toastMessage = "Link copied"; toastIcon = "doc.on.doc"; withAnimation { showToast = true } },
                                        onPlaybackFailed: {
                                            toastMessage = "Audio unavailable"
                                            toastIcon = "exclamationmark.triangle"
                                            withAnimation { showToast = true }
                                        }
                                    )
                                    .id(item.id)
                                    .padding(.horizontal, 6)
                                    .contentShape(Rectangle())
                                    .onAppear {
                                        impressions.mark(item.id)
                                        loader.noteVisibleIndex(index)
                                        if impressions.count % 8 == 0 {
                                            let idx = loader.currentVisibleIndex
                                            let goingUp = idx < lastScrollIndex
                                            lastScrollIndex = idx
                                            let shouldShow = goingUp && idx > 12
                                            if shouldShow != showScrollButton {
                                                showScrollButton = shouldShow
                                            }
                                        }
                                        Task { await loader.loadMoreIfNeeded(currentItem: item) }
                                    }
                                }
                            } header: {
                                sectionHeader(section.title)
                            }
                        }

                        // Filters/search matched nothing, but the feed itself
                        // has content — show guidance instead of a blank screen.
                        if loader.dateSections.isEmpty && !loader.items.isEmpty {
                            EmptyFilterView(category: loader.selectedNodeNames.joined(separator: ", "))
                        }
                    }
                    .padding(.top, 48)
                    .safeAreaInset(edge: .bottom) {
                        Color.clear.frame(height: 60).background(.ultraThinMaterial)
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .onScrollGeometryChange(for: CGFloat.self, of: { geo in
                    geo.contentOffset.y
                }, action: { _, newOffset in
                    if newOffset > 40 { userHasScrolled = true }
                    if newOffset < -110 && !isSearching {
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        withAnimation(.easeInOut(duration: 0.25)) { isSearching = true }
                    }
                })
                if showScrollButton { floatingButtons(proxy: proxy) }
            }
            .onChange(of: scrollTargetID) { _, targetID in
                guard let targetID else { return }
                // Short delay so LazyVStack has time to lay out the target
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(targetID, anchor: .top)
                    }
                }
                scrollTargetID = nil
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(LocalizedStringKey(title))
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    // MARK: - Floating Buttons

    private func floatingButtons(proxy: ScrollViewProxy) -> some View {
        HStack {
            Spacer()
            Button {
                let impact = UIImpactFeedbackGenerator(style: .soft)
                impact.impactOccurred()
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo("top", anchor: .top)
                }
                showScrollButton = false
            } label: {
                Image(systemName: "arrow.up")
                    .frame(width: 36, height: 36)
                    .background(engine.accent.opacity(0.12))
                    .clipShape(Circle())
            }
            .accessibilityLabel("Scroll to top")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: showScrollButton)
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
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { showToast = false }
                }}
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: showToast)
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
    private var unread: Int { loader.items.count - loader.readItemIDs.count }
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(loader.loadingState == .idle ? Color.green : Color.blue).frame(width: 6, height: 6)
            Text("\(loader.filteredItems.count)")
                .font(.caption).fontWeight(.semibold).contentTransition(.numericText())
            if unread > 0 {
                Text("\(unread) new")
                    .font(.caption2).fontWeight(.bold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.blue))
            }
            if loader.podcastItemCount > 0 {
                Text("🎧\(loader.podcastItemCount)").font(.caption2).foregroundStyle(.purple)
            }
            if loader.fetchErrorCount > 0 {
                Text("·\(loader.fetchErrorCount) err").font(.caption2).foregroundStyle(.orange)
            }
        }
    }
}

struct ScrollOffKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct CompactGreeting: View {
    @Environment(FeedLoader.self) private var loader
    @State private var engine = CircadianEngine.shared
    @AppStorage("showDebugBar") private var showDebugBar = false

    var body: some View {
        HStack(spacing: 4) {
            Image("Symbol-Gradient")
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
            Text("Feedmine").font(.caption).fontWeight(.bold)
            Text("·\(loader.sourceCount) sources").font(.caption2).foregroundStyle(.secondary)
        }
        // Secret gesture: triple-tap the greeting to toggle debug bar.
        // Not exposed in Settings — intentional, for development use only.
        .onTapGesture(count: 3) {
            let impact = UIImpactFeedbackGenerator(style: .medium)
            impact.impactOccurred()
            withAnimation(.easeInOut(duration: 0.3)) {
                showDebugBar.toggle()
            }
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

// MARK: - Skeleton Loading (with DreamyGradient from WhatsNew)

struct SkeletonLoadingView: View {
    @State private var messageIndex = 0
    @State private var engine = CircadianEngine.shared
    private let messages = ["Brewing coffee...", "Scanning the internet...", "Finding articles...", "Finding the best stories...", "Loading your feed...", "Checking sources...", "Almost there...", "Curating articles...", "Tuning antennas...", "Gathering news..."]

    var body: some View {
        VStack(spacing: 0) {
            Text(messages[messageIndex])
                .font(engine.font(for: .momentCard))
                .foregroundStyle(engine.accent)
                .padding(.vertical, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .id(messageIndex)
            ScrollView {
                VStack(spacing: engine.cardGap) {
                    ForEach(0..<3, id: \.self) { _ in
                        SkeletonCardView().padding(.horizontal, 12)
                    }
                }.padding(.vertical, 8)
            }
        }
        .disabled(true)
        .accessibilityLabel("Loading articles")
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.5))
                withAnimation(.easeInOut(duration: 0.4)) { messageIndex = (messageIndex + 1) % messages.count }
            }
        }
    }
}

struct SkeletonCardView: View {
    @State private var engine = CircadianEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Dreamy gradient placeholder — same system as WhatsNewCarousel
            SkeletonDreamyGradient()
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            RoundedRectangle(cornerRadius: 4).fill(shimmerGradient).frame(width: 120, height: 16).padding(.horizontal, 16).padding(.top, 12)
            RoundedRectangle(cornerRadius: 4).fill(shimmerGradient).frame(height: 20).padding(.horizontal, 16).padding(.top, 8)
            RoundedRectangle(cornerRadius: 4).fill(shimmerGradient).frame(width: 200, height: 20).padding(.horizontal, 16).padding(.top, 4)
            RoundedRectangle(cornerRadius: 4).fill(shimmerGradient).frame(height: 40).padding(.horizontal, 16).padding(.top, 4)
            RoundedRectangle(cornerRadius: 4).fill(shimmerGradient).frame(width: 80, height: 12).padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 16)
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: engine.cardRadius))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
        .accessibilityHidden(true)
    }

    private var shimmerGradient: LinearGradient {
        LinearGradient(
            colors: [engine.accent.opacity(0.15), engine.accent.opacity(0.08), engine.accent.opacity(0.15)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

/// A soft, slow dreamy gradient for skeleton cards — same vibe as WhatsNewCarousel
struct SkeletonDreamyGradient: View {
    @State private var engine = CircadianEngine.shared

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let phase = CGFloat(t.truncatingRemainder(dividingBy: 8) / 8)
            GeometryReader { geo in
                ZStack {
                    engine.accent.opacity(0.08)
                    Circle()
                        .fill(engine.accent.opacity(0.12))
                        .frame(width: geo.size.width * 0.6)
                        .blur(radius: 15)
                        .offset(x: geo.size.width * 0.2 * cos(phase * .pi * 2),
                                y: geo.size.height * 0.15 * sin(phase * .pi * 1.6))
                    Circle()
                        .fill(engine.accent.opacity(0.08))
                        .frame(width: geo.size.width * 0.45)
                        .blur(radius: 12)
                        .offset(x: geo.size.width * -0.1 * sin(phase * .pi * 1.8),
                                y: geo.size.height * -0.1 * cos(phase * .pi * 2.2))
                }
            }
        }
    }
}

// MARK: - Empty Filter
struct EmptyFilterView: View {
    let category: String
    var body: some View {
        ContentUnavailableView("No \(category) articles", systemImage: "rectangle.stack.fill", description: Text("This category has articles in the feed, but they may have been trimmed from the visible buffer. Try scrolling through All first.")).padding(.top, 80)
    }
}

// MARK: - Header Button Style

extension View {
    func headerButtonStyle(accent: Color) -> some View {
        self.frame(width: 36, height: 36)
            .background(accent.opacity(0.1))
            .clipShape(Circle())
    }
}
