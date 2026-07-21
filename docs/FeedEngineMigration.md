# FeedEngine Migration — Stage 1: Verified Diagnosis, Baseline & Boundary

**Date:** 2026-07-16  
**Last updated:** 2026-07-17  
**Repository:** `wawasoft/feedmine`
**Reviewed branch:** `main`  
**Reviewed commit:** `58ab9229`  
**Status:** Stage 1 — verified diagnosis, measurement, and architectural boundary  
**Target:** Safe, incremental migration from the in-memory `FeedStore` architecture to a paginated, SQLite-backed `FeedEngine`, without changing current user-facing behavior.

---

## Evidence labels used in this document

To avoid mixing observation with assumption, statements are classified as:

- **Confirmed:** verified in the reviewed repository snapshot.
- **Reported:** copied from an existing audit or test result but not re-executed during this review.
- **Estimated:** a hypothesis that must be replaced by measurement.
- **Target decision:** a rule for the new architecture, not a description of the current implementation.

Line numbers and file counts are snapshot data. They must be refreshed whenever this document is updated against a new commit.

---

## Executive decisions

The migration is based on the following non-negotiable decisions:

1. **OPML files and directory structure remain the editorial source of truth.**
2. **`catalog.sqlite` is a compiled, disposable, read-optimized index.**
3. **User state and operational content state live in separate databases.**
4. **The application never materializes the complete catalog as Swift objects.**
5. **Cold start never parses the complete OPML corpus or recompiles the catalog.**
6. **Catalog publication is versioned and atomic.** Readers see either the old valid catalog or the new valid catalog, never a partially compiled database.
7. **Pagination uses keyset cursors, not offsets.**
8. **Cross-database identity must remain stable after a full catalog rebuild.** SQLite auto-generated row IDs alone cannot provide that guarantee.
9. **URL canonicalization must be conservative.** `http`, `https`, `www`, trailing slashes, and query parameters are not automatically equivalent.
10. **The first migration vertical is catalog compilation, browse, and search only.** Timeline, fetching, and the reservoir remain on the legacy path until the catalog vertical is proven.

---

# Part I — Verified diagnosis

## 1. Reviewed repository snapshot

### 1.1 Current corpus

**Reported by `docs/audit-taxonomy-filtering-2026-07-16.md`:**

- 4,534 OPML files
- 39,697 unique sources
- 18,197 duplicate source occurrences removed by the current global deduplication step
- 82 tests reported passing: 75 unit tests and 7 UI tests

The previous draft used 24,045 unique sources. That number is stale for the reviewed `main` snapshot and must not be used as the current baseline.

### 1.2 Current central coordinator

**Confirmed:**

```swift
@MainActor
@Observable
final class FeedStore {
```

`FeedStore` owns or coordinates:

- database lifecycle and migrations;
- source registry;
- source scheduling;
- HTTP fetching;
- item ingestion and persistence;
- taxonomy and content filtering;
- reservoir updates;
- read and surfaced state;
- search;
- bookmarks;
- What's New;
- image prefetching;
- maintenance;
- public observable state consumed by SwiftUI.

The architectural problem is not merely file length. The main problem is that UI state, domain policy, persistence, network orchestration, and catalog ownership share the same actor and lifecycle.

### 1.3 Current data flow

```text
OPML files
    ↓
OPMLParser.parseAll()
    ↓
Global URL deduplication
    ↓
SourceRegistry.sources             complete source catalog in memory
    ├── TaxonomyStore.build()      complete taxonomy indices in memory
    ├── SourceScheduler            URL-keyed operational dictionaries
    └── source enablement          URL/string-keyed user state
    ↓
RSSFetcher
    ↓
FeedStore.persistFetchedItems()
    ↓
feedmine.sqlite
    ↓
Reservoir
    ↓
FeedStore filtering and UI pipeline
    ↓
FeedLoader / SwiftUI
```

### 1.4 Current storage ownership

The current `feedmine.sqlite` combines several concerns:

| Current data | Architectural owner in the target design |
|---|---|
| `feed_item`, FTS content index | `content.sqlite` |
| source health and fetch state | `content.sqlite` |
| bookmark lists and bookmark items | `user.sqlite` |
| source toggles and user overrides | `user.sqlite` |
| source catalog | currently memory-only; target `catalog.sqlite` |
| taxonomy | currently memory/cache-only; target `catalog.sqlite` |

The target separation is logical and physical. It is not simply a set of repository protocols around the same database.

---

## 2. Confirmed scaling constraints

### 2.1 Entire catalog is retained in memory

**Confirmed:** `SourceRegistry` retains the complete source collection, while `TaxonomyStore` maintains complete reverse and forward lookup structures.

The exact byte cost is **not currently measured**. Previous estimates such as "~200 bytes per `FeedSource`" or "~6 MB for a dictionary" must be treated as directional only because Swift strings and collections use shared heap storage, copy-on-write behavior, capacity slack, and allocator metadata.

The correct baseline is process `phys_footprint`, allocations, retained object counts, and collection counts measured at defined points.

### 2.2 Current deduplication destroys provenance

**Confirmed:** `OPMLParser.parseAll()` globally deduplicates sources after parsing and keeps the first occurrence in sorted file order.

This creates two problems for the target architecture:

1. A source appearing in several OPML files loses all but one editorial occurrence.
2. "First file wins" becomes an accidental metadata precedence rule.

