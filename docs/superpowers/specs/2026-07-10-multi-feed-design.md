# Multi-Feed — Design Doc

**Date:** 2026-07-10
**Status:** Approved (brainstorming) — ready for implementation planning
**Author:** Wagner Montes + Claude

## Goal

Turn feedmine into a **multi-feed** app. The user swipes left/right (full-screen paging)
between **fully independent feeds**, each with completely separate configuration and data.
The only automatic difference between feeds is **color** (each feed uses a distinct palette).

Feeds do **not** share data — this isolation is a performance choice, not a product limitation.
Each feed is its own universe: separate sources, filters, bookmarks, read-history, What's New.

## Constraints & Key Decisions

| Topic | Decision |
|---|---|
| Max feeds | **5** (one distinct palette each; there are exactly 5 palette families) |
| Main tab (index 0) | Permanent, cannot be deleted; keeps the user-chosen palette (may be circadian/adaptive) |
| Secondary feeds | Auto-assigned a **fixed** unused palette (no circadian family cycling) |
| New-feed config | A single creation screen with **all parameters** (sources + view filters) + optional name |
| Creation surface | **Inline page** in the pager (rightmost), present only when `feeds.count < 5` |
| Commit / cancel | **OK** creates the feed and jumps into it; swiping back without OK cancels (draft cleared on exit) |
| Deletion | Via that feed's **own settings sheet** ("Delete this feed"); main has no such button |
| Data isolation | **Everything per-feed** (own SQLite DB + own settings key) |
| Global (shared) | Audio/mini-player, locale, session-tracking, image cache, network monitor, circadian time-of-day |
| Startup | All feeds warm up **in series** — active first, then the rest in order; then background refresh for inactive feeds |
| Page indicator | Colored dots floating at the **bottom**, above the mini-player; last dot is a **"+"** when `< 5` feeds |
| Migration | **None** — app still in development; legacy `feedmine.sqlite` / `app_settings` ignored |
| Export/import | **Architected for, not implemented** in this spec (see Forward Compatibility) |

## Chosen Approach

**`FeedManager` coordinator + N `FeedLoader`s, one SQLite DB per feed, pager of `FeedScreen`s.**

A new top-level `FeedManager` (`@Observable`) owns the array of feeds and the active index.
The existing `FeedStore`/`FeedLoader` engine is reused **per feed**, namespaced by a `feedID`.
Palette becomes a per-page injected value (`FeedTheme`) instead of a global `CircadianEngine.shared` read.

Rejected alternatives:
- **Single store, tagged partitions in one DB** — kills the performance isolation; cross-feed queries;
  complicates per-feed What's New / read-state. Contradicts "no shared data by performance".
- **Multi-scene / multiple windows** — overkill for single-screen paging; global mini-player becomes hard.

## Section 1 — Component Architecture

The app gains a new owner at the top. `FeedScreen` becomes a "dumb" renderer of **one** loader + **one**
theme; it has no knowledge that other feeds exist.

### New types

- **`FeedDescriptor`** (`Codable`, `Identifiable`) — persisted identity of a feed. No content data.
  - `id: UUID`
  - `name: String?`
  - `paletteFamily: PaletteFamily?` — `nil` = adaptive/global (main only); non-nil = fixed (secondaries)
  - `order: Int`
  - `createdAt: Date`

- **`FeedInstance`** (runtime, not persisted) — `descriptor: FeedDescriptor` + `loader: FeedLoader`.

- **`FeedManager`** (`@MainActor @Observable`, app-level singleton) — the coordinator:
  - `feeds: [FeedInstance]` (ordered by `order`), `activeIndex: Int`
  - `createFeed(...)`, `deleteFeed(id:)`, load/persist the feeds index
  - Orchestrates startup warm-up and background refresh (Section 5)
  - Assigns palettes (Section 3)

- **`FeedTheme`** — lightweight value resolving `pageBackground` and `accent` for one page.
  Main → delegates to `CircadianEngine.shared`. Secondary → resolves from the descriptor's fixed family.
  This is injected per page in place of a direct `engine.pageBackground` read.

### Changes to existing types

- **`FeedStore.init(feedID:)`** — uses the id to build `feedmine_<id>.sqlite` and the settings key
  `app_settings_<id>` (Section 2). No new responsibilities beyond this parameter.
