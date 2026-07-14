# Plan: Code Review Fixes (2026-07-13)

**Branch:** `fix/filter-pipeline-applyFilters`
**Base:** `main`
**Source:** Code review at max effort — 10 angles × 8 candidates → 11 verified findings

## Global Constraints

- All changes on `fix/filter-pipeline-applyFilters` branch
- Build must succeed after each task: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 14 Plus' build 2>&1 | tail -5`
- Commit per task with descriptive message
- No regressions to existing behavior
- Follow existing code patterns (same error handling style, same comment density)

---

## Task 1: Fix FeedStore crash risks (fatalError + migration gaps)

**Files:** `feedmine/Services/FeedLoader.swift`, `feedmine/Services/FeedStore.swift`

### 1a — Remove reintroduced fatalError (FeedLoader.swift ~line 385-392)

Commit `de5661e` correctly removed the fatalError by doing `(try? FeedStore(inMemory: true)) ?? FeedStore.empty()`. The working tree changes restructured this into an if/else block but re-added the fatalError in the else branch. `FeedStore.empty()` at line 390 is `try? FeedStore(inMemory: true)` — the same operation that already failed at line 382 — making it dead code that falls through to fatalError.

**Fix:** Remove the else branch. After the in-memory fallback fails, set `self.store = FeedStore.empty()` (which returns `FeedStore?`). If nil, leave `initError` set and let the app surface the error. Do NOT call fatalError.

Before (lines 385-392):
```swift
                } else {
                    // Both file-backed and in-memory init failed.
                    // FeedStore.empty() wraps try? so it returns nil here too.
                    // At this point the app cannot function without a store.
                    Log.db.error("In-memory fallback also failed.")
                    self.store = FeedStore.empty() ?? {
                        fatalError("[FeedLoader] Unable to create any FeedStore: \(error)")
                    }()
                }
```

After:
```swift
                } else {
                    Log.db.error("In-memory fallback also failed. App will operate with limited functionality.")
                    self.store = FeedStore.empty()
                    // initError remains set — UI can check it for degraded-mode banner
                }
```

### 1b — Add v6 migration to convert bookmark date columns (FeedStore.swift ~line 1594)

The v2 migration (`v2_epoch_dates`) converts `feed_item` TEXT timestamps to INTEGER epoch seconds but doesn't touch `bookmark_list.created_at` or `bookmark_item.added_at`. If old code (commit 8cc2551 era) wrote TEXT values via GRDB's default Date encoding, and the record structs now expect `Int`, fetching those rows crashes with DecodingError.

**Fix:** Add a new `v6_bookmark_epoch_dates` migration that applies the same TEXT→INTEGER conversion to bookmark columns:

```swift
migrator.registerMigration("v6_bookmark_epoch_dates") { db in
    try db.execute(sql: """
        UPDATE bookmark_list
        SET created_at = CAST(strftime('%s', created_at) AS INTEGER)
        WHERE typeof(created_at) = 'text'
    """)
    try db.execute(sql: """
        UPDATE bookmark_item
        SET added_at = CAST(strftime('%s', added_at) AS INTEGER)
        WHERE typeof(added_at) = 'text'
    """)
}
```

---

## Task 2: Fix content filter performance + locale regression

**Files:** `feedmine/Services/FeedStore.swift`, `feedmine/Models/ContentFilter.swift`

### 2a — Pre-fold keywords in ContentFilterStore.activeFilters

Keywords are lowercased at storage time (ContentFilter.swift lines 124, 138) but never diacritic-folded. The folding happens in the inner loop of `contentFilterExcludes` — 10,000 times per filter pass.

**Fix:** Add folding to `activeFilters` computed property (ContentFilter.swift line 157-159):

Before:
```swift
var activeFilters: [(id: UUID, keywords: [String])] {
    filters.filter(\.isEnabled).map { ($0.id, $0.keywords) }
}
```

After:
```swift
var activeFilters: [(id: UUID, keywords: [String])] {
    filters.filter(\.isEnabled).map { ($0.id, $0.keywords.map { $0.folding(options: .diacriticInsensitive, locale: nil) }) }
}
```

Then in `contentFilterExcludes` (FeedStore.swift line 137), remove the redundant `.lowercased().folding(...)` from the keyword — simplify to `text.contains(keyword)` since keywords are now pre-folded. Keep the text folding on lines 132-134 (it runs once per item).

### 2b — Restore localizedStandardContains for locale-aware matching

