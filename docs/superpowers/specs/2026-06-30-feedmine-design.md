# Feedmine — Design Spec

**Date:** 2026-06-30
**Platform:** iOS 18+ (iPhone only)
**Stack:** SwiftUI + SwiftData + FeedKit

## Concept

Feedmine is an RSS reader that looks and feels like a social media feed, using a Tinder-style swipe mechanic to make content consumption intentional. Swipe right to like/save a post, swipe left to skip it. The app learns from your swipes to surface more of what you like. A curated set of feeds ships with the app so there's zero setup friction.

## Architecture

Three tabs, flat navigation:

```
Sources tab  →  Feed tab (home)  →  Faves tab
```

- **Sources:** list of feeds (curated defaults + user-added), toggle on/off, add by URL
- **Feed:** the main Tinder-style card stack — the primary interaction surface
- **Faves:** list of liked/saved posts, grouped by source or date, tappable to open article

### Component Tree

| Component | Responsibility |
|-----------|---------------|
| `ContentView` | Tab container, owns the three tabs |
| `FeedView` | Manages the card stack, preloads next cards, owns the swipe gesture logic |
| `FeedCardView` | Single card — hero image, title, source badge, category chip. Renders swipe-driven transforms |
| `SwipeOverlay` | Like/dislike stamp that fades in proportional to horizontal drag |
| `SourcesListView` | Feed management — curated defaults grouped by category, toggle on/off, add custom |
| `AddFeedSheet` | URL paste + validation + preview before adding |
| `FavoritesListView` | Saved posts, tappable to open in an in-app Safari sheet |
| `RSSEngine` | Wraps FeedKit — fetch + parse a feed, return `[Post]`, handles errors gracefully |
| `FeedStore` | SwiftData-backed actor — CRUD for feeds/posts, lazy batch loading, seen-set management |
| `Personalizer` | Simple scoring model — boosts sources/categories with positive swipe ratio, decays old events |

### Dependencies

- **FeedKit** (MIT) — battle-tested Swift RSS/Atom/JSON Feed parser. Handles encoding, date formats, malformed feeds, and both RSS 2.0 and Atom namespaces.

## Data Model

All models are SwiftData `@Model` classes.

### Feed
```
url: String          (unique)
title: String
iconURL: String?
category: String     ("Tech", "News", "Science", "Design", "Culture")
isCurated: Bool      (shipped with app vs user-added)
isEnabled: Bool      (toggle on/off per source)
lastFetched: Date?
posts: [Post]        (one-to-many, cascade delete)
```

### Post
```
guid: String         (RSS item identifier, unique per feed)
title: String
excerpt: String      (first ~200 chars of content/description)
contentHTML: String  (full HTML for reader view)
url: String          (link to original article)
imageURL: String?    (lead image from enclosure, media:content, or og:image)
publishDate: Date
feedTitle: String    (denormalized for card display)
feedIconURL: String? (denormalized)
feedCategory: String (denormalized)
```

### SwipeEvent
```
postGuid: String
feedURL: String
feedCategory: String
action: String       ("like" or "dislike")
timestamp: Date
```

### SavedPost
```
postGuid: String
title: String
excerpt: String
url: String
imageURL: String?
feedTitle: String
feedCategory: String
savedAt: Date
```

### Seen Posts

Tracked as a per-feed `Set<String>` of GUIDs, persisted to disk via `UserDefaults` as a JSON array per feed URL. Trimmed to the last 500 entries per feed to bound size. Posts whose GUID is present are skipped during card generation.

## Card Rendering & Swipe UX

### Lazy Loading Pipeline

1. On launch, `FeedView` requests 10 posts from `FeedStore`
2. `FeedStore` iterates enabled feeds round-robin, skipping seen GUIDs
3. Feeds stale >15 minutes are re-fetched via `RSSEngine` before their posts enter the queue
4. Posts are sorted by publish date; posts within the same minute are shuffled to avoid clustering
5. `Personalizer.score(_:)` assigns each post a relevance weight; the queue is weighted-shuffled
6. While the user views card N, card N+1 preloads in a background view
7. When remaining cards drop below 5, the next batch of 10 is requested

