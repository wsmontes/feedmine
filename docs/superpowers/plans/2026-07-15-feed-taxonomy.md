# Feed Taxonomy — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the flat `category` string with a hierarchical taxonomy tree derived from the OPML file structure, supporting multi-select union filtering, arbitrary tree depth, and declarative language inheritance.

**Architecture:** New `TaxonomyStore` actor builds a tree from `FeedSource` records in a single O(n) pass and caches it to disk. `TaxonomyNode` (struct, ~128 bytes) forms the tree with a flat `[String: TaxonomyNode]` index for O(1) lookups. Filter state moves from `selectedCategory: String?` to `selectedNodeIDs: Set<String>` with union semantics. Three new SwiftUI views replace the flat category UI while preserving Content Type, Mood, and Region sections unchanged.

**Tech Stack:** Swift 6, SwiftUI, Observation framework, GRDB (SQLite), existing OPML XMLParser

## Global Constraints

- Tree depth: arbitrary (no limit) — mirrors filesystem + `<outline>` nesting
- Feed-to-node: single-home (one path per feed); multi-label via filter union
- Language: declared via `language` attribute in OPML `<head>` and `<outline>`; inherits nearest parent → `nil`
- Performance: cold tree build <500ms, scroll 60fps, search <100ms, <2MB memory for 5K nodes
- Existing filters (ContentType, Mood, Region) remain untouched — taxonomy is an additional AND filter
- No breaking changes to OPML format beyond optional `language` attribute
- No breaking changes to existing persistence (filter settings, feed data)

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `feedmine/Models/TaxonomyNode.swift` | Create | `TaxonomyNode`, `NodeKind` data types |
| `feedmine/Services/TaxonomyStore.swift` | Create | Tree builder, disk cache, search, selection state |
| `feedmine/Models/FeedSource.swift` | Modify | Add `language: String?` field |
| `feedmine/Services/OPMLParser.swift` | Modify | Parse `<language>` from `<head>` and `<outline>` |
| `feedmine/Services/FeedStore.swift` | Modify | Replace `activeCategory: String?` with `activeNodeIDs: Set<String>`, update `applyFilters` |
| `feedmine/Services/FeedLoader.swift` | Modify | Replace `selectedCategory`/`selectCategory` with `selectedNodeIDs`/`toggleNode`, new `availableTaxonomyRoot` |
| `feedmine/Services/AppSettings.swift` | Modify | Add `filterTaxonomyNodes` persistence, update `Keys` |
| `feedmine/Services/SourceRegistry.swift` | Modify | Update `isSourceEnabled` to use node ID path instead of flat category |
| `feedmine/Views/TaxonomyChipBar.swift` | Create | Horizontal chip bar replacing `CategoryFilterBar` |
| `feedmine/Views/TaxonomyTreeView.swift` | Create | Expandable tree with checkboxes + search for `FilterSheetView` |
| `feedmine/Views/TaxonomyBrowseView.swift` | Create | Full-screen drill-down navigation mode |
| `feedmine/Views/FilterSheetView.swift` | Modify | Replace Category section with `TaxonomyTreeView` |
| `feedmine/Views/FeedScreen.swift` | Modify | Replace `CategoryFilterBar` usage with `TaxonomyChipBar` |
| `feedmine/Views/CategoryFilterBar.swift` | Delete | Replaced by `TaxonomyChipBar` |
| `feedmineTests/TaxonomyStoreTests.swift` | Create | Unit tests for tree build, cache, search, selection |

---

### Task 1: Data Model — TaxonomyNode and FeedSource.language

**Files:**
- Create: `feedmine/Models/TaxonomyNode.swift`
- Modify: `feedmine/Models/FeedSource.swift`

**Interfaces:**
- Produces: `TaxonomyNode` (Identifiable, Hashable, Sendable), `NodeKind` (String, Codable, Sendable)
- Produces: `FeedSource.language: String?` — optional, nil when undeclared

- [ ] **Step 1: Define NodeKind and TaxonomyNode**

Create `feedmine/Models/TaxonomyNode.swift`:

```swift
import Foundation

/// The type of a node in the taxonomy tree.
enum NodeKind: String, Codable, Sendable, CaseIterable {
    case topic        // global topic OPML (coffee_tea, tech, science)
    case country      // country directory
    case region       // sub-region within a country
    case subcategory  // <outline> group within an OPML
}

/// A single node in the feed taxonomy tree.
///
/// IDs are canonical slug paths (e.g. "countries/brazil/news").
/// The virtual root uses the sentinel ID `__root__`.
/// `feedCount` is the total number of feeds in this subtree (all descendants).
/// `childrenCount` is only direct children (nodes, not feeds).
struct TaxonomyNode: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let parentId: String?
    let childrenCount: Int
    let feedCount: Int
    let language: String?
    let level: Int
    let kind: NodeKind

    /// Sentinel ID for the virtual root node.
    static let rootID = "__root__"

    /// Virtual root — parent of all top-level nodes.
    static func root(feedCount: Int, childrenCount: Int) -> TaxonomyNode {
        TaxonomyNode(
            id: rootID,
            name: "All Feeds",
            parentId: nil,
            childrenCount: childrenCount,
            feedCount: feedCount,
            language: nil,
            level: 0,
            kind: .topic
        )
    }

    /// Whether this node is an ancestor of the given node ID.
    /// O(depth) — walks parent chain via id prefix matching.
    func isAncestor(of leafId: String) -> Bool {
        leafId.hasPrefix(id + "/")
    }
}
```

- [ ] **Step 2: Add language to FeedSource**

Modify `feedmine/Models/FeedSource.swift`:

```swift
// After the existing `let region: String` line (around line 15), add:
    let language: String?   // ISO 639-1 code, inherited from OPML <head> or <outline>

// Update CodingKeys enum (around line 43):
    enum CodingKeys: String, CodingKey {
        case title, url, category, region, language, mediaKind = "media_kind"
    }

// Update init(from decoder:) (around line 47):
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        url = try c.decode(String.self, forKey: .url)
        category = try c.decode(String.self, forKey: .category)
        region = (try? c.decode(String.self, forKey: .region)) ?? "global"
        language = try? c.decode(String.self, forKey: .language)
        mediaKind = (try? c.decode(MediaKind.self, forKey: .mediaKind)) ?? .text
    }

// Update init(title:url:category:region:mediaKind:) (around line 35):
    init(title: String, url: String, category: String, region: String = "global",
         mediaKind: MediaKind = .text, language: String? = nil) {
        self.title = title
        self.url = url
        self.category = category
        self.region = region
        self.mediaKind = mediaKind
        self.language = language
    }
```

