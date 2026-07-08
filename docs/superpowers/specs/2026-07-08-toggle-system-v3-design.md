# Toggle System v3 — Design

## Model

Single set, three states per node:

```swift
var disabled: Set<String> = []  // only tracks what's explicitly OFF

// Node keys:
"url:https://folha.com/rss"       // feed
"region:countries/brazil"          // country
"region:countries/brazil/alagoas"  // sub-region
"cat:tech"                         // category
```

**Three states per node:**
- ON — not in `disabled`
- OFF — in `disabled`, zero active children
- PARTIAL — in `disabled`, but has ≥1 active child (individual override)

**Resolution (O(1) — 4 Set lookups):**
1. Feed's own key in `disabled`? → OFF
2. Feed's region key in `disabled`? → OFF
3. Feed's country key in `disabled`? → OFF
4. Feed's category key in `disabled`? → OFF
5. Otherwise → ON

---

## SourceRegistry API

```swift
enum NodeStatus: Equatable {
    case on
    case off
    case partial(activeCount: Int)
}

final class SourceRegistry {
    var sources: [FeedSource] = []
    var disabled: Set<String> = []
    private var activeCount: [String: Int] = [:]

    // Key constructors
    static func regionKey(_ path: String) -> String
    static func categoryKey(_ name: String) -> String
    static func sourceKey(_ url: String) -> String

    // Feed resolution — O(1)
    func isSourceEnabled(_ url: String) -> Bool

    // Group status — O(1) from cache
    func status(of key: String) -> NodeStatus

    // Toggle — O(1) toggle + O(n) cache rebuild
    func toggleRegion(_ path: String)
    func toggleCategory(_ name: String)
    func toggleSource(_ url: String)

    // Cache
    private func recomputeActiveCounts()

    // Filtered sources
    var enabledSources: [FeedSource]
}
```

### `isSourceEnabled` — O(1)

```swift
func isSourceEnabled(_ sourceURL: String) -> Bool {
    guard let source = sources.first(where: { $0.url == sourceURL }) else { return false }
    // 1. Feed itself
    if disabled.contains(Self.sourceKey(sourceURL)) { return false }
    // 2. Region (exact, e.g. "countries/brazil/alagoas")
    if disabled.contains(Self.regionKey(source.region)) { return false }
    // 3. Country (parent region, e.g. "countries/brazil")
    let parts = source.region.split(separator: "/").map(String.init)
    if parts.count >= 2, parts[0] == "countries" {
        let countryKey = Self.regionKey(parts.prefix(2).joined(separator: "/"))
        if disabled.contains(countryKey) { return false }
    }
    // 4. Category
    if disabled.contains(Self.categoryKey(source.category)) { return false }
    return true
}
```

### `status(of:)` — O(1) cached

```swift
func status(of key: String) -> NodeStatus {
    if !disabled.contains(key) { return .on }
    let count = activeCount[key] ?? 0
    return count > 0 ? .partial(activeCount: count) : .off
}
```

### Toggle actions

```swift
func toggleRegion(_ region: String) {
    let key = Self.regionKey(region)
    if disabled.contains(key) {
        disabled.remove(key)  // OFF → ON
    } else {
        disabled.insert(key)  // ON → OFF
    }
    recomputeActiveCounts()
}

func toggleCategory(_ category: String) {
    let key = Self.categoryKey(category)
    if disabled.contains(key) {
        disabled.remove(key)
    } else {
        disabled.insert(key)
    }
    recomputeActiveCounts()
}

func toggleSource(_ sourceURL: String) {
    let key = Self.sourceKey(sourceURL)
    if disabled.contains(key) {
        disabled.remove(key)  // OFF → ON
    } else {
        disabled.insert(key)  // ON → OFF
    }
    recomputeActiveCounts()
}
```

### `recomputeActiveCounts` — O(n)

