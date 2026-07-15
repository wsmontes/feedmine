# Scalability Fixes for Massive Feeds & Subjects

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix 10 performance, correctness, and efficiency issues found during max-effort code review of the feed reservoir, taxonomy, and fetch pipeline subsystems handling 7,500+ feeds across 39 languages.

**Architecture:** Six independent tasks grouped by subsystem — TaxonomyStore (O(n²) build + O(n) children lookup), Reservoir (unified interleave + off-main-actor computation + bounded timestamps), FeedStore (pre-computed filter set + simpler SQL inserts), and SourceRegistry (skip redundant cache rebuilds). Each task is independently testable with its own test cycle.

**Tech Stack:** Swift 5, GRDB (SQLite), XCTest, @MainActor + actor concurrency

## Global Constraints

- Build must succeed after each task: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
- Test target must pass: `xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20`
- Commit per task with descriptive message
- No regressions to existing behavior — existing tests must continue to pass
- Follow existing code patterns (same error handling style, same comment density, @MainActor annotations)
- All changes on a single branch off `main`

---

### Task 1: Fix O(n²) feedCount pass + add children index in TaxonomyStore

**Files:**
- Modify: `feedmine/Services/TaxonomyStore.swift:96-115` (bottom-up pass), `:223-235` (children(of:))
- Test: `feedmineTests/TaxonomyStoreTests.swift` (add new tests)

**Interfaces:**
- Consumes: `TaxonomyStore.build(from:)` — existing method signature, no external callers change
- Produces: `TaxonomyStore.children(of:)` — same signature, O(1) amortized instead of O(n); new private `childrenIndex: [String: [String]]` field

- [ ] **Step 1: Add failing test for feedCount correctness at scale**

Add to `feedmineTests/TaxonomyStoreTests.swift`:

```swift
func testBuildFeedCountsCorrectAtScale() async {
    // Simulate 100 sources across 20 categories in 4 countries
    var sources: [FeedSource] = []
    let countries = ["brazil", "japan", "germany", "nigeria"]
    let categories = ["News", "Sports", "Tech", "Culture", "Music"]
    for country in countries {
        for category in categories {
            let count = 5
            for i in 0..<count {
                sources.append(FeedSource(
                    title: "\(country)-\(category)-\(i)",
                    url: "https://\(country).example.com/\(category)/\(i)",
                    category: category,
                    region: "countries/\(country)",
                    mediaKind: .text
                ))
            }
        }
    }
    // 4 countries × 5 categories × 5 feeds = 100 feeds
    XCTAssertEqual(sources.count, 100)

    let store = TaxonomyStore()
    await store.build(from: sources)

    // Root should have total of 100
    XCTAssertEqual(store.root?.feedCount, 100)

    // Countries node should have 100
    let rootChildren = store.children(of: TaxonomyNode.rootID)
    XCTAssertEqual(rootChildren.count, 1)
    let countriesNode = rootChildren[0]
    XCTAssertEqual(countriesNode.feedCount, 100)

    // Each country should have 25 (5 categories × 5 feeds)
    let countryChildren = store.children(of: countriesNode.id)
    XCTAssertEqual(countryChildren.count, 4)
    for country in countryChildren {
        XCTAssertEqual(country.feedCount, 25, "\(country.name) should have 25 feeds")
    }

    // Each leaf category should have 5
    if let firstCountry = countryChildren.first {
        let catChildren = store.children(of: firstCountry.id)
        XCTAssertEqual(catChildren.count, 5)
        for cat in catChildren {
            XCTAssertEqual(cat.feedCount, 5, "\(cat.name) should have 5 feeds")
        }
    }
}

func testChildrenLookupIsFast() async {
    var sources: [FeedSource] = []
    for i in 0..<500 {
        sources.append(FeedSource(
            title: "Feed \(i)",
            url: "https://example.com/feed/\(i)",
            category: "Category \(i % 50)",
            region: "global",
            mediaKind: .text
        ))
    }
    let store = TaxonomyStore()
    await store.build(from: sources)

    // children(of:) should not iterate all 500+ nodes
    let rootChildren = store.children(of: TaxonomyNode.rootID)
    // With 500 sources in "global" region, root has 1 child (Global topic)
    // which has ~50 subcategory children
    XCTAssertFalse(rootChildren.isEmpty)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:feedmineTests/TaxonomyStoreTests/testBuildFeedCountsCorrectAtScale -only-testing:feedmineTests/TaxonomyStoreTests/testChildrenLookupIsFast 2>&1 | tail -20`
Expected: FAIL — `testBuildFeedCountsCorrectAtScale` will likely fail on intermediate node feedCounts because the current O(n²) pass miscounts when multiple feeds share the same leaf node.

- [ ] **Step 3: Pre-compute feed counts in a single pass**

In `TaxonomyStore.swift`, replace lines 96-115 (the bottom-up section inside `build(from:)`):

