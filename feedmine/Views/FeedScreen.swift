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
    @State private var selectedSource: SourceReference?
    @State private var sourceToCollect: SourceReference?
    @FocusState private var searchFocused: Bool
    @State private var showSettings = false
    @State private var showSources = false
    @State private var showFilters = false
    @State private var showBookmarks = false
    @State private var showAddFeed = false
    @State private var showCollections = false
    @State private var showExport = false
    @State private var showCatalogExplore = false
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastIcon = "checkmark"
    @State private var headerHeight: CGFloat = 48
    @State private var filterLensExpanded = true
    @State private var lastScrollOffset: CGFloat = 0
    @State private var filterLensCollapseTask: Task<Void, Never>?
    @State private var engine = CircadianEngine.shared
    @AppStorage("showDebugBar") private var showDebugBar = false
    @AppStorage("nightMode") private var nightMode = false
    @AppStorage("lastScrollItemID") private var lastScrollItemID = ""
    @AppStorage("filterLensDismissedSignature") private var filterLensDismissedSignature = ""
    @State private var scrollTargetID: String? = nil
    /// True once the user has actually scrolled the feed. Gates the one-shot
    /// cold-start position restore so it can never yank a user who already
    /// started reading. (Feed is sacred: it doesn't move on its own.)
    @State private var userHasScrolled = false
    @State private var didRestoreScroll = false
    @State private var didRecordFirstScreen = false
    @State private var didRecordFirstUsefulContent = false
    @State private var player = AudioPlayerManager.shared

    private var emptyMode: FeedEmptyMode {
        if loader.sources.isEmpty || (!loader.isGlobalFeedsEnabled && !loader.isAnyCountryEnabled) {
            return .noSourcesEnabled
        }
        if loader.hasActiveFilters && loader.items.isEmpty && (loader.loadingState == .refreshing || loader.isUrgentFetching) {
            return .fetching(
                topic: loader.selectedNodeNames.joined(separator: ", "),
                fetched: loader.emptyStateFetchedCount,
                total: loader.selectedNodeIDs.reduce(0) { $0 + (TaxonomyStore.shared.node(id: $1)?.feedCount ?? 0) }
            )
        }
        if loader.hasActiveFilters && loader.items.isEmpty && loader.loadingState == .idle {
            return .noResults(topic: loader.selectedNodeNames.joined(separator: ", "))
        }
        return .generic
    }

    var body: some View {
        screenWithSheets
    }

    private var screenContent: some View {
        ZStack(alignment: .top) {
            // Full-bleed feed content with circadian page tint
            engine.pageBackground.ignoresSafeArea()

            if isSearching && !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                unifiedSearchPanel
            } else if loader.items.isEmpty
                && (loader.isPreparingInitialRunway || loader.loadingState == .initial) {
                InitialFeedLoadingView()
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
    }

    private var observedScreen: some View {
        screenContent
        .task {
            await startScreen()
        }
        .onAppear { recordFirstScreenMetric() }
        .onChange(of: loader.items.count) { _, count in recordFirstUsefulContentMetric(count: count) }
        .onChange(of: scenePhase) { _, phase in handleScenePhase(phase) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            handleWillEnterForeground()
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
        .onChange(of: filterLensSignature) { _, _ in
            handleFilterLensContentChange()
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
    }

    private var screenWithSheets: some View {
        observedScreen
        .sheet(item: $articleItem) { item in ArticleReaderView(item: item) }
        .sheet(item: $selectedSource) { SourceFeedView(source: $0) }
        .sheet(item: $sourceToCollect) { AddSourceToCollectionSheet(source: $0) }
        .sheet(isPresented: $showSettings) { SettingsSheetView() }
        .sheet(isPresented: $showSources) { SourceManagementView() }
        .sheet(isPresented: $showFilters) { FilterSheetView() }
        .sheet(isPresented: $showBookmarks) { BookmarkBoxesView() }
        .sheet(isPresented: $showAddFeed) { AddFeedView() }
        .sheet(isPresented: $showCollections) { CollectionManagementView() }
        .sheet(isPresented: $showExport) { ExportView() }
        .sheet(isPresented: $showCatalogExplore) {
            if let databaseURL = FeedEngineCatalogDiagnostics.activeDatabaseURL(),
               let repository = try? SQLiteCatalogRepository(databaseURL: databaseURL, readOnly: true) {
                CatalogExploreView(engine: repository)
            } else {
                ContentUnavailableView(
                    "Catalog unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("The local catalog could not be opened.")
                )
            }
        }
        .tint(engine.accent)
        .animation(.easeInOut(duration: 2.0), value: engine.period)
        .overlay { if nightMode { nightOverlay } }
        .onDisappear {
            filterLensCollapseTask?.cancel()
        }
    }

    private var hasFilterLensContent: Bool {
        loader.activeFilterCount > 0
    }

    private var isFilterLensDismissedForCurrentSelection: Bool {
        hasFilterLensContent
            && !filterLensSignature.isEmpty
            && filterLensDismissedSignature == filterLensSignature
    }

    private var isFilterLensVisible: Bool {
        !isSearching && hasFilterLensContent && filterLensExpanded && !isFilterLensDismissedForCurrentSelection
    }

    private var feedTopPadding: CGFloat {
        max(48, headerHeight) + (isFilterLensVisible ? 20 : 0)
    }

    private var filterLensSignature: String {
        guard hasFilterLensContent else { return "" }
        var parts: [String] = []
        parts.append(loader.selectedRegion ?? "")
        parts.append(loader.selectedContentType.rawValue)
        parts.append(loader.selectedMood.rawValue)
        parts.append(loader.selectedNodeIDs.sorted().joined(separator: ","))
        parts.append(loader.selectedLanguages.sorted().joined(separator: ","))
        parts.append(loader.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines))
        return parts.joined(separator: "|")
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

                HStack(spacing: 4) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) { isSearching.toggle() }
                        if isSearching { searchText = "" }
                    } label: {
                        Image(systemName: isSearching ? "magnifyingglass.circle.fill" : "magnifyingglass")
                            .headerButtonStyle(accent: engine.accent)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .accessibilityIdentifier("search-button")
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
                    if showDebugBar {
                        Button {
                            showCatalogExplore = true
                        } label: {
                            Image(systemName: "books.vertical")
                                .headerButtonStyle(accent: engine.accent)
                        }
                        .accessibilityLabel("Explore Catalog")
                    }
                    Menu {
                        Button { showAddFeed = true } label: {
                            Label("Add Feed", systemImage: "plus.circle")
                        }
                        Button { showExport = true } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                        Button { showCollections = true } label: {
                            Label("Source Collections", systemImage: "rectangle.stack.fill")
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

            if isFilterLensVisible {
                FilterLensBar {
                    dismissFilterLensForCurrentSelection()
                }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .readHeaderHeight($headerHeight)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search sources, topics, and saved content", text: $searchText)
                .focused($searchFocused)
                .accessibilityIdentifier("unified-search-field")
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

    private var unifiedSearchPanel: some View {
        let results = loader.unifiedSearchResults
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if loader.isSearchLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Searching sources and your library…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)
                }

                if !results.sources.isEmpty {
                    searchSectionHeader("Sources", count: results.sources.count, icon: "antenna.radiowaves.left.and.right")
                    ForEach(results.sources) { source in
                        Button { selectedSource = source.sourceReference } label: {
                            SourceSearchRow(source: source)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("source-result-\(source.id)")
                        .contextMenu {
                            Button { selectedSource = source.sourceReference } label: {
                                Label("View Source", systemImage: "rectangle.stack")
                            }
                            Button { sourceToCollect = source.sourceReference } label: {
                                Label("Add Source to Collection", systemImage: "rectangle.stack.badge.plus")
                            }
                        }
                    }
                }

                if !results.savedItems.isEmpty {
                    searchSectionHeader("Saved", count: results.savedItems.count, icon: "bookmark.fill")
                    ForEach(results.savedItems) { item in
                        searchContentRow(item, saved: true)
                    }
                }

                if !results.localItems.isEmpty {
                    searchSectionHeader("History & local content", count: results.localItems.count, icon: "clock.arrow.circlepath")
                    ForEach(results.localItems) { item in
                        searchContentRow(item, saved: false)
                    }
                }

                if !loader.isSearchLoading && results.isEmpty {
                    ContentUnavailableView(
                        "No matches",
                        systemImage: "magnifyingglass",
                        description: Text("Try a topic, source, tag, or words from an article you saw before.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 50)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 90)
        }
        .scrollDismissesKeyboard(.interactively)
        .padding(.top, headerHeight + 52)
        .accessibilityIdentifier("unified-search-results")
    }

    private func searchSectionHeader(_ title: String, count: Int, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
            Text(title).fontWeight(.semibold)
            Spacer()
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .foregroundStyle(engine.accent)
        .padding(.top, 8)
    }

    private func searchContentRow(_ item: FeedItem, saved: Bool) -> some View {
        Button { articleItem = item } label: {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: saved ? "bookmark.fill" : (item.isRead ? "clock.fill" : "doc.text"))
                    .foregroundStyle(saved ? engine.accent : Color.secondary)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(item.sourceTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var filterButton: some View {
        let activeCount = loader.activeFilterCount
        return Button {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
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
        .accessibilityIdentifier("filter-button")
        .accessibilityValue("\(activeCount)")
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
                                ForEach(section.items) { item in
                                    FeedItemView(item: item,
                                        onOpen: { articleItem = item },
                                        onCopy: { toastMessage = "Link copied"; toastIcon = "doc.on.doc"; withAnimation { showToast = true } },
                                        onPlaybackFailed: {
                                            toastMessage = "Audio unavailable"
                                            toastIcon = "exclamationmark.triangle"
                                            withAnimation { showToast = true }
                                        },
                                        onViewSource: { selectedSource = loader.sourceReference(for: item) },
                                        onAddSourceToCollection: { sourceToCollect = loader.sourceReference(for: item) }
                                    )
                                    .id(item.id)
                                    .padding(.horizontal, 6)
                                    .contentShape(Rectangle())
                                    .onAppear {
                                        impressions.mark(item.id)
                                        loader.noteVisibleIndex(for: item)
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
                                if section.showsHeader {
                                    sectionHeader(section.title)
                                }
                            }
                        }

                        // Filters/search matched nothing, but the feed itself
                        // has content — show guidance instead of a blank screen.
                        if loader.dateSections.isEmpty && !loader.items.isEmpty {
                            EmptyFilterView(category: loader.selectedNodeNames.joined(separator: ", "))
                        }
                    }
                    .padding(.top, feedTopPadding)
                    .safeAreaInset(edge: .bottom) {
                        Color.clear.frame(height: 60).background(.ultraThinMaterial)
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .onScrollGeometryChange(for: CGFloat.self, of: { geo in
                    geo.contentOffset.y
                }, action: { _, newOffset in
                    handleScrollOffset(newOffset)
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

    private func startScreen() async {
        await loader.start()
        await loader.refreshBookmarkState()
        updateBadge()
        engine.refresh()
        // Restore scroll position once on cold start, but never if the user
        // already started reading.
        if !didRestoreScroll && !userHasScrolled
            && !lastScrollItemID.isEmpty && !loader.items.isEmpty {
            scrollTargetID = lastScrollItemID
        }
        didRestoreScroll = true
    }

    private func handleScrollOffset(_ newOffset: CGFloat) {
        if newOffset > 40 { userHasScrolled = true }

        let delta = newOffset - lastScrollOffset
        lastScrollOffset = newOffset

        guard hasFilterLensContent, !isSearching, !isFilterLensDismissedForCurrentSelection else { return }

        if delta > 8 && newOffset > 24 {
            collapseFilterLens()
        } else if delta < -8 {
            revealFilterLens()
        }
    }

    private func revealFilterLens(scheduleAutoCollapse: Bool = false) {
        guard hasFilterLensContent, !isFilterLensDismissedForCurrentSelection else { return }
        filterLensCollapseTask?.cancel()

        if !filterLensExpanded {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                filterLensExpanded = true
            }
        }

        if scheduleAutoCollapse {
            scheduleFilterLensCollapse()
        }
    }

    private func handleFilterLensContentChange() {
        guard hasFilterLensContent else {
            filterLensCollapseTask?.cancel()
            filterLensExpanded = true
            filterLensDismissedSignature = ""
            return
        }

        if isFilterLensDismissedForCurrentSelection {
            filterLensCollapseTask?.cancel()
            filterLensExpanded = false
        } else {
            revealFilterLens(scheduleAutoCollapse: true)
        }
    }

    private func dismissFilterLensForCurrentSelection() {
        guard hasFilterLensContent, !filterLensSignature.isEmpty else { return }
        filterLensCollapseTask?.cancel()
        filterLensDismissedSignature = filterLensSignature
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            filterLensExpanded = false
        }
    }

    private func collapseFilterLens() {
        filterLensCollapseTask?.cancel()
        guard hasFilterLensContent, filterLensExpanded else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            filterLensExpanded = false
        }
    }

    private func scheduleFilterLensCollapse() {
        filterLensCollapseTask?.cancel()
        filterLensCollapseTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, hasFilterLensContent, !isSearching else { return }
            if filterLensExpanded {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                    filterLensExpanded = false
                }
            }
        }
    }

    private func updateBadge() {
        let unread = loader.items.count - loader.readItemIDs.count
        Task { @MainActor in UIApplication.shared.applicationIconBadgeNumber = max(0, unread) }
    }

    private func recordFirstScreenMetric() {
        guard !didRecordFirstScreen else { return }
        didRecordFirstScreen = true
        FeedMetrics.event("UI.firstScreenRendered")
        FeedMetrics.memory("firstScreenRendered")
    }

    private func recordFirstUsefulContentMetric(count: Int) {
        guard count > 0, !didRecordFirstUsefulContent else { return }
        didRecordFirstUsefulContent = true
        FeedMetrics.event("UI.firstUsefulContent", "count=\(count)")
        FeedMetrics.memory("firstUsefulContent")
    }

    private func handleScenePhase(_ phase: ScenePhase) {
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
            let allItems = loader.dateSections.flatMap(\.items)
            let idx = min(lastScrollIndex, allItems.count - 1)
            if idx >= 0, idx < allItems.count {
                lastScrollItemID = allItems[idx].id
            }
        }
    }

    private func handleWillEnterForeground() {
        Task {
            engine.refresh()
            await loader.refreshIfStale()
        }
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

private struct HeaderHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 48
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private extension View {
    func readHeaderHeight(_ height: Binding<CGFloat>) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: HeaderHeightKey.self, value: proxy.size.height)
            }
        }
        .onPreferenceChange(HeaderHeightKey.self) { height.wrappedValue = $0 }
    }
}

struct CompactGreeting: View {
    @Environment(FeedLoader.self) private var loader
    @State private var engine = CircadianEngine.shared
    @State private var showReadyPulse = false
    @AppStorage("showDebugBar") private var showDebugBar = false

    private var isShowingStartupProgress: Bool {
        loader.isPreparingInitialRunway || showReadyPulse
    }

    private var startupTotal: Int {
        max(loader.startupTotalSourceCount, loader.sourceCount)
    }

    var body: some View {
        HStack(spacing: 4) {
            Image("Symbol-Gradient")
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
            Text("Feedmine").font(.caption).fontWeight(.bold)
            if isShowingStartupProgress {
                HStack(spacing: 3) {
                    Text("· \(loader.startupFetchedSourceCount)/\(startupTotal)")
                        .contentTransition(.numericText())
                    if showReadyPulse {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolEffect(.pulse, value: showReadyPulse)
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(showReadyPulse ? Color.green : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityLabel(
                    "\(loader.startupFetchedSourceCount) de \(startupTotal) fontes verificadas"
                )
            } else {
                Text("·\(loader.sourceCount) sources")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
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
        .task(id: loader.startupRunwayReady) {
            guard loader.startupRunwayReady else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                showReadyPulse = true
            }
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.35)) {
                showReadyPulse = false
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

private struct SourceSearchRow: View {
    let source: SourceSearchResult

    private var mediaIcon: String {
        switch source.mediaKind {
        case .text: return "doc.text"
        case .video: return "play.rectangle.fill"
        case .audio: return "headphones"
        case .forum: return "bubble.left.and.bubble.right.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: mediaIcon)
                .foregroundStyle(source.defaultEnabled ? Color.accentColor : Color.secondary)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(source.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if !source.defaultEnabled {
                        Text("DORMANT")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.13), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                if let description = source.sourceDescription, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 5) {
                    if let host = source.displayHost {
                        Text(host).lineLimit(1)
                    }
                    ForEach(source.tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.09), in: Capsule())
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct SourceSearchDetailView: View {
    @Environment(FeedLoader.self) private var loader
    @Environment(\.dismiss) private var dismiss
    let source: SourceSearchResult

    private var isEnabled: Bool { loader.isSourceEnabled(source.feedURL) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(source.title)
                            .font(.title2.bold())
                        if let host = source.displayHost {
                            Text(host).font(.subheadline).foregroundStyle(.secondary)
                        }
                        if let description = source.sourceDescription {
                            Text(description).font(.body)
                        }
                    }

                    if !source.tags.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Topics").font(.headline)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack {
                                    ForEach(source.tags, id: \.self) { tag in
                                        Text(tag)
                                            .font(.caption)
                                            .padding(.horizontal, 9)
                                            .padding(.vertical, 6)
                                            .background(Color.secondary.opacity(0.12), in: Capsule())
                                    }
                                }
                            }
                        }
                    }

                    HStack(spacing: 10) {
                        Label(source.mediaKind.rawValue.capitalized, systemImage: "dot.radiowaves.left.and.right")
                        if let activity = source.activity {
                            Label(activity.capitalized, systemImage: "waveform.path.ecg")
                        }
                        if let language = source.language {
                            Label(language, systemImage: "character.book.closed")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if !source.defaultEnabled {
                        Label(
                            "Kept for discovery, but not refreshed by default because this current-sensitive source is dormant.",
                            systemImage: "archivebox"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }

                    Button {
                        loader.toggleSource(source.feedURL)
                    } label: {
                        Label(
                            isEnabled ? "Disable source" : "Enable source",
                            systemImage: isEnabled ? "minus.circle" : "plus.circle.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    HStack {
                        if let rawSiteURL = source.siteURL, let siteURL = URL(string: rawSiteURL) {
                            Link(destination: siteURL) {
                                Label("Website", systemImage: "safari")
                            }
                        }
                        Spacer()
                        ShareLink(item: source.feedURL) {
                            Label("Share feed", systemImage: "square.and.arrow.up")
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(20)
            }
            .navigationTitle("Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Initial Feed Loading

struct InitialFeedLoadingView: View {
    @Environment(FeedLoader.self) private var loader
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var engine = CircadianEngine.shared
    @State private var displayedSourceName = ""
    @State private var nextSourceNameIndex = 0

    private var progressFraction: Double {
        guard loader.startupTargetSourceCount > 0 else { return 0 }
        return min(
            1,
            Double(loader.startupFetchedSourceCount) / Double(loader.startupTargetSourceCount)
        )
    }

    private var loadingTitle: String {
        loader.hasPreviouslyLoadedContent
            ? String(localized: "Loading your feed...")
            : String(localized: "Loading articles")
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Spacer(minLength: max(88, proxy.size.height * 0.13))

                StartupSignalView(
                    accent: engine.accent,
                    isReady: loader.startupRunwayReady,
                    reduceMotion: reduceMotion
                )
                .frame(width: 152, height: 72)

                Text(loadingTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.top, 22)

                Text(String(localized: "We are keeping you entertained while the content arrives."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 330)
                    .padding(.top, 8)

                VStack(spacing: 8) {
                    GeometryReader { bar in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.secondary.opacity(0.14))
                            Capsule()
                                .fill(loader.startupRunwayReady ? Color.green : engine.accent)
                                .frame(width: max(4, bar.size.width * progressFraction))
                        }
                    }
                    .frame(height: 5)

                    HStack {
                        Text(verbatim: "\(loader.startupFetchedSourceCount)/\(loader.startupTargetSourceCount)")
                            .contentTransition(.numericText())
                        Spacer()
                        Text(verbatim: "\(Int((progressFraction * 100).rounded()))%")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 290)
                .padding(.top, 28)

                VStack(spacing: 7) {
                    Text(String(localized: "Loading articles"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)

                    ZStack {
                        Text(displayedSourceName.isEmpty ? loadingTitle : displayedSourceName)
                            .id(displayedSourceName)
                            .transition(.opacity)
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(engine.accent)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300, minHeight: 42)
                }
                .padding(.top, 34)

                Spacer(minLength: 44)
            }
            .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            .padding(.horizontal, 24)
        }
        .disabled(true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(loadingTitle)
        .accessibilityValue(
            "\(loader.startupFetchedSourceCount)/\(loader.startupTargetSourceCount)"
        )
        .task {
            while !Task.isCancelled {
                let names = loader.startupRecentSourceNames
                if nextSourceNameIndex < names.count {
                    let backlog = names.count - nextSourceNameIndex
                    let step = max(1, backlog / 4)
                    let index = min(names.count - 1, nextSourceNameIndex + step - 1)
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
                        displayedSourceName = names[index]
                    }
                    nextSourceNameIndex = index + 1
                }
                try? await Task.sleep(for: .milliseconds(650))
            }
        }
    }
}

private struct StartupSignalView: View {
    let accent: Color
    let isReady: Bool
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 6) {
                ForEach(0..<13, id: \.self) { index in
                    let wave = reduceMotion
                        ? 0.45
                        : (sin(time * 4.2 + Double(index) * 0.72) + 1) / 2
                    Capsule()
                        .fill((isReady ? Color.green : accent).opacity(0.35 + wave * 0.65))
                        .frame(width: 5, height: 12 + wave * 42)
                }
            }
            .frame(width: 152, height: 72)
            .animation(.easeInOut(duration: 0.25), value: isReady)
        }
        .accessibilityHidden(true)
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