The compiler must not deduplicate editorial placements. It must deduplicate only the intrinsic source record while preserving every placement.

### 2.3 URL strings are both identity and transport

**Confirmed:** the current implementation uses normalized URL strings as source identity, scheduler keys, taxonomy membership keys, toggle keys, and SQL filter values.

This causes:

- repeated normalization and variant generation;
- large string-keyed runtime maps;
- coupling between source identity and a mutable network endpoint;
- difficult migrations when a feed changes URL;
- broad `IN (...)` queries for taxonomy filtering.

The problem is not that string comparison has a specific universal slowdown factor. The problem is duplicated variable-length identity and the inability to maintain a stable cross-database reference when the URL changes.

### 2.4 Taxonomy filtering expands nodes into URL sets

**Confirmed:** the legacy pipeline resolves selected taxonomy nodes into a set of feed URLs, then builds URL variants and queries `feed_item.source_url` with batched `IN` clauses.

This is acceptable as a temporary compatibility path. It is not the target design. The target design uses `SourceID` and relational joins without expanding a broad taxonomy into a large Swift array.

### 2.5 Startup depends on catalog reconstruction caches

**Confirmed:** the current parser cache is stored in `Caches/opml-parse-cache.plist`. A cache miss reparses the complete OPML corpus. The fingerprint currently enumerates OPML files and reads modification dates on every launch.

The code comment calling the cache path "O(1), no filesystem walk or stat" is inaccurate for the reviewed implementation: `cacheFingerprint()` performs a recursive enumeration before attempting to load the cache.

This cache improves the legacy architecture but does not solve the target cold-start requirement. A compiled catalog must already exist before the runtime UI path begins.

---

## 3. Confirmed current defects

These defects belong to a **parallel stabilization track**. They should not wait for FeedEngine, and FeedEngine should not be presented as their fix.

### 3.1 Taxonomy reverse index missing after cache restore

**Confirmed in `TaxonomyStore.loadFromCache()`:**

- `flatIndex` is restored;
- `feedToNodeID` is restored;
- `childrenIndex` is rebuilt;
- `nodeToFeedURLs` is not rebuilt or restored.

Result: the warm-cache path can return empty URL sets for taxonomy subtree queries.

**Required legacy fix:** rebuild `nodeToFeedURLs` during cache load or serialize it as part of the cache.

### 3.2 Reservoir flush and refresh ordering race

**Confirmed:** `flushPendingReservoir()` launches detached work and returns immediately. The urgent taxonomy fetch then schedules `.refresh`. The refresh can execute before the detached interleave has appended the new items.

**Required legacy fix:** make the flush awaitable and await completion before scheduling refresh, or combine append and refresh into one actor-isolated operation.

### 3.3 Bookmark state stamped as false

**Confirmed:** `setVisibleItems` calls:

```swift
item.stamped(readItemIDs: readItemIDs, bookmarkItemIDs: [])
```

**Required legacy fix:** load or maintain the actual bookmarked item ID set and pass it through the single stamping pipeline.

### 3.4 Legacy `http://` rows are excluded by current taxonomy SQL variants

**Confirmed:** the taxonomy SQL path generates normalized `https`, trailing-slash, and `www` variants, but does not generate `http` variants.

**Required legacy fix:** support known legacy aliases while old rows exist, or migrate those rows explicitly.

This defect must not be "fixed" in the new architecture by globally declaring `http` and `https` equivalent.

### 3.5 Additional audit items

The current audit also identifies:

- DST-sensitive `sectionDayOffset` calculation;
- `.trim` without a generation guard;
- `loadedIDs` mutation before stale-generation rejection;
- redundant URL normalization in filtering;
- repeated `searchableText` allocation.

These are useful stabilization tasks but are not FeedEngine Stage 1 acceptance criteria unless explicitly added to the stage scope.

---

# Part II — Baseline and instrumentation

## 4. Measurement rules

### 4.1 Do not use estimates as baseline values

The previous draft included precise startup and memory ranges derived from static inspection. Those figures are hypotheses, not a baseline.

The baseline table must contain measured results with:

- device model;
- OS version;
- build configuration;
- commit SHA;
- database size and row counts;
- catalog/cache state;
- number of runs;
- median and p95 where useful.

### 4.2 Physical device is the performance authority

Use a physical supported iPhone for startup, memory, CPU, I/O, and scrolling measurements.

The simulator remains useful for:

- functional tests;
- deterministic integration tests;
- UI automation;
- query correctness.

Simulator timings must not become release performance targets.

### 4.3 Separate startup milestones

Measure distinct events:

1. process launch;
2. first frame;
3. first screen structure;
4. first cached content;
5. first network-refreshed content;
6. background catalog/cache work complete.

"First CA commit" should be measured with the App Launch template in Instruments, not inferred from a SwiftUI `body` callback.

---

## 5. Required baseline scenarios

### 5.1 Legacy startup scenarios

| Scenario | Purpose |
|---|---|
| Warm OPML parse cache | Normal current startup |
| Missing OPML parse cache | Worst current reconstruction path |
| Warm taxonomy cache | Normal taxonomy startup |
| Missing taxonomy cache | Current rebuild path |
| Empty content database | First-use behavior |
| Representative content database | Normal returning-user behavior |

### 5.2 Catalog-era startup scenarios