Replacing `localizedStandardContains` with manual folding loses ß→ss expansion (German), Turkish i/ı handling, and ligature normalization. The performance comment estimated 10K comparisons but the actual cost of `localizedStandardContains` vs manual folding wasn't measured.

**Fix:** Keep the text pre-folding (once per item), but use `localizedStandardContains` for the comparison instead of `contains`:

```swift
if text.localizedStandardContains(keyword) {
```

This fixes the locale regression while keeping the text-pre-folding optimization. The keyword is still pre-folded from Task 2a, and `localizedStandardContains` handles the locale-specific expansions that raw folding misses.

---

## Task 3: Fix AddFeedView state management + UX

**Files:** `feedmine/Views/AddFeedView.swift`

### 3a — Fix isResolving stuck on Task cancellation

Three early-return `guard !Task.isCancelled else { return }` paths (lines 255, 293, 302) skip the `isResolving = false` resets at lines 270 and 314.

**Fix:** Add `defer { isResolving = false }` at the top of `importFeeds()` (after `isResolving = true`) and `confirmImport()` (after `isResolving = true`). Then remove the explicit `isResolving = false` assignments since defer handles cleanup on ALL exit paths.

### 3b — Surface OPML import failures

The for-loop at line ~296 uses `if let opmlResult = await loader.importOPML(...)` which silently skips nil returns (network/parse errors).

**Fix:** Add an `else` clause that counts OPML failures and includes them in the result:

```swift
var opmlErrors = 0
for url in pendingOPMLs {
    if let opmlResult = await loader.importOPML(data: url.data, fileName: url.fileName) {
        opmlImported += opmlResult.importedCount
    } else {
        opmlErrors += 1
    }
}
```

Then include opmlErrors in the combined result message.

### 3c — Aggregate OPML error counts in combined result

The combined result only sums `importedCount`. OPML's duplicate/unreachable/invalid counts are lost.

**Fix:** Create a combined `ImportResult` that sums ALL fields from both URL and OPML results, or at minimum include opmlErrors from 3b in the user-facing message.

---

## Task 4: Fix ImportPipeline data integrity

**Files:** `feedmine/Services/ImportPipeline.swift`

### 4a — Preserve duplicate URL categories instead of silently dropping

`Dictionary(parsedSources.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })` silently discards the second entry when the same URL appears in two OPML groups with different categories.

**Fix:** Deduplicate at the source: filter `parsedSources` to remove duplicates BEFORE building the dictionary, and log a warning when a duplicate with a different category is dropped:

```swift
var dedupedSources: [FeedSource] = []
var seenURLs = Set<String>()
for source in parsedSources {
    let normalized = OPMLParser.normalizeURL(source.url)
    if seenURLs.insert(normalized).inserted {
        dedupedSources.append(source)
    }
}
let titleMap = Dictionary(uniqueKeysWithValues: dedupedSources.map { ($0.url, $0) })
```

Use `dedupedSources` for the `urls` array passed to `ingest()`.

### 4b — Guard OPMLImportDelegate stacks against XMLParser error recovery desync

`categoryStack` and `outlinePushStack` are parallel arrays. If XMLParser skips `didEndElement` calls after a fatal parse error, they desync.

**Fix:** Reset both stacks in `parserDidEndDocument:` and `parser:parseErrorOccurred:` callbacks. Add `parserDidEndDocument` and `parser:parseErrorOccurred:` methods that clear both arrays:

```swift
func parserDidEndDocument(_ parser: XMLParser) {
    categoryStack.removeAll()
    outlinePushStack.removeAll()
}

func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
    categoryStack.removeAll()
    outlinePushStack.removeAll()
}
```

---

## Task 5: Harden filteredItems cache key

**Files:** `feedmine/Services/FeedLoader.swift`

### 5a — Use mutation counter instead of sampling item IDs

The current cache key samples first, second, and last item IDs — the comment admits middle-item changes aren't reflected. While FeedItem is immutable today, relying on immutability and append-only semantics is fragile.

**Fix:** Add a `private var _itemsGeneration: Int = 0` counter. Increment it on every mutation to `items`. Use `_itemsGeneration ^ searchQuery.hashValue` as the cache key. This is simpler, more robust, and handles any future mutation pattern correctly.

Find all places that write to `self.items` and add `_itemsGeneration += 1` or `_itemsGeneration &+= 1` after each assignment.

---

## Task Order

Tasks 1-5 are independent (different files or non-conflicting areas). Execute in order but they could safely run in parallel.