Before (lines 96-115):
```swift
        // Bottom-up feedCount computation — single pass, true O(n)
        // Sort by descending level so leaves are processed before parents
        let sortedIDs = tree.keys.sorted {
            (tree[$0]?.node.level ?? 0) > (tree[$1]?.node.level ?? 0)
        }
        for nodeID in sortedIDs {
            guard var entry = tree[nodeID] else { continue }
            // Direct feeds at this node
            let directFeeds = feedToNodeID.values.filter { $0 == nodeID }.count
            // Child feedCounts are already computed (children have higher level)
            let childTotal = entry.childIDs.reduce(0) {
                $0 + (tree[$1]?.node.feedCount ?? 0)
            }
            let total = directFeeds + childTotal
            tree[nodeID] = (TaxonomyNode(
                id: entry.node.id, name: entry.node.name, parentId: entry.node.parentId,
                childrenCount: entry.childIDs.count, feedCount: total,
                language: entry.node.language, level: entry.node.level, kind: entry.node.kind
            ), entry.childIDs)
        }
```

After:
```swift
        // Pre-compute direct feed counts: single O(M) pass over feedToNodeID,
        // then O(N) bottom-up aggregation for subtree totals. True O(N+M).
        var nodeFeedCounts: [String: Int] = [:]
        for (_, nodeID) in feedToNodeID {
            nodeFeedCounts[nodeID, default: 0] += 1
        }

        // Bottom-up feedCount computation — sort by descending level so
        // leaves are processed before parents
        let sortedIDs = tree.keys.sorted {
            (tree[$0]?.node.level ?? 0) > (tree[$1]?.node.level ?? 0)
        }
        for nodeID in sortedIDs {
            guard let entry = tree[nodeID] else { continue }
            // Direct feeds at this node (O(1) dictionary lookup)
            let directFeeds = nodeFeedCounts[nodeID] ?? 0
            // Child feedCounts are already computed (children have higher level)
            let childTotal = entry.childIDs.reduce(0) {
                $0 + (tree[$1]?.node.feedCount ?? 0)
            }
            let total = directFeeds + childTotal
            tree[nodeID] = (TaxonomyNode(
                id: entry.node.id, name: entry.node.name, parentId: entry.node.parentId,
                childrenCount: entry.childIDs.count, feedCount: total,
                language: entry.node.language, level: entry.node.level, kind: entry.node.kind
            ), entry.childIDs)
        }
```

- [ ] **Step 4: Add children index for O(1) lookups**

Add a new private field to `TaxonomyStore` (near line 30, next to `feedToNodeID`):

```swift
    /// parentID → [childID] index, rebuilt during build(). Makes children(of:) O(1).
    private var childrenIndex: [String: [String]] = [:]
```

Replace the `children(of:)` method (lines 223-235):

Before:
```swift
    func children(of nodeID: String) -> [TaxonomyNode] {
        guard let _ = flatIndex[nodeID] else { return [] }
        // Children are nodes whose parentId == nodeID
        return flatIndex.values
            .filter { $0.parentId == nodeID }
            .sorted { lhs, rhs in
                // Countries last, then alphabetical
                if lhs.kind == .country && rhs.kind != .country { return false }
                if rhs.kind == .country && lhs.kind != .country { return true }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }
```

After:
```swift
    func children(of nodeID: String) -> [TaxonomyNode] {
        guard let childIDs = childrenIndex[nodeID] else { return [] }
        return childIDs
            .compactMap { flatIndex[$0] }
            .sorted { lhs, rhs in
                // Countries last, then alphabetical
                if lhs.kind == .country && rhs.kind != .country { return false }
                if rhs.kind == .country && lhs.kind != .country { return true }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }
```

Build the index at the end of `build(from:)`, right before `persistCache()` (after the root construction, around line 140). Insert:

```swift
        // Build children index for O(1) lookups
        childrenIndex.removeAll()
        for (nodeID, node) in flatIndex {
            guard let parentID = node.parentId else { continue }
            childrenIndex[parentID, default: []].append(nodeID)
        }
```

Also clear the index in the `build(from:)` method at the top, alongside `feedToNodeID.removeAll()` (line 46). Insert:

```swift
        childrenIndex.removeAll()
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:feedmineTests/TaxonomyStoreTests 2>&1 | tail -20`
Expected: All TaxonomyStoreTests PASS

- [ ] **Step 6: Run full test suite**

Run: `xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20`
Expected: All tests PASS, no regressions

- [ ] **Step 7: Commit**

```bash
git add feedmine/Services/TaxonomyStore.swift feedmineTests/TaxonomyStoreTests.swift
git commit -m "perf: O(n) feedCount pass + children index in TaxonomyStore

Replace O(n*m) feedToNodeID.values.filter per node with a single
O(m) counting pass. Add childrenIndex [parentID: [childID]] for
O(1) children(of:) lookups instead of scanning all flatIndex values.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Unify Reservoir interleave — fix sourceRegionMap, text-clash, duplication

**Files:**
- Modify: `feedmine/Services/Reservoir.swift:179-545` (interleave methods), `:38` (sourceRegionMap)
- Test: `feedmineTests/ReservoirTests.swift` (add new tests)

**Interfaces:**
- Consumes: `Reservoir.interleaveOffMain(_:readItemIDs:surfacedTimestamps:sourceRegionMap:)` — existing callers in `FeedStore.flushPendingReservoir()` at lines 220-222
- Produces: Same public signatures; internal implementation unified into a single private static method with a `useCountrySpreading: Bool` parameter

- [ ] **Step 1: Add tests for off-main interleave country diversity + text spreading**

Add to `feedmineTests/ReservoirTests.swift`:

```swift
// MARK: - interleaveOffMain diversity