- **`FeedLoader.init(feedID:)`** — passes the id through to its `FeedStore`.
- **`FeedScreen`** — stops reading `CircadianEngine.shared` directly; receives a `FeedTheme`
  (via per-page environment). Still reads `@Environment(FeedLoader.self)`, but each page injects **its** loader.
- **Root view** (`ContentView` / `feedmineApp`) — stops creating a single `FeedLoader`; creates the
  `FeedManager` and renders the pager (Section 6).

### Responsibility boundary

`FeedManager` knows "which feeds exist and which is active." Each `FeedLoader`/`FeedStore` knows only its
own world (sources, items, filters, bookmarks) and is **unaware** other feeds exist. This keeps the already
large `FeedStore` (~76 KB) free of new responsibilities.

## Section 2 — Data & Persistence

Each feed is an island on disk. Three things become namespaced by `feedID`:

### 1. SQLite database — one file per feed
- `FeedStore.dbPath` is no longer a fixed static; it becomes `feedmine_<id>.sqlite` in the documents dir.
- `Self.migrate` runs identically per new file — same schema, separate data.
- Bookmarks, read-history, `source_health`, `feed_item`, What's New baseline: all inside that feed's DB.

### 2. Filters + source toggles — one settings entry per feed
- `AppSettings` key changes from the single `"app_settings"` to `"app_settings_<id>"`.
- `toggleDisabled` / `toggleEnabledOverrides` (SourceRegistry on/off state) and filters
  (`filterRegion/Category/ContentType/Mood`) already live in `AppSettings` → isolated for free.
- `AppSettings.load()/save()` gain a `feedID` parameter (or become instances with the key embedded).

### 3. Feeds index — one list at the top
- New `Codable` blob in `UserDefaults`, key `"feeds_index"`: `[FeedDescriptor]`.
- `FeedManager` loads it at launch, rebuilds `FeedInstance`s, and rewrites it on every create/delete/rename.

### First launch / no migration
The app is still in development — no user data to preserve. On first launch of the multi-feed build,
if `"feeds_index"` is absent, `FeedManager` creates **only the main** (order 0, adaptive palette) and
proceeds. Legacy `feedmine.sqlite` and `"app_settings"` are ignored/removable.

### Delete cleanup
Deleting a feed removes `feedmine_<id>.sqlite` (plus WAL/`-shm`), removes `"app_settings_<id>"`, and
removes the descriptor from the index.

### Global (not per-feed)
`ImageCache` and `NetworkMonitor` stay **global and shared** — reconstructible cache / device-wide signal,
not feed data. Sharing saves memory and network.

## Section 3 — Palette Assignment

Rule: **every live feed uses a distinct palette family** from the 5
(`warmEarth, coolSky, botanical, lavenderHour, monochrome`).

### Main (order 0)
- `paletteFamily = nil` → theme resolves via `CircadianEngine.shared` (adaptive; respects user setting;
  may vary by time-of-day period).
- The main's **effective** family at any moment (`CircadianEngine.shared.paletteFamily`) counts as **occupied**
  for secondary assignment.