| Scenario | Required behavior |
|---|---|
| Valid bundled/current catalog | Open and query immediately |
| Hot-folder changes pending | Show current catalog; compile in background |
| Catalog compilation interrupted | Continue using previous valid catalog |
| Candidate catalog invalid | Reject candidate; continue using current catalog |
| Catalog missing or corrupt | Use bundled fallback where available; rebuild outside the first-render path |

---

## 6. High-value metrics

| ID | Metric | Tool/source |
|---|---|---|
| M1 | Process launch to first frame | Instruments App Launch |
| M2 | Launch to first non-empty cached timeline | signpost + UI marker |
| M3 | `FeedStore.init()` | interval signpost |
| M4 | OPML fingerprint calculation | interval signpost |
| M5 | OPML cache decode | interval signpost |
| M6 | Full OPML parse | interval signpost |
| M7 | Taxonomy cache load or build | interval signpost |
| M8 | Content database query for initial working set | interval signpost |
| M9 | Reservoir seed/interleave | interval signpost |
| M10 | First visible item publication | event signpost |
| M11 | Process `phys_footprint` after key milestones | Instruments / `TASK_VM_INFO` |
| M12 | Source, node, placement, and item counts | structured counters |
| M13 | Fetch batch duration | interval signpost |
| M14 | Ingestion and persistence duration | interval signpost |
| M15 | Catalog browse query median and p95 | repository metrics |
| M16 | Catalog search query median and p95 | repository metrics |
| M17 | Catalog compilation full and incremental duration | compiler report |
| M18 | Candidate validation and atomic publication duration | compiler report |

Per-file OPML timing should be aggregated or sampled. Emitting thousands of signposts can materially alter the operation being measured.

---

## 7. Instrumentation implementation

Use static signpost names. Do not pass dynamic `String` values where the API requires `StaticString`.

A minimal wrapper can use `OSSignposter`:

```swift
import os

#if INSTRUMENTATION
enum FeedMetrics {
    static let signposter = OSSignposter(
        subsystem: "com.feedmine.app",
        category: "FeedEngine"
    )

    static func measure<T>(
        _ name: StaticString,
        operation: () throws -> T
    ) rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try operation()
    }
}
#endif
```

For async operations, provide a separate async wrapper or use explicit begin/end calls.

For memory, use `TASK_VM_INFO` and `phys_footprint`, or rely on Instruments. `mach_task_basic_info.resident_size` is not the same metric as `phys_footprint`.

Enable instrumentation in a dedicated profiling configuration or compilation condition. Debug builds are useful for diagnosis, but final performance numbers should come from an optimized build with signposting enabled.

---

## 8. Baseline results table

Do not prefill expected values as facts.

| Metric | Device | Configuration | Cache state | Median | p95 | Status |
|---|---|---|---|---:|---:|---|
| M1 first frame | — | — | — | — | — | Not measured |
| M2 first cached content | — | — | — | — | — | Not measured |
| M4 OPML fingerprint | — | — | — | — | — | Not measured |
| M5 OPML cache decode | — | — | — | — | — | Not measured |
| M6 full OPML parse | — | — | cache miss | — | — | Not measured |
| M7 taxonomy load/build | — | — | warm/cold | — | — | Not measured |
| M11 `phys_footprint` | — | — | key milestones | — | — | Not measured |
| M15 catalog browse | — | — | compiled catalog | — | — | Future vertical |
| M16 catalog search | — | — | compiled catalog | — | — | Future vertical |

---

# Part III — Target architecture

## 9. Architectural invariants

### 9.1 Editorial authority

The editorial source of truth is:

- directory hierarchy;
- OPML documents;
- nested OPML outline hierarchy;
- source occurrences;
- occurrence order;
- explicit metadata and overrides stored in those files or approved sidecar files.

The database does not invent category membership or ownership.

### 9.1.1 OPML and Folder Structure as Source of Truth

The editorial structure is not transferred permanently into SQLite.

`catalog.sqlite` is a compiled index of the OPML and folder corpus. Deleting
and rebuilding the catalog must produce the same logical hierarchy, source
identity set, placements, provenance, and editorial order from the same files.

A single source may appear in several OPML files or folders. That creates one
operational source identity and multiple editorial placements; it is not an
operational duplicate. Each placement must preserve:

- OPML relative path;
- folder-derived parent path;
- nested outline path where applicable;
- order within the OPML;
- per-placement title, language, or media-kind overrides.

The compiler may optimize this structure for pagination and FTS lookup, but it
must not become the authority for the editorial model.

### 9.2 Compiled catalog

`catalog.sqlite` is:

- derived;
- rebuildable;
- versioned;
- query-optimized;
- read-only for runtime consumers;
- written only as a staging candidate by the compiler;
- published atomically after validation.

A rebuild must reproduce the same **logical dataset and stable identities**. It is not required to produce byte-identical SQLite files; page layout, timestamps, and SQLite implementation details can legitimately differ.

### 9.3 Working set

Runtime Swift objects are bounded by the current operation:

- current catalog page;
- current search page;
- current timeline window;
- small prefetch buffers;
- bounded operational batches.

No public API returns the entire catalog or a complete subtree as an array.

---

## 10. Identity model

### 10.1 Two concepts must not be confused

The target architecture needs both:

1. **`SourceKey`** — stable semantic identity used to reconstruct the same source across catalog rebuilds.
2. **`SourceID`** — compact numeric representation stored in databases and used at runtime.

