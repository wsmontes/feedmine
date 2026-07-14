# Filter Pipeline Fix — Missing applyFilters Calls

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the feed filtering pipeline so disabled sources/regions are consistently excluded from the visible feed at every code path — `.append` (scroll), `.trim` (buffer management), `emergencyTrim` (memory pressure), and `toggleAllCountries` (bulk country toggle).

**Architecture:** The root cause is that `applyFilters()` — the single source of truth for in-memory item filtering — is called inconsistently across `applyUpdate` pipeline cases. `.refresh` calls it; `.append` and `.trim` do not. `emergencyTrim` and `toggleAllCountries` bypass the pipeline entirely. The fix adds the missing `applyFilters` call to each code path and gives `toggleAllCountries` a proper `FeedStore`-level method that flushes and reloads like `toggleRegion` does.

**Tech Stack:** Swift 6, GRDB, @Observable (no TCA)

## Global Constraints

- Feed is sacred: never move content under a scrolling user
- `applyFilters` is the single source of truth for in-memory filtering
- All `visibleItems` assignments must route through `applyFilters`
- `FeedStore` owns all filtering state; `FeedLoader` delegates to it
- No new dependencies; no API changes to `FeedLoader`

---

### Task 1: Fix `.append` to call `applyFilters`

**Files:**
- Modify: `feedmine/Services/FeedStore.swift:363-373`

**Interfaces:**
- Consumes: `applyFilters(_:) -> [FeedItem]` (existing, line 107)
- Produces: (same — fixes the `.append` case in `applyUpdate`)

- [ ] **Step 1: Verify the current bug with a code-level trace**

The `.append` case at line 370 reads:
```swift
self.visibleItems = self.reservoir.visibleItems
```
The `.refresh` case at line 381 reads:
```swift
self.visibleItems = self.applyFilters(self.reservoir.visibleItems)
```
Confirm `.append` is the only `visibleItems` assignment in the `applyUpdate` switch that moves items from reservoir to visible without filtering.

- [ ] **Step 2: Apply the fix**

In `feedmine/Services/FeedStore.swift`, change line 370 from:
```swift
self.visibleItems = self.reservoir.visibleItems
```
to:
```swift
self.visibleItems = self.applyFilters(self.reservoir.visibleItems)
```

The full corrected `.append` case (lines 363-373) becomes:
```swift
case .append:
    let prev = pipelineTask
    pipelineTask = Task { [weak self] in
        await prev?.value
        guard !Task.isCancelled, let self else { return }
        self.reservoir.moveToVisible(count: Reservoir.pageSize)
        self.markSurfaced(self.reservoir.visibleItems)
        self.visibleItems = self.applyFilters(self.reservoir.visibleItems)
        self.reservoirCount = self.reservoir.reservoirCount
        self.prefetchVisibleAndNext()
    }
```

- [ ] **Step 3: Build to verify compilation**

Run: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add feedmine/Services/FeedStore.swift
git commit -m "fix: .append path now calls applyFilters before assigning visibleItems

The .append case in applyUpdate (scrolling pagination) was moving items
from reservoir to visibleItems without filtering, so disabled sources and
regions appeared on every page after the first. Now consistent with the
.refresh case which already called applyFilters.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Fix `.trim` and `emergencyTrim` — same missing `applyFilters`

**Files:**
- Modify: `feedmine/Services/FeedStore.swift:385-393` (`.trim` case)
- Modify: `feedmine/Services/FeedStore.swift:1555-1559` (`emergencyTrim`)

**Interfaces:**
- Consumes: `applyFilters(_:) -> [FeedItem]` (existing, line 107)
- Produces: (same — fixes two more paths that bypass filtering)

- [ ] **Step 1: Fix `.trim` case**

In `feedmine/Services/FeedStore.swift`, change line 391 from:
```swift
self.visibleItems = self.reservoir.visibleItems
```
to:
```swift
self.visibleItems = self.applyFilters(self.reservoir.visibleItems)
```