### Secondaries
- At creation, `FeedManager` computes the **free pool** = 5 families minus those in use (main's effective +
  other secondaries' fixed families).
- Assigns the **first free family in canonical enum order**. Stored in the descriptor (`paletteFamily != nil`)
  → **fixed**, non-circadian. Time-of-day may still adjust tone (light/dark) **within** the fixed family for
  legibility, but the family never changes.

### Collision handling
1. **User changes the main's family** in settings to one used by a secondary → the main's palette picker
   **excludes families in use by secondaries** (it chooses only among free families + its current one).
   The main never collides.
2. **Delete frees a color** → the freed family returns to the pool. Existing feeds are **not** recolored
   (changing an existing feed's color is confusing); the freed color is only available to the next new feed.

### 5-feed ceiling
When 5 feeds exist, the pool is empty → **no creation page exists**; the pager holds only the 5 feeds and
swipe navigates only between them. The creation page (and "+") reappears only after a feed is deleted.

Canonical assignment order = enum order (`warmEarth → coolSky → botanical → lavenderHour → monochrome`),
skipping occupied families. Deterministic.

## Section 4 — Creation & Deletion Lifecycle

### The creation page ("blank page" on the right)
- Always the **last** page of the pager, present only when `feeds.count < 5`.
- Not a `FeedScreen` — a dedicated `FeedCreationPage` showing **all parameters** (sources + view filters)
  on screen, plus an **optional name** field and an **OK / Create** button.
- Painted with the **next free color** (preview of the palette the feed will receive).
- Until confirmed, **nothing is fetched or persisted** — it is just a form.
- Draft is **cleared on exit** (swiping away without OK).

### Confirmation (OK)
1. `FeedManager.createFeed(name:, config:)` builds the `FeedDescriptor` (new id, next free color,
   `order = feeds.count`) and writes it to `"feeds_index"`.
2. Instantiates `FeedLoader(feedID:)` → new DB + settings; applies chosen config (source toggles + filters).
3. Inserts the `FeedInstance` **before** the creation page; starts buffer warm-up (Section 5).
4. The pager animates **into** the newly created feed; if there is still room (`< 5`), a fresh blank page is
   born to its right.

### Deletion (via the feed's own settings)
- Each `FeedScreen` already presents a `SettingsSheetView`. **Secondary** feeds get a destructive
  "**Delete this feed**" section (with confirmation). The **main has none**.
- On confirm: `FeedManager.deleteFeed(id:)` removes it from the list, deletes DB + settings (Section 2),
  rewrites the index, and the pager slides to the neighbor (previous; or main if it was the first secondary).
  The color returns to the pool.

### Later editing
A feed's config (sources/filters) is editable anytime via the controls that **already exist** inside
`FeedScreen` (SourceManagement + filter bars). Creation and editing use the **same** config components;
creation is just "the first time" with them, in a form, before the feed exists. No new config UI is invented.

## Section 5 — Startup Warm-up & Background Refresh

Implements the chosen behavior: on startup all feeds warm up in order (active first), then inactive feeds
get a light periodic refresh.

**Coordinator:** `FeedManager` — the only object that sees all feeds and which is active. Each `FeedStore`
still only knows how to fetch **itself**; `FeedManager` decides **order and priority**.

### Cold start
1. `FeedManager` loads the index and instantiates the `FeedLoader`s (cheap — opens DBs, no fetching).
2. Warms up **serially, in order**: the **active** feed first (`activeIndex`, normally main) via full
   `loader.start()` with priority. Only after it has usable content, the rest fire **one at a time** by `order`.
   - Serial (not parallel) on purpose: 5 stores fetching RSS at once saturate network/CPU. Queuing keeps the
     active feed fast and the others warming behind it without competing.
3. While the active warms, others are "pending" (their page shows the existing skeleton/empty state if the
   user swipes there early).

### Steady state
- **Active feed:** current behavior — refresh-if-stale on appear, load-more on scroll, What's New, etc.
- **Inactive feeds:** `FeedManager` schedules a **light periodic refresh** (e.g., every N minutes and/or on
  `scenePhase == .active`), **low priority**, **one at a time**, only to accumulate new items
  (feed the buffer / What's New). No mass image prefetch, no load-more.
- **Feed switch (swipe):** the new feed becomes active → immediate `refreshIfStale()` (high priority);
  the one that left returns to the background cadence.

### Budget / safety
- **One refresh in flight** at a time at the `FeedManager` level (a queue) — never 5 concurrent fetches.
- Respects `NetworkMonitor`: no network → no warm-up; resumes on connection.
- Newly created feeds enter the warm-up queue right after OK, but the new feed is active (user was jumped
  into it), so it warms with priority naturally.

Refresh interval / "N" are **code constants** (e.g., 15 min), not UI options.

## Section 6 — Pager, Navigation & Indicator

### Paging container
- Root = `TabView(selection: $manager.activeIndex)` with `.tabViewStyle(.page(indexDisplayMode: .never))`
  — native full-screen horizontal paging ("pulling the whole screen").
- Native index display **off**; we draw our own colored-dot indicator.
- Pages, in order: `feeds[0]` (main) … `feeds[n]` … and, if `feeds.count < 5`, the `FeedCreationPage` last.
- Each feed page = `FeedScreen` with **its** `FeedLoader` and `FeedTheme` injected via per-page
  `.environment(...)`. `FeedScreen`'s shape doesn't change — it just receives another loader/theme per page.

### Indicator (colored dots)
- A thin dot strip floating at the **bottom**, above the mini-player. Each dot painted in its feed's
  **palette color**; the active dot larger/filled, others smaller.
- If `feeds.count < 5`, the **last "dot" is a "+"** (in the next free color) for the creation page. At 5,
  the "+" disappears.
- Tapping a dot jumps directly to that feed (cheap, since we have the binding).

### Gestures (resolving the conflict)
- The feed is a **vertical** `ScrollView` of cards → the `TabView`'s **horizontal** pan doesn't fight the
  vertical scroll. Clean.
- The attention point is the `.swipeActions` in the **list** variant (`FeedItemView` rows with swipe to
  mark read/bookmark). SwiftUI `.swipeActions` captures a horizontal drag **starting on the row**, and
  generally coexists with the `TabView` page-swipe (which needs a broader horizontal drag). Card feeds (the
  default) have no `.swipeActions` → zero conflict. Plan: **keep** `.swipeActions` in the list variant; if it
  conflicts in practice, the fallback is converting those actions to buttons/context-menu. Known risk, not a
  blocker.

### Per-feed header
- Header/greeting and the feed name (if any) live inside `FeedScreen`, tinted by that page's `FeedTheme`.
  The optional feed name may appear in the compact header to reinforce "where I am."

### Focus / lifecycle
- Only the active `FeedScreen` does heavy on-appear work; swiping triggers the new page's `.task` →
  `refreshIfStale()` (Section 5), and `FeedManager` updates `activeIndex`.

## Section 7 — Errors, Edge Cases & Testing

### Edge cases
- **Feed with no sources:** falls into the existing `FeedEmptyStateView`. No special handling.
- **App closed mid-creation:** draft not persisted → on reopen only confirmed feeds exist; creation page
  reappears blank.
- **Deleting the active feed:** the pager slides to the neighbor **before** the store is destroyed, so a dead
  loader is never rendered.
- **Corrupt/unreadable index** (`"feeds_index"` invalid): `FeedManager` falls back to "main only", as on
  first launch. Never stuck without a feed.
- **Main color change frees/occupies a slot:** the main's picker already excludes occupied colors → no collision.
- **5 feeds:** no creation page; swipe navigates only among the 5.
- **Audio playing + feed switch:** `AudioPlayerManager.shared` is global → playback continues across feeds;
  the mini-player floats above any page. Concretely: the user can tap a podcast in feed A, swipe to feed B
  to browse other content, and the podcast keeps playing uninterrupted. The mini-player (and its now-playing
  item) is a single global instance shared by all feeds — it is **not** reset or rebound when the active
  feed changes. No interruption on swipe.

### Database errors
Each `FeedStore.init` can throw (open/migrate SQLite). If a **secondary** feed fails to open, `FeedManager`
**skips** it (logs + marks the descriptor "unavailable", or drops it from the index) without crashing. If the
**main** fails, it is fatal as today.

### Global vs per-feed (consolidated)
- **Global:** `AudioPlayerManager`, `LocaleManager`, `SessionTracker`, `ImageCache`, `NetworkMonitor`,
  circadian time-of-day period.
- **Per-feed:** SQLite DB, `SourceRegistry` (toggles), filters, bookmarks, read-history, What's New, and the
  **palette family** (fixed for secondaries; adaptive for main).

### Testing (Swift Testing; `FeedLoader.init` already supports injecting a `FeedStore`)
- `FeedManager`: creating up to 5 feeds assigns distinct colors in canonical order; a 6th is not allowed;
  delete frees the color and shrinks the pager.
- Namespacing: two `FeedStore`s with different ids write to different DBs; a bookmark in one feed does not
  appear in the other.
- Palette assignment: the main's picker excludes occupied colors; delete does not recolor existing feeds.
- Index persistence: round-trip `[FeedDescriptor]` via UserDefaults; fallback on corrupt blob.
- Warm-up coordination: start order (active first) and single queue (no 5 concurrent fetches), testable with a
  fake `FeedStore` that records call order.

## Forward Compatibility — Export / Import (architected, not implemented)

The intent is to later support **exporting data and importing feeds** — but **never sharing between tabs**.
Import/export moves a **whole feed universe** in/out; it never copies data across existing tabs.

This spec does not implement the UI. It only ensures the architecture doesn't preclude it:
- A feed's config (descriptor + source toggles + filters) must be serializable as a self-contained **bundle**.
- `createFeed` is designed to accept an imported bundle (subject to the 5-feed ceiling and color pool).
- Per-feed DB isolation already makes exporting a feed's content a self-contained operation.

## Out of Scope (YAGNI)

- Manual reordering of feeds
- Sharing/duplicating config **between** tabs
- Cross-device sync
- More than 5 feeds
- Legacy data migration
- Export/import UI (this spec only keeps the door open for it)
