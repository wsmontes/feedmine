# Feed Taxonomy — Design Spec

**Date:** 2026-07-15
**Status:** Draft

---

## 1. Overview

Replace the current flat `category` system with a hierarchical taxonomy derived from the existing OPML file structure. Each feed belongs to exactly one path in the tree (single-home), but the filter UI supports multi-select with **union semantics**, giving users the practical equivalent of multi-label tagging without the maintenance cost.

### Key decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Taxonomy source | Derived from OPML directory + `<outline>` structure | Zero new config files, ~2K OPMLs already have rich hierarchy |
| Feed-to-node relationship | Single-home (one path per feed) | Sufficient for feed reader; multi-label achieved via filter union |
| Filter semantics | Multi-select, union of sub-trees | User selects N nodes → sees all feeds in those sub-trees |
| Language detection | Declarative via `language` attribute in OPML `<head>` and `<outline>` | Precise, auditable, no guessing |
| Tree depth | Arbitrary (no limit) | Mirrors filesystem + OPML nesting faithfully |

---

## 2. Data Model

### 2.1 TaxonomyNode

```swift
enum NodeKind: String, Codable, Sendable {
    case topic        // global topic OPML (coffee_tea, tech, science)
    case country      // country directory
    case region       // sub-region within a country
    case subcategory  // <outline> group within an OPML
}

struct TaxonomyNode: Identifiable, Hashable, Sendable {
    let id: String             // canonical slug path: "countries/brazil/news"
    let name: String           // display name: "News"
    let parentId: String?      // nil = virtual root
    let childrenCount: Int     // direct children (nodes, not feeds)
    let feedCount: Int         // total feeds in this subtree (incl. descendants)
    let language: String?      // inherited from OPML <head> or parent <outline>
    let level: Int             // 0 = virtual root, 1, 2, ...
    let kind: NodeKind
}
```

**ID scheme**: IDs are slug path segments joined by `/`. The virtual root has a special sentinel ID (e.g., `__root__`). Examples:
- `coffee-tea` (topic OPML)
- `coffee-tea/coffee-news` (subcategory)
- `countries/brazil` (country)
- `countries/brazil/sao-paulo` (region)
- `countries/brazil/sao-paulo/sports` (subcategory within region OPML)

### 2.2 FeedSource (updated)

```swift
struct FeedSource: Codable, Identifiable, Sendable {
    let title: String
    let url: String
    let category: String       // NOW: taxonomy node ID (leaf path), was flat string
    let region: String         // preserved for backward compat: "global" | "countries/brazil"
    let mediaKind: MediaKind
    let language: String?      // NEW — inherited from OPML <head> or <outline>
}
```

Migration: existing `category` values that don't match any taxonomy node ID are aliased automatically (see Section 5).

### 2.3 TaxonomyStore

```swift
@MainActor
final class TaxonomyStore: ObservableObject {
    static let shared = TaxonomyStore()

    private(set) var root: TaxonomyNode?
    private(set) var flatIndex: [String: TaxonomyNode] = [:]   // O(1) lookup
    private(set) var feedToNodeIDs: [String: String] = [:]     // feed URL → leaf node ID
    private(set) var selectedNodeIDs: Set<String> = []

    func build(from sources: [FeedSource]) async
    func invalidateCache()
    func search(_ query: String) -> [TaxonomyNode]
    func ancestors(of nodeId: String) -> [TaxonomyNode]
    func children(of nodeId: String) -> [TaxonomyNode]
    func select(_ nodeId: String)
    func deselect(_ nodeId: String)
    func clearSelection()
}
```

---

## 3. OPML Changes

### 3.1 Language declaration (NEW)

```xml
<!-- Per-file default -->
<head>
  <title>Coffee &amp; Tea — Brewing, Culture &amp; Reviews</title>
  <language>en</language>
</head>

<!-- Per-outline override -->
<outline text="Coffee News" language="en">
  <outline title="Sprudge" xmlUrl="https://sprudge.com/feed" type="rss" />
</outline>
```

**Inheritance rule**: feed inherits `language` from nearest parent `<outline>` → file `<head>` → `nil` (future: auto-detect fallback).