The corrected `.trim` case (lines 385-393):
```swift
case .trim(let idx):
    let prev = pipelineTask
    pipelineTask = Task { [weak self] in
        await prev?.value
        guard !Task.isCancelled, let self else { return }
        self.reservoir.trimBuffer(currentVisibleIndex: idx)
        self.visibleItems = self.applyFilters(self.reservoir.visibleItems)
        self.reservoirCount = self.reservoir.reservoirCount
    }
```

- [ ] **Step 2: Fix `emergencyTrim`**

In `feedmine/Services/FeedStore.swift`, change line 1557 from:
```swift
visibleItems = reservoir.visibleItems
```
to:
```swift
visibleItems = applyFilters(reservoir.visibleItems)
```

The corrected `emergencyTrim` (lines 1555-1559):
```swift
func emergencyTrim() {
    reservoir.emergencyTrim()
    visibleItems = applyFilters(reservoir.visibleItems)
    reservoirCount = reservoir.reservoirCount
}
```

- [ ] **Step 3: Build to verify compilation**

Run: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add feedmine/Services/FeedStore.swift
git commit -m "fix: .trim and emergencyTrim now call applyFilters before assigning visibleItems

Same defect as .append — both paths assigned reservoir.visibleItems
directly without filtering, bypassing isItemEnabled, content-type,
category, and mood checks. All visibleItems assignments now route
through applyFilters.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Fix `toggleAllCountries` — give it a `FeedStore`-level reload like `toggleRegion`

**Files:**
- Modify: `feedmine/Services/FeedStore.swift` (add method)
- Modify: `feedmine/Services/FeedLoader.swift:450-454`

**Interfaces:**
- Produces: `FeedStore.toggleAllCountries()` — new method
- Consumes: `applyUpdate(.flush())`, `resetWhatsNewBaseline()`, `refreshWhatsNew()` (all existing)
- Modifies: `FeedLoader.toggleAllCountries()` — delegates to new store method

- [ ] **Step 1: Add `toggleAllCountries` method to `FeedStore`**

Insert after `toggleRegion` (after line 1179 in `FeedStore.swift`):

```swift
func toggleAllCountries() {
    let wasAnyOn = registry.isAnyCountryEnabled
    registry.toggleAllCountries()
    if wasAnyOn {
        // Disabling all countries — purge their items from the reservoir
        // and all visible items. Unlike individual toggleRegion, this
        // affects every country at once, so a full flush is appropriate.
        let countryRegions = registry.sources
            .filter { $0.isCountryFeed }
            .map { $0.region }
        for region in Set(countryRegions) {
            reservoir.removeRegion(region)
        }
        applyUpdate(.replace(applyFilters(reservoir.visibleItems)))
    } else {
        // Enabling all countries — flush and reload from SQLite so
        // country content appears immediately.
        resetWhatsNewBaseline()
        refreshWhatsNew()
        applyUpdate(.flush())
    }
    reservoirCount = reservoir.reservoirCount
}
```

- [ ] **Step 2: Update `FeedLoader.toggleAllCountries` to delegate**

In `feedmine/Services/FeedLoader.swift`, change lines 450-454 from:
```swift
func toggleAllCountries() {
    store.registry.toggleAllCountries()
    store.resetWhatsNewBaseline()
    Task { await loadWhatsNew() }
}
```
to:
```swift
func toggleAllCountries() {
    store.toggleAllCountries()
    Task { await loadWhatsNew() }
}
```

- [ ] **Step 3: Build to verify compilation**

Run: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add feedmine/Services/FeedStore.swift feedmine/Services/FeedLoader.swift
git commit -m "fix: toggleAllCountries now reloads feed via FeedStore pipeline

Previously toggleAllCountries only mutated SourceRegistry.disabled
without flushing the reservoir or reloading visibleItems. Country items
stayed on screen until the next manual refresh. Now mirrors toggleRegion's
flush-and-reload pattern: disabling all countries purges their items;
enabling them triggers a fresh SQLite reload.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: Pre-filter reservoir during seeding in `reloadFromSQLite`

**Files:**
- Modify: `feedmine/Services/FeedStore.swift:1081-1098`

**Interfaces:**
- Consumes: `applyFilters(_:) -> [FeedItem]` (existing, line 107)
- Produces: `reloadFromSQLite` now seeds reservoir with pre-filtered items