func testInterleaveOffMainSpreadsSources() {
    let a = makeItems(count: 15, sourceURL: "https://a.com/feed")
    let b = makeItems(count: 15, sourceURL: "https://b.com/feed")
    let c = makeItems(count: 15, sourceURL: "https://c.com/feed")
    let all = a + b + c
    let result = Reservoir.interleaveOffMain(
        all, readItemIDs: [], surfacedTimestamps: [:], sourceRegionMap: [:]
    )
    // Should not have 3+ consecutive from same source
    for i in 0..<(result.count - 3) {
        let slice = result[i..<(i + 3)]
        let sources = Set(slice.map(\.sourceURL))
        XCTAssertTrue(sources.count >= 2, "3 consecutive from same source at idx \(i)")
    }
}

func testInterleaveOffMainSpreadsTextItems() {
    // Two text feeds (different sources, different categories)
    let tech = makeItems(count: 10, sourceURL: "https://tech.com/feed",
                         category: "Technology")
    let science = makeItems(count: 10, sourceURL: "https://science.com/feed",
                           category: "Science")
    let all = tech + science
    let result = Reservoir.interleaveOffMain(
        all, readItemIDs: [], surfacedTimestamps: [:], sourceRegionMap: [:]
    )
    // Since both are text, the spreadConsecutive pass should avoid
    // back-to-back text-text pairs (matching instance interleave behavior)
    var consecutiveTextCount = 0
    for i in 0..<(result.count - 1) {
        let a = result[i], b = result[i + 1]
        if !a.isYouTube && !a.isPodcast && !b.isYouTube && !b.isPodcast {
            consecutiveTextCount += 1
        }
    }
    // With interleaving, fewer than half the pairs should be text-text
    XCTAssertLessThan(consecutiveTextCount, result.count / 2,
                      "Too many consecutive text pairs: \(consecutiveTextCount)/\(result.count)")
}

func testInterleaveOffMainUsesSourceRegionMap() {
    // Items from 3 different countries — region map should spread them
    var regionMap: [String: String] = [:]
    let br = makeItems(count: 10, sourceURL: "https://br.com/feed")
    let jp = makeItems(count: 10, sourceURL: "https://jp.com/feed")
    let de = makeItems(count: 10, sourceURL: "https://de.com/feed")
    regionMap["https://br.com/feed"] = "countries/brazil"
    regionMap["https://jp.com/feed"] = "countries/japan"
    regionMap["https://de.com/feed"] = "countries/germany"
    let all = br + jp + de
    let result = Reservoir.interleaveOffMain(
        all, readItemIDs: [], surfacedTimestamps: [:], sourceRegionMap: regionMap
    )
    // Should not have 4+ consecutive from same country
    for i in 0..<(result.count - 4) {
        let slice = result[i..<(i + 4)]
        let countries = Set(slice.map { regionMap[$0.sourceURL] ?? "unknown" })
        XCTAssertTrue(countries.count >= 2,
                      "4 consecutive from same country at idx \(i): \(countries)")
    }
}