A SQLite `INTEGER PRIMARY KEY` assigned by insertion order is not sufficient. Adding a source earlier in sort order could renumber later rows and break references in `user.sqlite` and `content.sqlite`.

### 10.2 Recommended representation

```swift
struct SourceID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: Int64
}

struct CatalogNodeID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: Int64
}
```

Use `Int64` because SQLite `INTEGER` is a signed 64-bit value.

### 10.3 Stable ID generation

Default source identity:

```text
SourceKey = versioned conservative canonical form of the declared feed URL
SourceID  = positive 63-bit digest of SourceKey
```

Requirements:

- hash algorithm and canonicalization version are explicit catalog metadata;
- the compiler stores the full `source_key` alongside the numeric ID;
- a numeric collision with a different key fails validation rather than silently merging sources;
- an optional explicit identity key may later be stored in OPML or a versioned sidecar to preserve identity through intentional URL changes.

The same principle applies to catalog nodes: derive a stable `node_key` from the editorial path and compute a deterministic numeric ID.

### 10.4 Source removal does not cascade across databases

Removing a source from OPML removes it from the new catalog version. It must not automatically delete:

- subscriptions;
- bookmarks;
- saved tabs;
- read history;
- retained feed items;
- fetch history.

User and content databases keep their references and enough source snapshot data to represent an orphaned or custom source.

---

## 11. URL model

The current `normalizeURL()` is too aggressive for permanent identity because it:

- converts `http` to `https`;
- strips `www`;
- strips a trailing slash;
- removes query parameters including generic names such as `source` and `ref`.

Those transformations can merge distinct endpoints.

The target model separates:

| Field | Purpose |
|---|---|
| `declared_url` | Exact endpoint written in OPML |
| `request_url` | Endpoint currently used for fetching |
| `source_key` | Stable identity input |
| `display_host` | Presentation/search aid |
| `source_alias` | Explicit or observed equivalent endpoint |

Conservative canonicalization may safely normalize details such as scheme/host case, default ports, and fragments. It must not assume transport or path equivalence without evidence.

Redirects and manually approved replacements are recorded in `source_alias`; they are not inferred through broad query-time variant generation.

---

## 12. Database ownership

### 12.1 `catalog.sqlite`

Contains only compiled editorial/index data:

- catalog metadata and schema version;
- input file manifest and fingerprints;
- intrinsic source records;
- source endpoint aliases;
- catalog nodes;
- source placements;
- search index;
- materialized counts needed for browse UI.

It contains no user choices and no fetch state.

### 12.2 `user.sqlite`

Contains user-owned state:

- subscriptions;
- hidden or muted sources;
- node/source overrides;
- bookmarks and bookmark collections;
- tabs;
- saved queries;
- preferences;
- read and surfaced state, if retained as user history.

Bookmarks must survive content retention. Either bookmark rows store a durable item snapshot or bookmarked content is pinned by an explicit retention rule.

### 12.3 `content.sqlite`

Contains operational and fetched data:

- feed items and content FTS;
- source fetch state;
- ETag and Last-Modified;
- health and backoff state;
- fetch queue and jobs;
- translations;
- content/cache metadata;
- source snapshots required to fetch orphaned subscribed sources.

### 12.4 Cross-database references

Relationships across these databases are logical, not SQL foreign keys. SQLite cannot enforce a normal foreign key constraint into another independent database file.

Therefore:

- deletion in one database does not cascade into another;
- reconciliation is explicit;
- stable IDs and snapshots are mandatory;
- each database owns its own migrations and recovery policy.

---

## 13. Catalog schema

A minimal first-vertical schema:

```sql
CREATE TABLE catalog_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE catalog_file (
    id               INTEGER PRIMARY KEY,
    relative_path    TEXT NOT NULL UNIQUE,
    content_hash     BLOB NOT NULL,
    file_size        INTEGER NOT NULL,
    modified_at      REAL,
    compiler_version INTEGER NOT NULL
);

CREATE TABLE source (
    id             INTEGER PRIMARY KEY,
    source_key     TEXT NOT NULL UNIQUE,
    declared_url   TEXT NOT NULL,
    request_url    TEXT NOT NULL,
    title          TEXT,
    media_kind     INTEGER NOT NULL,
    language       TEXT
);

CREATE TABLE source_alias (
    alias_url  TEXT PRIMARY KEY,
    source_id  INTEGER NOT NULL REFERENCES source(id)
);

CREATE TABLE catalog_node (
    id            INTEGER PRIMARY KEY,
    node_key      TEXT NOT NULL UNIQUE,
    parent_id     INTEGER REFERENCES catalog_node(id),
    name          TEXT NOT NULL,
    kind          INTEGER NOT NULL,
    sort_order    INTEGER NOT NULL,
    source_count  INTEGER NOT NULL DEFAULT 0,
    child_count   INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE catalog_placement (
    id               INTEGER PRIMARY KEY,
    placement_key    TEXT NOT NULL UNIQUE,
    file_id          INTEGER NOT NULL REFERENCES catalog_file(id),
    node_id          INTEGER NOT NULL REFERENCES catalog_node(id),
    source_id        INTEGER NOT NULL REFERENCES source(id),
    sort_order       INTEGER NOT NULL,
    title_override   TEXT,
    language_override TEXT,
    media_kind_override INTEGER
);
```

Required indices include:

```sql
CREATE INDEX idx_node_parent_order
ON catalog_node(parent_id, sort_order, id);

CREATE INDEX idx_placement_node_order
ON catalog_placement(node_id, sort_order, id);

CREATE INDEX idx_placement_source
ON catalog_placement(source_id);
```

Add FTS5 for source title, host, aliases, and denormalized editorial paths. The FTS query returns IDs; a second bounded query hydrates summaries.

### 13.1 Why `catalog_placement` is required

A source can appear:

- in several OPML files;
- in several folders;
- in several nested outlines;
- more than once with different display metadata.

These are not duplicate sources. They are separate editorial placements.

No "primary region" or "first occurrence wins" field is required for the core model. The current browse context comes from the placement and node. Any global display metadata precedence must be explicit and deterministic.

---

## 14. Catalog compiler

### 14.1 Inputs

The compiler accepts one or more editorial roots:

- bundled catalog root;
- user hot folder;
- future imported/shared roots.

Each input root has an explicit precedence policy. Precedence must not depend on filesystem enumeration order.

### 14.2 Per-file manifest

Each file record stores:

- relative path;
- content hash;
- size;
- modification time as a fast hint;
- compiler version;
- parse format version.

Content hash is authoritative. Size and modification time are fast pre-checks only.

### 14.3 Incremental algorithm

```text
watcher reports changed paths
    ↓
compare candidate files with catalog_file manifest
    ↓
open staging catalog derived from current valid catalog
    ↓
for each changed/deleted file:
    remove placements and nodes owned by that file
    parse file preserving outline hierarchy and order
    upsert stable source rows
    insert nodes and placements
    update FTS and materialized counts
    ↓
remove unreferenced catalog-only source rows
    ↓
validate
    ↓
publish atomically
```

A full rebuild uses the same parser and validation rules but starts from an empty staging catalog.

### 14.4 Build-time catalog

The bundled corpus should be compiled during the application build/release process. The application ships with a ready-to-query catalog.

The runtime must not require a complete OPML parse after an app update merely because the build number changed.

### 14.5 Cold-start rule

At launch:

```text
open current valid catalog
    ↓
restore session
    ↓
show timeline or browse state
    ↓
start watcher and background validation
```

Catalog compilation, full directory scans, and network fetches do not block first render.

---

## 15. Atomic catalog publication

The compiler never mutates the database currently used by the UI.

```text
catalog-current.sqlite           current valid catalog
catalog-candidate.sqlite         staging output
catalog-candidate.sqlite-shm     temporary only
catalog-candidate.sqlite-wal     temporary only
```

Publication sequence:

1. compile candidate;
2. run schema and integrity validation;
3. verify source/node/placement counts and stable-ID collision checks;
4. checkpoint and close candidate connections;
5. write catalog version metadata;
6. atomically replace the published file or version pointer;
7. open the new catalog repository;
8. notify UI/query layers that catalog version changed;
9. delete old versions only after no reader holds them.

A failed or cancelled build leaves `catalog-current.sqlite` untouched.

Catalog metadata includes at least:

- `schema_version`;
- `compiler_version`;
- `identity_version`;
- `catalog_version`;
- `logical_digest`;
- `built_at`;
- input manifest digest.

`built_at` is operational metadata and is excluded from deterministic logical-dataset comparison.

---

## 16. Query and pagination model

### 16.1 No offset cursors

Offset pagination becomes increasingly expensive and is unstable when rows are inserted or removed between requests.

Use keyset pagination with a catalog version:

```swift
struct CatalogCursor: Codable, Sendable {
    let catalogVersion: Int64
    let sortKey: String
    let entityID: Int64
}
```

The public cursor can be encoded as an opaque token so UI code does not depend on its fields.

A cursor from an older catalog version is rejected with a restartable `cursorExpired` result.

### 16.2 Separate page types

A page cannot contain "either nodes or sources" while declaring a single typed array.

```swift
struct CatalogNodePage: Sendable {
    let items: [CatalogNodeSummary]
    let nextCursor: CatalogCursor?
    let estimatedTotalCount: Int?
}

struct SourcePage: Sendable {
    let items: [SourceSummary]
    let nextCursor: CatalogCursor?
    let estimatedTotalCount: Int?
}
```

Counts are optional. Do not perform a full `COUNT(*)` for every request unless the UI needs it and the query plan is cheap.

### 16.3 Timeline cursor

Date alone is not a stable cursor because many items share the same timestamp.

```swift
struct TimelineCursor: Codable, Sendable {
    let sortTimestamp: Date
    let itemID: String
}
```

The query orders by `(sort_timestamp DESC, item_id DESC)` and applies the corresponding tuple boundary.

### 16.4 Do not expand broad queries into arrays

Avoid APIs such as:

```swift
func sourceIDs(for nodeIDs: [CatalogNodeID]) async throws -> [SourceID]
```

A broad node may contain hundreds of thousands of sources. The repository should express the scope relationally and perform joins or bounded pages inside SQLite.

Likewise, `ContentQuery` must not require a massive `[SourceID]` array. Use a typed scope:

```swift
enum SourceScope: Sendable {
    case allEnabled
    case nodes([CatalogNodeID])
    case explicitSmallSet([SourceID])
    case savedQuery(Int64)
}
```

The explicit array case has a documented small limit. Broad scopes are resolved in SQL.

---

## 17. Stage 1 API boundary

Do not create a new monolithic protocol that prematurely fixes the shape of catalog, timeline, fetching, ingestion, and user state before the first vertical exists.