- [ ] **Step 1: Filter items before seeding the reservoir**

Currently `reloadFromSQLite` at lines 1081-1098 seeds ALL items into the reservoir, then only filters the first page. Change it to pre-filter all items before seeding, so the reservoir never contains items that would be filtered out.

In `feedmine/Services/FeedStore.swift`, replace lines 1081-1098:

**Before:**
```swift
var feedItems = items.map { $0.toFeedItem() }
// Prepend seed items at the top so newly enabled region appears first
if !prepend.isEmpty {
    feedItems = prepend + feedItems
}
// Register all loaded IDs to prevent re-fetch duplicates
for item in feedItems { loadedIDs.insert(item.id) }
reservoir.seed(items: feedItems)
markSurfaced(reservoir.visibleItems)
visibleItems = applyFilters(reservoir.visibleItems)
// If the active filter (e.g. Podcasts) removed all seeded visible items,
// pull more from the reservoir so the screen isn't empty.
if visibleItems.count < Reservoir.pageSize && reservoir.reservoirCount > 0 {
    repeat {
        reservoir.moveToVisible(count: Reservoir.pageSize)
        visibleItems = applyFilters(reservoir.visibleItems)
    } while visibleItems.count < Reservoir.pageSize && reservoir.reservoirCount > 0
}
reservoirCount = reservoir.reservoirCount
```

**After:**
```swift
var feedItems = items.map { $0.toFeedItem() }
// Prepend seed items at the top so newly enabled region appears first
if !prepend.isEmpty {
    feedItems = prepend + feedItems
}
// Register all loaded IDs to prevent re-fetch duplicates
for item in feedItems { loadedIDs.insert(item.id) }
// Pre-filter before seeding so the reservoir never holds items that
// would be filtered out. This prevents the reservoir from becoming a
// trove of disabled-source items that leak through on .append/.trim
// (even after Task 1-2 fixes, this avoids wasted memory and ensures
// consistent reservoirCount).
let filteredItems = applyFilters(feedItems)
reservoir.seed(items: filteredItems)
// markSurfaced runs on reservoir.visibleItems AFTER seed, so only
// items that actually appear on screen are recorded as surfaced.
markSurfaced(reservoir.visibleItems)
visibleItems = reservoir.visibleItems  // already filtered — no double-filter needed
// If the active filter (e.g. Podcasts) removed all seeded items,
// pull more from the reservoir so the screen isn't empty.
// (This loop is now a safety net — the reservoir is pre-filtered,
// but edge cases like very restrictive mood filters may still
// produce an empty first page.)
if visibleItems.count < Reservoir.pageSize && reservoir.reservoirCount > 0 {
    repeat {
        reservoir.moveToVisible(count: Reservoir.pageSize)
        visibleItems = applyFilters(reservoir.visibleItems)
    } while visibleItems.count < Reservoir.pageSize && reservoir.reservoirCount > 0
}
reservoirCount = reservoir.reservoirCount
```

**Key change:** `applyFilters` is called on ALL `feedItems` before `reservoir.seed()`. Since the items entering the reservoir are already filtered, `visibleItems` doesn't need double-filtering inside `reloadFromSQLite` (`.append` and `.trim` still call `applyFilters` for defense-in-depth, per Tasks 1-2).

- [ ] **Step 2: Apply the same pre-filtering to `loadReservoir` (cold-start path)**

In `feedmine/Services/FeedStore.swift`, replace lines 266-283 in `start()`:

**Before:**
```swift
let cached = try? await loadReservoir()
if let items = cached, !items.isEmpty {
    for item in items { loadedIDs.insert(item.id) }
    loadedIDsCount = loadedIDs.count
    reservoir.seed(items: items)
    markSurfaced(reservoir.visibleItems)
    visibleItems = applyFilters(reservoir.visibleItems)
    if visibleItems.count < Reservoir.pageSize && reservoir.reservoirCount > 0 {
        repeat {
            reservoir.moveToVisible(count: Reservoir.pageSize)
            visibleItems = applyFilters(reservoir.visibleItems)
        } while visibleItems.count < Reservoir.pageSize && reservoir.reservoirCount > 0
    }
    reservoirCount = reservoir.reservoirCount
    loadingState = .idle
    prefetchVisibleAndNext()
}
```

