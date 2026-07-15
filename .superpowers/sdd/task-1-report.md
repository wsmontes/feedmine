# Task 1 Report: Fix O(n²) feedCount pass + add children index in TaxonomyStore

## 1. Status

DONE

## 2. Commits

- `43e30b62` — perf: O(n) feedCount pass + children index in TaxonomyStore

## 3. Test Results

### Selected TaxonomyStore tests (before fixes):
```
Test Suite 'TaxonomyStoreTests' passed at 2026-07-15 13:16:44.319.
     Executed 2 tests, with 0 failures (0 unexpected) in 0.010 (0.011) seconds
```

### All TaxonomyStore tests (after fixes):
```
Test Suite 'TaxonomyStoreTests' passed at 2026-07-15 13:17:25.181.
     Executed 11 tests, with 0 failures (0 unexpected) in 0.027 (0.032) seconds
```

### Full test suite (after fixes):
```
Test Suite 'All tests' passed at 2026-07-15 13:17:35.120.
     Executed 11 tests, with 0 failures (0 unexpected) in 0.022 (0.026) seconds
```

### Build:
```
** BUILD SUCCEEDED **
```

All tests pass. No regressions.

## 4. Self-Review

**What was checked:**

1. **FeedCount correctness**: The two new scalability tests (`testBuildFeedCountsCorrectAtScale`, `testChildrenLookupIsFast`) plus all 9 existing tests pass, confirming feedCount aggregation is correct at scale (100 sources across 4 countries, 5 categories each, 5 feeds per category).

2. **Children lookup correctness**: Existing tests (`testBuildSingleTopicOPML`, `testBuildCountryOPMLWithDepth`) verify `children(of:)` returns correctly sorted children. These pass with the new O(1) index-based implementation.

3. **Edge cases verified**:
   - Empty sources (`testBuildEmptySourcesProducesEmptyTree`)
   - Feed-to-node mapping (`testFeedToNodeMapping`)
   - Search (`testSearchFindsMatchingNodes`, `testSearchIsCaseInsensitive`)
   - Selection (`testSelectAndDeselectNode`, `testClearSelectionRemovesAll`)
   - Subtree membership (`testIsFeedInSubtree`)

4. **Children index completeness**: The index is built from `flatIndex` after all nodes are registered, ensuring no node is missed. Nodes without a parent (root) are correctly skipped. The `children(of:)` method falls back to `[]` when the node ID isn't in the index, matching the original behavior.

5. **Clean build**: `xcodebuild build` succeeds with no warnings on the changed files.

## 5. Concerns

- The two new test methods passed BEFORE the performance fixes were applied. This is because the old O(n*m) feedCount computation, while inefficient, is mathematically correct for the test data shape (each feed URL is unique, each category leaf gets the correct count). The tests serve as correctness regression tests but do not directly validate the performance improvement. No additional action needed — the asymptotic improvement is achieved by replacing `feedToNodeID.values.filter { $0 == nodeID }` (O(m) per node) with a pre-computed `nodeFeedCounts` dictionary lookup (O(1) per node).

- The `childrenIndex` is not persisted to the disk cache (`CachedTree`). It is rebuilt from `flatIndex` on every `build(from:)` call but not after `loadFromCache()`. If `loadFromCache()` is used in production, `children(of:)` will fall back to `[]` and return no children until the next `build(from:)` call. This was addressed in the follow-up fix below (section 6) by rebuilding `childrenIndex` inside `loadFromCache()` after restoring state.

## 6. Follow-up Fix: Rebuild childrenIndex in loadFromCache()

**Change made:** In `loadFromCache()`, after restoring `flatIndex` and `feedToNodeID`, added rebuild of `childrenIndex` from the restored `flatIndex`.

**File:** `/Users/wagnermontes/Documents/GitHub/feedmine/feedmine/Services/TaxonomyStore.swift`

**Exact change (lines 331-340):**
```swift
        self.flatIndex = cached.flatIndex
        self.feedToNodeID = cached.feedToNodeID
        // Rebuild children index from restored flatIndex
        self.childrenIndex.removeAll()
        for (nodeID, node) in self.flatIndex {
            guard let parentID = node.parentId else { continue }
            self.childrenIndex[parentID, default: []].append(nodeID)
        }
        self.root = cached.root
```

**Build:**
```
** BUILD SUCCEEDED **
```

**Test:**
```
Test Suite 'All tests' passed at 2026-07-15 13:22:09.026.
     Executed 11 tests, with 0 failures (0 unexpected) in 0.023 (0.026) seconds
```

**Commit message:**
```
fix: rebuild childrenIndex in loadFromCache() after restoring flatIndex

After loadFromCache() restores `flatIndex` and `feedToNodeID`, it now
also rebuilds `childrenIndex` from the restored `flatIndex`. Without this,
children(of:) returned empty results after a cache load until the next
full build(from:) call.

Co-Authored-By: Claude <noreply@anthropic.com>
```