- [ ] **Step 3: Build to verify compilation**

```bash
xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add feedmine/Models/TaxonomyNode.swift feedmine/Models/FeedSource.swift
git commit -m "feat: add TaxonomyNode model and FeedSource.language field"
```

---

### Task 2: TaxonomyStore — Tree Builder, Cache, Search, Selection

**Files:**
- Create: `feedmine/Services/TaxonomyStore.swift`
- Test: Create `feedmineTests/TaxonomyStoreTests.swift`

**Interfaces:**
- Produces: `TaxonomyStore` (@Observable, @MainActor) with `root`, `flatIndex`, `feedToNodeID`, `selectedNodeIDs`
- Produces: `func build(from: [FeedSource])`, `func search(String) -> [TaxonomyNode]`, `func children(of:) -> [TaxonomyNode]`, `func select/deselect/clearSelection()`

- [ ] **Step 1: Write failing tests**

Create `feedmineTests/TaxonomyStoreTests.swift`:

```swift
import XCTest
@testable import feedmine

final class TaxonomyStoreTests: XCTestCase {

    // MARK: - Tree Building

    func testBuildEmptySourcesProducesEmptyTree() async {
        let store = TaxonomyStore()
        await store.build(from: [])
        let root = store.root
        XCTAssertNotNil(root)
        XCTAssertEqual(root?.id, TaxonomyNode.rootID)
        XCTAssertEqual(root?.feedCount, 0)
        XCTAssertEqual(root?.childrenCount, 0)
    }

    func testBuildSingleTopicOPML() async {
        let sources = [
            FeedSource(title: "Sprudge", url: "https://sprudge.com/feed",
                       category: "Coffee News", region: "global", mediaKind: .text),
            FeedSource(title: "Tea Journey", url: "https://teajourney.pub/feed",
                       category: "Tea Culture", region: "global", mediaKind: .text),
        ]
        let store = TaxonomyStore()
        await store.build(from: sources)

        // Root has 1 child (the topic OPML)
        let rootChildren = store.children(of: TaxonomyNode.rootID)
        XCTAssertEqual(rootChildren.count, 1, "Should have 1 topic node")

        let topicNode = rootChildren[0]
        XCTAssertEqual(topicNode.name, "global")  // region as topic name
        XCTAssertEqual(topicNode.feedCount, 2)

        // Topic has 2 subcategory children
        let subChildren = store.children(of: topicNode.id)
        XCTAssertEqual(subChildren.count, 2)
        XCTAssertEqual(subChildren.map(\.name).sorted(), ["Coffee News", "Tea Culture"])
    }

    func testBuildCountryOPMLWithDepth() async {
        let sources = [
            FeedSource(title: "Folha", url: "https://folha.com/feed",
                       category: "News", region: "countries/brazil", mediaKind: .text),
            FeedSource(title: "Globo Esporte", url: "https://globo.com/esporte/feed",
                       category: "Sports", region: "countries/brazil", mediaKind: .text),
        ]
        let store = TaxonomyStore()
        await store.build(from: sources)

        let rootChildren = store.children(of: TaxonomyNode.rootID)
        XCTAssertEqual(rootChildren.count, 1)
        XCTAssertEqual(rootChildren[0].name, "countries")

        let countriesChildren = store.children(of: rootChildren[0].id)
        XCTAssertEqual(countriesChildren.count, 1)
        XCTAssertEqual(countriesChildren[0].name, "brazil")

        let brazilChildren = store.children(of: countriesChildren[0].id)
        XCTAssertEqual(brazilChildren.count, 2)
    }

    func testFeedToNodeMapping() async {
        let sources = [
            FeedSource(title: "Test", url: "https://test.com/feed",
                       category: "News", region: "global", mediaKind: .text),
        ]
        let store = TaxonomyStore()
        await store.build(from: sources)

        let nodeID = await store.nodeID(for: "https://test.com/feed")
        XCTAssertNotNil(nodeID)
        XCTAssertTrue(nodeID?.hasSuffix("/news") ?? false)
    }

    // MARK: - Search

    func testSearchFindsMatchingNodes() async {
        let sources = [
            FeedSource(title: "Sprudge", url: "https://a.com",
                       category: "Coffee News", region: "global", mediaKind: .text),
            FeedSource(title: "TechCrunch", url: "https://b.com",
                       category: "Startups", region: "global", mediaKind: .text),
        ]
        let store = TaxonomyStore()
        await store.build(from: sources)

        let results = store.search("coffee")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].name, "Coffee News")
    }

    func testSearchIsCaseInsensitive() async {
        let sources = [
            FeedSource(title: "Test", url: "https://a.com",
                       category: "Coffee News", region: "global", mediaKind: .text),
        ]
        let store = TaxonomyStore()
        await store.build(from: sources)

        XCTAssertEqual(store.search("COFFEE").count, 1)
        XCTAssertEqual(store.search("coffee").count, 1)
        XCTAssertEqual(store.search("Coffee").count, 1)
    }

    // MARK: - Selection

    func testSelectAndDeselectNode() async {
        let store = TaxonomyStore()
        store.select("test/id")
        XCTAssertTrue(store.selectedNodeIDs.contains("test/id"))
        store.deselect("test/id")
        XCTAssertFalse(store.selectedNodeIDs.contains("test/id"))
    }

    func testClearSelectionRemovesAll() async {
        let store = TaxonomyStore()
        store.select("a")
        store.select("b")
        store.clearSelection()
        XCTAssertTrue(store.selectedNodeIDs.isEmpty)
    }

    // MARK: - isFeedInSubtree

    func testIsFeedInSubtree() async {
        let sources = [
            FeedSource(title: "Folha", url: "https://folha.com/feed",
                       category: "News", region: "countries/brazil", mediaKind: .text),
        ]
        let store = TaxonomyStore()
        await store.build(from: sources)

        let folhaNodeID = await store.nodeID(for: "https://folha.com/feed")!
        let brazilNodeID = folhaNodeID.components(separatedBy: "/").prefix(3).joined(separator: "/")

        // Brazil node should contain Folha
        let result = store.isFeedInSubtree(feedURL: "https://folha.com/feed", nodeID: brazilNodeID)
        XCTAssertTrue(result)

        // Unrelated node should not
        let result2 = store.isFeedInSubtree(feedURL: "https://folha.com/feed", nodeID: "coffee-tea")
        XCTAssertFalse(result2)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:feedmineTests/TaxonomyStoreTests 2>&1 | tail -10
```