Stage 1 defines the catalog boundary only:

```swift
protocol CatalogReading: Sendable {
    func childNodes(
        of parentID: CatalogNodeID?,
        cursor: CatalogCursor?,
        limit: Int
    ) async throws -> CatalogNodePage

    func sources(
        in nodeID: CatalogNodeID,
        cursor: CatalogCursor?,
        limit: Int
    ) async throws -> SourcePage

    func searchSources(
        text: String,
        filters: CatalogSearchFilters,
        cursor: CatalogCursor?,
        limit: Int
    ) async throws -> SourcePage

    func sourceDetails(id: SourceID) async throws -> SourceDetails?
}

protocol CatalogCompiling: Sendable {
    func compileFull() async throws -> CatalogCompileReport
    func compileIncremental(
        changes: [CatalogFileChange]
    ) async throws -> CatalogCompileReport
}
```

A small `FeedEngine` facade may compose repositories later, but the repositories remain independently testable.

### 17.1 Catalog models

```swift
struct SourceSummary: Identifiable, Sendable {
    let id: SourceID
    let title: String
    let displayHost: String?
    let mediaKind: MediaKind
    let language: String?
}

struct SourceDetails: Identifiable, Sendable {
    let id: SourceID
    let title: String
    let declaredURL: URL
    let requestURL: URL
    let mediaKind: MediaKind
    let language: String?
    let placements: [SourcePlacementSummary]
}

struct CatalogNodeSummary: Identifiable, Sendable {
    let id: CatalogNodeID
    let name: String
    let kind: CatalogNodeKind
    let sourceCount: Int
    let childCount: Int
}
```

`SourceSummary` does not need the full request URL merely to render a browse row. Details and fetch targets load that data when needed.

---

# Part IV — Migration plan

## 18. Stage 1 scope

Stage 1 prepares the terrain and changes no user-facing behavior.

### In scope

- verify and commit the architecture document against a specific SHA;
- fix or separately track the confirmed legacy defects;
- add high-value instrumentation;
- measure the legacy baseline on a physical device;
- define stable identity rules;
- define catalog schema and atomic publication rules;
- add compile-safe catalog domain types and repository protocols;
- add tests for the architectural invariants;
- retain all current UI and timeline behavior.

### Out of scope

- replacing `FeedStore`;
- changing the `feed_item` schema;
- migrating timeline queries;
- changing the reservoir behavior;
- redesigning source scheduling;
- migrating fetch state;
- moving bookmarks into a new database;
- implementing the full production compiler;
- adding user-facing features;
- importing one million sources into the application target;
- introducing bitmap indexes, custom binary formats, or custom memory mapping.

---

## 19. First migration vertical

```text
OPML files + directories
    ↓
CatalogCompiler
    ↓
versioned catalog candidate
    ↓
validation + atomic publication
    ↓
CatalogRepository
    ↓
Browse screen adapter
    ↓
Catalog search adapter
```

The timeline remains on `FeedStore` during this vertical.

### Why this vertical comes first

- it is self-contained;
- it directly removes the complete catalog and taxonomy from the runtime object graph;
- it validates stable IDs and provenance before content state depends on them;
- it provides measurable browse/search performance;
- it can coexist with the legacy timeline.

---

## 20. Reuse, adapt, replace

### 20.1 Reuse with adaptation

| Component | Decision |
|---|---|
| `RSSFetcher` | Keep network/parser core; later adapt input to bounded fetch targets carrying `SourceID` and URL. |
| OPML XML parsing mechanics | Reuse parser mechanics, but change output to preserve nested nodes, every placement, and order. Do not reuse global dedup as compiler behavior. |
| `SearchEngine` | Keep for content FTS. Catalog search gets a separate FTS index. |
| `FeedItem` | Keep during the first vertical. Add source identity only in a later content migration. |
| `BookmarkStore` | Keep during the first vertical; later migrate behind `user.sqlite` ownership. |
| logging and image infrastructure | Keep. |

### 20.2 Replace after the catalog vertical proves parity

| Component | Replacement |
|---|---|
| `SourceRegistry.sources` | paginated `CatalogReading` queries |
| `SourceRegistry.sourceByURL` | source and alias indices in `catalog.sqlite` |
| `TaxonomyStore.flatIndex` | `catalog_node` queries |
| `feedToNodeID` / `nodeToFeedURLs` | `catalog_placement` joins |
| taxonomy search over Swift dictionaries | FTS5 + bounded hydration |
| URL as cross-system identity | stable `SourceKey` + numeric `SourceID` |

### 20.3 Keep temporarily, but place behind boundaries

| Component | Treatment |
|---|---|
| `FeedStore` | remains legacy coordinator while screens migrate |
| `SourceScheduler` | remains operational legacy; later move URL-keyed state to `content.sqlite` and `SourceID` |
| `Reservoir` | remains a bounded timeline presentation policy/working-set manager; it is not a repository and not merely a SwiftUI concern |
| OPML parse cache | remains for legacy behavior until the compiled catalog path replaces it |

---

## 21. Required tests

### 21.1 Identity

- same source key produces the same `SourceID` across full rebuilds;
- insertion of unrelated sources does not renumber existing IDs;
- deletion and re-addition reproduce the same ID;
- different source keys cannot share an ID;
- `http` and `https` remain distinct unless an explicit alias exists;
- explicit identity override preserves ID through an intentional URL change.