**After:**
```swift
let cached = try? await loadReservoir()
if let items = cached, !items.isEmpty {
    for item in items { loadedIDs.insert(item.id) }
    loadedIDsCount = loadedIDs.count
    // Pre-filter before seeding — same pattern as reloadFromSQLite.
    let filteredItems = applyFilters(items)
    reservoir.seed(items: filteredItems)
    markSurfaced(reservoir.visibleItems)
    visibleItems = reservoir.visibleItems  // already filtered
    if visibleItems.count < Reservoir.pageSize && reservoir.reservoirCount > 0 {
        repeat {
            reservoir.moveToVisible(count: Reservoir.pageSize)
            visibleItems = applyFilters(reservoir.visibleItems)
        } while visibleItems.count < Reservoir.pageSize && reservoir.reservoirCount > 0
    }
    reservoirCount = reservoir.reservoirCount
    loadingState = .idle
    prefetchVisibleAndNext()
}
```

- [ ] **Step 3: Build to verify compilation**

Run: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add feedmine/Services/FeedStore.swift
git commit -m "fix: pre-filter reservoir during seeding in reloadFromSQLite and loadReservoir

Previously both paths seeded the reservoir with ALL items from SQLite
and only filtered the first visible page. The remaining items (180+
in reload, 380+ in cold-start) stayed unfiltered in the reservoir.
Now applyFilters runs on the full item set before seed(), so the
reservoir never holds items from disabled sources/regions.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: End-to-end verification

**Files:**
- No new files. Verify the fix chain by tracing the full user scenario.

- [ ] **Step 1: Trace the "Angola only" scenario through the fixed code**

Scenario: User disables "All Countries" + "Selected Feeds" (global), then enables "Angola".

1. `toggleAllCountries()` → now calls `store.toggleAllCountries()` (Task 3) → `applyUpdate(.flush())` → `reloadFromSQLite()` → pre-filters via `applyFilters` (Task 4) → only items from enabled Angola sources survive
2. `toggleRegion("countries/angola")` → enables Angola in registry → reloads from SQLite → pre-filters (Task 4) → Angola items appear
3. User scrolls → `loadMoreIfNeeded` → `.append` → `applyFilters` called (Task 1) → no disabled items leak through
4. Background fetch runs → `progressiveFetch` adds items → they pass through `registry.enabledSources` (Angola only) → reservoir gets Angola-only items → `.append` calls `applyFilters` (Task 1) → consistent filtering

- [ ] **Step 2: Verify there are no remaining `visibleItems = reservoir.visibleItems` without `applyFilters`**

Run: `grep -n "visibleItems = reservoir.visibleItems" feedmine/Services/FeedStore.swift`
Expected: Only one match at line 1097 (inside the already-filtered `reloadFromSQLite` where `visibleItems` was set from a pre-filtered reservoir, and the top-up loop explicitly calls `applyFilters` on line 1096).

Actually, after Task 4, the `visibleItems = reservoir.visibleItems` on the line equivalent to old-1090 is intentional — items are pre-filtered before seeding. There may also be a reference inside the filter-top-up loop. Count them and verify each is justified.

- [ ] **Step 3: Build and run the app**

```bash
xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

Then launch in simulator and verify:
1. App launches with default filters (countries off, global on) → see global feeds
2. Disable "Selected Feeds" → global feeds disappear
3. Enable "Angola" → Angola feeds appear
4. Scroll through 3+ pages → only Angola feeds visible
5. Wait 3 minutes for background refresh → still only Angola feeds
6. Trigger memory warning (Simulator → Debug → Simulate Memory Warning) → verify `emergencyTrim` preserves filtering

- [ ] **Step 4: Commit**

```bash
git commit --allow-empty -m "verify: end-to-end filter pipeline audit after fixes

All visibleItems assignments now route through applyFilters.
Reservoir is pre-filtered during seeding.
toggleAllCountries reloads via the FeedStore pipeline.

Co-Authored-By: Claude <noreply@anthropic.com>"
```
