# Feedmine

News & podcast aggregator for iOS. Curates content from 28,000+ RSS feeds across global sources and 190+ countries, with YouTube channel integration.

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

## OPML Pipeline

```
scripts/feed_discovery/   # Python — discover feeds by country/category
  └─ generates OPML files in feedmine/Resources/Feeds/
     ├── youtube.opml      # 545 YouTube channels
     ├── countries/        # 190+ countries with local RSS feeds
     └── *.opml            # Curated global feeds by category
```

## License

Proprietary — all rights reserved.