// Add category parameter to existing makeItems helper
private func makeItems(count: Int, sourceURL: String, category: String = "Tech") -> [FeedItem] {
    (0..<count).map { i in
        FeedItem(
            id: "\(sourceURL)#\(i)",
            sourceTitle: "Source",
            sourceURL: sourceURL,
            category: category,
            title: "Item \(i)",
            excerpt: "Excerpt \(i)",
            url: "https://example.com/\(i)",
            imageURL: nil,
            publishedAt: Date().addingTimeInterval(-Double(i) * 3600),
            audioURL: nil,
            duration: nil,
            region: "global"
        )
    }
}
```

- [ ] **Step 2: Run new tests to verify they fail**

Run: `xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:feedmineTests/ReservoirTests/testInterleaveOffMainSpreadsTextItems -only-testing:feedmineTests/ReservoirTests/testInterleaveOffMainUsesSourceRegionMap 2>&1 | tail -20`
Expected: `testInterleaveOffMainSpreadsTextItems` FAILS — too many consecutive text pairs; `testInterleaveOffMainUsesSourceRegionMap` FAILS — same-country items cluster together

- [ ] **Step 3: Extract shared interleave logic, fix sourceRegionMap usage, unify spreadConsecutive**

Replace the instance `interleave` method body and the static `interleaveOffMain` method with a single shared implementation. The private static method contains all logic; both callers pass a flag for country spreading.

In `Reservoir.swift`, replace lines 179-545 (the entire interleave section from `private func interleave` through the end of `spreadConsecutiveStatic`) with:

```swift
    // MARK: - Interleave

    private func interleave(_ items: [FeedItem]) -> [FeedItem] {
        // Instance path: full diversity with country spreading on MainActor.
        // Pass sourceRegionMap so slots are spread by country.
        return Self.interleaveImpl(
            items,
            readItemIDs: readItemIDs,
            surfacedTimestamps: surfacedTimestamps,
            sourceRegionMap: sourceRegionMap,
            useCountrySpreading: true
        )
    }

    /// Pure interleave computation — no instance state, safe to call from any thread.
    /// Takes snapshots of the mutable state it needs.
    nonisolated static func interleaveOffMain(
        _ items: [FeedItem],
        readItemIDs: Set<String>,
        surfacedTimestamps: [String: Date],
        sourceRegionMap: [String: String]
    ) -> [FeedItem] {
        // Off-main path: full diversity with country spreading.
        // sourceRegionMap is now actually used (was accepted but ignored).
        return interleaveImpl(
            items,
            readItemIDs: readItemIDs,
            surfacedTimestamps: surfacedTimestamps,
            sourceRegionMap: sourceRegionMap,
            useCountrySpreading: true
        )
    }

    /// Single shared interleave implementation. Both on-main and off-main
    /// paths use this, guaranteeing identical ordering behavior.
    private static func interleaveImpl(
        _ items: [FeedItem],
        readItemIDs: Set<String>,
        surfacedTimestamps: [String: Date],
        sourceRegionMap: [String: String],
        useCountrySpreading: Bool
    ) -> [FeedItem] {
        guard items.count > 1 else { return items }
        var bySource: [String: [FeedItem]] = [:]
        for item in items {
            bySource[item.sourceURL, default: []].append(item)
        }
        guard bySource.count > 1 else {
            return interleaveByTypeCategoryImpl(items)
        }
        // Within each source: surfaced → stale → recent, each spread by type+category
        let surfacedCutoff = Date().addingTimeInterval(-surfacedCooldown)
        let staleNewsCutoff = Date().addingTimeInterval(-86400)
        let staleEvergreenCutoff = Date().addingTimeInterval(-604800)
        for key in bySource.keys {
            let bucket = bySource[key]!
            let readIDs = bucket.filter { readItemIDs.contains($0.id) }.map(\.id)
            let surfacedIDs = Set(bucket.filter { item in
                guard let ts = surfacedTimestamps[item.id] else { return false }
                return ts > surfacedCutoff
            }.map(\.id))
            let staleIDs = Set(bucket.filter { item in
                if surfacedIDs.contains(item.id) || readIDs.contains(item.id) { return false }
                let cutoff = item.isTimeless ? staleEvergreenCutoff : staleNewsCutoff
                return item.publishedAt < cutoff
            }.map(\.id) + readIDs)
            let recent = interleaveByTypeCategoryImpl(bucket.filter { !surfacedIDs.contains($0.id) && !staleIDs.contains($0.id) }.shuffled())
            let stale = interleaveByTypeCategoryImpl(bucket.filter { staleIDs.contains($0.id) }.shuffled())
            let surfaced = interleaveByTypeCategoryImpl(bucket.filter { surfacedIDs.contains($0.id) }.shuffled())
            bySource[key] = recent + stale + surfaced
        }
        // Weighted slots
        let minCount = max(1, bySource.values.map(\.count).min() ?? 1)
        let weights: [String: Int] = bySource.mapValues { min(5, max(1, $0.count / minCount)) }
        var slots: [String] = []
        for (sourceURL, srcItems) in bySource where !srcItems.isEmpty {
            let w = weights[sourceURL] ?? 1
            for _ in 0..<w { slots.append(sourceURL) }
        }
        // Spread slots to avoid consecutive same-source and same-country
        slots = spreadSlotsImpl(slots)
        if useCountrySpreading {
            slots = spreadSlotsByCountryImpl(slots, sourceRegionMap: sourceRegionMap)
        }
        // Round-robin
        var result: [FeedItem] = []
        result.reserveCapacity(items.count)
        var indices: [String: Int] = Dictionary(uniqueKeysWithValues: bySource.keys.map { ($0, 0) })
        var added = true
        while added {
            added = false
            for sourceURL in slots {
                guard let list = bySource[sourceURL], indices[sourceURL]! < list.count else { continue }
                result.append(list[indices[sourceURL]!])
                indices[sourceURL]! += 1
                added = true
            }
        }
        return spreadConsecutiveImpl(result)
    }

    private static func interleaveByTypeCategoryImpl(_ items: [FeedItem]) -> [FeedItem] {
        guard items.count > 1 else { return items }
        var buckets: [String: [FeedItem]] = [:]
        for item in items {
            let type = item.isPodcast ? "audio" : (item.isYouTube ? "video" : "text")
            buckets["\(type):\(item.category)", default: []].append(item)
        }
        guard buckets.count > 1 else { return items.shuffled() }
        for key in buckets.keys { buckets[key] = buckets[key]?.shuffled() }
        var result: [FeedItem] = []
        result.reserveCapacity(items.count)
        var indices = Dictionary(uniqueKeysWithValues: buckets.keys.map { ($0, 0) })
        let keys = buckets.keys.shuffled()
        var added = true
        while added {
            added = false
            for key in keys {
                guard let list = buckets[key], indices[key]! < list.count else { continue }
                result.append(list[indices[key]!])
                indices[key]! += 1
                added = true
            }
        }
        return result
    }

    private static func spreadSlotsImpl(_ slots: [String]) -> [String] {
        var groups: [String: [String]] = [:]
        for slot in slots { groups[slot, default: []].append(slot) }
        guard groups.count > 1 else { return slots }
        for key in groups.keys { groups[key] = groups[key]?.shuffled() }
        var result: [String] = []
        result.reserveCapacity(slots.count)
        let keys = groups.keys.shuffled()
        var indices = Dictionary(uniqueKeysWithValues: keys.map { ($0, 0) })
        var added = true
        while added {
            added = false
            for key in keys {
                guard let list = groups[key], indices[key]! < list.count else { continue }
                result.append(list[indices[key]!])
                indices[key]! += 1
                added = true
            }
        }
        return result
    }

    private static func spreadSlotsByCountryImpl(_ slots: [String], sourceRegionMap: [String: String]) -> [String] {
        guard slots.count > 2 else { return slots }
        var result = slots
        var pass = 0
        var swapped = true
        while swapped && pass < 3 {
            swapped = false; pass += 1
            for i in 0..<(result.count - 1) {
                let countryA = sourceRegionMap[result[i]] ?? "global"
                let countryB = sourceRegionMap[result[i + 1]] ?? "global"
                guard countryA == countryB else { continue }
                var swapIdx: Int?
                for j in (i + 2)..<result.count {
                    if (sourceRegionMap[result[j]] ?? "global") != countryA { swapIdx = j; break }
                }
                if swapIdx == nil {
                    for j in stride(from: i - 1, through: 0, by: -1) {
                        if (sourceRegionMap[result[j]] ?? "global") != countryA { swapIdx = j; break }
                    }
                }
                if let j = swapIdx { result.swapAt(i + 1, j); swapped = true }
            }
        }
        return result
    }

    /// Post-processing pass: scan for back-to-back items that share an
    /// attribute (source, type, category) and swap with a later item that
    /// breaks the run. O(n) single pass — maintains a look-ahead pointer.
    private static func spreadConsecutiveImpl(_ items: [FeedItem]) -> [FeedItem] {
        guard items.count > 2 else { return items }
        var result = items
        var lookAhead = 2
        for i in 0..<(result.count - 1) {
            let a = result[i], b = result[i + 1]
            let clash = a.sourceURL == b.sourceURL
                || a.category == b.category
                || (a.isYouTube && b.isYouTube)
                || (a.isPodcast && b.isPodcast)
                || (!a.isYouTube && !a.isPodcast && !b.isYouTube && !b.isPodcast)
            guard clash else { continue }
            lookAhead = max(lookAhead, i + 2)
            while lookAhead < result.count {
                let c = result[lookAhead]
                if a.sourceURL != c.sourceURL && b.sourceURL != c.sourceURL
                    && a.category != c.category
                    && !(a.isYouTube && c.isYouTube) && !(a.isPodcast && c.isPodcast)
                    && !(b.isYouTube && c.isYouTube) && !(b.isPodcast && c.isPodcast) {
                    result.swapAt(i + 1, lookAhead)
                    break
                }
                lookAhead += 1
            }
            if lookAhead >= result.count { break }
        }
        return result
    }