### 21.2 Editorial structure

- one source in several OPML files creates one source row and several placements;
- nested outline hierarchy is preserved;
- folder hierarchy is preserved;
- placement order matches OPML order;
- metadata precedence is deterministic and does not depend on file enumeration order.

### 21.3 Incremental compilation

- unchanged files are not reparsed;
- changed file placements are replaced correctly;
- deleted files remove only their owned nodes/placements;
- full and incremental builds produce the same logical digest;
- compiler-version change invalidates affected file fingerprints.

### 21.4 Publication and recovery

- interrupted compilation leaves the current catalog readable;
- invalid candidate is rejected;
- atomic swap exposes only complete versions;
- old cursors expire after publication;
- repository reopens on the new catalog version;
- catalog removal does not cascade into user/content fixtures.

### 21.5 Query behavior

- browse is ordered and keyset-paginated;
- no duplicates or gaps within one catalog version;
- search returns IDs then hydrates a bounded page;
- empty query and empty node are handled without scanning Swift collections;
- page limits are enforced.

---

## 22. Stage 1 success criteria

1. Architecture document is committed with the reviewed commit SHA.
2. Claims are labeled confirmed, reported, estimated, or target decision.
3. The four confirmed critical legacy defects are fixed or tracked in explicit issues outside the migration acceptance criteria.
4. Instrumentation emits the selected startup, memory, and pipeline metrics.
5. Physical-device baseline results replace empty values in the baseline table.
6. Stable `SourceID` and `CatalogNodeID` rules are implemented and tested.
7. Catalog schema and migration ownership are documented.
8. Atomic catalog publication behavior is tested with a minimal prototype.
9. Catalog domain models and `CatalogReading`/`CatalogCompiling` protocols compile without depending on `FeedStore`.
10. Existing tests remain green and no current screen changes behavior.
11. Build succeeds with no new warnings.

## 22.1 Implementation snapshot — 2026-07-17

This snapshot completes the first boundary pass without replacing legacy
behavior.

Created or updated:

- `feedmine/FeedEngine/Identities.swift`: type-safe numeric `UInt32` wrappers for `SourceID` and `CatalogNodeID`.
- `feedmine/FeedEngine/CatalogModels.swift`: `SourceSummary`, `SourceDetails`, `CatalogNodeSummary`, `TimelineItemSummary`, `CatalogBrowseQuery`, `CatalogSearchQuery`, and `ContentQuery`.
- `feedmine/FeedEngine/Pagination.swift`: bounded `CatalogPage`, typed page structs, versioned cursors, and `FeedEnginePageLimit`.
- `feedmine/FeedEngine/CatalogProtocols.swift`: `FeedEngineProtocol` plus catalog, search, timeline, fetch, parsing, ingestion, and user-state repository boundaries.
- `feedmine/Services/FeedMetrics.swift`: removable signpost and `phys_footprint` measurement wrapper.
- `feedmine/Services/FeedStore.swift`: startup markers for backend start, OPML load, taxonomy load/build, read state, reservoir load/seed, first visible items, object counts, and memory.
- `feedmine/Services/OPMLParser.swift`: separate signposts for OPML fingerprinting, cache read, cache hit/miss, full parse, and parse counts.
- `feedmine/feedmineApp.swift`: process-start marker.
- `feedmine/Views/FeedScreen.swift`: first screen and first useful content markers.
- `feedmineTests/FeedEngineBoundaryTests.swift`: initial tests for ID equality, cursor stability, page limits, query shapes, source/details separation, multiple placements, and bounded protocol behavior.

Still not implemented in this snapshot:

- compiled `catalog.sqlite`;
- full or incremental catalog compiler;
- real catalog repository backed by GRDB;
- FTS5 catalog search;
- atomic catalog publication;
- migration of any current UI screen to `FeedEngine`;
- physical-device baseline values.

The next vertical remains:

```text
OPML/pastas
    ↓
catalog.sqlite derivado
    ↓
navegação paginada
    ↓
busca local
```

## 22.2 Implementation snapshot — catalog vertical prototype

This snapshot implements the first migration vertical as a tested,
non-user-facing prototype. It still does **not** replace the legacy feed UI.

Created or updated:

- `feedmine/FeedEngine/CatalogIdentity.swift`: deterministic `UInt32` IDs for sources and catalog nodes, conservative URL keys, display host extraction, slug generation, and collision errors.
- `feedmine/FeedEngine/CatalogInput.swift`: compiler input model for source occurrences and editorial node paths.
- `feedmine/FeedEngine/OPMLCatalogScanner.swift`: OPML/folder scanner that preserves file provenance, outline order, language, and media overrides.
- `feedmine/FeedEngine/SQLiteCatalogStore.swift`: GRDB schema, full compiler, atomic candidate publication, paginated catalog browse, source details, and FTS5 local search.
- `feedmine/Services/FeedEngineCatalogDiagnostics.swift`: DEBUG/INSTRUMENTATION-only runtime compiler that builds a diagnostic catalog after legacy startup and reads the first catalog page.
- `scripts/build_catalog.py`: build-time catalog compiler for `feedmine/Resources/Feeds`.
- `feedmine/Resources/FeedEngine/catalog.sqlite`: precompiled derived catalog bundled with the app.
- `feedmine/Resources/FeedEngine/catalog-manifest.json`: generated catalog build report.
- `feedmine/Services/FeedLoader.swift`: schedules DEBUG diagnostics that open the bundled catalog read-only, falling back to legacy-source compilation only when the bundle resource is missing.
- `feedmine/Views/DebugStatusBar.swift`: exposes compact catalog diagnostics when the existing debug bar is enabled.
- `feedmineTests/SQLiteCatalogStoreTests.swift`: verifies source deduplication with multiple placements, direct-child pagination, source details, local FTS, and search filters.