Expected: Build errors (TaxonomyStore not found) or test failures.

- [ ] **Step 3: Implement TaxonomyStore**

Create `feedmine/Services/TaxonomyStore.swift`:

```swift
import Foundation
import Observation

/// Builds and maintains the feed taxonomy tree from `FeedSource` records.
///
/// The tree is derived from the OPML file structure (directories + <outline> nesting).
/// Each feed belongs to exactly one leaf node (single-home). Multi-label semantics
/// are achieved via filter union — selecting multiple nodes shows all feeds in their subtrees.
///
/// Performance:
/// - Build: O(n) single pass, <500ms cold, <50ms warm (disk cache)
/// - Search: O(n) over flatIndex, 300ms debounce in UI layer
/// - Lookup: O(1) via flatIndex dictionary
/// - Memory: ~128 bytes per node → <2MB for 10K nodes
@MainActor
@Observable
final class TaxonomyStore {

    // MARK: - State

    private(set) var root: TaxonomyNode?
    private(set) var flatIndex: [String: TaxonomyNode] = [:]

    /// O(1) node lookup by ID.
    func node(id: String) -> TaxonomyNode? { flatIndex[id] }
    private var feedToNodeID: [String: String] = [:]  // normalizedURL → leaf node ID
    var selectedNodeIDs: Set<String> = []

    // MARK: - Persistence

    private let cacheURL: URL = {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("taxonomy_cache.json")
    }()

    // MARK: - Tree Building

    /// Build the taxonomy tree from all feed sources.
    /// Single pass, O(n). Caches result to disk for warm starts.
    func build(from sources: [FeedSource]) {
        // Intermediate: path segments → children
        var tree: [String: (node: TaxonomyNode, childIDs: Set<String>) = [:]
        var rootChildren: Set<String> = []

        // Ensure virtual root exists
        let rootNode = TaxonomyNode.root(feedCount: 0, childrenCount: 0)
        tree[rootNode.id] = (rootNode, [])

        for source in sources {
            // Derive path: region + category → node ID segments
            let segments = derivePath(from: source)
            var parentID = TaxonomyNode.rootID

            for (depth, segment) in segments.enumerated() {
                let nodeID: String
                if parentID == TaxonomyNode.rootID {
                    nodeID = segment.slug
                } else {
                    nodeID = "\(parentID)/\(segment.slug)"
                }

                if tree[nodeID] == nil {
                    let node = TaxonomyNode(
                        id: nodeID,
                        name: segment.name,
                        parentId: parentID,
                        childrenCount: 0,
                        feedCount: 0,
                        language: segment.language,
                        level: depth + 1,
                        kind: segment.kind
                    )
                    tree[nodeID] = (node, [])
                    tree[parentID]?.childIDs.insert(nodeID)
                    if parentID == TaxonomyNode.rootID {
                        rootChildren.insert(nodeID)
                    }
                }

                parentID = nodeID
            }

            // Map feed URL → leaf node
            let normalizedURL = OPMLParser.normalizeURL(source.url)
            feedToNodeID[normalizedURL] = parentID
        }

        // Bottom-up: compute feedCount (feeds at this node + all descendants)
        func computeFeedCount(_ nodeID: String) -> Int {
            guard let entry = tree[nodeID] else { return 0 }
            let directFeeds = feedToNodeID.values.filter { $0 == nodeID }.count
            let descendantFeeds = entry.childIDs.reduce(0) { $0 + computeFeedCount($1) }
            return directFeeds + descendantFeeds
        }

        // Compute all feedCounts
        for nodeID in tree.keys {
            let count = computeFeedCount(nodeID)
            let old = tree[nodeID]!
            tree[nodeID] = (TaxonomyNode(
                id: old.node.id, name: old.node.name, parentId: old.node.parentId,
                childrenCount: old.childIDs.count, feedCount: count,
                language: old.node.language, level: old.node.level, kind: old.node.kind
            ), old.childIDs)
        }

        // Update root
        let totalFeeds = tree[TaxonomyNode.rootID]?.childIDs.reduce(0) {
            tree[$1]?.node.feedCount ?? 0
        } ?? 0
        tree[TaxonomyNode.rootID] = (
            TaxonomyNode.root(feedCount: totalFeeds, childrenCount: rootChildren.count),
            rootChildren
        )

        // Build flat index
        flatIndex = Dictionary(uniqueKeysWithValues: tree.map { ($0.key, $0.value.node) })

        // Top-level children sorted by name
        let topChildren = rootChildren
            .compactMap { flatIndex[$0] }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let rootWithChildren = TaxonomyNode(
            id: rootNode.id, name: rootNode.name, parentId: nil,
            childrenCount: topChildren.count, feedCount: totalFeeds,
            language: nil, level: 0, kind: .topic
        )

        self.root = rootWithChildren
        persistCache()
    }

    // MARK: - Path derivation

    private struct PathSegment {
        let slug: String
        let name: String
        let language: String?
        let kind: NodeKind
    }

    private func derivePath(from source: FeedSource) -> [PathSegment] {
        var segments: [PathSegment] = []
        let region = source.region

        if region == "global" {
            // Global topic: use category as subcategory
            let slug = source.category
                .lowercased()
                .replacingOccurrences(of: "&", with: "and")
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "/", with: "-")
            segments.append(PathSegment(
                slug: slug, name: source.category,
                language: source.language, kind: .subcategory
            ))
        } else if region.hasPrefix("countries/") {
            // Countries path: countries → country → (region?) → subcategory
            // Always starts with "countries" virtual node
            if segments.isEmpty || segments.last?.slug != "countries" {
                // Check if countries node already exists in this batch
                segments.append(PathSegment(
                    slug: "countries", name: "Countries",
                    language: nil, kind: .topic
                ))
            }

            let parts = region.components(separatedBy: "/")
            // parts[0] = "countries", parts[1] = country, parts[2+] = sub-region
            for (idx, part) in parts.enumerated() where idx >= 1 {
                let kind: NodeKind = idx == 1 ? .country : .region
                let displayName = part
                    .replacingOccurrences(of: "-", with: " ")
                    .capitalized
                segments.append(PathSegment(
                    slug: part, name: displayName,
                    language: source.language, kind: kind
                ))
            }

            // Append subcategory
            let subSlug = source.category
                .lowercased()
                .replacingOccurrences(of: "&", with: "and")
                .replacingOccurrences(of: " ", with: "_")
            segments.append(PathSegment(
                slug: subSlug, name: source.category,
                language: source.language, kind: .subcategory
            ))
        } else if region == "imported" {
            segments.append(PathSegment(
                slug: "imported", name: "Imported",
                language: source.language, kind: .topic
            ))
            let subSlug = source.category
                .lowercased()
                .replacingOccurrences(of: "&", with: "and")
                .replacingOccurrences(of: " ", with: "_")
            segments.append(PathSegment(
                slug: subSlug, name: source.category,
                language: source.language, kind: .subcategory
            ))
        }

        return segments
    }

    // MARK: - Queries

    /// Direct children of a node, sorted by name.
    func children(of nodeID: String) -> [TaxonomyNode] {
        guard let node = flatIndex[nodeID] else { return [] }
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

    /// All ancestors from root to the given node (inclusive).
    func ancestors(of nodeID: String) -> [TaxonomyNode] {
        var result: [TaxonomyNode] = []
        var current: String? = nodeID
        while let id = current, let node = flatIndex[id] {
            result.append(node)
            current = node.parentId
        }
        return result.reversed()
    }

    /// Leaf node ID for a feed URL.
    func nodeID(for feedURL: String) -> String? {
        feedToNodeID[OPMLParser.normalizeURL(feedURL)]
    }

    /// Whether a feed's leaf node is in the subtree of the given node ID.
    func isFeedInSubtree(feedURL: String, nodeID: String) -> Bool {
        guard let leafID = feedToNodeID[OPMLParser.normalizeURL(feedURL)] else { return false }
        if leafID == nodeID { return true }
        return leafID.hasPrefix(nodeID + "/")
    }

    /// Search flat index by name. Case-insensitive. Returns up to 50 results.
    func search(_ query: String) -> [TaxonomyNode] {
        guard !query.isEmpty else { return [] }
        let q = query.lowercased()
        return flatIndex.values
            .filter { $0.name.localizedCaseInsensitiveContains(q) }
            .prefix(50)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Selection

    func select(_ nodeID: String) {
        selectedNodeIDs.insert(nodeID)
        persistSelection()
    }

    func deselect(_ nodeID: String) {
        selectedNodeIDs.remove(nodeID)
        persistSelection()
    }

    func toggle(_ nodeID: String) {
        if selectedNodeIDs.contains(nodeID) {
            deselect(nodeID)
        } else {
            select(nodeID)
        }
    }

    func clearSelection() {
        selectedNodeIDs.removeAll()
        persistSelection()
    }

    var hasSelection: Bool { !selectedNodeIDs.isEmpty }

    /// Resolved node names for display in chip bar, sorted by depth then name.
    var selectedNodeNames: [String] {
        selectedNodeIDs.compactMap { flatIndex[$0]?.name }.sorted()
    }

    // MARK: - Cache

    /// Invalidate disk cache — call when OPML manifest changes.
    func invalidateCache() {
        try? FileManager.default.removeItem(at: cacheURL)
    }

    /// Try to load from disk cache. Returns true if cache was valid.
    func loadFromCache() -> Bool {
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode(CachedTree.self, from: data) else {
            return false
        }
        self.flatIndex = cached.flatIndex
        self.feedToNodeID = cached.feedToNodeID
        self.root = cached.root
        self.selectedNodeIDs = cached.selectedNodeIDs
        return true
    }

    private func persistCache() {
        let cached = CachedTree(
            root: root,
            flatIndex: flatIndex,
            feedToNodeID: feedToNodeID,
            selectedNodeIDs: selectedNodeIDs
        )
        guard let data = try? JSONEncoder().encode(cached) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private func persistSelection() {
        // Just re-save the cache with updated selection
        persistCache()
    }
}

// MARK: - Cache DTO

private struct CachedTree: Codable {
    let root: TaxonomyNode?
    let flatIndex: [String: TaxonomyNode]
    let feedToNodeID: [String: String]
    let selectedNodeIDs: Set<String>
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:feedmineTests/TaxonomyStoreTests 2>&1 | tail -10
```

Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add feedmine/Services/TaxonomyStore.swift feedmineTests/TaxonomyStoreTests.swift
git commit -m "feat: add TaxonomyStore — tree builder, cache, search, selection"
```

---

### Task 3: OPMLParser — Parse language attribute

**Files:**
- Modify: `feedmine/Services/OPMLParser.swift`

**Interfaces:**
- Consumes: `FeedSource.language: String?` (from Task 1)
- Produces: Updated `OPMLDelegate` that tracks language stack and passes it to `FeedSource` init

- [ ] **Step 1: Update OPMLDelegate to track language**

Modify `feedmine/Services/OPMLParser.swift` in the `OPMLDelegate` class (around line 334):

```swift
// Add after existing private vars (around line 341-342):
    private var languageStack: [String] = []
    private var fileLanguage: String?  // from <head><language>

