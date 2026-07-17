# CatalogBrowserViewModel + Catalog Explore UI - Implementation Plan

**Status:** reviewed and corrected after the FeedEngine catalog vertical landed.  
**Last updated:** 2026-07-17  
**Goal:** Add a debug-gated catalog browse/search screen backed by the bundled read-only `catalog.sqlite`, without changing the legacy timeline or replacing `FeedStore`.

This plan assumes the current FeedEngine foundation already exists:

- `feedmine/FeedEngine/SQLiteCatalogStore.swift`
- `feedmine/FeedEngine/CatalogModels.swift`
- `feedmine/FeedEngine/CatalogProtocols.swift`
- `feedmine/FeedEngine/Pagination.swift`
- `feedmine/Services/FeedEngineCatalogDiagnostics.swift`
- `feedmine/Resources/FeedEngine/catalog.sqlite`

The screen is intentionally additive. It is a proving ground for catalog browse/search, not a timeline migration.

---

## Review Fixes Applied To This Plan

The previous draft had several issues that would likely break implementation:

- It referenced private ViewModel state (`nextCursor`, `searchResults`) from SwiftUI.
- `loadRoot()`/`navigate(to:)` spawned a task and returned before the page load completed, which would make tests flaky or fail.
- The SwiftUI screen used the browse cursor for search pagination.
- The source row loading indicator checked `selectedSourceDetails?.id`, which is nil while details are loading.
- The test stub conformed to `FeedEngineProtocol: Sendable` with mutable class state, which needs `@unchecked Sendable` or another concurrency-safe design.
- The plan forgot to add new files to `feedmine.xcodeproj/project.pbxproj`.
- The plan suggested committing after each task, which is not required for implementation and can create noisy history.
- Commands used an unavailable/unspecified simulator name. Use the known test destination from this repo unless a different simulator is verified.
- It required "zero warnings", while the current project has existing warnings. The correct requirement is no new warnings.

---

## Global Constraints

- Do not change `FeedStore`, `SourceRegistry`, `TaxonomyStore`, or the timeline behavior.
- Do not parse OPMLs or compile a catalog at launch.
- Open the bundled catalog read-only:

```swift
let repository = try SQLiteCatalogRepository(databaseURL: databaseURL, readOnly: true)
```

- Keep the screen behind the existing debug flag: `@AppStorage("showDebugBar")`.
- Use keyset pagination only. Never use offsets.
- Do not materialize full subtrees or all sources in Swift.
- Add all new Swift files to `feedmine.xcodeproj/project.pbxproj`.
- Keep tests focused on the ViewModel contract. UI smoke is enough for the view.

---

## Files

| File | Action | Purpose |
|---|---|---|
| `feedmine/FeedEngine/CatalogBrowserViewModel.swift` | Create | MainActor observable browse/search ViewModel |
| `feedmine/Views/CatalogExploreView.swift` | Create | Debug-only SwiftUI catalog browser |
| `feedmine/Views/FeedScreen.swift` | Modify | Add debug-gated sheet trigger |
| `feedmineTests/CatalogBrowserViewModelTests.swift` | Create | ViewModel unit tests with stub engine |
| `feedmine.xcodeproj/project.pbxproj` | Modify | Register new app and test files |

---

## Task 1 - Create `CatalogBrowserViewModel`

Create `feedmine/FeedEngine/CatalogBrowserViewModel.swift`.

Required shape:

```swift
import Foundation
import Observation

@MainActor
@Observable
final class CatalogBrowserViewModel {
    private let engine: FeedEngineProtocol

    private(set) var navigationPath: [CatalogNodeSummary] = []
    private(set) var nodes: [CatalogNodeSummary] = []
    private(set) var sources: [SourceSummary] = []
    private(set) var searchResults: [SourceSummary] = []
    private(set) var selectedSourceDetails: SourceDetails?

    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var isSearching = false
    private(set) var isLoadingDetails = false
    private(set) var loadingDetailsSourceID: SourceID?
    private(set) var errorMessage: String?
    private(set) var estimatedTotalCount: Int?

    var searchText = "" {
        didSet { scheduleSearchIfNeeded() }
    }

    private var browseNextCursor: CatalogCursor?
    private var searchNextCursor: CatalogCursor?

    @ObservationIgnored private var searchTask: Task<Void, Never>?

    init(engine: FeedEngineProtocol) {
        self.engine = engine
    }
}
```

Required public computed properties:

```swift
var currentNodeID: CatalogNodeID { navigationPath.last?.id ?? .root }
var currentNodeName: String { navigationPath.last?.name ?? "Catalog" }
var displaySources: [SourceSummary] { isSearching ? searchResults : sources }
var canLoadMoreBrowse: Bool { browseNextCursor != nil && !isSearching }
var canLoadMoreSearch: Bool { searchNextCursor != nil && isSearching }
var hasContent: Bool { !nodes.isEmpty || !displaySources.isEmpty }
```

Required methods:

```swift
func loadRoot() async
func navigate(to node: CatalogNodeSummary) async
func goBack() async
func goToRoot() async
func loadNextPage() async
func runSearch() async
func loadNextSearchPage() async
func clearSearch()
func loadSourceDetails(for sourceID: SourceID) async
func clearSourceDetails()
func clearError()
```

Implementation requirements:

- `loadRoot()`, `navigate(to:)`, `goBack()`, and `goToRoot()` must await the actual fetch before returning. Do not create a detached/unawaited `Task` for browse loading.
- Browse loading must reset `nodes`, `sources`, `browseNextCursor`, and `estimatedTotalCount`.
- Search loading must update only `searchResults` and `searchNextCursor`.
- `loadNextPage()` must append to browse arrays and must no-op while searching.
- `loadNextSearchPage()` must append to `searchResults` and must no-op when not searching.
- `clearSearch()` must cancel `searchTask`, clear `searchText`, set `isSearching = false`, clear `searchResults`, and clear `searchNextCursor`.
- `scheduleSearchIfNeeded()` should debounce for about 300 ms, then call `runSearch()` on the MainActor. It must cancel any previous search task.
- `loadSourceDetails(for:)` must set `loadingDetailsSourceID` before fetching and clear it in `defer`.

Do not make cursor properties public. The view should use `canLoadMoreBrowse` and `canLoadMoreSearch`.

---

## Task 2 - Add ViewModel Tests

Create `feedmineTests/CatalogBrowserViewModelTests.swift`.

The stub engine must account for `FeedEngineProtocol: Sendable`. The simplest acceptable test-only form is:

```swift
private final class StubFeedEngine: FeedEngineProtocol, @unchecked Sendable {
    var browseResponses: [CatalogPage] = []
    var searchResponses: [CatalogPage] = []
    var detailResponses: [SourceID: SourceDetails] = [:]
    var browseError: Error?
    var searchError: Error?
    var detailError: Error?

    private var browseCallCount = 0
    private var searchCallCount = 0
}
```

The stub methods must be defensive:

- If no browse response is configured, return an empty `CatalogPage`.
- If no search response is configured, return an empty `CatalogPage`.
- Do not compute `responses.count - 1` when the array is empty.

Minimum tests:

- `loadRoot()` populates nodes/sources and clears navigation.
- `navigate(to:)` pushes a node and loads its page.
- `goBack()` pops and reloads.
- `goToRoot()` clears the full path.
- setting `searchText` debounces and populates `searchResults`.
- `clearSearch()` restores browse mode.
- `loadNextPage()` appends browse nodes/sources.
- `loadNextSearchPage()` appends search results, not browse results.
- `loadSourceDetails(for:)` sets `selectedSourceDetails`.
- browse/search/detail errors set `errorMessage`.
- `clearError()` clears `errorMessage`.

Register the new test file in `feedmine.xcodeproj/project.pbxproj`.

---

## Task 3 - Create `CatalogExploreView`

Create `feedmine/Views/CatalogExploreView.swift`.

Required behavior:

- Own a `@State private var viewModel: CatalogBrowserViewModel`.
- Initialize with `FeedEngineProtocol`.
- Call `await viewModel.loadRoot()` in `.task`.
- Display search at the top.
- In browse mode, show node sections and source sections.
- In search mode, hide node sections and show only search result sources.
- Use `viewModel.canLoadMoreBrowse` and `viewModel.canLoadMoreSearch`.
- Show source details in a sheet using `selectedSourceDetails`.
- Use `loadingDetailsSourceID` for row-level progress.

Important UI rules:

- Keep the UI utilitarian and compact. This is a debug/explore tool, not a landing page.
- Use SF Symbols or existing icon patterns.
- Do not add feature-explaining body copy inside the app.
- Avoid nested cards.
- Make rows stable in height and readable on small screens.

Suggested view structure:

```swift
struct CatalogExploreView: View {
    @State private var viewModel: CatalogBrowserViewModel
    @Environment(\.dismiss) private var dismiss

    init(engine: FeedEngineProtocol) {
        _viewModel = State(initialValue: CatalogBrowserViewModel(engine: engine))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                content
            }
            .navigationTitle(viewModel.currentNodeName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !viewModel.navigationPath.isEmpty {
                        Button {
                            Task { await viewModel.goBack() }
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await viewModel.loadRoot() }
        }
    }
}
```