Generated catalog from `feedmine/Resources/Feeds`:

- OPML files: 4,534
- `catalog_source`: 39,717
- `catalog_node`: 8,798
- `catalog_placement`: 57,650
- duplicate editorial placements: 17,933
- generated bundle size: 34 MB

Simulator verification on `iPhone 14 Plus`, iOS 26.5:

- App installed and launched as `com.feedmine.app`.
- Clean install did **not** create `Library/Application Support/FeedEngine/catalog.sqlite`; runtime opened the bundled catalog.
- FTS query for `startupi` returned `Startupi | startupi.com.br`.

Important limitation:

- The feed timeline still uses the legacy `FeedStore`. The bundled catalog proves browse/search storage and read-only opening, but no current screen has been migrated to FeedEngine yet.

---

## 23. Ordered next actions

1. **Stabilize current behavior:** fix the reverse-index cache restore, awaitable reservoir flush, bookmark stamping, and legacy `http` matching.
2. **Record a real baseline:** run the instrumented warm/cold legacy scenarios on a physical device and fill the baseline table.
3. **Move catalog generation before launch:** generate `catalog.sqlite` from OPML/folders as a build artifact or explicit maintenance step, not from `SourceRegistry.sources`.
4. **Add a manifest table/file:** store OPML path, size, modified time, and hash so incremental rebuild can run after first render.
5. **Open production catalog read-only:** make runtime browse/search use an existing validated catalog instead of compiling one.
6. **Add query-plan and allocation checks:** verify browse and search remain bounded on the full catalog.
7. **Migrate one browse/search screen through an adapter:** keep the timeline on `FeedStore`.
8. **Separate `user.sqlite` and `content.sqlite`:** move user state and operational feed state behind explicit repositories.
9. **Implement source aliases deliberately:** support legacy row matching without declaring broad URL equivalence.
10. **Remove legacy catalog materialization only after parity:** `SourceRegistry` and `TaxonomyStore` remain until the new vertical passes functional and performance acceptance.

---

# Appendix A — Catalog compile report

```swift
struct CatalogCompileReport: Sendable {
    let mode: Mode
    let catalogVersion: Int64
    let sourceCount: Int
    let nodeCount: Int
    let placementCount: Int
    let aliasCount: Int
    let duplicateOccurrenceCount: Int
    let invalidSourceCount: Int
    let changedFileCount: Int
    let deletedFileCount: Int
    let failedFileCount: Int
    let logicalDigest: String
    let elapsed: Duration

    enum Mode: Sendable {
        case full
        case incremental
    }
}
```

A duplicate occurrence is not an error. It means the same intrinsic source appears in more than one editorial placement.

---

# Appendix B — Future ownership boundaries

These boundaries are directional. They are not all required as Stage 1 compile-time protocols.

| Responsibility | Future owner |
|---|---|
| catalog compilation and publication | catalog compiler actor/tool |
| catalog browse and source search | catalog repository |
| network target resolution | fetch coordinator + catalog/content snapshots |
| HTTP fetch and feed parsing | feed fetcher |
| normalization and item transformation | ingestion pipeline |
| content persistence and timeline query | content repository |
| source health, ETag, queue, jobs | operational repository in `content.sqlite` |
| subscriptions, tabs, saved queries, bookmarks | user repository in `user.sqlite` |
| bounded timeline interleave and presentation policy | timeline working-set coordinator |
| SwiftUI observable state | screen-specific view models/adapters |

---

# Appendix C — Decisions corrected from the previous draft

1. Current source count updated from 24,045 to the audit-reported 39,697.
2. Precise memory and startup estimates removed from the baseline until measured.
3. `UInt32` aliases replaced with type-safe `UInt32` wrappers for compile-time clarity.
4. Auto-generated SQLite row IDs rejected as cross-database stable identity.
5. Deterministic logical output distinguished from byte-identical SQLite bytes.
6. Aggressive URL normalization rejected as permanent identity policy.
7. "First OPML occurrence wins" removed from the target metadata model.
8. `node_source` replaced by explicit source placements with file provenance and order.
9. Offset pagination replaced by versioned keyset cursors.
10. Bounded `CatalogPage` kept for the facade, with typed node/source page models available below it.
11. Unbounded `sourceIDs(for:)` API removed.
12. Timeline cursor expanded from date-only to `(timestamp, itemID)`.
13. Full catalog compilation removed from the cold-start path.
14. Build-time catalog and background incremental hot-folder compilation made explicit.
15. Atomic catalog publication and cursor invalidation added.
16. `FeedEngineProtocol` defines the UI facade while catalog, timeline, fetch, ingestion, and user-state responsibilities stay independently testable.
17. Reservoir reclassified as timeline working-set policy, not simply a UI concern.
18. Current critical defects separated from the migration architecture and assigned to a stabilization track.
19. Simulator removed as the authority for performance baselines.
20. Instrumentation corrected to use static signpost names and true `phys_footprint` measurement.
