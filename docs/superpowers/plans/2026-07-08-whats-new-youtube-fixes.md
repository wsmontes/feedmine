# What's New + YouTube Pipeline Fixes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix What's New carousel showing empty state and YouTube sources never being fetched.

**Architecture:** Three independent fix groups: (A) What's New carousel reliability — ensure `onAppear` reloads, `onDisappear` doesn't clear cache, baseline fallback prevents empty state, and `filterContentType` is removed so the carousel is a discovery surface unaffected by the main feed's active content-type filter. (B) YouTube pipeline — remove the 60-source cap in `progressiveFetch`, add a content-type-aware buffer gate so video/audio sources aren't starved by text items, and shuffle enabled sources so YouTube isn't buried at the end of alphabetical order. (C) Clean up Info.plist diff noise.

**Tech Stack:** Swift 6, SwiftUI, GRDB 7.4.0, SQLite, FeedKit 9.1.2

## Global Constraints

- iOS 18 target, Xcode 26.5
- `project.yml` is stale — edit `.xcodeproj` directly; GRDB is NOT in `project.yml`
- SourceKit diagnostics are noise — trust `xcodebuild`, not inline errors
- Build command: `xcodebuild build -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 14 Plus'`

---

### Task 1: Commit already-applied fixes (What's New P0)

**Files:**
- Already modified: `feedmine/Views/WhatsNewCarousel.swift:42-51`
- Already modified: `feedmine/Services/FeedLoader.swift:276-278`
- Already modified: `feedmine/Services/FeedStore.swift:453-495`

**Status:** Code already written and verified via `xcodebuild`. Needs commit.

- [ ] **Step 1: Review the diff**

```bash
git diff feedmine/Views/WhatsNewCarousel.swift feedmine/Services/FeedLoader.swift feedmine/Services/FeedStore.swift
```

- [ ] **Step 2: Commit the What's New fixes (excluding Info.plist noise)**

```bash
git add feedmine/Views/WhatsNewCarousel.swift feedmine/Services/FeedLoader.swift feedmine/Services/FeedStore.swift
git commit -m "fix(whats-new): carousel empty-state resilience — reload on appear, preserve cache, 7-day fallback

- WhatsNewCarousel.onAppear now calls loadWhatsNew() so the carousel
  refreshes when it reappears after a filter change or scroll-back.
- Removed flushWhatsNewQueue() from onDisappear — baseline is only
  advanced on scenePhase == .background, not on every dismiss.
- loadWhatsNew() only overwrites cachedWhatsNew when result is non-empty,
  preventing cache from being cleared by a transient empty query.
- loadWhatsNewItems() falls back to a 7-day sliding window when the
  baseline query returns nothing (e.g. staleness gate skips fetch,
  no new items after background/foreground cycle).
"
```

- [ ] **Step 3: Build to verify**

```bash
xcodebuild build -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 14 Plus' 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

---

### Task 2: Remove `filterContentType` from What's New carousel query

**Files:**
- Modify: `feedmine/Services/FeedStore.swift:472`

**Interfaces:**
- Consumes: `filterContentType` closure (FeedStore private property, line 77-84)
- Produces: `loadWhatsNewItems()` returns items unfiltered by content type

**Why:** The What's New carousel is a discovery surface — it should show new items regardless of whether the user has Podcasts/Video/Text filter active. Currently `filterContentType` is applied, so when a user is browsing Podcasts, the carousel shows zero items because most podcasts lack `image_url`. Removing this filter from `loadWhatsNewItems()` fixes the carousel for filtered views AND doesn't affect the main feed (which uses `applyFilters`).

- [ ] **Step 1: Remove `filterContentType` from the inner `query` function**

In `feedmine/Services/FeedStore.swift`, change line 472 from:

```swift
return records.map { $0.toFeedItem() }.filter(isItemEnabled).filter(filterContentType).shuffled()
```

To:

```swift
return records.map { $0.toFeedItem() }.filter(isItemEnabled).shuffled()
```

The `query` function is a nested function inside `loadWhatsNewItems()`. The edit target:

```diff
-            return records.map { $0.toFeedItem() }.filter(isItemEnabled).filter(filterContentType).shuffled()
+            return records.map { $0.toFeedItem() }.filter(isItemEnabled).shuffled()
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild build -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 14 Plus' 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add feedmine/Services/FeedStore.swift
git commit -m "fix(whats-new): remove filterContentType from carousel query