// Update init to accept fileLanguage:
    init(fallbackCategory: String, region: String = "global", mediaKind: MediaKind = .text,
         fileLanguage: String? = nil) {
        self.fallbackCategory = fallbackCategory
        self.region = region
        self.mediaKind = mediaKind
        self.fileLanguage = fileLanguage
    }

// Update didStartElement — in the category container branch (around line 356-365),
// before "Category container — push onto stack":
// Add language attribute parsing:
        let language = attributeDict["language"]

// In the category push branch (around line 358-361), change to:
            let category = attributeDict["title"] ?? attributeDict["text"]
            if let cat = category, !cat.isEmpty {
                categoryStack.append(cat)
                // Push language: outline attr → file-level → nil
                languageStack.append(language ?? fileLanguage ?? (languageStack.last ?? fileLanguage) ?? "unknown")
                outlinePushStack.append(true)
            } else {
                outlinePushStack.append(false)
            }

// In the feed source creation branch (around line 380-398), update to pass language:
        let resolvedLanguage = language ?? languageStack.last ?? fileLanguage
        sources.append(
            FeedSource(
                title: title.isEmpty ? category : title,
                url: xmlUrl,
                category: category,
                region: region,
                mediaKind: resolvedKind,
                language: resolvedLanguage
            )
        )