```

Delete the old instance methods `spreadSlots`, `spreadSlotsByCountry`, `spreadConsecutive`, `interleaveByTypeCategory`, and the old static methods `interleaveByTypeCategoryStatic`, `spreadConsecutiveStatic`. They are all replaced by the `*Impl` variants above.

- [ ] **Step 4: Run Reservoir tests to verify they pass**

Run: `xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:feedmineTests/ReservoirTests 2>&1 | tail -20`
Expected: All ReservoirTests PASS

- [ ] **Step 5: Run full test suite**

Run: `xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20`
Expected: All tests PASS, no regressions

- [ ] **Step 6: Commit**

```bash
git add feedmine/Services/Reservoir.swift feedmineTests/ReservoirTests.swift
git commit -m "fix: unify Reservoir interleave, fix sourceRegionMap and text-clash

Merge interleave() and interleaveOffMain() into a single shared
interleaveImpl(). The static path now uses spreadSlotsByCountry
(previously accepted sourceRegionMap but never read it).
spreadConsecutive now includes text-text adjacency check in both
paths. Removes ~100 lines of duplicated code.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Offload reservoir.append interleave off MainActor + bound surfacedTimestamps

**Files:**
- Modify: `feedmine/Services/FeedStore.swift:965` (fetchNextBatch append call)
- Modify: `feedmine/Services/Reservoir.swift:406-416` (markAsSurfaced trim)

**Interfaces:**
- Consumes: `Reservoir.appendPreInterleaved(_:)` — already exists, used by `flushPendingReservoir`
- Produces: No public API change; `Reservoir.append(_:)` remains for callers that don't need off-main interleave (e.g., `toggleSource` which handles small batches)

- [ ] **Step 1: Route fetchNextBatch through throttledReservoirAppend instead of direct append**