The What's New carousel is a discovery surface — it should surface new
items regardless of the main feed's active content-type filter. When
the user is browsing Podcasts, filterContentType previously excluded
all non-podcast items from the carousel, which combined with podcasts
rarely having images meant the carousel was always empty."
```

---

### Task 3: YouTube pipeline — remove 60-source cap from `progressiveFetch`

**Files:**
- Modify: `feedmine/Services/FeedStore.swift:637`

**Interfaces:**
- Consumes: `registry.enabledSources` (array of `FeedSource`, ordered by OPML parse order)
- Produces: `progressiveFetch()` processes ALL enabled sources, not just the first 60

**Why:** `progressiveFetch` caps at `min(allEnabled.count, 60)`. With 577+ sources, only the first 60 (all text blogs, alphabetically first) get fetched. YouTube sources at positions ~500+ never reach the fetcher. Removing the cap lets `progressiveFetch` process all sources on first launch.

- [ ] **Step 1: Remove the 60-source cap**

In `feedmine/Services/FeedStore.swift`, change line 637 from:

```swift
for chunkStart in stride(from: 0, to: min(allEnabled.count, 60), by: chunkSize) {
```

To:

```swift
for chunkStart in stride(from: 0, to: allEnabled.count, by: chunkSize) {
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild build -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 14 Plus' 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add feedmine/Services/FeedStore.swift
git commit -m "fix(youtube): remove 60-source cap from progressiveFetch

progressiveFetch previously stopped after 60 sources (min(count, 60)),
leaving ~500 sources — including all 545 YouTube channels — permanently
unfetched. With 577+ enabled sources on first launch, only the first
60 alphabetically (all text blogs) were reached. Remove the cap so
every enabled source gets at least one fetch cycle."
```

---

### Task 4: YouTube pipeline — content-type-aware buffer gate

**Files:**
- Modify: `feedmine/Services/SourceScheduler.swift:28-39`

**Interfaces:**
- Consumes: `reservoir` ([FeedItem]), `activeContentType` (String?)
- Produces: `currentBuffer` counts items matching active content type; when `activeContentType` is nil (default mixed feed), uses per-type sub-buffers: text max 300, video max 100, audio max 100. If ANY sub-buffer is below its target, the gate opens.

**Why:** When `activeContentType` is nil (default `.all`), the current code counts ALL reservoir items as "buffer." With 1,886 text items, `currentBuffer = 1886` always exceeds `bufferNeeded` (50-500), so `fetchNextBatch` always returns `[]`. YouTube and podcast sources are permanently starved because text items saturate the buffer. The fix: when no content-type filter is active, check each content type independently against a target ceiling. If ANY type is below target, the gate opens — allowing the scheduler to pick sources of that type.

- [ ] **Step 1: Replace the buffer gate logic**

In `feedmine/Services/SourceScheduler.swift`, replace lines 28-39:

**Before:**
```swift
        let currentBuffer: Int = {
            guard let ct = activeContentType else { return reservoir.count }
            return reservoir.filter { item in
                switch ct {
                case "video": return item.isYouTube
                case "audio": return item.isPodcast
                case "text": return !item.isYouTube && !item.isPodcast
                default: return true
                }
            }.count
        }()
        guard currentBuffer < bufferNeeded else { return [] }
```

**After:**
```swift
        // Content-type-aware buffer gate. When no filter is active (default
        // mixed feed), count each type independently — text items shouldn't
        // starve video/audio sources. Gate opens if ANY type is below its
        // per-type ceiling.
        if let ct = activeContentType {
            let currentBuffer: Int = reservoir.filter { item in
                switch ct {
                case "video": return item.isYouTube
                case "audio": return item.isPodcast
                case "text": return !item.isYouTube && !item.isPodcast
                default: return true
                }
            }.count
            guard currentBuffer < bufferNeeded else { return [] }
        } else {
            // Mixed feed: per-type ceilings. Text items are abundant; video
            // and audio are scarce. If any type is below its ceiling, the
            // scheduler can still pick sources of that type.
            let textCount = reservoir.filter { !$0.isYouTube && !$0.isPodcast }.count
            let videoCount = reservoir.filter { $0.isYouTube }.count
            let audioCount = reservoir.filter { $0.isPodcast }.count
            let textTarget = max(bufferNeeded, 300)
            let videoTarget = max(bufferNeeded / 2, 50)
            let audioTarget = max(bufferNeeded / 2, 50)
            let anyBelowTarget = textCount < textTarget || videoCount < videoTarget || audioCount < audioTarget
            guard anyBelowTarget else { return [] }
        }
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild build -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 14 Plus' 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add feedmine/Services/SourceScheduler.swift
git commit -m "fix(youtube): content-type-aware buffer gate in SourceScheduler

When the main feed shows all content types (default), the buffer gate
counted all reservoir items as a single pool. With 1,886 text items,
the gate always stayed closed, permanently starving YouTube and podcast
sources. Now the gate tracks each content type independently: text
(ceiling 300), video (ceiling 50), and audio (ceiling 50). If any type
is below its ceiling, the scheduler is allowed to pick sources of that
type, weighted by region/category deficits and contentTypeBoost."
```

---

### Task 5: YouTube pipeline — shuffle enabled sources so YouTube isn't buried

**Files:**
- Modify: `feedmine/Services/FeedStore.swift:635`

**Interfaces:**
- Consumes: `registry.enabledSources` (ordered by OPML parse — alphabetical, YouTube last)
- Produces: Shuffled copy so `progressiveFetch` interleaves text, video, and audio sources instead of processing all text first

**Why:** `progressiveFetch` iterates `enabledSources` in OPML parse order. With 3,838 OPML files parsed alphabetically, all country feeds (~3,700 files) come before `youtube.opml`. Shuffling gives YouTube sources a fair chance to appear in early chunks rather than waiting until the very end.

- [ ] **Step 1: Shuffle sources in `progressiveFetch`**

In `feedmine/Services/FeedStore.swift`, change line 635 from:

```swift
let allEnabled = registry.enabledSources
```

To:

```swift
let allEnabled = registry.enabledSources.shuffled()
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild build -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 14 Plus' 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add feedmine/Services/FeedStore.swift
git commit -m "fix(youtube): shuffle enabled sources in progressiveFetch

OPML files are parsed alphabetically — all country feeds (~3,700 files)
come before youtube.opml. This means progressiveFetch always processes
text sources first, and with the old 60-source cap, YouTube never got a
chance. Shuffling interleaves text/video/audio sources so every fetch
cycle has a fair mix of content types."
```

---

### Task 6: Clean up Info.plist diff noise

**Files:**
- Modify: `feedmine/Info.plist`

**Status:** `Info.plist` has unrelated whitespace/reordering changes. Revert to keep the commit history clean.

- [ ] **Step 1: Revert Info.plist to HEAD**

```bash
git checkout HEAD -- feedmine/Info.plist
```

- [ ] **Step 2: Verify clean state**

```bash
git diff --stat
```

Expected: Only `Info.plist` should no longer appear (it was already modified before our changes, now reverted).

- [ ] **Step 3: Commit if needed**

If Info.plist changes were the only remaining diff:

```bash
git status
```

---

### Task 7: End-to-end verification

**Files:**
- All modified files from Tasks 1-5

**Interfaces:**
- Verifies: What's New carousel shows content, YouTube sources reach the fetcher on fresh install

- [ ] **Step 1: Full build**

```bash
xcodebuild build -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 14 Plus' 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Clean install on simulator**

```bash
xcrun simctl terminate booted com.feedmine.app 2>/dev/null
xcrun simctl uninstall booted com.feedmine.app 2>/dev/null
xcrun simctl install booted .build-dd/Build/Products/Debug-iphonesimulator/feedmine.app
xcrun simctl launch booted com.feedmine.app
```

Wait 30+ seconds for progressive fetch to process all sources.

- [ ] **Step 3: Verify YouTube sources in source_health**

```bash
CONTAINER=$(find ~/Library/Developer/CoreSimulator/Devices -name "com.feedmine.app.plist" -maxdepth 6 2>/dev/null | head -1 | xargs dirname | xargs dirname | xargs dirname)
sqlite3 "$CONTAINER/Documents/feedmine.sqlite" "SELECT COUNT(*) FROM source_health WHERE url LIKE '%youtube%';"
```

Expected: `> 0` (YouTube URLs should appear in source_health, meaning they were at least attempted)

- [ ] **Step 4: Verify What's New carousel has items**

```bash
plutil -p "$CONTAINER/Library/Preferences/com.feedmine.app.plist" | grep diag_whatsnew_result
```

Expected: `final=` with a number > 0

- [ ] **Step 5: Screenshot**

```bash
xcrun simctl io booted screenshot /tmp/feedmine-verified.png
```

- [ ] **Step 6: Install on device for manual testing**

```bash
xcodebuild build -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS,id=00008110-00067D861486201E' 2>&1 | tail -5
xcrun devicectl device install app --device 00008110-00067D861486201E .build-dd/Build/Products/Debug-iphoneos/feedmine.app
```
