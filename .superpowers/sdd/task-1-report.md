# Task 1 Report: Namespace SourceRegistry and FeedStore by feedID

## Summary

Added `feedID` and injected `UserDefaults` parameters to `FeedStore` and `SourceRegistry`, routed feed-scoped persistence keys through the injected defaults, and threaded parameters through `FeedLoader`. Global keys (`prefetchImages`, `showDebugBar`) remain on `UserDefaults.standard`.

## Changes per file

### feedmine/Services/SourceRegistry.swift
- **Added** `private let defaults: UserDefaults` stored property
- **Added** `init(defaults: UserDefaults = .standard)` initializer
- **Routed through `defaults`** (6 instances of `UserDefaults.standard` to `defaults`):
  - `saveState()`: `toggleDisabled` and `toggleEnabledOverrides` writes
  - `loadState()`: `toggleDisabled` and `toggleEnabledOverrides` reads
  - `loadFromOPML()`: `hasInitializedSourceDefaults` read and write

### feedmine/Services/FeedStore.swift
- **Added** `static let mainID = UUID(uuidString: "00000000-0000-0000-0000-0000000000FE")!` (temporary; moves to FeedDescriptor in Task 2)
- **Added** `let feedID: UUID` and `private let defaults: UserDefaults` stored properties
- **Changed** `let registry = SourceRegistry()` to `let registry: SourceRegistry` (now initialized in init)
- **Replaced** `init()` with `init(feedID: UUID = FeedStore.mainID, defaults: UserDefaults = .standard)`
- **Replaced** `private static var dbPath` with `static func dbPath(for feedID: UUID) -> String` (per-feed DB path: `feedmine_<uuid>.sqlite`)
- **Added** `static func deleteDatabaseFiles(feedID: UUID)` (removes .sqlite, -wal, -shm)
- **Routed through `self.defaults`** (feed-scoped keys):
  - `persistFilters()` / `restoreFilters()`: `filterRegion`, `filterCategory`, `filterContentType`, `filterMood`
  - `start()`: `last_whats_new_seen_at` read (baseline date)
  - `advanceWhatsNewBaseline()` / `resetWhatsNewBaseline()`: `last_whats_new_seen_at` write
  - `performHeavyMaintenance()`: `lastHeavyMaintenance` read/write
  - `migrate()` (static, added `defaults` parameter): `toggleDisabled` / `toggleEnabledOverrides` values extracted before the `@Sendable` closure to avoid Sendable warning
- **Left on `UserDefaults.standard`** (global keys):
  - `prefetchImages` (lines 91, 101)
  - `showDebugBar` (line 877)

### feedmine/Services/FeedLoader.swift
- **Replaced** `init(store: FeedStore? = nil)` with `init(feedID: UUID = FeedStore.mainID, defaults: UserDefaults = .standard, store: FeedStore? = nil)`
- Threads `feedID` and `defaults` through to `FeedStore(feedID:defaults:)`

## Build Verification

```
** BUILD SUCCEEDED **
```

Only one error encountered during development: `capture of 'defaults' with non-Sendable type 'UserDefaults' in a '@Sendable' closure` in the migration closure. Fixed by extracting array values before the closure instead of capturing `UserDefaults` directly.

## Run Verification

App launched on iPhone 14 Plus simulator (iOS 18.0). Feed renders with content (screenshot at `/tmp/feedmine_task1.png`).

## Self-Review Findings

1. **Sendable**: The `UserDefaults` in `@Sendable` closure issue was the only strict-concurrency error. Fixed cleanly.
2. **Key correctness**: All 6 `SourceRegistry` and all feed-scoped `FeedStore` `UserDefaults.standard` usages routed. Cross-checked `prefetchImages` (2 sites) and `showDebugBar` (1 site) remain on `.standard`.
3. **Backward compatibility**: All new parameters have default values, so existing callers (`FeedLoader()`, `FeedStore()`, `SourceRegistry()`) continue to compile unchanged.
4. **DB file change**: The SQLite file is now `feedmine_<mainID>.sqlite` instead of `feedmine.sqlite`. Fresh database on first launch.
5. **No test target**: Verification was build + app launch.

## Concerns

- The old `feedmine.sqlite` is abandoned in place. A future task should delete it on first launch of the new build.
- The `migrate` static function now takes a `defaults` parameter used only for the `v5_source_toggle` migration (copying toggle state into SQLite). Slightly asymmetric but harmless.

## Files Changed

```
feedmine/Services/SourceRegistry.swift
feedmine/Services/FeedStore.swift
feedmine/Services/FeedLoader.swift
```

## Commit

```
8073ce1 refactor(feed): namespace FeedStore/SourceRegistry by feedID + injected UserDefaults
```