### 3.2 No other OPML changes required

The taxonomy tree is built entirely from the existing structure:
- Directories → parent nodes
- OPML file name → topic/country/region node
- `<outline text="...">` → subcategory nodes (may nest to arbitrary depth)
- `<outline title="..." xmlUrl="..." type="...">` → feed leaf

No new OPML attributes are needed beyond `language`. The existing `type` attribute on feed outlines already maps to `MediaKind`.

---

## 4. Tree Construction Algorithm

```
buildTree(sources: [FeedSource]) -> TaxonomyNode:
  1. For each OPML file path (e.g. "countries/brazil/sao-paulo.opml"):
     a. Split directory components → create/merge ancestor nodes
     b. Parse OPML → for each <outline>:
        - If it contains feed children → subcategory node
        - Feed outlines become leaves, inherit taxonomy path
  2. Compute feedCount bottom-up for every node
  3. Serialize to disk cache (JSON)
  4. Build flatIndex for O(1) lookups
```

Complexity: **O(n)** single pass over all `FeedSource` items. ~50K sources takes <500ms cold.

---

## 5. UI Design

### 5.1 Replacements

| Before | After |
|--------|-------|
| `CategoryFilterBar` (horizontal pills) | `TaxonomyChipBar` — selected node chips + "Edit" button |
| `FilterSheetView` Category section (flat list) | `TaxonomyTreeView` — expandable tree with checkboxes and search |

### 5.2 TaxonomyChipBar

```
┌──────────────────────────────────────────────────┐
│  [All]  [Coffee & Tea ×]  [Brazil ×]  [+ Edit]   │
└──────────────────────────────────────────────────┘
```

- Max 3 visible chips, overflow shows "+N more"
- `×` deselects individual node
- "Edit" or filter icon opens `FilterSheetView`
- "All" chip shown when nothing selected

### 5.3 FilterSheetView — Taxonomy section

```
┌─────────────────────────────────────┐
│  TAXONOMY                           │
│  🔍 Search tags...                  │
│                                     │
│  ▼ ☐ Coffee & Tea          (10)    │
│     ☐ Coffee News            (5)   │
│     ☑ Coffee Brewing         (3)   │
│     ☐ Tea Culture            (2)   │
│  ▶ ☐ Tech                   (45)   │
│  ▼ ☑ Countries             (120)   │
│     ▶ ☐ Brazil              (30)   │
│        ☐ News                (15)  │
│        ☐ Sports              (8)   │
│        ☐ Tech                (7)   │
│     ▶ ☐ France               (8)   │
│  ▶ ☐ Science                 (32)  │
└─────────────────────────────────────┘
```

Behavior:
- `▶/▼` expands/collapses; collapsed by default at depth > 2
- `☐/☑` selects the node → union of all descendant feeds
- Selecting a parent does NOT auto-select children
- Count `(N)` = total feeds in subtree at any depth
- Search bar filters nodes flat + auto-expands path to matches
- Content Type and Mood sections remain unchanged from current

### 5.4 Full-screen drill-down (alternative browse mode)

When tapping "Browse All" from the sheet, a dedicated `NavigationStack` drill-down:

```
Screen 1:                 Screen 2 (after tapping Coffee & Tea):
┌──────────────────┐      ┌──────────────────────────┐
│  ← Taxonomy      │      │  ← Coffee & Tea          │
├──────────────────┤      ├──────────────────────────┤
│  Coffee & Tea  > │      │  ☑ All Coffee & Tea (10) │
│  Tech          > │      │  Coffee News     (5)  >  │
│  Countries     > │      │  Coffee Brewing  (3)  >  │
│  Science       > │      │  Tea Culture     (2)  >  │
└──────────────────┘      └──────────────────────────┘
```

This mode is better for exploring than the collapsed tree in the sheet. The sheet stays compact; drill-down is for discovery.

---

## 6. Performance Guarantees

### 6.1 Build phase

| Operation | Strategy | Target |
|-----------|----------|--------|
| Parse 1,995 OPMLs → tree | Single pass, O(n) | <500ms cold, <50ms warm (disk cache) |
| Disk cache | `taxonomy_cache.json` alongside `opml_manifest.json` | Invalidated when OPML manifest changes |