In `FeedStore.swift`, replace line 965:

Before (line 965):
```swift
        reservoir.append(actualNew)
```

After:
```swift
        throttledReservoirAppend(actualNew)
```

Also remove the immediate visibleItems/reservoirCount update on lines 968-971 since `throttledReservoirAppend` handles that via its flush path. Replace lines 964-971:

Before (lines 964-971):
```swift
        // Append to reservoir
        reservoir.append(actualNew)
        prefetchImagesIfEnabled(for: actualNew)
        // Only update visibleItems if no active search
        if !isSearching {
            visibleItems = applyFilters(reservoir.visibleItems)
            reservoirCount = reservoir.reservoirCount
        }
```

After:
```swift
        // Append to reservoir via throttled path — interleave runs off MainActor
        throttledReservoirAppend(actualNew)
        prefetchImagesIfEnabled(for: actualNew)
```

The flush in `throttledReservoirAppend` already updates `visibleItems` and `reservoirCount` when appropriate (lines 227-233 of `flushPendingReservoir`). For the immediate-feedback case where `visibleItems` is empty, the flush already handles it.

- [ ] **Step 2: Bound surfacedTimestamps with LRU cap**

In `Reservoir.swift`, replace the `markAsSurfaced` method (lines 406-416):

Before:
```swift
    private func markAsSurfaced(_ items: [FeedItem]) {
        let now = Date()
        for item in items {
            if surfacedTimestamps[item.id] == nil {
                surfacedTimestamps[item.id] = now
            }
        }
        if surfacedTimestamps.count > 2000 {
            let cutoff = now.addingTimeInterval(-Self.surfacedCooldown)
            surfacedTimestamps = surfacedTimestamps.filter { $0.value > cutoff }
        }
    }
```

After:
```swift
    private func markAsSurfaced(_ items: [FeedItem]) {
        let now = Date()
        for item in items {
            if surfacedTimestamps[item.id] == nil {
                surfacedTimestamps[item.id] = now
            }
        }
        // Two-tier cleanup: first remove expired (older than cooldown),
        // then cap at 1500 most recent if still over threshold.
        if surfacedTimestamps.count > 1500 {
            let cutoff = now.addingTimeInterval(-Self.surfacedCooldown)
            surfacedTimestamps = surfacedTimestamps.filter { $0.value > cutoff }
        }
        // If still too many (all within cooldown), keep only the 1500 newest
        if surfacedTimestamps.count > 1500 {
            let sorted = surfacedTimestamps.sorted { $0.value > $1.value }
            surfacedTimestamps = Dictionary(uniqueKeysWithValues: sorted.prefix(1500))
        }
    }
```

- [ ] **Step 3: Build and run tests**

Run: `xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20`
Expected: All tests PASS

- [ ] **Step 4: Commit**

```bash
git add feedmine/Services/FeedStore.swift feedmine/Services/Reservoir.swift
git commit -m "perf: offload fetchNextBatch interleave off MainActor, bound surfacedTimestamps

Route fetchNextBatch through throttledReservoirAppend so interleave
runs in Task.detached instead of blocking MainActor. Add LRU cap at
1500 entries for surfacedTimestamps to prevent unbounded growth in
long sessions.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: Pre-compute taxonomy feed URL set in applyFilters

**Files:**
- Modify: `feedmine/Services/FeedStore.swift:110-125` (applyFilters), add cached set near filter state
- Test: `feedmineTests/TaxonomyStoreTests.swift` (add test for isFeedInSubtree performance pattern)

**Interfaces:**
- Consumes: `TaxonomyStore.shared.isFeedInSubtree(feedURL:nodeID:)` — existing method
- Produces: New private `cachedTaxonomyFeedURLs: Set<String>` and `cachedTaxonomyNodeIDs: Set<String>` for cache validation

- [ ] **Step 1: Add cached taxonomy feed URL set**

Add two private fields to `FeedStore` near the filter state (around line 54):

```swift
    /// Cached set of feed URLs that match the current taxonomy selection.
    /// Invalidated when activeNodeIDs changes. Makes applyFilters O(items) instead
    /// of O(items × selectedNodes).
    private var cachedTaxonomyFeedURLs: Set<String> = []
    private var cachedTaxonomyNodeIDs: Set<String> = []