// Update didEndElement (around line 401-408), after popping categoryStack:
        if didPushCategory, !languageStack.isEmpty {
            languageStack.removeLast()
        }
```

- [ ] **Step 2: Parse <language> from <head> in the parse method**

Find the `parse(opmlData:region:mediaKind:)` or equivalent method that creates the `OPMLDelegate`. Before creating the delegate, scan for `<language>` in the XML:

```swift
// Add a helper to extract <language> from the OPML <head>:
private static func extractLanguage(from data: Data) -> String? {
    // Quick scan — look for <language>en</language> in the first 2KB
    let head = String(data: data.prefix(2048), encoding: .utf8) ?? ""
    guard let range = head.range(of: "<language>"),
          let endRange = head.range(of: "</language>", range: range.upperBound..<head.endIndex) else {
        return nil
    }
    let lang = String(head[range.upperBound..<endRange.lowerBound])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return lang.isEmpty ? nil : lang
}
```

Then pass `extractLanguage(from: data)` as `fileLanguage` to the delegate init.

- [ ] **Step 3: Verify existing OPML tests still pass**

```bash
xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "Test.*passed|Test.*failed|BUILD"
```

Expected: All existing tests pass (no regressions).

- [ ] **Step 4: Commit**

```bash
git add feedmine/Services/OPMLParser.swift
git commit -m "feat: parse language attribute from OPML <head> and <outline>"
```

---

### Task 4: FeedStore and FeedLoader — Multi-select Node Filtering

**Files:**
- Modify: `feedmine/Services/FeedStore.swift`
- Modify: `feedmine/Services/FeedLoader.swift`
- Modify: `feedmine/Services/AppSettings.swift`
- Modify: `feedmine/Services/SourceRegistry.swift`

**Interfaces:**
- Consumes: `TaxonomyStore.selectedNodeIDs`, `TaxonomyStore.isFeedInSubtree`
- Produces: `FeedStore.activeNodeIDs: Set<String>`, updated `applyFilters` with union semantics
- Produces: `FeedLoader.selectedNodeIDs`, `FeedLoader.toggleNode`, `FeedLoader.toggleAllNodes`, `FeedLoader.availableTaxonomyRoot`

- [ ] **Step 1: Update FeedStore filter state**

In `feedmine/Services/FeedStore.swift`:

```swift
// Replace (around line 53):
    var activeCategory: String?

// With:
    var activeNodeIDs: Set<String> = []

// In applyFilters (around line 110-123), replace the category check:
// OLD:
    && (category == nil || item.category == category)

// NEW:
    && (activeNodeIDs.isEmpty || activeNodeIDs.contains(where: { nodeID in
        TaxonomyStore.shared.isFeedInSubtree(feedURL: item.sourceURL, nodeID: nodeID)
    }))

// In setFilter (around line 594), update signature and body:
    func setFilter(region: String?, nodeIDs: Set<String>, type: FeedLoader.ContentType, mood: FeedLoader.MoodFilter = .all) {
        activeRegion = region
        activeNodeIDs = nodeIDs
        activeContentType = type
        activeMood = mood
        persistFilters()
        filterDebounceTask?.cancel()
        filterDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.loadingState = .refreshing
            self.refreshWhatsNew()
            self.applyUpdate(.flush())
        }
    }

// In clearAllFilters (around line 615-624):
    func clearAllFilters() {
        loadingState = .refreshing
        activeRegion = nil
        activeNodeIDs = []
        activeContentType = .all
        activeMood = .all
        persistFilters()
        refreshWhatsNew()
        applyUpdate(.flush())
    }

// In persistFilters (around line 561-563), replace filterCategory:
    Settings.filterTaxonomyNodes = Array(activeNodeIDs)

// In restoreFilters (around line 583-584), replace:
    activeCategory = Settings.filterCategory
// With:
    activeNodeIDs = Set(Settings.filterTaxonomyNodes)

// In search (around line 637), update the search call to pass nodeIDs:
    let results = await searchEngine.search(query, region: activeRegion, taxonomyNodeIDs: activeNodeIDs)

// In applyFilters, remove the local `let category = activeCategory` binding:
// Replace (around line 111):
        let category = activeCategory
// With:
        let nodeIDs = activeNodeIDs
```

- [ ] **Step 2: Update FeedLoader public API**

In `feedmine/Services/FeedLoader.swift`:

```swift
// Replace (around line 94):
    var selectedCategory: String? { store.activeCategory }
    var availableCategories: [String] {
        Set(store.registry.enabledSources.map(\.category)).sorted()
    }

// With:
    var selectedNodeIDs: Set<String> { store.activeNodeIDs }
    var selectedNodeNames: [String] { TaxonomyStore.shared.selectedNodeNames }
    var hasTaxonomySelection: Bool { !selectedNodeIDs.isEmpty }
    var availableTaxonomyRoot: TaxonomyNode? { TaxonomyStore.shared.root }

// Replace selectCategory (around line 421-426):
    func selectCategory(_ category: String?) {
        let newValue = (store.activeCategory == category) ? nil : category
        store.setFilter(region: store.activeRegion, category: newValue,
                        type: store.activeContentType, mood: store.activeMood)
        Task { await loadWhatsNew() }
    }

// With:
    func toggleNode(_ nodeID: String) {
        TaxonomyStore.shared.toggle(nodeID)
        store.setFilter(region: store.activeRegion,
                        nodeIDs: TaxonomyStore.shared.selectedNodeIDs,
                        type: store.activeContentType, mood: store.activeMood)
        Task { await loadWhatsNew() }
    }

    func clearTaxonomySelection() {
        TaxonomyStore.shared.clearSelection()
        store.setFilter(region: store.activeRegion,
                        nodeIDs: [],
                        type: store.activeContentType, mood: store.activeMood)
        Task { await loadWhatsNew() }
    }

