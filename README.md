# Feedmine

News, podcast, video, and forum feed reader for iOS. The bundled catalog
contains 34,243 normalized content-analyzed sources with descriptions, tags,
language, format, activity, and freshness-aware defaults.

## Build

```bash
# iOS Simulator
xcodebuild build -project feedmine.xcodeproj -scheme feedmine \
  -destination 'platform=iOS Simulator,name=iPhone 14 Plus'

# Physical device
xcodebuild build -project feedmine.xcodeproj -scheme feedmine \
  -destination 'platform=iOS,id=<DEVICE_UDID>'
```

**Important:** Edit `feedmine.xcodeproj` directly. Do not regenerate with `xcodegen` from `project.yml` — it would drop the GRDB dependency that was added manually.

For build, installation, XCUITest automation, screenshots, and diagnostics on a
USB-connected iPhone, see [Physical Device Testing](docs/PhysicalDeviceTesting.md).

## Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| [FeedKit](https://github.com/nmdias/FeedKit) | 9.1.2 | RSS/Atom/JSON Feed parsing |
| [GRDB](https://github.com/groue/GRDB.swift) | 7.4.0 | SQLite with FTS5 full-text search |

## Architecture

```
feedmine/
├── Models/         # FeedItem, FeedSource, Country
├── Services/       # FeedStore, FeedLoader, RSSFetcher, Reservoir, SourceScheduler
├── Views/          # SwiftUI views — FeedScreen, cards, player, settings
└── Resources/      # OPML feed files, Localizable strings, translations
```

- **FeedStore** — SQLite persistence, migrations, fetch orchestration
- **FeedLoader** — `@Observable` view model bridging FeedStore to SwiftUI
- **Reservoir** — In-memory buffer with fairness interleave for feed diversity
- **SourceScheduler** — Selects which RSS sources to fetch based on entropy/deficits
- **CircadianEngine** — Time-of-day visual theme (palette, typography)
- **SearchEngine** — tiered FTS5 search over sources/tags, saved items, and the
  remaining local history/cache
- **Source View and Source Collections** — direct per-source history and
  reusable many-to-many playlists; see
  [Source experience](editorial/feed-curation/source-experience.md)

## OPML Pipeline

The Parquet corpus is the evidence layer; OPML remains the editorial/runtime
source of truth. Folder prefixes define the menu order. Production currently
uses 118 OPML 2.0 files instead of thousands of discovery fragments.

```bash
# Generate a validated tree and audit artifacts without replacing the bundle
.venv_feeds/bin/python scripts/curate_opml_catalog.py \
  --now 2026-07-20T00:00:00Z

# Build the disposable FTS5 catalog from the generated tree
python3 scripts/build_catalog.py \
  --feeds-root build/feed-curation/Feeds \
  --output build/feed-curation/catalog.sqlite \
  --manifest-output build/feed-curation/catalog-manifest.json
```

Dormant evergreen feeds remain enabled and discoverable. Dormant feeds whose
value depends on recency (news, politics, gossip, personal voices, and similar)
remain searchable but are disabled by default. Non-production discoveries live
in `editorial/feed-curation/staging/` and are not bundled; every identity also
has a production, empty, failed, policy-excluded, or synthetic disposition in
`editorial/feed-curation/source-disposition-ledger.csv.gz`.

## Image diagnostics

Audit recent image URLs from a copied app database and group failures by feed
and cause:

```bash
make audit-images IMAGE_AUDIT_DB=/path/to/feedmine.sqlite
```

The command writes JSON, CSV, and Markdown reports to `build/image-audit/`.

## License

Proprietary — all rights reserved.
