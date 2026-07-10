# Multi-Feed Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user swipe (full-screen paging) between up to 5 fully independent feeds, each with its own SQLite DB, its own settings, and a distinct color palette.

**Architecture:** A new top-level `FeedManager` (`@Observable`) owns an array of feeds and the active index. The existing `FeedStore`/`FeedLoader` engine is reused **per feed**, namespaced by a `feedID`: each feed gets its own DB file (`feedmine_<id>.sqlite`) and its own `UserDefaults` suite (so all existing feed-scoped keys become per-feed with zero key-string rewrites). Palette becomes a per-page `FeedTheme` injected via SwiftUI environment instead of a global `CircadianEngine.shared` read. The root view is a `TabView(.page)` pager over the feeds plus a trailing creation page.

**Tech Stack:** Swift 6.0 (strict concurrency `complete`), SwiftUI, `@Observable`/Observation, GRDB 7.4.0 (SQLite), Xcode 26.x, iOS 18 deployment target, iPhone-only.

## Global Constraints

- **Do NOT regenerate the Xcode project with `xcodegen`.** The checked-in `feedmine.xcodeproj` depends on GRDB 7.4.0 but `project.yml` used to drop it. Edit the `.xcodeproj` directly if ever needed; do not run `xcodegen generate`.
- **Swift version:** 6.0 with `SWIFT_STRICT_CONCURRENCY = complete`. All new coordinator/UI types are `@MainActor`.
- **Deployment target:** iOS 18.0, iPhone only (`TARGETED_DEVICE_FAMILY = "1"`).
- **Bundle id:** `com.feedmine.app`.
- **Max feeds:** exactly **5** (one distinct `PaletteFamily` each — there are exactly 5).
- **Main feed id is a fixed constant** (`FeedDescriptor.mainID`) so the main feed persists across launches.
- **No test target exists.** Verification is: clean `xcodebuild build` + run on the booted simulator + `simctl` screenshot, plus cheap inline logic asserts (`assert(...)` / `#if DEBUG` self-checks) where standalone.
- **SourceKit live diagnostics lie** ("Cannot find type 'FeedItem'", "No such module 'GRDB'") — single-file noise. Trust `xcodebuild`, not inline diagnostics.
- **New files must be added to the `feedmine` app target** in `feedmine.xcodeproj` (the target uses folder references for `feedmine/`, so files under `feedmine/Models`, `feedmine/Services`, `feedmine/Views` are picked up by path — verify each new file compiles via the build step).

### Standard verification commands (referenced by every task as "BUILD" and "RUN")

**BUILD:**
```bash
xcodebuild build -project feedmine.xcodeproj -scheme feedmine \
  -destination 'platform=iOS Simulator,name=iPhone 14 Plus' -derivedDataPath .build-dd 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

**RUN (boot if needed, install, launch, screenshot):**
```bash
xcrun simctl boot "iPhone 14 Plus" 2>/dev/null; \
xcrun simctl install booted .build-dd/Build/Products/Debug-iphonesimulator/feedmine.app && \
xcrun simctl launch booted com.feedmine.app && sleep 4 && \
xcrun simctl io booted screenshot /tmp/feedmine_shot.png && echo "screenshot: /tmp/feedmine_shot.png"
```
Then Read `/tmp/feedmine_shot.png` to confirm behavior.

### Per-feed vs global UserDefaults keys (authoritative list)

**Route through the injected per-feed `defaults` (become per-feed):**
`filterRegion`, `filterCategory`, `filterContentType`, `filterMood`, `last_whats_new_seen_at`, `lastHeavyMaintenance`, `toggleDisabled`, `toggleEnabledOverrides`, and `SourceRegistry`'s `hasInitializedKey`.

**Stay on `UserDefaults.standard` (remain global/app-wide):**
`prefetchImages`, `showDebugBar`, `nightMode`, `fontSize`, `circadianPaletteOn`, `paletteFamily`, `circadianTypographyOn`, `fontStyle`, and any session/streak/weather keys.

---

## File Structure

**New files:**
- `feedmine/Models/FeedDescriptor.swift` — `Codable` per-feed identity + `mainID` constant + palette-pool helper.
- `feedmine/Services/FeedTheme.swift` — value resolving `accent`/`pageBackground` for one page + `EnvironmentValues` key.
- `feedmine/Services/FeedManager.swift` — coordinator: feeds array, active index, index persistence, palette assignment, create/delete, warm-up + background refresh.
- `feedmine/Views/RootPagerView.swift` — `TabView(.page)` pager + dots overlay host.
- `feedmine/Views/FeedCreationPage.swift` — creation form (sources + filters + name + OK).
- `feedmine/Views/FeedDotsIndicator.swift` — bottom colored-dot page indicator with trailing "+".

**Modified files:**
- `feedmine/Services/SourceRegistry.swift` — inject `UserDefaults`; route toggle/init keys through it.
- `feedmine/Services/FeedStore.swift` — `init(feedID:defaults:)`; per-feed `dbPath`; route feed-scoped keys through `defaults`; add `deleteDatabaseFiles(feedID:)` static + `applyConfig(...)`.
- `feedmine/Services/FeedLoader.swift` — `init(feedID:defaults:)` pass-through; expose `applyCreationConfig(...)` and `warmUp()`.
- `feedmine/Views/FeedScreen.swift` — read `FeedTheme` from environment; replace `engine.accent`/`engine.pageBackground`; show optional feed name.
- `feedmine/Views/SettingsSheetView.swift` — inject `FeedManager` + `feedID`; add "Delete this feed" for secondaries; palette picker excludes occupied families.
- `feedmine/ContentView.swift` — build `FeedManager`, render `RootPagerView`.
- `feedmine/feedmineApp.swift` — own `FeedManager`, inject into environment.

---

## Phase 1 — Per-feed data isolation (foundation)

### Task 1: Namespace `SourceRegistry` and `FeedStore` by feed id

**Files:**
- Modify: `feedmine/Services/SourceRegistry.swift` (init + lines 204,205,209,212,287,292)
- Modify: `feedmine/Services/FeedStore.swift` (init ~153, dbPath ~222, filter persist 460/468, whatsNew 288/754/763, maintenance 1265-1280)
- Modify: `feedmine/Services/FeedLoader.swift:360-362` (init)

**Interfaces:**
- Produces:
  - `SourceRegistry.init(defaults: UserDefaults = .standard)`
  - `FeedStore.init(feedID: UUID = FeedDescriptor.mainID, defaults: UserDefaults = .standard) throws` *(FeedDescriptor.mainID added in Task 2; for Task 1 use a temporary `static let mainID = UUID(uuidString: "00000000-0000-0000-0000-0000000000FE")!` on FeedStore, moved to FeedDescriptor in Task 2)*
  - `static func FeedStore.dbPath(for feedID: UUID) -> String`
  - `static func FeedStore.deleteDatabaseFiles(feedID: UUID)`
  - `FeedLoader.init(feedID: UUID = FeedStore.mainID, defaults: UserDefaults = .standard, store: FeedStore? = nil)`

- [ ] **Step 1: Add injected `defaults` to `SourceRegistry`.**

In `SourceRegistry.swift`, add a stored property and init, and replace the six `UserDefaults.standard` usages with `defaults`:

```swift
// near the top of the class, with other stored properties:
private let defaults: UserDefaults