// Update clearAllFilters (around line 442-446):
    func clearAllFilters() {
        searchQuery = ""
        TaxonomyStore.shared.clearSelection()
        store.clearAllFilters()
        Task { await loadWhatsNew() }
    }
```

- [ ] **Step 3: Update AppSettings for taxonomy persistence**

In `feedmine/Services/AppSettings.swift`:

```swift
// In Keys enum (around line 10-11), replace:
    static let filterCategory = "filterCategory"

// With:
    static let filterTaxonomyNodes = "filterTaxonomyNodes"

// In Settings enum (around line 64-66), replace:
    static var filterCategory: String? {
        get { d.string(forKey: Keys.filterCategory) }
        set { d.set(newValue, forKey: Keys.filterCategory) }
    }

// With:
    static var filterTaxonomyNodes: [String] {
        get { d.stringArray(forKey: Keys.filterTaxonomyNodes) ?? [] }
        set { d.set(newValue, forKey: Keys.filterTaxonomyNodes) }
    }
```

- [ ] **Step 4: Update SourceRegistry for node ID-based filtering**

In `feedmine/Services/SourceRegistry.swift`, `isSourceEnabled` (around line 67):

```swift
// The existing check (around line 82):
        if disabled.contains(Self.categoryKey(source.category)) { return false }

// Change to also check the full node path. FeedSource.category is now the
// leaf node ID (e.g. "countries/brazil/news") instead of a flat name.
// The category key still works for toggling individual leaf categories.
// No code change needed — the key is derived from the category string,
// which is now the full node path. Verify this by checking:
//   source.category == "coffee-tea/coffee-news" (was "Coffee News")
// Since the OPMLParser now produces full-path categories from Task 3,
// this check naturally works.
```

Note: after Task 3, `source.category` contains the full node path. The `categoryKey(_:)` function already accepts any string, so no code change is needed. But we should verify the OPMLParser produces full paths now:

In `feedmine/Services/OPMLParser.swift`, update the `OPMLDelegate` category assignment (around line 394):

```swift
// OLD: category: category (just the outline text)
// NEW: category: build node path from region + category stack
        let nodePath: String
        if region == "global" {
            let slug = category.lowercased()
                .replacingOccurrences(of: "&", with: "and")
                .replacingOccurrences(of: " ", with: "_")
            nodePath = slug
        } else {
            let regionSlug = region.replacingOccurrences(of: "/", with: "/")
            let catSlug = category.lowercased()
                .replacingOccurrences(of: "&", with: "and")
                .replacingOccurrences(of: " ", with: "_")
            nodePath = "\(regionSlug)/\(catSlug)"
        }
        sources.append(
            FeedSource(
                title: title.isEmpty ? category : title,
                url: xmlUrl,
                category: nodePath,
                region: region,
                mediaKind: resolvedKind,
                language: resolvedLanguage
            )
        )
```

- [ ] **Step 5: Build to verify compilation**

```bash
xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add feedmine/Services/FeedStore.swift feedmine/Services/FeedLoader.swift feedmine/Services/AppSettings.swift feedmine/Services/SourceRegistry.swift feedmine/Services/OPMLParser.swift
git commit -m "feat: replace single category filter with multi-select taxonomy node filter"
```

---

### Task 5: UI — TaxonomyChipBar (Replace CategoryFilterBar)

**Files:**
- Create: `feedmine/Views/TaxonomyChipBar.swift`
- Modify: `feedmine/Views/FeedScreen.swift` (usage sites)
- Delete: `feedmine/Views/CategoryFilterBar.swift`

**Interfaces:**
- Consumes: `FeedLoader.selectedNodeIDs`, `FeedLoader.selectedNodeNames`, `FeedLoader.toggleNode(_:)`, `FeedLoader.clearTaxonomySelection()`
- Produces: `TaxonomyChipBar` SwiftUI view

- [ ] **Step 1: Create TaxonomyChipBar**

Create `feedmine/Views/TaxonomyChipBar.swift`:

```swift
import SwiftUI

/// Horizontal scrollable chip bar showing selected taxonomy nodes.
/// Replaces the flat `CategoryFilterBar` with multi-select chip UI.
/// Max 3 visible chips; overflow shows "+N more".
struct TaxonomyChipBar: View {
    @Environment(FeedLoader.self) private var loader
    let onEditTap: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // "All" chip — shown when nothing selected, or always as reset
                if !loader.hasTaxonomySelection {
                    TaxonomyChip(
                        title: "All",
                        isSelected: true,
                        color: .gray
                    ) {}
                } else {
                    TaxonomyChip(
                        title: "All",
                        isSelected: false,
                        color: .gray
                    ) {
                        loader.clearTaxonomySelection()
                    }
                }

                // Selected node chips (max 3)
                let names = loader.selectedNodeNames
                ForEach(Array(names.prefix(3)), id: \.self) { name in
                    TaxonomyChip(
                        title: name,
                        isSelected: true,
                        color: .blue
                    ) {
                        // Find the node ID for this name and toggle it off
                        if let nodeID = TaxonomyStore.shared.selectedNodeIDs
                            .first(where: { TaxonomyStore.shared.node(id: $0)?.name == name }) {
                            loader.toggleNode(nodeID)
                        }
                    }
                }