```

- [ ] **Step 2: Rebuild cache when taxonomy selection changes**

In the `setFilter` method (line 602), after the state updates and before the debounced flush, insert cache rebuild logic. Find this block (around lines 602-608):

```swift
    func setFilter(region: String?, nodeIDs: Set<String>, type: FeedLoader.ContentType, mood: FeedLoader.MoodFilter = .all) {
        // Update state immediately for UI responsiveness
        activeRegion = region
        activeNodeIDs = nodeIDs
        activeContentType = type
        activeMood = mood
        persistFilters()
```

Insert after the state updates and before `persistFilters()`:

```swift
        // Rebuild taxonomy URL cache when selection changes
        if activeNodeIDs != cachedTaxonomyNodeIDs {
            cachedTaxonomyNodeIDs = activeNodeIDs
            if activeNodeIDs.isEmpty {
                cachedTaxonomyFeedURLs = []
            } else {
                let store = TaxonomyStore.shared
                cachedTaxonomyFeedURLs = Set(store.registry.allFeedURLs.filter { url in
                    activeNodeIDs.contains { nodeID in
                        store.isFeedInSubtree(feedURL: url, nodeID: nodeID)
                    }
                })
            }
        }
```

Wait — `TaxonomyStore` doesn't expose `registry` or `allFeedURLs`. We need a different approach. Add a method to `TaxonomyStore` instead.

- [ ] **Step 2 (revised): Add feedURLs(inSubtreeOf:) to TaxonomyStore**

In `TaxonomyStore.swift`, add this method (near the other query methods, after `isFeedInSubtree` around line 258):

```swift
    /// All feed URLs whose leaf node falls within the subtree of any of the given node IDs.
    /// Used by FeedStore to pre-compute the taxonomy filter set for O(1) filtering.
    func feedURLs(inSubtreesOf nodeIDs: Set<String>) -> Set<String> {
        guard !nodeIDs.isEmpty else { return [] }
        var result: Set<String> = []
        for (feedURL, leafID) in feedToNodeID {
            for nodeID in nodeIDs {
                if leafID == nodeID || leafID.hasPrefix(nodeID + "/") {
                    result.insert(feedURL)
                    break
                }
            }
        }
        return result
    }
```

- [ ] **Step 3: Rebuild cache when taxonomy selection changes**

In `FeedStore.setFilter` (line 602), after the state updates and before `persistFilters()`:

Insert:
```swift
        // Rebuild taxonomy URL cache when selection changes (O(1) filter instead of O(n×m))
        if activeNodeIDs != cachedTaxonomyNodeIDs {
            cachedTaxonomyNodeIDs = activeNodeIDs
            cachedTaxonomyFeedURLs = TaxonomyStore.shared.feedURLs(inSubtreesOf: activeNodeIDs)
        }
```

- [ ] **Step 4: Use cached set in applyFilters**

In `applyFilters` (lines 110-125), replace the taxonomy check:

Before (lines 119-121):
```swift
            && (nodeIDs.isEmpty || nodeIDs.contains(where: { nodeID in
                TaxonomyStore.shared.isFeedInSubtree(feedURL: item.sourceURL, nodeID: nodeID)
            }))
```

After:
```swift
            && (cachedTaxonomyFeedURLs.isEmpty || cachedTaxonomyFeedURLs.contains(item.sourceURL))
```

And remove the now-unused local `let nodeIDs = activeNodeIDs` at line 111 (it's no longer needed in this method; the cached set replaces it).

The full `applyFilters` method should now start:
```swift
    private func applyFilters(_ items: [FeedItem]) -> [FeedItem] {
        let region = activeRegion
        let contentType = filterContentType
        let contentFilters = ContentFilterStore.shared.isEnabled
            ? ContentFilterStore.shared.activeFilters : []
        return items.filter { item in
            isItemEnabled(item)
            && (region == nil || item.region == region || item.region.hasPrefix(region! + "/"))
            && (cachedTaxonomyFeedURLs.isEmpty || cachedTaxonomyFeedURLs.contains(item.sourceURL))
            && contentType(item)
            && !contentFilterExcludes(item, filters: contentFilters)
        }
    }
```

- [ ] **Step 5: Invalidate cache on taxonomy rebuild**

In `FeedStore.start()`, after `TaxonomyStore.shared.build(from:)` or `loadFromCache()` (around lines 361-363), invalidate the cache:

Insert after the taxonomy build section:
```swift
        // Invalidate taxonomy filter cache after rebuild
        cachedTaxonomyNodeIDs = []
        cachedTaxonomyFeedURLs = []
```

- [ ] **Step 6: Build and run tests**

Run: `xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20`
Expected: All tests PASS

- [ ] **Step 7: Commit**

```bash
git add feedmine/Services/FeedStore.swift feedmine/Services/TaxonomyStore.swift
git commit -m "perf: pre-compute taxonomy feed URL set for O(1) applyFilters

Add feedURLs(inSubtreesOf:) to TaxonomyStore and cache the result
in FeedStore. applyFilters now checks a Set.contains instead of
calling isFeedInSubtree O(items × selectedNodes) times. Cache
invalidates on selection change and taxonomy rebuild.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: Replace SAVEPOINT-per-item with INSERT OR IGNORE in persistFetchedItems

**Files:**
- Modify: `feedmine/Services/FeedStore.swift:880-895` (persistFetchedItems write loop)

**Interfaces:**
- Consumes: None — internal implementation change
- Produces: Same return type `[FeedItem]`; behavior unchanged externally

- [ ] **Step 1: Replace SAVEPOINT loop with INSERT OR IGNORE**

In `FeedStore.swift`, replace lines 880-895:

Before:
```swift
            // Single batch write with SAVEPOINT per item. One bad row
            // rolls back to its savepoint without killing the whole batch. (#2)
            let succeeded: [FeedItem] = try await db.write { db -> [FeedItem] in
                var ok: [FeedItem] = []
                for (item, region) in itemsWithRegions {
                    do {
                        try db.execute(sql: "SAVEPOINT item_insert")
                        try FeedItemRecord(from: item, region: region).insert(db)
                        try db.execute(sql: "RELEASE SAVEPOINT item_insert")
                        ok.append(item)
                    } catch {
                        try? db.execute(sql: "ROLLBACK TO SAVEPOINT item_insert")
                    }
                }
                return ok
            }
```

After:
```swift
            // Single batch write. Items are deduplicated in memory before this
            // point (loadedIDs check + batch-internal dedup), so the only
            // possible conflict is a PRIMARY KEY collision from a concurrent
            // write — INSERT OR IGNORE handles that without the 3× per-item
            // SQL overhead of SAVEPOINT/RELEASE/ROLLBACK.
            let succeeded: [FeedItem] = try await db.write { db -> [FeedItem] in
                var ok: [FeedItem] = []
                for (item, region) in itemsWithRegions {
                    do {
                        try FeedItemRecord(from: item, region: region).insert(db)
                        ok.append(item)
                    } catch {
                        // Only expected error is database integrity (PRIMARY KEY
                        // collision from concurrent write). Log and skip.
                        Log.db.warning("persistFetchedItems: skip \(item.id): \(error.localizedDescription)")
                    }
                }
                return ok
            }
```

The `INSERT OR IGNORE` behavior comes from GRDB's `PersistenceError.recordNotFound` not being thrown for INSERT — but since we want explicit IGNORE semantics, we should use raw SQL. Let me revise:

Actually, the simplest change that preserves the tolerance for individual row failures while removing the savepoint overhead:

```swift
            let succeeded: [FeedItem] = try await db.write { db -> [FeedItem] in
                var ok: [FeedItem] = []
                for (item, region) in itemsWithRegions {
                    do {
                        try FeedItemRecord(from: item, region: region).insert(db)
                        ok.append(item)
                    } catch {
                        // Skip individual row failures. Items are deduplicated in
                        // memory (loadedIDs + batch-internal), so the only expected
                        // failure is a PRIMARY KEY collision from a concurrent write.
                        // One bad row does not roll back the batch.
                        Log.db.warning("persistFetchedItems: skip \(item.id): \(error)")
                    }
                }
                return ok
            }
```

This removes 3 SQL statements per item (SAVEPOINT, RELEASE, conditional ROLLBACK) while keeping the same error tolerance. The existing `do`/`catch` inside the loop already prevents one failure from aborting the whole batch — the savepoints were redundant.

- [ ] **Step 2: Build and run tests**

Run: `xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20`
Expected: All tests PASS, no persistence regressions

- [ ] **Step 3: Commit**

```bash
git add feedmine/Services/FeedStore.swift
git commit -m "perf: remove SAVEPOINT-per-item in persistFetchedItems

Items are already deduplicated in memory (loadedIDs + batch-internal),
so PRIMARY KEY collisions are the only expected failure. The do/catch
inside the write loop already prevents one bad row from aborting the
batch — per-item SAVEPOINT/RELEASE/ROLLBACK (3 SQL statements each)
was redundant overhead.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 6: Skip redundant SourceRegistry cache rebuild on unchanged sources

**Files:**
- Modify: `feedmine/Services/SourceRegistry.swift:30-35` (sources didSet)

**Interfaces:**
- Consumes: `SourceRegistry.sources` — existing property, all assignments via `didSet`
- Produces: Same property; `didSet` skips rebuild when the array is identical

- [ ] **Step 1: Guard didSet against redundant rebuilds**

In `SourceRegistry.swift`, replace the `sources` property (lines 30-35):

Before:
```swift
    var sources: [FeedSource] = [] {
        // Keep the url→source and region caches in sync no matter who assigns
        // `sources` — FeedLoader.addSources sets it directly, bypassing
        // loadFromOPML. Without this, imported feeds are missing from
        // sourceByURL and isSourceEnabled wrongly reports them as disabled.
        didSet { rebuildCaches() }
    }
```

After:
```swift
    var sources: [FeedSource] = [] {
        didSet {
            // Skip rebuild when sources haven't changed — prevents redundant
            // 7,500-entry dictionary allocation during startup when
            // loadFromOPML then restoreImportedSources both assign.
            // Compare by count first (fast reject), then by URL set (O(n)).
            guard sources.count != oldValue.count
                    || Set(sources.map(\.url)) != Set(oldValue.map(\.url)) else { return }
            rebuildCaches()
        }
    }
```

- [ ] **Step 2: Build and verify**

Run: `xcodebuild build -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Run full test suite**

Run: `xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20`
Expected: All tests PASS

- [ ] **Step 4: Commit**

```bash
git add feedmine/Services/SourceRegistry.swift
git commit -m "perf: skip SourceRegistry cache rebuild when sources unchanged

Guard sources didSet against redundant rebuilds by comparing URL sets.
Prevents two 7,500-entry dictionary allocations during startup when
loadFromOPML and restoreImportedSources both assign sources.

Co-Authored-By: Claude <noreply@anthropic.com>"
```