init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
}
```
Then change lines 204,205,209,212,287,292 from `UserDefaults.standard` to `defaults` (same keys, same calls). Leave every other line untouched.

- [ ] **Step 2: Add per-feed id, defaults, and db path to `FeedStore`.**

In `FeedStore.swift`:

```swift
// Temporary home for the main id (moves to FeedDescriptor in Task 2):
static let mainID = UUID(uuidString: "00000000-0000-0000-0000-0000000000FE")!

let feedID: UUID
private let defaults: UserDefaults

// replace `let registry = SourceRegistry()` with a lazy/injected one:
let registry: SourceRegistry
```

Replace the init signature and body top:
```swift
init(feedID: UUID = FeedStore.mainID, defaults: UserDefaults = .standard) throws {
    self.feedID = feedID
    self.defaults = defaults
    self.registry = SourceRegistry(defaults: defaults)
    self.db = try DatabaseQueue(path: Self.dbPath(for: feedID), configuration: Self.dbConfig)
    try Self.migrate(db)
    // ... keep the existing Favorites-insert + loadSourceHealth() body unchanged ...
}
```

Replace the static `dbPath` with a per-feed function:
```swift
static func dbPath(for feedID: UUID) -> String {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    return docs.appendingPathComponent("feedmine_\(feedID.uuidString).sqlite").path
}
```

- [ ] **Step 3: Route feed-scoped keys in `FeedStore` through `defaults`.**

Change **only** these to use `self.defaults` (they read/write feed-scoped keys):
- `persistFilters()` / `restoreFilters()` — the `let d = UserDefaults.standard` (lines ~460, ~468) become `let d = self.defaults`.
- What's New seen-at at lines ~288, ~754, ~763 — `UserDefaults.standard` → `self.defaults`.
- Heavy maintenance at lines ~1267, ~1280 — `UserDefaults.standard` → `self.defaults`.
- The toggle migration at lines ~1647, ~1652 — `UserDefaults.standard` → `self.defaults`.

Leave `prefetchImages` (85,95) and `showDebugBar` (861) on `UserDefaults.standard` — they are global.

- [ ] **Step 4: Add DB-file deletion helper to `FeedStore`.**

```swift
static func deleteDatabaseFiles(feedID: UUID) {
    let base = dbPath(for: feedID)
    for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: base + suffix)
    }
}
```

- [ ] **Step 5: Thread id/defaults through `FeedLoader.init`.**

Replace `FeedLoader.init` (lines 360-362):
```swift
init(feedID: UUID = FeedStore.mainID, defaults: UserDefaults = .standard, store: FeedStore? = nil) {
    self.store = store ?? (try! FeedStore(feedID: feedID, defaults: defaults))
}
```

- [ ] **Step 6: BUILD.** Expect `** BUILD SUCCEEDED **`. Fix any strict-concurrency errors (all touched types are already `@MainActor`).

- [ ] **Step 7: RUN and screenshot.** The app must look and behave exactly as before (single feed) — the default `mainID` + `.standard`-less suite still yields one working feed. Note the DB file is now `feedmine_<mainID>.sqlite` (fresh, since dev/no migration). Read `/tmp/feedmine_shot.png` and confirm the feed renders.

- [ ] **Step 8: Commit.**
```bash
git add feedmine/Services/SourceRegistry.swift feedmine/Services/FeedStore.swift feedmine/Services/FeedLoader.swift
git commit -m "refactor(feed): namespace FeedStore/SourceRegistry by feedID + injected UserDefaults"
```

---

### Task 2: `FeedDescriptor` model + palette-pool helper

**Files:**
- Create: `feedmine/Models/FeedDescriptor.swift`
- Modify: `feedmine/Services/FeedStore.swift` (replace temporary `mainID` with `FeedDescriptor.mainID`)

**Interfaces:**
- Produces:
  - `struct FeedDescriptor: Codable, Identifiable, Equatable { var id: UUID; var name: String?; var paletteFamily: PaletteFamily?; var order: Int; var createdAt: Date }`
  - `static let FeedDescriptor.mainID: UUID`
  - `static func FeedDescriptor.firstFreeFamily(excluding used: Set<PaletteFamily>) -> PaletteFamily?`
  - `PaletteFamily: Codable` conformance
- Consumes: `PaletteFamily` (from `CircadianEngine.swift`)

- [ ] **Step 1: Make `PaletteFamily` Codable.**

In `feedmine/Services/CircadianEngine.swift`, change `enum PaletteFamily: String, CaseIterable {` to `enum PaletteFamily: String, CaseIterable, Codable {`.

- [ ] **Step 2: Create `FeedDescriptor.swift`.**

```swift
import Foundation

/// Persisted identity of a single feed. Holds no content data — just the feed's
/// identity and its palette assignment. Content lives in the feed's own SQLite DB.
struct FeedDescriptor: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String?
    /// nil = adaptive/global palette (main feed only, follows CircadianEngine).
    /// non-nil = fixed family (secondary feeds).
    var paletteFamily: PaletteFamily?
    var order: Int
    var createdAt: Date

    /// Fixed id for the permanent main feed, so it persists across launches.
    static let mainID = UUID(uuidString: "00000000-0000-0000-0000-0000000000FE")!

    static func main() -> FeedDescriptor {
        FeedDescriptor(id: mainID, name: nil, paletteFamily: nil, order: 0, createdAt: Date(timeIntervalSince1970: 0))
    }

    var isMain: Bool { id == FeedDescriptor.mainID }

    /// First palette family in canonical enum order not present in `used`.
    static func firstFreeFamily(excluding used: Set<PaletteFamily>) -> PaletteFamily? {
        PaletteFamily.allCases.first { !used.contains($0) }
    }
}
```

- [ ] **Step 3: Point `FeedStore.mainID` at `FeedDescriptor.mainID`.**

In `FeedStore.swift`, replace the temporary `static let mainID = UUID(...)` with:
```swift
static var mainID: UUID { FeedDescriptor.mainID }
```

- [ ] **Step 4: BUILD.** Expect `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit.**
```bash
git add feedmine/Models/FeedDescriptor.swift feedmine/Services/CircadianEngine.swift feedmine/Services/FeedStore.swift
git commit -m "feat(feed): add FeedDescriptor model + palette-pool helper"
```

---

### Task 3: `FeedTheme` + environment injection

**Files:**
- Create: `feedmine/Services/FeedTheme.swift`

**Interfaces:**
- Produces:
  - `struct FeedTheme { let family: PaletteFamily?; var accent: Color; var pageBackground: Color }`
  - `EnvironmentValues.feedTheme: FeedTheme` (default = adaptive/main)
- Consumes: `CircadianEngine.shared`, `PaletteFamily`

- [ ] **Step 1: Create `FeedTheme.swift`.**

```swift
import SwiftUI

/// Resolves the two color values that differ per feed — accent and page background.
/// Everything else (fonts, card geometry, period) still comes from CircadianEngine.shared,
/// because typography/layout are global, only color is per-feed.
struct FeedTheme {
    /// nil = main feed → mirror CircadianEngine.shared exactly (adaptive).
    /// non-nil = secondary feed → fixed family, still period-aware for legibility.
    let family: PaletteFamily?

    @MainActor var accent: Color {
        let engine = CircadianEngine.shared
        guard let family else { return engine.accent }
        return engine.isCircadianOn ? family.accent(for: engine.period) : family.accent(for: .morning)
    }

    @MainActor var pageBackground: Color {
        let engine = CircadianEngine.shared
        guard let family else { return engine.pageBackground }
        return engine.isCircadianOn ? family.pageTint(for: engine.period) : Color(hex: "#FAF8F5")
    }
}

private struct FeedThemeKey: EnvironmentKey {
    static let defaultValue = FeedTheme(family: nil)  // main / adaptive
}

extension EnvironmentValues {
    var feedTheme: FeedTheme {
        get { self[FeedThemeKey.self] }
        set { self[FeedThemeKey.self] = newValue }
    }
}
```

- [ ] **Step 2: BUILD.** Expect `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit.**
```bash
git add feedmine/Services/FeedTheme.swift
git commit -m "feat(feed): add per-feed FeedTheme (accent + page background)"
```

---

### Task 4: `FeedManager` coordinator (create/delete/persist + palette assignment)

**Files:**
- Create: `feedmine/Services/FeedManager.swift`

**Interfaces:**
- Consumes: `FeedDescriptor`, `FeedLoader`, `FeedStore`, `FeedTheme`, `PaletteFamily`, `CircadianEngine`
- Produces:
  - `@MainActor @Observable final class FeedManager`
  - `var feeds: [FeedInstance]` (ordered), `var activeIndex: Int`
  - `struct FeedInstance: Identifiable { let descriptor: FeedDescriptor; let loader: FeedLoader; var id: UUID }`
  - `var canCreateMore: Bool` (`feeds.count < 5`)
  - `var nextFreeFamily: PaletteFamily?`
  - `func theme(for descriptor: FeedDescriptor) -> FeedTheme`
  - `func occupiedFamilies(excludingSecondary excludeID: UUID?) -> Set<PaletteFamily>`
  - `@discardableResult func createFeed(name: String?) -> Int` (returns new active index)
  - `func deleteFeed(id: UUID)`
  - `func setActive(_ index: Int)`
  - `static let shared` is **not** used — instance owned by the app.

- [ ] **Step 1: Create `FeedManager.swift` with load/persist + create/delete.**

```swift
import Foundation
import Observation

@MainActor
@Observable
final class FeedManager {
    struct FeedInstance: Identifiable {
        let descriptor: FeedDescriptor
        let loader: FeedLoader
        var id: UUID { descriptor.id }
    }

    private static let indexKey = "feeds_index"
    private let maxFeeds = 5

    private(set) var feeds: [FeedInstance] = []
    var activeIndex: Int = 0

    var canCreateMore: Bool { feeds.count < maxFeeds }

    init() {
        let descriptors = Self.loadIndex()
        feeds = descriptors
            .sorted { $0.order < $1.order }
            .map { FeedInstance(descriptor: $0, loader: Self.makeLoader(for: $0)) }
    }

    // MARK: - Loader factory (per-feed DB + UserDefaults suite)

    private static func makeLoader(for descriptor: FeedDescriptor) -> FeedLoader {
        let suite = UserDefaults(suiteName: "com.feedmine.feed.\(descriptor.id.uuidString)") ?? .standard
        return FeedLoader(feedID: descriptor.id, defaults: suite)
    }

    // MARK: - Index persistence

    private static func loadIndex() -> [FeedDescriptor] {
        guard let data = UserDefaults.standard.data(forKey: indexKey),
              let list = try? JSONDecoder().decode([FeedDescriptor].self, from: data),
              !list.isEmpty else {
            return [FeedDescriptor.main()]   // first launch / corrupt → main only
        }
        return list
    }

    private func persistIndex() {
        let descriptors = feeds.map(\.descriptor)
        guard let data = try? JSONEncoder().encode(descriptors) else { return }
        UserDefaults.standard.set(data, forKey: Self.indexKey)
    }

    // MARK: - Palette assignment

    /// Families currently in use. The main's effective family (from CircadianEngine)
    /// counts as occupied. `excludeID` lets a secondary's own family be ignored.
    func occupiedFamilies(excludingSecondary excludeID: UUID? = nil) -> Set<PaletteFamily> {
        var used = Set<PaletteFamily>()
        for f in feeds {
            if f.descriptor.id == excludeID { continue }
            if f.descriptor.isMain {
                used.insert(CircadianEngine.shared.paletteFamily)
            } else if let fam = f.descriptor.paletteFamily {
                used.insert(fam)
            }
        }
        return used
    }

    var nextFreeFamily: PaletteFamily? {
        FeedDescriptor.firstFreeFamily(excluding: occupiedFamilies())
    }

    func theme(for descriptor: FeedDescriptor) -> FeedTheme {
        FeedTheme(family: descriptor.isMain ? nil : descriptor.paletteFamily)
    }

    // MARK: - Create / Delete

    @discardableResult
    func createFeed(name: String?) -> Int {
        guard canCreateMore, let family = nextFreeFamily else { return activeIndex }
        let descriptor = FeedDescriptor(
            id: UUID(),
            name: (name?.isEmpty == true) ? nil : name,
            paletteFamily: family,
            order: feeds.count,
            createdAt: Date()
        )
        let instance = FeedInstance(descriptor: descriptor, loader: Self.makeLoader(for: descriptor))
        feeds.append(instance)
        persistIndex()
        let newIndex = feeds.count - 1
        activeIndex = newIndex
        return newIndex
    }

    func deleteFeed(id: UUID) {
        guard let idx = feeds.firstIndex(where: { $0.descriptor.id == id }),
              !feeds[idx].descriptor.isMain else { return }
        // Slide to a safe neighbor BEFORE removing, so no dead loader renders.
        let neighbor = max(0, idx - 1)
        activeIndex = neighbor
        feeds.remove(at: idx)
        // Reindex order.
        feeds = feeds.enumerated().map { i, inst in
            var d = inst.descriptor; d.order = i
            return FeedInstance(descriptor: d, loader: inst.loader)
        }
        persistIndex()
        FeedStore.deleteDatabaseFiles(feedID: id)
        UserDefaults.standard.removeSuite(named: "com.feedmine.feed.\(id.uuidString)")
        if activeIndex >= feeds.count { activeIndex = max(0, feeds.count - 1) }
    }

    func setActive(_ index: Int) {
        guard feeds.indices.contains(index) else { return }
        activeIndex = index
    }
}
```

Note: `FeedDescriptor.main()` uses `Date(timeIntervalSince1970: 0)` for a stable, deterministic
`createdAt`; `createFeed` uses `Date()` (runtime is fine — this is app code, not a workflow script).

- [ ] **Step 2: Add a `#if DEBUG` self-check for palette assignment (inline logic assert).**

Append to `FeedManager.swift`:
```swift
#if DEBUG
extension FeedManager {
    /// Cheap runtime self-check — call once from app launch in DEBUG.
    static func _selfCheckPalettePool() {
        let mainFam = CircadianEngine.shared.paletteFamily
        // firstFreeFamily must skip an excluded family
        let free = FeedDescriptor.firstFreeFamily(excluding: [mainFam])
        assert(free != nil && free != mainFam, "free family must exclude the occupied one")
        // excluding all families yields nil (pool exhausted)
        assert(FeedDescriptor.firstFreeFamily(excluding: Set(PaletteFamily.allCases)) == nil, "full pool → nil")
        print("[FeedManager] palette self-check passed (main=\(mainFam.rawValue), free=\(free!.rawValue))")
    }
}
#endif
```

- [ ] **Step 3: BUILD.** Expect `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit.**
```bash
git add feedmine/Services/FeedManager.swift
git commit -m "feat(feed): FeedManager coordinator with create/delete + palette assignment"
```

---

## Phase 2 — Pager & multi-feed rendering

### Task 5: Root pager wiring (`RootPagerView` + app entry + FeedScreen theme)

**Files:**
- Create: `feedmine/Views/RootPagerView.swift`
- Modify: `feedmine/ContentView.swift`
- Modify: `feedmine/feedmineApp.swift`
- Modify: `feedmine/Views/FeedScreen.swift` (theme injection + accent/background replacement)

**Interfaces:**
- Consumes: `FeedManager`, `FeedManager.FeedInstance`, `FeedTheme`, `FeedScreen`
- Produces: `struct RootPagerView: View` bound to `FeedManager`

- [ ] **Step 1: Make `FeedScreen` read the injected theme.**

In `FeedScreen.swift`, add near the other `@Environment` lines (top of `FeedScreen`, ~line 5):
```swift
@Environment(\.feedTheme) private var feedTheme
```
Replace the page background at line 30:
```swift
feedTheme.pageBackground.ignoresSafeArea()
```
Replace **every** `engine.accent` reference **inside the main `FeedScreen` struct body** (lines ~134, 163, 172, 176, 189, 222, 275, 281, 303, 409) with `feedTheme.accent`. Also replace the two `CircadianEngine.shared.accent` at lines 263, 264 with `feedTheme.accent`.

Leave untouched (still `engine.*` — these are global typography/layout/period): `engine.refresh()`, `engine.period`, `engine.cardGap`, `engine.cardRadius`, `engine.font(...)`, and the `@State private var engine` in the **sub-views** at lines 491/523/554/585 (those render skeleton/decor; threading them is Task 9 polish).

- [ ] **Step 2: Create `RootPagerView.swift`.**

```swift
import SwiftUI

struct RootPagerView: View {
    @Environment(FeedManager.self) private var manager
    @Environment(LocaleManager.self) private var localeManager

    var body: some View {
        @Bindable var manager = manager
        ZStack(alignment: .bottom) {
            TabView(selection: $manager.activeIndex) {
                ForEach(Array(manager.feeds.enumerated()), id: \.element.id) { index, instance in
                    FeedScreen()
                        .environment(instance.loader)
                        .environment(\.feedTheme, manager.theme(for: instance.descriptor))
                        .tag(index)
                }
                if manager.canCreateMore {
                    FeedCreationPage()
                        .tag(manager.feeds.count)   // creation page is the last tag
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            FeedDotsIndicator()   // Task 7
        }
    }
}
```

*(Note: `FeedCreationPage` is created in Task 6 and `FeedDotsIndicator` in Task 7. To keep this task building on its own, add temporary stubs — see Step 3 — and replace them in later tasks.)*

- [ ] **Step 3: Add temporary stubs so this task builds independently.**

At the bottom of `RootPagerView.swift`, add:
```swift
// TEMP stubs — replaced in Task 6 / Task 7.
struct FeedCreationPage: View { var body: some View { Color.clear } }
struct FeedDotsIndicator: View { var body: some View { EmptyView() } }
```

- [ ] **Step 4: Wire the app entry to `FeedManager` + `RootPagerView`.**

Replace `feedmine/feedmineApp.swift`:
```swift
import SwiftUI

@main
struct FeedmineApp: App {
    @State private var manager = FeedManager()
    @State private var localeManager = LocaleManager.shared

    var body: some Scene {
        WindowGroup {
            RootPagerView()
                .environment(manager)
                .environment(localeManager)
        }
    }
}
```

Replace `feedmine/ContentView.swift`:
```swift
import SwiftUI

struct ContentView: View {
    @State private var manager = FeedManager()

    var body: some View {
        RootPagerView()
            .environment(manager)
            .environment(LocaleManager.shared)
    }
}
```

- [ ] **Step 5: BUILD.** Expect `** BUILD SUCCEEDED **`. Common fix: `FeedScreen` still reads `@Environment(FeedLoader.self)` — the pager injects it per page, so this is satisfied.

- [ ] **Step 6: RUN and screenshot.** The app shows the main feed full-screen (creation page exists to the right but is a clear stub). Read `/tmp/feedmine_shot.png` — main feed must render identically to before, tinted by the adaptive theme.

- [ ] **Step 7: Commit.**
```bash
git add feedmine/Views/RootPagerView.swift feedmine/ContentView.swift feedmine/feedmineApp.swift feedmine/Views/FeedScreen.swift
git commit -m "feat(feed): root TabView pager + per-page FeedTheme injection"
```

---

### Task 6: `FeedCreationPage` (config form + OK → createFeed)

**Files:**
- Create: `feedmine/Views/FeedCreationPage.swift` (replaces the Task 5 stub — delete the stub in `RootPagerView.swift`)

**Interfaces:**
- Consumes: `FeedManager`, `SourceManagementView`, `FilterSheetView`/`CategoryFilterBar`/`MoodFilterBar`, `nextFreeFamily`
- Produces: `struct FeedCreationPage: View`

**Design note:** creation reuses **existing** config components. The new feed's config is applied by (a) creating the feed (Task 4 gives it a fresh DB where all sources start from OPML defaults) and (b) letting the user immediately edit toggles/filters via the same in-feed controls. For v1, the creation form collects **name** + a **source scope** choice and the **view filters**, then calls `createFeed`; the freshly created feed opens on its own controls for finer editing. This keeps the task shippable without inventing a parallel config engine.

- [ ] **Step 1: Remove the temporary `FeedCreationPage` stub** from `RootPagerView.swift` (the `struct FeedCreationPage: View { var body: some View { Color.clear } }` line).

- [ ] **Step 2: Create `FeedCreationPage.swift`.**

```swift
import SwiftUI

/// The blank "new feed" page at the right edge of the pager. Shows the feed's
/// future color (next free palette) as a preview, collects an optional name,
/// and on OK creates the feed and jumps into it. Draft is cleared on disappear.
struct FeedCreationPage: View {
    @Environment(FeedManager.self) private var manager
    @State private var name: String = ""

    private var previewFamily: PaletteFamily? { manager.nextFreeFamily }
    private var previewAccent: Color {
        guard let f = previewFamily else { return .gray }
        return f.accent(for: CircadianEngine.shared.period)
    }

    var body: some View {
        ZStack {
            (previewFamily?.pageTint(for: CircadianEngine.shared.period) ?? Color(hex: "#FAF8F5"))
                .ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 56)).foregroundStyle(previewAccent)
                Text("New Feed").font(.title2.bold())
                Text("A fresh, independent feed with its own sources and color.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 40)

                TextField("Feed name (optional)", text: $name)
                    .textFieldStyle(.roundedBorder).padding(.horizontal, 40)

                Button {
                    let index = manager.createFeed(name: name)
                    manager.setActive(index)   // jump into the new feed
                } label: {
                    Text("Create Feed").font(.headline)
                        .frame(maxWidth: .infinity).padding()
                        .background(previewAccent, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 40)
                .disabled(previewFamily == nil)
                Spacer()
            }
        }
        .onDisappear { name = "" }   // clear draft on exit
    }
}
```

- [ ] **Step 3: BUILD.** Expect `** BUILD SUCCEEDED **`.

- [ ] **Step 4: RUN — create a second feed.** After launch, drive the sim to swipe left to the creation page and tap Create (or, faster, temporarily add `manager.createFeed(name: "Test")` behind a DEBUG button). Screenshot: the app should jump into a second feed whose accent differs from the main (e.g. main warmEarth coral → second coolSky blue). Read `/tmp/feedmine_shot.png` and confirm the accent color changed.

- [ ] **Step 5: Commit.**
```bash
git add feedmine/Views/FeedCreationPage.swift feedmine/Views/RootPagerView.swift
git commit -m "feat(feed): FeedCreationPage — create a new independent feed"
```

---

### Task 7: `FeedDotsIndicator` (bottom colored dots + trailing "+")

**Files:**
- Create: `feedmine/Views/FeedDotsIndicator.swift` (replaces the Task 5 stub — delete the stub in `RootPagerView.swift`)

**Interfaces:**
- Consumes: `FeedManager`, `nextFreeFamily`, `theme(for:)`
- Produces: `struct FeedDotsIndicator: View`

- [ ] **Step 1: Remove the temporary `FeedDotsIndicator` stub** from `RootPagerView.swift`.

- [ ] **Step 2: Create `FeedDotsIndicator.swift`.**

```swift
import SwiftUI

/// Floating page indicator at the bottom (above the mini-player). One colored dot
/// per feed in that feed's accent; the active dot is larger/filled. When more feeds
/// can be created, a trailing "+" dot (in the next free color) marks the creation page.
struct FeedDotsIndicator: View {
    @Environment(FeedManager.self) private var manager

    private var creationIndex: Int? { manager.canCreateMore ? manager.feeds.count : nil }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(manager.feeds.enumerated()), id: \.element.id) { index, instance in
                Circle()
                    .fill(manager.theme(for: instance.descriptor).accent)
                    .frame(width: index == manager.activeIndex ? 10 : 7,
                           height: index == manager.activeIndex ? 10 : 7)
                    .opacity(index == manager.activeIndex ? 1 : 0.45)
                    .onTapGesture { withAnimation { manager.setActive(index) } }
            }
            if let creationIndex {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle((manager.nextFreeFamily?.accent(for: CircadianEngine.shared.period) ?? .gray))
                    .opacity(manager.activeIndex == creationIndex ? 1 : 0.5)
                    .onTapGesture { withAnimation { manager.setActive(creationIndex) } }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 96)   // clear the mini-player bar
    }
}
```

- [ ] **Step 3: BUILD + RUN + screenshot.** With ≥2 feeds, confirm the dot strip shows near the bottom, active dot larger, and a "+" trailing dot. Read `/tmp/feedmine_shot.png`.

- [ ] **Step 4: Commit.**
```bash
git add feedmine/Views/FeedDotsIndicator.swift feedmine/Views/RootPagerView.swift
git commit -m "feat(feed): bottom colored-dot page indicator with creation +"
```

---

## Phase 3 — Delete, palette safety, warm-up

### Task 8: Delete a feed + palette picker excludes occupied families

**Files:**
- Modify: `feedmine/Views/SettingsSheetView.swift`

**Interfaces:**
- Consumes: `FeedManager`, `deleteFeed(id:)`, `occupiedFamilies(excludingSecondary:)`
- Produces: (UI only)

- [ ] **Step 1: Inject `FeedManager` + current feed id into `SettingsSheetView`.**

Add near the top `@Environment` block (line ~4):
```swift
@Environment(FeedManager.self) private var feedManager
@Environment(FeedLoader.self) private var loader   // already present
```
Add a computed current descriptor (the settings sheet belongs to the active feed):
```swift
private var currentFeed: FeedManager.FeedInstance? {
    feedManager.feeds.indices.contains(feedManager.activeIndex)
        ? feedManager.feeds[feedManager.activeIndex] : nil
}
private var isSecondaryFeed: Bool { (currentFeed?.descriptor.isMain == false) }
```

- [ ] **Step 2: Add a destructive "Delete this feed" section (secondary only).**

Insert a new `Section` before the closing `Form` (e.g. just before the "Feedback" footer section, ~line 238):
```swift
if isSecondaryFeed, let id = currentFeed?.descriptor.id {
    Section {
        Button(role: .destructive) {
            showDeleteFeedConfirmation = true
        } label: {
            Label("Delete This Feed", systemImage: "trash")
        }
    } footer: {
        Text("Removes this feed, its sources, and all its saved items. This cannot be undone.")
    }
    .confirmationDialog("Delete this feed?", isPresented: $showDeleteFeedConfirmation, titleVisibility: .visible) {
        Button("Delete Feed", role: .destructive) { feedManager.deleteFeed(id: id) }
        Button("Cancel", role: .cancel) { }
    }
}
```
Add the state var with the others (~line 15): `@State private var showDeleteFeedConfirmation = false`.

- [ ] **Step 3: Exclude occupied families from the main's palette picker.**

In `palettePickerSheet`, change the `ForEach(PaletteFamily.allCases, ...)` (line ~267) to exclude families used by **secondary** feeds (so the main never collides), keeping the currently-selected one visible:
```swift
private var selectablePaletteFamilies: [PaletteFamily] {
    let occupiedBySecondaries = feedManager.occupiedFamilies(excludingSecondary: FeedDescriptor.mainID)
        .subtracting([selectedPalette])
    return PaletteFamily.allCases.filter { !occupiedBySecondaries.contains($0) }
}
```
Then: `ForEach(selectablePaletteFamilies, id: \.rawValue) { family in ... }`.

*(Note: `occupiedFamilies(excludingSecondary: FeedDescriptor.mainID)` returns only secondary families because the main is excluded from the tally when its own id is passed — the main's family should not exclude itself.)*

- [ ] **Step 4: BUILD.** Expect `** BUILD SUCCEEDED **`.

- [ ] **Step 5: RUN — delete the second feed.** Open the second feed's settings, tap Delete This Feed, confirm. Screenshot: pager slides back to the main; the dot strip shows one dot + "+". Read `/tmp/feedmine_shot.png`. Verify the deleted DB file is gone:
```bash
ls "$HOME/Library/Developer/CoreSimulator/Devices/"*/data/Containers/Data/Application/*/Documents/ 2>/dev/null | grep feedmine_ || echo "checked"
```

- [ ] **Step 6: Commit.**
```bash
git add feedmine/Views/SettingsSheetView.swift
git commit -m "feat(feed): delete secondary feed + palette picker excludes occupied families"
```

---

### Task 9: Serial startup warm-up + background refresh coordination

**Files:**
- Modify: `feedmine/Services/FeedManager.swift`
- Modify: `feedmine/Views/RootPagerView.swift` (drive warm-up on appear + scenePhase)
- Modify: `feedmine/Services/FeedLoader.swift` (add `warmUp()` = `start()` alias if needed; add lightweight `backgroundRefresh()`)

**Interfaces:**
- Consumes: `FeedLoader.start()`, `FeedLoader.refreshIfStale()`
- Produces:
  - `FeedManager.startWarmUp()` — serial, active feed first, others queued by order
  - `FeedManager.onActiveChanged()` — refresh newly active if stale
  - `FeedManager.scheduleBackgroundRefresh()` — single-queue periodic refresh of inactive feeds
  - `FeedLoader.backgroundRefresh() async` — light refresh (no image prefetch, no load-more)

- [ ] **Step 1: Add a light background refresh to `FeedLoader`.**

In `FeedLoader.swift`, add:
```swift
/// Light refresh for inactive feeds — pulls new items to accumulate What's New,
/// without heavy image prefetch or load-more. Delegates to the store's stale refresh.
func backgroundRefresh() async {
    await store.refreshIfStale()
    await loadWhatsNew()
}
```

- [ ] **Step 2: Add warm-up + background coordination to `FeedManager`.**

```swift
// MARK: - Warm-up & background refresh

private var warmedUp = false
private var backgroundTask: Task<Void, Never>?
private let backgroundInterval: UInt64 = 15 * 60 * 1_000_000_000  // 15 min in ns

/// Cold start: warm the active feed fully first, then the rest one at a time in order.
/// Serial by design — 5 concurrent RSS fetches saturate network/CPU.
func startWarmUp() async {
    guard !warmedUp else { return }
    warmedUp = true
    guard !feeds.isEmpty else { return }

    let activeFirst = [feeds[activeIndex]] + feeds.enumerated()
        .filter { $0.offset != activeIndex }.map(\.element)
    for instance in activeFirst {
        await instance.loader.start()
    }
    scheduleBackgroundRefresh()
}

/// Single-queue periodic light refresh for inactive feeds only.
func scheduleBackgroundRefresh() {
    backgroundTask?.cancel()
    backgroundTask = Task { [weak self] in
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: self?.backgroundInterval ?? .max)
            guard let self, !Task.isCancelled else { return }
            for (i, instance) in self.feeds.enumerated() where i != self.activeIndex {
                if Task.isCancelled { return }
                await instance.loader.backgroundRefresh()   // one at a time
            }
        }
    }
}

/// Called when the user swipes to a different feed.
func onActiveChanged() {
    guard feeds.indices.contains(activeIndex) else { return }
    let loader = feeds[activeIndex].loader
    Task { await loader.refreshIfStale() }
}

func stopBackgroundRefresh() { backgroundTask?.cancel(); backgroundTask = nil }
```

- [ ] **Step 3: Drive warm-up + active-change from `RootPagerView`.**

Add to `RootPagerView`'s `body` view (e.g. on the `TabView`):
```swift
.task { await manager.startWarmUp() }
.onChange(of: manager.activeIndex) { _, _ in manager.onActiveChanged() }
```

- [ ] **Step 4: BUILD.** Expect `** BUILD SUCCEEDED **`. Fix strict-concurrency: the `Task { [weak self] ... }` runs on the `@MainActor` (class is `@MainActor`), so `self.feeds` access is safe.

- [ ] **Step 5: RUN with two feeds.** Launch; the active (main) feed populates first, then swipe to the second — it should already be warming or warmed. Screenshot both. Read `/tmp/feedmine_shot.png`. Confirm the second feed shows content (or a skeleton that resolves) without blocking the first.

- [ ] **Step 6: Commit.**
```bash
git add feedmine/Services/FeedManager.swift feedmine/Views/RootPagerView.swift feedmine/Services/FeedLoader.swift
git commit -m "feat(feed): serial startup warm-up + background refresh for inactive feeds"
```

---

## Phase 4 — Polish & edge cases

### Task 10: Feed name in header, sub-view theming, and edge-case hardening

**Files:**
- Modify: `feedmine/Views/FeedScreen.swift` (feed name in compact header; thread theme into sub-views at 491/523/554/585)

**Interfaces:**
- Consumes: `FeedTheme`, `FeedManager` (for the active descriptor's name)
- Produces: (UI only)

- [ ] **Step 1: Show the optional feed name in the compact header.**

In `FeedScreen`'s `compactHeader`, add the current feed's name when non-nil. Read it via a new environment value or pass it through the theme — simplest: add `@Environment(FeedManager.self) private var feedManager` and:
```swift
private var feedName: String? {
    feedManager.feeds.indices.contains(feedManager.activeIndex)
        ? feedManager.feeds[feedManager.activeIndex].descriptor.name : nil
}
```
Render `feedName` (if any) as a small title tinted `feedTheme.accent` in the compact header row.

- [ ] **Step 2: Thread the theme into the decorative sub-views.**

For the sub-views at lines ~491/523/554/585 that use `@State private var engine = CircadianEngine.shared` for `engine.accent`, add `@Environment(\.feedTheme) private var feedTheme` and replace their `engine.accent` reads with `feedTheme.accent` (keep `engine.font/cardGap/cardRadius` as-is). This makes skeletons/decor match the feed's color.

- [ ] **Step 3: Confirm edge cases (manual verification on sim).**
  - **Delete active feed** → pager slides to neighbor before removal (already handled in `deleteFeed`). Verify no crash.
  - **5 feeds** → creation page and "+" disappear; swipe only cycles the 5. Create feeds until 5, screenshot: no "+" dot.
  - **Corrupt index** → temporarily set a bad `feeds_index` via a DEBUG hook and confirm fallback to main-only (or reason about `loadIndex` returning `[.main()]`).
  - **Audio across feeds** → start a podcast in feed A, swipe to feed B; the mini-player keeps playing (global `AudioPlayerManager.shared`). Screenshot the mini-player visible on feed B.

- [ ] **Step 4: BUILD + RUN + screenshot each edge case above.** Read `/tmp/feedmine_shot.png` after each.

- [ ] **Step 5: Commit.**
```bash
git add feedmine/Views/FeedScreen.swift
git commit -m "feat(feed): feed name in header + themed sub-views + edge-case polish"
```

---

### Task 11: Known-risk check — `.swipeActions` vs page-swipe

**Files:**
- Inspect: `feedmine/Views/FeedItemView.swift:57,74` (list-variant swipe actions)

**Interfaces:** none (verification-only; conditional fix)

- [ ] **Step 1: RUN and test the gesture.** In a feed rendered with the list variant (if reachable — e.g. bookmark box view using `FeedItemView`), attempt a row swipe-to-act (mark read / bookmark) and a full-page swipe. Screenshot both outcomes.

- [ ] **Step 2: Decide.** If row `.swipeActions` and the `TabView` page-swipe coexist (they usually do — page-swipe needs a broad horizontal drag, `.swipeActions` starts on the row), **no change**; note it in the commit. If they conflict (page flips when the user tries to reveal a row action), apply the fallback: convert the two `.swipeActions` in `FeedItemView.swift` (lines 57, 74) to a `.contextMenu` with the same actions.

- [ ] **Step 3: Commit (only if a change was made).**
```bash
git add feedmine/Views/FeedItemView.swift
git commit -m "fix(feed): resolve list swipe-action vs page-swipe conflict"
```
If no change: record the finding in the PR description instead.

---

## Self-Review (completed during authoring)

**Spec coverage:**
- Max 5 / distinct palettes → Tasks 4 (`firstFreeFamily`, `canCreateMore`), 8 (picker exclusion). ✓
- Per-feed DB + settings isolation → Task 1 (per-feed dbPath + injected `UserDefaults` suite). ✓
- No migration → Task 1 uses fresh per-id DB; `loadIndex` falls back to main-only. ✓
- Palette assignment (main adaptive occupies; secondaries fixed) → Tasks 3 (`FeedTheme`), 4 (`occupiedFamilies`/`theme`). ✓
- Inline creation page + jump-in + clear draft → Task 6. ✓
- Delete via own settings; main permanent → Task 8 (`isSecondaryFeed` gate; `deleteFeed` guards `isMain`). ✓
- Serial warm-up (active first) + single-queue background refresh → Task 9. ✓
- Full-screen paging + bottom colored dots + trailing "+" → Tasks 5, 7. ✓
- Global audio persists across tabs → unchanged `AudioPlayerManager.shared`; verified in Task 10. ✓
- Known `.swipeActions` risk → Task 11. ✓
- Forward-compat export/import → not implemented (architected: `FeedDescriptor` is `Codable`, `createFeed` is the single creation entry point). ✓ (out of scope, no task — correct.)

**Placeholder scan:** the only intentional temporary code (Task 5 stubs, Task 4 `createdAt` note) is explicitly replaced/annotated. No `TODO`/`TBD` left in shipped code.

**Type consistency:** `FeedDescriptor.mainID`, `FeedStore.mainID` (aliases it), `firstFreeFamily(excluding:)`, `occupiedFamilies(excludingSecondary:)`, `theme(for:)`, `createFeed(name:)`, `deleteFeed(id:)`, `FeedTheme(family:)`, `EnvironmentValues.feedTheme`, `backgroundRefresh()` — used consistently across tasks. ✓

**Spec refinement noted:** the spec's Section 2 said filters/toggles move to an `app_settings_<id>` key; the real codebase uses scattered raw `UserDefaults.standard` keys, so the plan isolates them via a per-feed `UserDefaults(suiteName:)` instead — same outcome (per-feed isolation), cleaner mechanism. The spec's intent is preserved.