                // Overflow indicator
                if names.count > 3 {
                    Text("+\(names.count - 3) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                }

                // Edit button → opens filter sheet
                Button {
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                    onEditTap()
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}

/// A single selectable chip, reused from the original CategoryPill design.
struct TaxonomyChip: View {
    let title: String
    let isSelected: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            action()
        }) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? .white : .primary)
                if isSelected {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(isSelected ? color : color.opacity(0.1))
            )
            .scaleEffect(isSelected ? 1.0 : 0.97)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 2: Update FeedScreen to use TaxonomyChipBar**

In `feedmine/Views/FeedScreen.swift`, find all references to `CategoryFilterBar` and replace with `TaxonomyChipBar`. Also update all references to `loader.selectedCategory`, `loader.selectCategory`, `loader.availableCategories`:

```swift
// Find: CategoryFilterBar()
// Replace with:
            TaxonomyChipBar {
                showFilters = true
            }

// Find all references to loader.selectedCategory and update:
// OLD: if loader.selectedCategory != nil || loader.selectedMood != .all ...
// NEW: if loader.hasTaxonomySelection || loader.selectedMood != .all ...

// OLD: if let cat = loader.selectedCategory { parts.append(cat) }
// NEW: if loader.hasTaxonomySelection {
//     parts.append(contentsOf: loader.selectedNodeNames)
// }

// OLD: let region = loader.selectedCategory  // activeCategory from FeedStore
// NEW: let hasTaxonomy = loader.hasTaxonomySelection

// OLD: let hasFilters = loader.selectedCategory != nil || mood != .all ...
// NEW: let hasFilters = loader.hasTaxonomySelection || mood != .all ...

// OLD: if let cat = loader.selectedCategory { chip(cat, action: { loader.selectCategory(cat) }) }
// NEW: ForEach(loader.selectedNodeNames, id: \.self) { name in
//     chip(name, action: { /* handled by TaxonomyChipBar */ })
// }

// OLD: let activeCount = (loader.selectedCategory != nil ? 1 : 0) + ...
// NEW: let activeCount = (loader.hasTaxonomySelection ? loader.selectedNodeIDs.count : 0) + ...

// OLD: && loader.selectedCategory == nil
// NEW: && !loader.hasTaxonomySelection

// OLD: EmptyFilterView(category: loader.selectedCategory ?? "matching")
// NEW: EmptyFilterView(category: loader.selectedNodeNames.joined(separator: ", "))
```

- [ ] **Step 3: Delete old CategoryFilterBar**

```bash
rm feedmine/Views/CategoryFilterBar.swift
```

Remove from Xcode project navigator (if needed, the build will catch missing references).

- [ ] **Step 4: Build to verify compilation**

```bash
xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add feedmine/Views/TaxonomyChipBar.swift feedmine/Views/FeedScreen.swift
git rm feedmine/Views/CategoryFilterBar.swift
git commit -m "feat: replace CategoryFilterBar with TaxonomyChipBar — multi-select chips"
```

---

### Task 6: UI — TaxonomyTreeView in FilterSheetView

**Files:**
- Create: `feedmine/Views/TaxonomyTreeView.swift`
- Modify: `feedmine/Views/FilterSheetView.swift`

**Interfaces:**
- Consumes: `TaxonomyStore.children(of:)`, `TaxonomyStore.search(_:)`, `TaxonomyStore.toggle(_:)`, `TaxonomyStore.selectedNodeIDs`
- Consumes: `FeedLoader.toggleNode(_:)`, `FeedLoader.availableTaxonomyRoot`
- Produces: `TaxonomyTreeView` — expandable tree with checkboxes and search

- [ ] **Step 1: Create TaxonomyTreeView**

Create `feedmine/Views/TaxonomyTreeView.swift`:

```swift
import SwiftUI

/// Expandable taxonomy tree with checkboxes and search bar.
/// Used inside FilterSheetView and as a standalone drill-down.
///
/// Performance:
/// - Uses `List` for cell reuse (UITableView-backed)
/// - Each level lazy-loads children
/// - Search uses `TaxonomyStore.search` with flat index O(n)
/// - Nodes collapsed by default beyond depth 2
struct TaxonomyTreeView: View {
    @Environment(FeedLoader.self) private var loader
    @State private var store = TaxonomyStore.shared
    @State private var searchText = ""
    @State private var searchResults: [TaxonomyNode] = []
    @State private var searchTask: Task<Void, Never>?

    /// Whether to show in compact mode (sheet) vs full-screen.
    var compact: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search tags...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        searchResults = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if !searchText.isEmpty {
                // Search results — flat list with breadcrumb paths
                List(searchResults) { node in
                    searchResultRow(node)
                }
                .listStyle(.plain)
            } else {
                // Tree view
                List {
                    if let root = store.root {
                        OutlineGroup(root, children: children) { node in
                            taxonomyRow(node)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .onChange(of: searchText) { _, query in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                searchResults = store.search(query)
            }
        }
    }

    // MARK: - Children provider for OutlineGroup

    private func children(of node: TaxonomyNode) -> [TaxonomyNode] {
        store.children(of: node.id)
    }

    // MARK: - Tree row

    private func taxonomyRow(_ node: TaxonomyNode) -> some View {
        HStack(spacing: 8) {
            // Checkbox
            Button {
                loader.toggleNode(node.id)
            } label: {
                Image(systemName: store.selectedNodeIDs.contains(node.id)
                      ? "checkmark.circle.fill"
                      : "circle")
                    .foregroundStyle(store.selectedNodeIDs.contains(node.id) ? .blue : .secondary.opacity(0.3))
                    .font(.body)
            }
            .buttonStyle(.plain)

            // Icon based on kind
            Image(systemName: icon(for: node.kind))
                .font(.caption)
                .foregroundStyle(node.kind == .country ? .green : .secondary)
                .frame(width: 16)

            // Name
            Text(node.name)
                .font(.subheadline)
                .lineLimit(1)

            Spacer()

            // Feed count badge
            Text("\(node.feedCount)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
        .padding(.vertical, 2)
    }

    // MARK: - Search result row

    private func searchResultRow(_ node: TaxonomyNode) -> some View {
        Button {
            loader.toggleNode(node.id)
            searchText = ""
            searchResults = []
        } label: {
            HStack(spacing: 8) {
                Image(systemName: store.selectedNodeIDs.contains(node.id)
                      ? "checkmark.circle.fill"
                      : "circle")
                    .foregroundStyle(store.selectedNodeIDs.contains(node.id) ? .blue : .secondary.opacity(0.3))

                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Text(breadcrumb(for: node))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer()

                Text("\(node.feedCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func breadcrumb(for node: TaxonomyNode) -> String {
        store.ancestors(of: node.id)
            .filter { $0.id != TaxonomyNode.rootID && $0.id != node.id }
            .map(\.name)
            .joined(separator: " > ")
    }

    private func icon(for kind: NodeKind) -> String {
        switch kind {
        case .topic: return "square.grid.2x2"
        case .country: return "flag"
        case .region: return "mappin.and.ellipse"
        case .subcategory: return "folder"
        }
    }
}
```

- [ ] **Step 2: Update FilterSheetView to use TaxonomyTreeView**

In `feedmine/Views/FilterSheetView.swift`, replace the "Category" section (around lines 59-75):

```swift
// Replace the entire Section("Category") { ... } block with:
                Section("Topics") {
                    TaxonomyTreeView()
                }
```

Also remove the `categoryIcon(_:)` helper method (around lines 101-110) since it's no longer needed.

- [ ] **Step 3: Build to verify compilation**

```bash
xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add feedmine/Views/TaxonomyTreeView.swift feedmine/Views/FilterSheetView.swift
git commit -m "feat: add TaxonomyTreeView with search — replace flat category list in FilterSheet"
```

---

### Task 7: UI — TaxonomyBrowseView (Full-screen Drill-down)

**Files:**
- Create: `feedmine/Views/TaxonomyBrowseView.swift`

**Interfaces:**
- Consumes: `TaxonomyStore.children(of:)`, `TaxonomyStore.toggle(_:)`, `TaxonomyStore.selectedNodeIDs`
- Consumes: `FeedLoader.toggleNode(_:)`
- Produces: `TaxonomyBrowseView` — full-screen `NavigationStack` drill-down

- [ ] **Step 1: Create TaxonomyBrowseView**

Create `feedmine/Views/TaxonomyBrowseView.swift`:

```swift
import SwiftUI

/// Full-screen taxonomy browser with NavigationStack drill-down.
/// Each level shows direct children of the current node with checkboxes.
/// Tapping a row with children navigates deeper.
struct TaxonomyBrowseView: View {
    @Environment(FeedLoader.self) private var loader
    @State private var store = TaxonomyStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            if let root = store.root {
                TaxonomyLevelView(node: root)
                    .navigationTitle("Topics")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { dismiss() }
                        }
                    }
            }
        }
    }
}

/// A single level of the taxonomy browse — shows children of one node.
private struct TaxonomyLevelView: View {
    @Environment(FeedLoader.self) private var loader
    @State private var store = TaxonomyStore.shared
    let node: TaxonomyNode

    var body: some View {
        let children = store.children(of: node.id)
        List {
            if node.id != TaxonomyNode.rootID {
                // "All in this category" toggle
                Button {
                    loader.toggleNode(node.id)
                } label: {
                    HStack {
                        Image(systemName: store.selectedNodeIDs.contains(node.id)
                              ? "checkmark.circle.fill"
                              : "circle")
                            .foregroundStyle(store.selectedNodeIDs.contains(node.id) ? .blue : .secondary)
                        Text("All \(node.name)")
                            .fontWeight(.medium)
                        Spacer()
                        Text("\(node.feedCount) feeds")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }

            ForEach(children) { child in
                let grandchildCount = store.children(of: child.id).count
                if grandchildCount > 0 {
                    // Has children — navigate deeper
                    NavigationLink {
                        TaxonomyLevelView(node: child)
                            .navigationTitle(child.name)
                    } label: {
                        HStack {
                            Image(systemName: store.selectedNodeIDs.contains(child.id)
                                  ? "checkmark.circle.fill"
                                  : "circle")
                                .foregroundStyle(store.selectedNodeIDs.contains(child.id) ? .blue : .secondary)
                            Text(child.name)
                            Spacer()
                            Text("\(child.feedCount)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    // Leaf — no children, just toggle
                    Button {
                        loader.toggleNode(child.id)
                    } label: {
                        HStack {
                            Image(systemName: store.selectedNodeIDs.contains(child.id)
                                  ? "checkmark.circle.fill"
                                  : "circle")
                                .foregroundStyle(store.selectedNodeIDs.contains(child.id) ? .blue : .secondary)
                            Text(child.name)
                            Spacer()
                            Text("\(child.feedCount)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.plain)
    }
}
```

- [ ] **Step 2: Add Browse button to FilterSheetView**

In `feedmine/Views/FilterSheetView.swift`, add a "Browse All Topics" button at the bottom of the Taxonomy section:

```swift
// After TaxonomyTreeView() in the Section("Topics") block, add:
                    NavigationLink {
                        TaxonomyBrowseView()
                    } label: {
                        Label("Browse All Topics", systemImage: "list.bullet.rectangle")
                    }
```

- [ ] **Step 3: Build to verify compilation**

```bash
xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add feedmine/Views/TaxonomyBrowseView.swift feedmine/Views/FilterSheetView.swift
git commit -m "feat: add TaxonomyBrowseView — full-screen drill-down topic browser"
```

---

### Task 8: Performance Validation and Final Integration

**Files:**
- Modify: `feedmine/feedmineApp.swift` (startup: build taxonomy)
- No new files

**Interfaces:**
- Consumes: All prior tasks
- Produces: Working end-to-end taxonomy with verified performance

- [ ] **Step 1: Wire taxonomy build at app startup**

In `feedmine/feedmineApp.swift`, after the `FeedLoader` is created and sources are loaded, trigger the taxonomy build:

```swift
// After loader.start() or where sources are first available:
Task {
    // Try cached tree first
    if !TaxonomyStore.shared.loadFromCache() {
        await TaxonomyStore.shared.build(from: loader.sources)
    }
}
```

- [ ] **Step 2: Verify cold build performance**

Add a temporary timing log in `TaxonomyStore.build(from:)`:

```swift
let start = CFAbsoluteTimeGetCurrent()
// ... build logic ...
let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
Log.feed.info("taxonomy built in \(String(format: "%.1f", elapsed))ms — \(flatIndex.count) nodes, \(feedToNodeID.count) feeds")
```

Build and run:

```bash
xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Launch in simulator and check Xcode console for timing. Expected: <500ms.

- [ ] **Step 3: Verify search performance**

Test by typing in the search bar in `TaxonomyTreeView`. Results should appear within 100ms (the debounce is 300ms, but after that, results should be instant).

- [ ] **Step 4: Verify scroll performance**

Open `FilterSheetView` and expand nodes with 30+ children. Scroll should be 60fps (List cell reuse).

- [ ] **Step 5: Remove temporary timing log**

Remove the `CFAbsoluteTimeGetCurrent()` timing code from `TaxonomyStore.build(from:)`.

- [ ] **Step 6: Run full test suite**

```bash
xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "Test.*passed|Test.*failed|BUILD|Executed"
```

Expected: All tests pass, no regressions.

- [ ] **Step 7: Commit**

```bash
git add feedmine/feedmineApp.swift feedmine/Services/TaxonomyStore.swift
git commit -m "feat: wire taxonomy build at startup, validate performance"
```