Add small private extensions for icon names:

- `CatalogNodeKind`: `.topic`, `.country`, `.region`, `.subcategory`, `.language`
- `MediaKind`: `.text`, `.audio`, `.video`, `.forum`

Do not add `@unknown default` to these switches unless the compiler requires it. These enums are not frozen public SDK enums.

Register the new view file in `feedmine.xcodeproj/project.pbxproj`.

---

## Task 4 - Integrate In `FeedScreen` Behind Debug Flag

Modify `feedmine/Views/FeedScreen.swift`.

Add state near the existing sheet flags:

```swift
@State private var showCatalogExplore = false
```

Add a debug-only trigger in the compact header near the existing icon buttons:

```swift
if showDebugBar {
    Button {
        showCatalogExplore = true
    } label: {
        Image(systemName: "books.vertical")
            .headerButtonStyle(accent: engine.accent)
    }
    .accessibilityLabel("Explore Catalog")
}
```

Add the sheet alongside the existing sheets:

```swift
.sheet(isPresented: $showCatalogExplore) {
    if let databaseURL = FeedEngineCatalogDiagnostics.bundledDatabaseURL(),
       let repository = try? SQLiteCatalogRepository(databaseURL: databaseURL, readOnly: true) {
        CatalogExploreView(engine: repository)
    } else {
        ContentUnavailableView(
            "Catalog unavailable",
            systemImage: "exclamationmark.triangle",
            description: Text("The bundled catalog could not be opened.")
        )
    }
}
```

Do not compile the catalog here. If the bundled database is missing or corrupt, show the unavailable state.

---

## Task 5 - Xcode Project Registration

Update `feedmine.xcodeproj/project.pbxproj`.

Add these to the app target sources:

- `CatalogBrowserViewModel.swift`
- `CatalogExploreView.swift`

Add this to the test target sources:

- `CatalogBrowserViewModelTests.swift`

Keep IDs unique and consistent with the existing project style.

---

## Task 6 - Verification

Use the known simulator destination from this repo unless another destination is verified first:

```bash
xcodebuild -project feedmine.xcodeproj \
  -scheme feedmine \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build -quiet
```

```bash
xcodebuild test -project feedmine.xcodeproj \
  -scheme feedmine \
  -destination 'platform=iOS Simulator,name=iPhone 14 Plus,OS=26.5' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:feedmineTests \
  -quiet
```

Then run a simulator smoke check:

```bash
SIM_ID="D3A8E60A-D820-4E29-A7E3-BC32DE7AD990"
xcrun simctl terminate "$SIM_ID" com.feedmine.app >/dev/null 2>&1 || true
xcrun simctl install "$SIM_ID" build/DerivedData/Build/Products/Debug-iphonesimulator/feedmine.app
xcrun simctl launch "$SIM_ID" com.feedmine.app
```

Manual smoke:

- Enable debug bar.
- Tap the catalog button.
- Root categories load from bundled `catalog.sqlite`.
- Search for `startupi`.
- Open source details.
- Drill into a node and back.
- Load more where available.

Expected:

- Build succeeds.
- Unit tests pass.
- No new warnings introduced by the new files.
- No runtime catalog is created in `Library/Application Support/FeedEngine`.
- Existing feed timeline behavior is unchanged.

---

## Acceptance Checklist

- [ ] `CatalogBrowserViewModel` exists and does not depend on `FeedStore`.
- [ ] Browse, search, pagination, navigation, details, and error handling are tested.
- [ ] `CatalogExploreView` uses ViewModel public state only.
- [ ] Search pagination and browse pagination are separate.
- [ ] Detail loading has a per-source loading indicator.
- [ ] New files are registered in the Xcode project.
- [ ] `FeedScreen` exposes the screen only when `showDebugBar` is true.
- [ ] Bundled catalog opens read-only.
- [ ] No OPML parse or catalog compile is added to launch.
- [ ] Build, unit tests, and simulator smoke pass.

---

## Do Not Do In This Plan

- Do not migrate the timeline.
- Do not change source enable/disable behavior.
- Do not write to `catalog.sqlite`.
- Do not introduce `user.sqlite` or `content.sqlite` yet.
- Do not remove `SourceRegistry` or `TaxonomyStore`.
- Do not add marketing/landing UI.
- Do not add background refresh behavior.