### 6.2 Render phase

| Scenario | Strategy | Target |
|----------|----------|--------|
| Scroll with 5K+ visible rows | `List` + `DisclosureGroup` (cell reuse via UITableView) | 60fps |
| Deeply nested trees | Collapse nodes with >50 children by default; lazy-load on expand | No dropped frames on expand |
| Search | `flatIndex` O(1) lookup, filtered in background Task, 300ms debounce | <100ms results |

### 6.3 Memory

- `TaxonomyNode` structs ~128 bytes each
- ~5K nodes → ~640KB
- With SwiftUI overhead → <2MB for the full tree in memory

### 6.4 Safe defaults

- Expand only 2 levels deep initially; everything else collapsed
- Nodes with >50 children: show top 20 + "Show all N..." expander
- Search results limited to 50 matches
- Guard assertion on >10K nodes (warn, don't crash)

---

## 7. Filter Logic (Update to FeedStore/FeedLoader)

### 7.1 Multi-select union

```
visibleItems = allItems.filter { item in
    if selectedNodeIDs.isEmpty { return true }  // nothing selected = show all
    return selectedNodeIDs.contains(where: { nodeId in
        taxonomyStore.isFeedInSubtree(item.feedURL, nodeId: nodeId)
    })
}
```

`isFeedInSubtree` is precomputed: `feedToNodeIDs` maps URL → leaf node ID, and `isAncestor(nodeId, leafId)` is O(depth) via parent chain traversal.

### 7.2 Composition with other filters

Filters remain orthogonal — all applied as AND:

```
visible = all
  ∩ taxonomyFilter(selectedNodeIDs)   // UNION of selected subtrees
  ∩ contentTypeFilter(selectedType)
  ∩ moodFilter(selectedMood)
  ∩ regionFilter(enabledRegions)
  ∩ searchQuery(query)
  ∩ contentFilters(activeKeywords)
```

### 7.3 Interaction with Region/Country toggles

The existing "Selected Feeds" and "Countries" toggles in the filter sheet remain as-is. They act as additional AND filters on top of taxonomy selection. A user can say "show me feeds tagged Coffee OR Brazil, but ONLY text articles, and ONLY from globally-enabled countries."

---

## 8. Migration Path

1. **Build taxonomy tree** from existing OPML structure — no data changes needed
2. **Map existing `category` strings** to taxonomy node IDs: prepend the OPML file slug path to the category value (e.g., category "Coffee News" in `coffee_tea.opml` → node ID `coffee-tea/coffee-news`). For feeds in country OPMLs, prepend the full country path (e.g., `countries/brazil/news`)
3. **Replace `selectedCategory: String?`** with `selectedNodeIDs: Set<String>`
4. **New UI components**: `TaxonomyChipBar`, `TaxonomyTreeView`, `TaxonomyBrowseView`
5. **Add `language` attribute** to OPML `<head>` elements incrementally (not blocking)
6. **Ship**: users see the tree immediately; no migration UX needed

---

## 9. Future Extensions (Out of Scope)

- Auto-detection language fallback when no `language` in OPML
- Explicit `tags="..."` attribute on feed outlines for true multi-home
- Cross-OPML symlinks (reference a feed by URL from another OPML)
- Taxonomy-based "similar feeds" recommendations
- User-curated taxonomy nodes (custom folders/tags)
- Analytics: which taxonomy nodes drive the most engagement

---

## 10. Implementation Order (Recommended)

1. **Data model** — `TaxonomyNode`, `NodeKind`, update `FeedSource.language`
2. **TaxonomyStore** — tree builder, cache, search, selection state
3. **OPMLParser update** — parse `<language>` from `<head>` and `<outline>`
4. **FeedStore/FeedLoader update** — `selectedNodeIDs`, union filter logic
5. **UI: TaxonomyChipBar** — replace `CategoryFilterBar`
6. **UI: FilterSheetView update** — replace category list with tree
7. **UI: TaxonomyBrowseView** — full-screen drill-down mode
8. **Performance validation** — verify cold build <500ms, scroll 60fps
9. **Add `language` to OPML files** — incremental, not blocking