```swift
private func recomputeActiveCounts() {
    activeCount.removeAll()
    for source in sources where isSourceEnabled(source.url) {
        // Count under the source's region
        activeCount[Self.regionKey(source.region), default: 0] += 1
        // Count under the country (parent of region)
        let parts = source.region.split(separator: "/").map(String.init)
        if parts.count >= 2, parts[0] == "countries" {
            activeCount[Self.regionKey(parts.prefix(2).joined(separator: "/")), default: 0] += 1
        }
        // Count under the category
        activeCount[Self.categoryKey(source.category), default: 0] += 1
    }
}
```

---

## Persistence

`disabled` set persisted to UserDefaults as string array:

```swift
private func saveState() {
    UserDefaults.standard.set(Array(disabled), forKey: "toggleDisabled")
}

func loadState() {
    if let arr = UserDefaults.standard.stringArray(forKey: "toggleDisabled") {
        disabled = Set(arr)
    }
}
```

Called in `loadFromOPML()` after parsing.

---

## FeedStore changes

- `isItemRegionEnabled` → `registry.isSourceEnabled(url)`
- `toggleRegion` delegates to `registry.toggleRegion`, then triggers seed+reload
- `toggleSource` delegates to `registry.toggleSource`, then triggers immediate fetch
- `toggleCategory` delegates to `registry.toggleCategory`, then triggers reload
- Remove all old state: `disabledRegions`, `disabledSourceIDs`, `disabledCategories`, `overrideSourceIDs`
- Disabled regions filter removed from SQL queries (in-memory filter via `isItemRegionEnabled` handles it)

---

## FeedLoader changes

- `isRegionEnabled` → `registry.status(of: regionKey) != .off`
- `isCategoryEnabled` → `registry.status(of: categoryKey) != .off`
- `isSourceEnabled` → delegates to registry
- Add `nodeStatus(for key: String) -> NodeStatus` for UI badges
- Add `activeCount(for key: String) -> Int` for badge display

---

## UI

### Toggle connections — each toggle must use the correct bindings:

| View | Toggle | get | set |
|------|--------|-----|-----|
| CountriesListScreen | Global | `loader.isRegionEnabled("global")` | `loader.toggleRegion("global")` |
| CountriesListScreen | País | `loader.isRegionEnabled(country.region)` | `loader.toggleRegion(country.region)` |
| CountryDetailScreen | Sub-região | `loader.isRegionEnabled(region.path)` | `loader.toggleRegion(region.path)` |
| CountryDetailScreen | Feed | `loader.isSourceEnabled(source.url)` | `loader.toggleSource(source.url)` |
| RegionDetailScreen | Feed | `loader.isSourceEnabled(source.url)` | `loader.toggleSource(source.url)` |
| SourceManagementView | Categoria | `loader.isCategoryEnabled(category)` | `loader.toggleCategory(category)` |
| SourceManagementView | Feed | `loader.isSourceEnabled(source.url)` | `loader.toggleSource(source.url)` |
| FilterSheetView | Global | `loader.isRegionEnabled("global")` | `loader.toggleGlobalFeeds()` |

### Badge display

When a node has PARTIAL status (OFF but with active children), show a badge:

```swift
let status = loader.nodeStatus(for: key)
if case .partial(let count) = status {
    Text("⚡\(count)").font(.caption2).foregroundStyle(.blue)
}
```

---

## Verification checklist

- [ ] Toggle source ON inside disabled region → only that source shows ON
- [ ] Parent region shows PARTIAL badge with correct count
- [ ] Toggle parent ON → all children ON (unless individually OFF)
- [ ] Toggle parent OFF → all children OFF, partial overrides preserved
- [ ] Category toggle OFF → all sources in that category blocked
- [ ] Category toggle ON → all sources in that category unblocked
- [ ] Active counts update immediately after each toggle
- [ ] Persist disabled set across app relaunch
- [ ] enabledSources returns correct set for download
- [ ] No O(n²) or infinite loops — app doesn't freeze
- [ ] Feed content appears/disappears correctly on toggle