### Card Layout

```
┌──────────────────────────┐
│                          │
│     Hero Image           │  ← AsyncImage, .aspectFill, gray placeholder
│                          │
├──────────────────────────┤
│ 🔬 Science · Ars Technica│  ← category chip (colored) + source name
│                          │
│ "Black holes may have    │  ← title, 2 lines max, semibold
│  a temperature after all"│
│                          │
│ Scientists at CERN...    │  ← excerpt, 3 lines max, secondary color
└──────────────────────────┘
```

### Swipe Gesture

- `DragGesture` with rotation (yaw) and opacity tied to `translation.width`
- Right swipe: green "LIKE" stamp fades in, card rotates slightly right
- Left swipe: red "NOPE" stamp fades in, card rotates slightly left
- Commit threshold: 40% of screen width
- Below threshold: spring back to center (`.spring(bounce: 0.6)`)
- Above threshold: card flies off with velocity-driven animation, next card slides up
- Tapping the card (not dragging) opens the article in an in-app Safari sheet (`.fullScreenCover`)

### Empty States

- **No feeds enabled:** "Add some feeds to get started" with a button linking to the Sources tab
- **All posts seen across all feeds:** "You're all caught up! Check back later" with pull-to-refresh
- **Feed fetch fails:** skip silently, retry next cycle — don't break the swipe flow

## Personalization Model

On-device only. No network, no telemetry.

### Scoring

`Personalizer.score(post:)` returns a 0.0–1.0 relevance weight:

- **Category boost:** `likes / max(1, likes + dislikes)` for the post's category
- **Source boost:** same ratio per specific feed
- **Cold start:** categories and feeds with no history default to 0.5 (neutral)
- **Recency decay:** swipe events older than 30 days are weighted at 50%; older than 60 days at 0%
- **Combined score:** `(categoryBoost * 0.4) + (sourceBoost * 0.6)` — source affinity matters slightly more

### Queue Assembly

The batch is shuffled with weighted randomness — higher score means more likely to appear earlier, but not guaranteed. Disliked content is never hidden; low-scoring posts just sink toward the bottom.

## Curated Feed List

Shipped as a static JSON file bundled with the app. Each entry has `title`, `url`, `category`, and `iconURL`. Categories and initial feeds:

| Category | Feeds |
|----------|-------|
| **News** | Reuters, AP News, NPR Top Stories |
| **Tech** | Ars Technica, The Verge, Hacker News |
| **Science** | Nature Briefing, Quanta Magazine, NASA |
| **Design** | This Is Colossal, It's Nice That, A List Apart |
| **Culture** | Aeon, The Atlantic, Longreads |

Users can disable any curated feed and add their own via URL.

## Error Handling

- **Invalid URL:** `AddFeedSheet` shows inline validation error before submission
- **Feed fetch timeout:** 15-second timeout per feed fetch. On failure, the feed is skipped this cycle and retried next time the card queue needs refilling
- **Parse failure:** logged to console, feed skipped silently — the user's swipe flow is never interrupted
- **No image in post:** card renders with a gradient placeholder in the image area, no broken image UI
- **Network offline:** cached posts in SwiftData continue to display. A subtle banner at the top of the feed says "Offline — showing cached posts"
- **Empty feed (valid URL, no items):** feed is added but shows "No posts yet" in the Sources list until items appear

## Testing Strategy

- **Unit tests:** `Personalizer` scoring math, `RSSEngine` parsing with known-good and known-malformed fixture files, `FeedStore` batch assembly logic
- **UI tests:** swipe gesture commit/reject thresholds, empty state transitions, tab navigation
- **No integration tests for MVP** — manual testing of the card feed UX is sufficient

## Out of Scope (Future)

- iCloud sync
- OPML import/export
- Reader view (stripped HTML for reading in-app)
- Widgets
- Notifications for new posts
- Search
- Share sheet integration
