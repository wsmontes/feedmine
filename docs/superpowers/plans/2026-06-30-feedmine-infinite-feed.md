# Feedmine Infinite Feed Prototype — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a single-screen iOS 18+ RSS reader with OPML hot-folder ingestion, reservoir-based lazy loading, and a bounded visible buffer with debug status display.

**Architecture:** SwiftUI app with `@Observable` + Actor concurrency. `FeedLoader` (`@MainActor`, `@Observable`) manages the full pipeline: OPMLParser → FeedSource[] → RSSFetcher actor → reservoir → visible items[] → bounded buffer discard. Views observe the loader passively. FeedKit handles RSS/Atom parsing; URLSession controls networking.

**Tech Stack:** SwiftUI, `@Observable`, Actor, FeedKit (SPM), iOS 18+, Swift 6 strict concurrency

## Global Constraints

- iOS 18+ deployment target (iPhone only)
- Swift 6 strict concurrency — `actor` for network I/O, `@Observable` + `@MainActor` for view state
- No persistence — all state in memory
- One external dependency: FeedKit (MIT, via SPM)
- No tests — manual validation only (prototype)
- Dark mode support via semantic colors (no hardcoded colors)
- 5 OPML files across 5 categories shipped as bundled resources
- FeedKit used for parsing only; URLSession controls fetching (timeout, User-Agent, concurrency)

---

## File Structure

```
feedmine/
├── feedmine.xcodeproj/
├── feedmine/
│   ├── feedmineApp.swift
│   ├── ContentView.swift
│   ├── Models/
│   │   ├── FeedSource.swift
│   │   ├── FeedItem.swift
│   │   ├── OPMLParseResult.swift
│   │   └── FeedFetchBatch.swift
│   ├── Services/
│   │   ├── RSSFetcher.swift
│   │   ├── FeedLoader.swift
│   │   └── OPMLParser.swift
│   ├── Resources/
│   │   └── Feeds/
│   │       ├── tech.opml
│   │       ├── news.opml
│   │       ├── science.opml
│   │       ├── design.opml
│   │       └── culture.opml
│   └── Views/
│       ├── FeedScreen.swift
│       ├── FeedItemCardView.swift
│       └── DebugStatusBar.swift
```

---

### Task 1: Project Setup & App Skeleton

**Files:**
- Create: `feedmine.xcodeproj/` (via Xcode New Project)
- Create: `feedmine/feedmineApp.swift`
- Create: `feedmine/ContentView.swift`
- Create: folder structure (`Models/`, `Services/`, `Views/`, `Resources/Feeds/`)

**Interfaces:**
- Consumes: nothing (first task)
- Produces: compilable project with FeedKit SPM dependency, iOS 18 target, folder structure ready

- [ ] **Step 1: Create Xcode project**

Open Xcode → File → New → Project → iOS → App → SwiftUI. Configure:
- Product Name: `feedmine`
- Interface: SwiftUI
- Language: Swift
- Deployment Target: iOS 18.0
- Uncheck "Include Tests" (manual validation only)

Save to `/Users/wagnermontes/Documents/GitHub/feedmine/`.

- [ ] **Step 2: Add FeedKit via SPM**

In Xcode: File → Add Package Dependencies → search `https://github.com/nmdias/FeedKit` → Add Package.

Select the `FeedKit` library product for the `feedmine` target. Click Add Package.

- [ ] **Step 3: Create folder structure**

In Xcode project navigator, right-click `feedmine/` group → New Group. Create these groups:
- `Models`
- `Services`
- `Views`
- `Resources` (then inside it, New Group → `Feeds`)

Then delete the auto-generated `feedmineApp.swift` and `ContentView.swift` (we'll recreate them with the right content).

Verify the project navigator shows:
```
feedmine/
├── feedmineApp.swift
├── ContentView.swift
├── Models/
├── Services/
├── Views/
└── Resources/
    └── Feeds/
```

- [ ] **Step 4: Write feedmineApp.swift**

Create `feedmine/feedmineApp.swift`:

```swift
import SwiftUI

@main
struct FeedmineApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

- [ ] **Step 5: Write ContentView.swift**

Create `feedmine/ContentView.swift`:

```swift
import SwiftUI

struct ContentView: View {
    @State private var loader = FeedLoader()

    var body: some View {
        FeedScreen()
            .environment(loader)
    }
}
```

This won't compile yet — `FeedLoader` and `FeedScreen` don't exist. That's expected. We only need the project to be structurally correct at this point.

- [ ] **Step 6: Build and verify it fails correctly**

Run: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -20`

Expected: build fails with `Cannot find 'FeedLoader' in scope` and `Cannot find 'FeedScreen' in scope`. This confirms the project structure, SPM dependency, and Swift compilation are working.

- [ ] **Step 7: Commit**

```bash
git add feedmine.xcodeproj/ feedmine/ Package.resolved
git commit -m "feat: create Xcode project with FeedKit SPM dependency and folder structure

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Models

**Files:**
- Create: `feedmine/Models/FeedSource.swift`
- Create: `feedmine/Models/FeedItem.swift`
- Create: `feedmine/Models/OPMLParseResult.swift`
- Create: `feedmine/Models/FeedFetchBatch.swift`
- Create: `feedmine/Models/FeedFetchResult.swift`

**Interfaces:**
- Consumes: nothing (standalone structs)
- Produces:
  - `FeedSource: Codable, Identifiable, Sendable` — `id: String { url }`, `title: String`, `url: String`, `category: String`
  - `FeedItem: Identifiable, Sendable` — `id: String`, `sourceTitle: String`, `sourceURL: String`, `category: String`, `title: String`, `excerpt: String`, `url: String`, `imageURL: String?`, `publishedAt: Date`
  - `OPMLParseResult: Sendable` — `sources: [FeedSource]`, `fileCount: Int`, `failedFileCount: Int`, `invalidSourceCount: Int`, `duplicateSourceCount: Int`
  - `FeedFetchBatch: Sendable` — `items: [FeedItem]`, `fetchedSourceCount: Int`, `failedSourceCount: Int`, `emptySourceCount: Int`
  - `FeedFetchResult: Sendable` — `source: FeedSource`, `items: [FeedItem]`, `status: FeedFetchStatus`
  - `FeedFetchStatus: Sendable, Equatable, CaseIterable` — `case success`, `case empty`, `case failed`

- [ ] **Step 1: Write FeedSource.swift**

Create `feedmine/Models/FeedSource.swift`:

```swift
import Foundation

struct FeedSource: Codable, Identifiable, Sendable {
    var id: String { url }
    let title: String
    let url: String
    let category: String
}
```

- [ ] **Step 2: Write FeedItem.swift**

Create `feedmine/Models/FeedItem.swift`:

```swift
import Foundation
import CryptoKit

struct FeedItem: Identifiable, Sendable {
    let id: String
    let sourceTitle: String
    let sourceURL: String
    let category: String
    let title: String
    let excerpt: String
    let url: String
    let imageURL: String?
    let publishedAt: Date

    /// SHA256("sourceURL|guid_or_link") — unique across feeds
    static func generateID(sourceURL: String, guid: String?, link: String?, title: String? = nil, publishedAt: Date? = nil) -> String {
        let token: String = {
            if let guid = guid, !guid.isEmpty { return guid }
            if let link = link, !link.isEmpty { return link }
            // Fallback: source + title + timestamp — imperfect but prevents data loss
            let ts = publishedAt.map { String($0.timeIntervalSince1970) } ?? "0"
            let t = title ?? "untitled"
            return "\(t)|\(ts)"
        }()
        let raw = "\(sourceURL)|\(token)"
        let data = Data(raw.utf8)
        return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 3: Write OPMLParseResult.swift**

Create `feedmine/Models/OPMLParseResult.swift`:

```swift
import Foundation

struct OPMLParseResult: Sendable {
    let sources: [FeedSource]
    let fileCount: Int
    let failedFileCount: Int
    let invalidSourceCount: Int
    let duplicateSourceCount: Int
}
```

- [ ] **Step 4: Write FeedFetchResult.swift**

Create `feedmine/Models/FeedFetchResult.swift`:

```swift
import Foundation

enum FeedFetchStatus: Sendable, Equatable, CaseIterable {
    case success
    case empty
    case failed
}

struct FeedFetchResult: Sendable {
    let source: FeedSource
    let items: [FeedItem]
    let status: FeedFetchStatus
}
```

- [ ] **Step 5: Write FeedFetchBatch.swift**

Create `feedmine/Models/FeedFetchBatch.swift`:

```swift
import Foundation

struct FeedFetchBatch: Sendable {
    let items: [FeedItem]
    let fetchedSourceCount: Int
    let failedSourceCount: Int
    let emptySourceCount: Int
}
```

- [ ] **Step 6: Build to verify models compile**

Run: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | grep -E 'error:|BUILD SUCCEEDED'`

Expected: builds fail with `Cannot find 'FeedLoader' in scope` (from ContentView) — models compile fine, the remaining error is from Task 1's ContentView referencing FeedLoader.

- [ ] **Step 7: Commit**

```bash
git add feedmine/Models/
git commit -m "feat: add feed models and fetch result types

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: OPMLParser + Curated OPML Files

**Files:**
- Create: `feedmine/Services/OPMLParser.swift`
- Create: `feedmine/Resources/Feeds/tech.opml`
- Create: `feedmine/Resources/Feeds/news.opml`
- Create: `feedmine/Resources/Feeds/science.opml`
- Create: `feedmine/Resources/Feeds/design.opml`
- Create: `feedmine/Resources/Feeds/culture.opml`

**Interfaces:**
- Consumes: `FeedSource`, `OPMLParseResult` (from Task 2)
- Produces:
  - `OPMLParser` — static method `parseAll() -> OPMLParseResult`
  - `OPMLParser` — private helpers `parseFile(url:) -> [FeedSource]`, `deduplicateSources(_:) -> [FeedSource]`, `normalizeURL(_:) -> String`

- [ ] **Step 1: Write tech.opml**

Create `feedmine/Resources/Feeds/tech.opml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<opml version="1.0">
  <head><title>Tech Feeds</title></head>
  <body>
    <outline text="Tech">
      <outline title="Ars Technica" xmlUrl="https://feeds.arstechnica.com/arstechnica/index" type="rss"/>
      <outline title="The Verge" xmlUrl="https://www.theverge.com/rss/index.xml" type="rss"/>
      <outline title="Hacker News" xmlUrl="https://hnrss.org/frontpage" type="rss"/>
    </outline>
  </body>
</opml>
```

- [ ] **Step 2: Write news.opml**

Create `feedmine/Resources/Feeds/news.opml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<opml version="1.0">
  <head><title>News Feeds</title></head>
  <body>
    <outline text="News">
      <outline title="Reuters" xmlUrl="https://news.google.com/rss/search?q=when:24h+allinurl:reuters.com&amp;hl=en-US&amp;gl=US&amp;ceid=US:en" type="rss"/>
      <outline title="AP News" xmlUrl="https://news.google.com/rss/search?q=when:24h+allinurl:apnews.com&amp;hl=en-US&amp;gl=US&amp;ceid=US:en" type="rss"/>
      <outline title="NPR Top Stories" xmlUrl="https://feeds.npr.org/1001/rss.xml" type="rss"/>
    </outline>
  </body>
</opml>
```

- [ ] **Step 3: Write science.opml**

Create `feedmine/Resources/Feeds/science.opml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<opml version="1.0">
  <head><title>Science Feeds</title></head>
  <body>
    <outline text="Science">
      <outline title="Nature Briefing" xmlUrl="https://www.nature.com/nature.rss" type="rss"/>
      <outline title="Quanta Magazine" xmlUrl="https://www.quantamagazine.org/feed/" type="rss"/>
      <outline title="NASA Breaking News" xmlUrl="https://www.nasa.gov/feeds/iotd-feed/" type="rss"/>
    </outline>
  </body>
</opml>
```

- [ ] **Step 4: Write design.opml**

Create `feedmine/Resources/Feeds/design.opml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<opml version="1.0">
  <head><title>Design Feeds</title></head>
  <body>
    <outline text="Design">
      <outline title="This Is Colossal" xmlUrl="https://www.thisiscolossal.com/feed/" type="rss"/>
      <outline title="It's Nice That" xmlUrl="https://www.itsnicethat.com/feed" type="rss"/>
      <outline title="A List Apart" xmlUrl="https://alistapart.com/main/feed/" type="rss"/>
    </outline>
  </body>
</opml>
```

- [ ] **Step 5: Write culture.opml**

Create `feedmine/Resources/Feeds/culture.opml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<opml version="1.0">
  <head><title>Culture Feeds</title></head>
  <body>
    <outline text="Culture">
      <outline title="Aeon" xmlUrl="https://aeon.co/feed.rss" type="rss"/>
      <outline title="The Atlantic" xmlUrl="https://feeds.feedburner.com/TheAtlantic" type="rss"/>
      <outline title="Longreads" xmlUrl="https://longreads.com/feed/" type="rss"/>
    </outline>
  </body>
</opml>
```

- [ ] **Step 6: Write OPMLParser.swift**

Create `feedmine/Services/OPMLParser.swift`:

```swift
import Foundation

struct OPMLParser {
    /// Scan the app bundle for all .opml files and parse them into FeedSource entries.
    /// Uses Bundle.urls(forResourcesWithExtension:subdirectory:) with fallback to root.
    static func parseAll() -> OPMLParseResult {
        // Try subdirectory "Feeds" first, then root as fallback
        var opmlFiles = Bundle.main.urls(forResourcesWithExtension: "opml", subdirectory: "Feeds") ?? []
        if opmlFiles.isEmpty {
            // Fallback: OPML files at bundle root
            opmlFiles = Bundle.main.urls(forResourcesWithExtension: "opml", subdirectory: nil) ?? []
        }
        opmlFiles.sort { $0.lastPathComponent < $1.lastPathComponent }

        guard !opmlFiles.isEmpty else {
            return OPMLParseResult(sources: [], fileCount: 0, failedFileCount: 0, invalidSourceCount: 0, duplicateSourceCount: 0)
        }

        var allSources: [FeedSource] = []
        var failedFileCount = 0
        var invalidSourceCount = 0

        for fileURL in opmlFiles {
            let fileName = fileURL.deletingPathExtension().lastPathComponent
            do {
                let (sources, invalids) = try parseFile(url: fileURL, fallbackCategory: fileName.capitalized)
                allSources.append(contentsOf: sources)
                invalidSourceCount += invalids
            } catch {
                print("[OPMLParser] Failed to parse \(fileURL.lastPathComponent): \(error)")
                failedFileCount += 1
            }
        }

        let deduped = deduplicateSources(allSources)
        let duplicateSourceCount = allSources.count - deduped.count

        return OPMLParseResult(
            sources: deduped,
            fileCount: opmlFiles.count,
            failedFileCount: failedFileCount,
            invalidSourceCount: invalidSourceCount,
            duplicateSourceCount: duplicateSourceCount
        )
    }

    // MARK: - Private

    private static func parseFile(url: URL, fallbackCategory: String) throws -> (sources: [FeedSource], invalidCount: Int) {
        let data = try Data(contentsOf: url)
        let parser = XMLParser(data: data)
        let delegate = OPMLDelegate(fallbackCategory: fallbackCategory)
        parser.delegate = delegate
        parser.parse()

        if let error = parser.parserError {
            throw error
        }

        return (delegate.sources, delegate.invalidSourceCount)
    }

    private static func deduplicateSources(_ sources: [FeedSource]) -> [FeedSource] {
        var seen: Set<String> = []
        var result: [FeedSource] = []

        for source in sources {
            let key = normalizeURL(source.url)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(source)
        }

        return result
    }

    /// Lowercase scheme and host only. Trim whitespace. Remove trailing slash. Preserve path/query case.
    static func normalizeURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else { return trimmed }

        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()

        var urlString = components.string ?? trimmed
        if urlString.hasSuffix("/") {
            urlString.removeLast()
        }
        return urlString
    }
}

// MARK: - XMLParser Delegate

private final class OPMLDelegate: NSObject, XMLParserDelegate {
    let fallbackCategory: String
    var sources: [FeedSource] = []
    var invalidSourceCount = 0

    private var categoryStack: [String] = []
    private var outlinePushStack: [Bool] = []  // tracks which opens pushed a category

    init(fallbackCategory: String) {
        self.fallbackCategory = fallbackCategory
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard elementName == "outline" else { return }

        let xmlUrl = attributeDict["xmlUrl"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = attributeDict["title"] ?? attributeDict["text"] ?? ""

        if xmlUrl.isEmpty {
            // Category container — push onto stack, record that we pushed
            let category = attributeDict["title"] ?? attributeDict["text"]
            if let cat = category, !cat.isEmpty {
                categoryStack.append(cat)
                outlinePushStack.append(true)
            } else {
                outlinePushStack.append(false)
            }
            return
        }

        // Feed source — did NOT push a category
        outlinePushStack.append(false)

        // Validate URL has scheme and host
        guard let components = URLComponents(string: xmlUrl),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil else {
            invalidSourceCount += 1
            return
        }

        let category = categoryStack.last ?? fallbackCategory
        sources.append(
            FeedSource(
                title: title.isEmpty ? category : title,
                url: xmlUrl,
                category: category
            )
        )
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard elementName == "outline" else { return }

        let didPushCategory = outlinePushStack.popLast() ?? false
        if didPushCategory, !categoryStack.isEmpty {
            categoryStack.removeLast()
        }
    }
}
```

- [ ] **Step 7: Verify OPML files are bundled**

The `OPMLParser` expects OPML files at `Feedmine.app/Feeds/*.opml` (uses `subdirectory: "Feeds"` with fallback to root).

In Xcode, drag the `Resources/Feeds/` folder from Finder into the project navigator under the `feedmine/` group. Choose:
- **"Create folder references"** (blue folder icon, NOT yellow group)
- **"Add to targets: feedmine"** — checked

This copies the folder as `Feedmine.app/Feeds/` preserving the directory structure.

Verify after build:
```bash
find ~/Library/Developer/Xcode/DerivedData/feedmine-*/Build/Products/Debug-iphonesimulator/feedmine.app -name "*.opml" 2>/dev/null
```
Expected: all five `.opml` files listed under `feedmine.app/Feeds/`.

- [ ] **Step 8: Commit**

```bash
git add feedmine/Services/OPMLParser.swift feedmine/Resources/
git commit -m "feat: add OPMLParser with tolerant parsing, category inheritance, and URL deduplication

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: RSSFetcher

**Files:**
- Create: `feedmine/Services/RSSFetcher.swift`

**Interfaces:**
- Consumes: `FeedSource`, `FeedItem`, `FeedFetchBatch`, `FeedFetchResult`, `FeedFetchStatus` (from Task 2)
- Produces:
  - `actor RSSFetcher` — `func fetch(_ source: FeedSource) async -> FeedFetchResult`
  - `actor RSSFetcher` — `func fetchAll(_ sources: [FeedSource], maxConcurrent: Int = 5) async -> FeedFetchBatch`

- [ ] **Step 1: Write RSSFetcher.swift**

Create `feedmine/Services/RSSFetcher.swift`:

```swift
import Foundation
import FeedKit

actor RSSFetcher {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        config.httpAdditionalHeaders = [
            "User-Agent": "FeedminePrototype/1.0"
        ]
        self.session = URLSession(configuration: config)
    }

    /// Fetch and parse a single feed. Never throws — returns FeedFetchResult with status.
    func fetch(_ source: FeedSource) async -> FeedFetchResult {
        guard let url = URL(string: source.url) else {
            print("[RSSFetcher] Invalid URL for \(source.title): \(source.url)")
            return FeedFetchResult(source: source, items: [], status: .failed)
        }

        do {
            let (data, response) = try await session.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                print("[RSSFetcher] Bad status for \(source.title)")
                return FeedFetchResult(source: source, items: [], status: .failed)
            }

            let parser = FeedParser(data: data)
            let result = parser.parse()

            switch result {
            case .success(let feed):
                let items = extractItems(from: feed, source: source)
                if items.isEmpty {
                    print("[RSSFetcher] Empty feed: \(source.title)")
                    return FeedFetchResult(source: source, items: [], status: .empty)
                }
                return FeedFetchResult(source: source, items: items, status: .success)
            case .failure(let error):
                print("[RSSFetcher] Parse failure for \(source.title): \(error)")
                return FeedFetchResult(source: source, items: [], status: .failed)
            }
        } catch {
            print("[RSSFetcher] Network error for \(source.title): \(error)")
            return FeedFetchResult(source: source, items: [], status: .failed)
        }
    }

    /// Fetch multiple feeds concurrently with a real concurrency cap.
    func fetchAll(_ sources: [FeedSource], maxConcurrent: Int = 5) async -> FeedFetchBatch {
        var allItems: [FeedItem] = []
        var fetchedSourceCount = 0
        var failedSourceCount = 0
        var emptySourceCount = 0

        // Process in chunks to enforce concurrency cap
        var remaining = sources
        while !remaining.isEmpty {
            let chunk = Array(remaining.prefix(maxConcurrent))
            remaining.removeFirst(chunk.count)

            let results: [FeedFetchResult] = await withTaskGroup(of: FeedFetchResult.self) { group in
                for source in chunk {
                    group.addTask {
                        await self.fetch(source)
                    }
                }
                var chunkResults: [FeedFetchResult] = []
                for await result in group {
                    chunkResults.append(result)
                }
                return chunkResults
            }

            // Count by status — independent of completion order
            for result in results {
                switch result.status {
                case .success:
                    fetchedSourceCount += 1
                    allItems.append(contentsOf: result.items)
                case .empty:
                    emptySourceCount += 1
                case .failed:
                    failedSourceCount += 1
                }
            }
        }

        return FeedFetchBatch(
            items: allItems,
            fetchedSourceCount: fetchedSourceCount,
            failedSourceCount: failedSourceCount,
            emptySourceCount: emptySourceCount
        )
    }

    // MARK: - Private

    private func extractItems(from feed: Feed, source: FeedSource) -> [FeedItem] {
        let entries: [FeedItem] = {
            switch feed {
            case .atom(let atomFeed):
                return (atomFeed.entries ?? []).compactMap { entry in
                    let rawContent = entry.content?.value ?? entry.summary?.value ?? ""
                    return makeItem(
                        guid: entry.id,
                        link: entry.links?.first?.attributes?.href ?? entry.id,
                        title: entry.title,
                        publishedAt: entry.published ?? entry.updated,
                        source: source,
                        rawDescription: entry.summary?.value ?? entry.content?.value,
                        rawContent: entry.content?.value,
                        imageURL: extractFirstImageFromHTML(rawContent)
                    )
                }
            case .rss(let rssFeed):
                return (rssFeed.items ?? []).compactMap { item in
                    makeItem(
                        guid: item.guid?.value,
                        link: item.link,
                        title: item.title,
                        publishedAt: item.pubDate,
                        source: source,
                        rawDescription: item.description,
                        rawContent: item.content?.contentEncoded,
                        imageURL: extractImageURL(from: item)
                    )
                }
            case .json(let jsonFeed):
                return (jsonFeed.items ?? []).compactMap { jsonItem in
                    makeItem(
                        guid: jsonItem.id,
                        link: jsonItem.url,
                        title: jsonItem.title,
                        publishedAt: jsonItem.datePublished,
                        source: source,
                        rawDescription: jsonItem.summary ?? jsonItem.contentText,
                        rawContent: jsonItem.contentHtml,
                        imageURL: jsonItem.image ?? jsonItem.bannerImage
                    )
                }
            }
        }()

        return entries
    }

    private func makeItem(
        guid: String?,
        link: String?,
        title: String?,
        publishedAt: Date?,
        source: FeedSource,
        rawDescription: String?,
        rawContent: String?,
        imageURL: String?
    ) -> FeedItem? {
        let resolvedLink = link ?? ""
        // Discard items without a clickable URL
        guard !resolvedLink.isEmpty else { return nil }

        let id = FeedItem.generateID(
            sourceURL: source.url,
            guid: guid,
            link: link,
            title: title,
            publishedAt: publishedAt
        )

        let excerpt = extractExcerpt(
            description: rawDescription,
            content: rawContent
        )

        return FeedItem(
            id: id,
            sourceTitle: source.title,
            sourceURL: source.url,
            category: source.category,
            title: title ?? "Untitled",
            excerpt: excerpt,
            url: resolvedLink,
            imageURL: imageURL,
            publishedAt: publishedAt ?? Date()
        )
    }

    /// Extract image URL from RSS item in priority order.
    private func extractImageURL(from item: RSSFeedItem) -> String? {
        // 1. media:content / media:thumbnail (Media RSS namespace)
        if let media = item.media,
           let mediaContent = media.mediaContents?.first,
           let url = mediaContent.attributes?.url {
            return url
        }
        if let media = item.media,
           let mediaThumbnails = media.mediaThumbnails,
           let thumb = mediaThumbnails.first,
           let url = thumb.attributes?.url {
            return url
        }

        // 2. enclosure with image type
        if let enclosure = item.enclosure,
           let type = enclosure.attributes?.type,
           type.hasPrefix("image/"),
           let url = enclosure.attributes?.url {
            return url
        }

        // 3. First <img> in content
        if let content = item.content?.contentEncoded ?? item.description {
            return extractFirstImageFromHTML(content)
        }

        return nil
    }

    /// Extract first <img src> from an HTML string.
    private func extractFirstImageFromHTML(_ html: String) -> String? {
        let pattern = #"<img[^>]+src=["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[range])
    }

    /// Extract excerpt from available fields in priority order.
    private func extractExcerpt(description: String?, content: String?) -> String {
        let raw = description ?? content ?? ""
        let stripped = strippingHTMLTags(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty { return "No description" }
        return String(stripped.prefix(200))
    }

    /// Strip HTML tags using NSAttributedString conversion.
    private func strippingHTMLTags(_ html: String) -> String {
        guard let data = html.data(using: .utf8) else { return html }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        if let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
            return attributed.string
        }
        // Fallback: regex strip
        return html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }
}
```

- [ ] **Step 2: Verify FeedKit API compatibility**

Open the file in Xcode and check that FeedKit's type and property names match what the code uses. Key properties to verify:

- `RSSFeedItem.guid?.value` — GUID value
- `RSSFeedItem.media?.mediaContents` — Media RSS content array
- `RSSFeedItem.media?.mediaThumbnails` — Media RSS thumbnail array
- `RSSFeedItem.enclosure?.attributes?.url` / `attributes?.type` — enclosure
- `RSSFeedItem.content?.contentEncoded` — content:encoded body
- `AtomFeedEntry.id`, `.links`, `.summary`, `.content` — Atom fields
- `JSONFeedItem.id`, `.url`, `.summary`, `.contentText`, `.contentHtml`, `.image`, `.bannerImage` — JSON Feed fields
- `FeedParser(data:)` — parser initializer
- `FeedParser.parse()` — parse method returning `Result<Feed, ParserError>`
- `Feed` enum cases: `.atom(AtomFeed)`, `.rss(RSSFeed)`, `.json(JSONFeed)`

If any property name differs, inspect the FeedKit type in Xcode autocomplete and adapt the property name **without changing the public interface** of `fetch(_:)` and `fetchAll(_:)`.

- [ ] **Step 3: Commit**

```bash
git add feedmine/Services/RSSFetcher.swift
git commit -m "feat: add RSSFetcher actor with URLSession control and FeedKit parsing

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: FeedLoader

**Files:**
- Create: `feedmine/Services/FeedLoader.swift`

**Interfaces:**
- Consumes: `FeedSource`, `FeedItem`, `OPMLParseResult`, `FeedFetchBatch` (Task 2), `RSSFetcher` (Task 4), `OPMLParser` (Task 3)
- Produces:
  - `@MainActor @Observable final class FeedLoader`
  - `enum FeedLoadingState: case idle, initial, refreshing, loadingMore`
  - Public: `items`, `loadingState`, debug counters
  - Methods: `start() async`, `refresh() async`, `loadMoreIfNeeded(currentItem:) async`, `trimBufferIfNeeded()`

- [ ] **Step 1: Write FeedLoader.swift**

Create `feedmine/Services/FeedLoader.swift`:

```swift
import Foundation
import Observation

enum FeedLoadingState {
    case idle
    case initial
    case refreshing
    case loadingMore
}

@MainActor
@Observable
final class FeedLoader {
    // MARK: - Public state (observed by views)
    private(set) var items: [FeedItem] = []
    private(set) var loadingState: FeedLoadingState = .idle

    // Debug counters
    private(set) var opmlFileCount = 0
    private(set) var sourceCount = 0
    private(set) var invalidSourceCount = 0
    private(set) var opmlErrorCount = 0
    private(set) var duplicateSourceCount = 0
    private(set) var reservoirCount = 0
    private(set) var totalFetched = 0
    private(set) var totalDiscarded = 0
    private(set) var fetchErrorCount = 0
    private(set) var emptyFeedCount = 0

    // MARK: - Internal state
    private let fetcher = RSSFetcher()
    private var sources: [FeedSource] = []
    private var reservoir: [FeedItem] = []
    private var loadedIDs: Set<String> = []
    private var currentVisibleItemID: String?
    private var currentVisibleIndex: Int = 0
    private var hasStarted = false

    // MARK: - Constants
    static let maxBuffer = 300
    static let loadMoreThreshold = 15
    static let discardBatchSize = 50
    static let initialWindowSize = 50
    static let reservoirLowWatermark = 20
    static let safetyZoneRadius = 50

    // MARK: - Public methods

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        loadingState = .initial

        // Step 1: Parse OPML
        let parseResult = OPMLParser.parseAll()
        sources = parseResult.sources
        opmlFileCount = parseResult.fileCount
        opmlErrorCount = parseResult.failedFileCount
        invalidSourceCount = parseResult.invalidSourceCount
        duplicateSourceCount = parseResult.duplicateSourceCount
        sourceCount = sources.count

        guard !sources.isEmpty else {
            loadingState = .idle
            return
        }

        // Step 2: Fetch from all sources
        let batch = await fetcher.fetchAll(sources)
        totalFetched = batch.items.count
        fetchErrorCount = batch.failedSourceCount
        emptyFeedCount = batch.emptySourceCount

        // Step 3: Deduplicate and register ALL accepted item IDs
        let actualNew = batch.items.filter { !loadedIDs.contains($0.id) }
        loadedIDs.formUnion(actualNew.map(\.id))

        // Step 4: Sort by publish date descending, fill reservoir
        reservoir = actualNew.sorted { $0.publishedAt > $1.publishedAt }

        // Step 5: Move initial window from reservoir to visible items
        let windowSize = min(Self.initialWindowSize, reservoir.count)
        items = Array(reservoir.prefix(windowSize))
        reservoir.removeFirst(windowSize)
        reservoirCount = reservoir.count

        loadingState = .idle
    }

    func refresh() async {
        loadingState = .refreshing

        // Clear all state
        loadedIDs.removeAll()
        reservoir.removeAll()
        items.removeAll()

        guard !sources.isEmpty else {
            loadingState = .idle
            return
        }

        let batch = await fetcher.fetchAll(sources)
        totalFetched = batch.items.count
        fetchErrorCount = batch.failedSourceCount
        emptyFeedCount = batch.emptySourceCount

        let actualNew = batch.items.filter { !loadedIDs.contains($0.id) }
        loadedIDs.formUnion(actualNew.map(\.id))

        reservoir = actualNew.sorted { $0.publishedAt > $1.publishedAt }

        let windowSize = min(Self.initialWindowSize, reservoir.count)
        items = Array(reservoir.prefix(windowSize))
        reservoir.removeFirst(windowSize)
        reservoirCount = reservoir.count

        loadingState = .idle
    }

    func loadMoreIfNeeded(currentItem: FeedItem) async {
        // Track visible position
        currentVisibleItemID = currentItem.id
        if let index = items.firstIndex(where: { $0.id == currentItem.id }) {
            currentVisibleIndex = index
        }

        guard loadingState == .idle else { return }

        // Only trigger when near the bottom
        guard let itemIndex = items.firstIndex(where: { $0.id == currentItem.id }),
              itemIndex >= items.count - Self.loadMoreThreshold else {
            return
        }

        // Step 1: If reservoir is empty, fetch first
        if reservoir.isEmpty {
            loadingState = .loadingMore
            await refillReservoir()
            loadingState = .idle
        }

        // Step 2: Move from reservoir to visible (show content we already have)
        moveFromReservoirToVisible(count: Self.loadMoreThreshold)

        // Step 3: Always trim after adding items (regardless of network fetch)
        trimBufferIfNeeded()

        // Step 4: Refill reservoir in background if low
        if reservoir.count < Self.reservoirLowWatermark {
            loadingState = .loadingMore
            await refillReservoir()
            loadingState = .idle
        }
    }

    func trimBufferIfNeeded() {
        guard items.count > Self.maxBuffer else { return }

        let excess = items.count - Self.maxBuffer
        let toDiscard = min(Self.discardBatchSize, excess)

        // Priority 1: discard items above current position (already scrolled past)
        let safeStart = max(0, currentVisibleIndex - Self.safetyZoneRadius)
        let aboveCandidates = items[0..<safeStart]
        let aboveToDiscard = min(toDiscard, aboveCandidates.count)

        if aboveToDiscard > 0 {
            items.removeFirst(aboveToDiscard)
            currentVisibleIndex -= aboveToDiscard  // adjust index after removal
            totalDiscarded += aboveToDiscard
        }

        // Priority 2: if still over, discard from far below
        let remaining = toDiscard - aboveToDiscard
        if remaining > 0 && items.count > Self.maxBuffer {
            let safeEnd = min(items.count, currentVisibleIndex + Self.safetyZoneRadius)
            if safeEnd < items.count {
                let belowToDiscard = min(remaining, items.count - safeEnd)
                if belowToDiscard > 0 {
                    items.removeLast(belowToDiscard)
                    totalDiscarded += belowToDiscard
                }
            }
        }
    }

    // MARK: - Private

    private func moveFromReservoirToVisible(count: Int) {
        guard !reservoir.isEmpty else { return }
        let toMove = min(count, reservoir.count)
        let batch = Array(reservoir.prefix(toMove))
        items.append(contentsOf: batch)
        reservoir.removeFirst(toMove)
        reservoirCount = reservoir.count
    }

    private func refillReservoir() async {
        guard !sources.isEmpty else { return }

        let batch = await fetcher.fetchAll(sources)
        totalFetched += batch.items.count
        fetchErrorCount += batch.failedSourceCount
        emptyFeedCount += batch.emptySourceCount

        let actualNew = batch.items.filter { !loadedIDs.contains($0.id) }
        loadedIDs.formUnion(actualNew.map(\.id))

        let sorted = actualNew.sorted { $0.publishedAt > $1.publishedAt }
        reservoir.append(contentsOf: sorted)
        reservoir.sort { $0.publishedAt > $1.publishedAt }
        reservoirCount = reservoir.count
    }
}
```

- [ ] **Step 2: Build to verify everything compiles**

Run: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | grep -E 'error:|BUILD SUCCEEDED'`

Expected: build fails with `Cannot find 'FeedScreen' in scope` (from `ContentView.swift`). All other types — FeedLoader, RSSFetcher, OPMLParser, models, FeedKit — compile successfully. The only remaining error is the missing `FeedScreen` view, which is created in Task 6.

Verify there are no other errors beyond `FeedScreen`:
```bash
xcodebuild ... 2>&1 | grep "error:" | grep -v "FeedScreen"
```
Expected: no output (no errors unrelated to FeedScreen).

- [ ] **Step 3: Commit**

```bash
git add feedmine/Services/FeedLoader.swift
git commit -m "feat: add FeedLoader with reservoir, buffer management, and loading states

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 6: Views

**Files:**
- Create: `feedmine/Views/DebugStatusBar.swift`
- Create: `feedmine/Views/FeedItemCardView.swift`
- Create: `feedmine/Views/FeedScreen.swift`
- Modify: `feedmine/ContentView.swift` (already created in Task 1, now compiles)

**Interfaces:**
- Consumes: `FeedLoader`, `FeedItem` (from Task 5 and Task 2)
- Produces: Complete UI — DebugStatusBar observes FeedLoader, FeedItemCardView renders a single item, FeedScreen composes scroll + lazy stack + debug bar, ContentView wires loader

- [ ] **Step 1: Write DebugStatusBar.swift**

Create `feedmine/Views/DebugStatusBar.swift`:

```swift
import SwiftUI

struct DebugStatusBar: View {
    @Environment(FeedLoader.self) private var loader

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                Text("\(loader.items.count) visible")
                Text(" · ")
                Text("\(loader.reservoirCount) reservoir")
                Text(" · ")
                Text("\(loader.sourceCount) sources")
                Text(" · ")
                Text("\(loader.opmlFileCount) files")
                if loader.duplicateSourceCount > 0 {
                    Text(" · ")
                    Text("\(loader.duplicateSourceCount) duplicates")
                }
                Text(" · ")
                Text("\(loader.totalFetched) fetched")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack(spacing: 0) {
                Text("\(loader.totalDiscarded) discarded")
                Text(" · ")
                Text("\(loader.fetchErrorCount) fetch errors")
                Text(" · ")
                Text("\(loader.opmlErrorCount) OPML errors")
                Text(" · ")
                statusIndicator
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(Color(.systemGray6))
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch loader.loadingState {
        case .idle:
            Text("✓ idle")
        case .initial:
            Text("⏳ initial")
        case .refreshing:
            Text("⟳ refreshing")
        case .loadingMore:
            Text("⏳ loading more")
        }
    }
}
```

- [ ] **Step 2: Write FeedItemCardView.swift**

Create `feedmine/Views/FeedItemCardView.swift`:

```swift
import SwiftUI

struct FeedItemCardView: View {
    let item: FeedItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Hero image
            if let imageURL = item.imageURL, let url = URL(string: imageURL) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(height: 180)
                            .clipped()
                    case .failure, .empty:
                        Color.gray.opacity(0.2)
                            .frame(height: 180)
                    @unknown default:
                        Color.gray.opacity(0.2)
                            .frame(height: 180)
                    }
                }
            }

            // Category + source
            HStack(spacing: 4) {
                Text(item.category)
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(categoryColor(item.category).opacity(0.15))
                    .clipShape(Capsule())

                Text("·")
                    .foregroundStyle(.tertiary)

                Text(item.sourceTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // Title
            Text(item.title)
                .font(.headline)
                .lineLimit(2)
                .padding(.horizontal, 16)
                .padding(.top, 8)

            // Excerpt
            Text(item.excerpt)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .padding(.horizontal, 16)
                .padding(.top, 4)

            // Relative date
            Text(item.publishedAt, style: .relative)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 16)
        }
        .background(Color(.systemBackground))
    }

    private func categoryColor(_ category: String) -> Color {
        switch category.lowercased() {
        case "tech": return .blue
        case "news": return .red
        case "science": return .green
        case "design": return .purple
        case "culture": return .orange
        default: return .gray
        }
    }
}
```

- [ ] **Step 3: Write FeedScreen.swift**

Create `feedmine/Views/FeedScreen.swift`:

```swift
import SwiftUI
import SafariServices

struct ArticleRoute: Identifiable {
    let id = UUID()
    let url: URL
}

struct FeedScreen: View {
    @Environment(FeedLoader.self) private var loader
    @State private var selectedArticle: ArticleRoute?

    var body: some View {
        VStack(spacing: 0) {
            DebugStatusBar()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(loader.items) { item in
                        FeedItemCardView(item: item)
                            .onTapGesture {
                                if let url = URL(string: item.url) {
                                    selectedArticle = ArticleRoute(url: url)
                                }
                            }
                            .onAppear {
                                Task {
                                    await loader.loadMoreIfNeeded(currentItem: item)
                                }
                            }
                    }
                }
            }
        }
        .task {
            await loader.start()
        }
        .refreshable {
            await loader.refresh()
        }
        .sheet(item: $selectedArticle) { route in
            SafariView(url: route.url)
        }
    }
}

// MARK: - SFSafariViewController wrapper

private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
```

- [ ] **Step 4: Verify ContentView.swift is correct**

The ContentView from Task 1 should already have the right content. Confirm `feedmine/ContentView.swift` reads:

```swift
import SwiftUI

struct ContentView: View {
    @State private var loader = FeedLoader()

    var body: some View {
        FeedScreen()
            .environment(loader)
    }
}
```

If it still has placeholder content, replace it with the above.

- [ ] **Step 5: Build and verify full compilation**

Run: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | grep -E 'error:|warning:|BUILD SUCCEEDED'`

Expected: `BUILD SUCCEEDED` with zero errors.

- [ ] **Step 6: Commit**

```bash
git add feedmine/Views/ feedmine/ContentView.swift
git commit -m "feat: add DebugStatusBar, FeedItemCardView, FeedScreen, and finalize ContentView

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 7: Verify & Run

- [ ] **Step 1: Build for simulator**

```bash
xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 2: Open in Xcode and run**

Open the project in Xcode:
```bash
open feedmine.xcodeproj
```

Select iPhone 16 simulator. Press Cmd+R to build and run.

- [ ] **Step 3: Manual validation checklist**

Verify each acceptance criterion:

1. App opens directly into feed screen — content loads automatically
2. Debug bar shows counters: visible items, reservoir, sources, files, fetched, discarded, fetch errors, OPML errors, loading state
3. Cards show title, source, category chip, excerpt, relative date
4. Cards with images show images (async with placeholder)
5. Cards without images collapse the image area
6. Tapping a card opens SFSafariViewController with the article URL
7. Scrolling near bottom loads more items from reservoir (reservoir count decreases)
8. Pull-to-refresh clears and reloads everything
9. No duplicate posts appear
10. Debug bar updates counters in real time

- [ ] **Step 4: Test buffer discard**

With only 15 feeds, you may not reach 300 items in a normal session. To validate the discard logic, temporarily change the buffer constants in `FeedLoader.swift`:

```swift
static let maxBuffer = 100       // was 300
static let discardBatchSize = 20 // was 50
```

Then scroll extensively — after the feed accumulates more than 100 visible items plus reservoir, the discard should trim items above the current position. Verify:

1. `totalDiscarded` counter in the debug bar increments
2. Scroll position remains stable (no jumps)
3. Items near the visible area are preserved

After validating, restore the original values:
```swift
static let maxBuffer = 300
static let discardBatchSize = 50
```

Commit the restored values before proceeding.

- [ ] **Step 5: Test OPML hot folder**

Add a new test file `test.opml` to `Resources/Feeds/`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<opml version="1.0">
  <body>
    <outline text="Test">
      <outline title="Test Feed" xmlUrl="https://example.com/feed.xml" type="rss"/>
    </outline>
  </body>
</opml>
```

Rebuild (Cmd+R). Debug bar should show `sources: 16` (15 original + 1 new). The new feed may show as a `fetch error` if example.com doesn't serve RSS — that's expected behavior.

Remove `test.opml`, rebuild. Sources should return to 15.

- [ ] **Step 6: Test error resilience**

Temporarily break one OPML file by adding invalid XML to `culture.opml`:
```xml
<broken>
```

Rebuild. Debug bar should show `1 OPML error`. culture feeds disappear but tech, news, science, and design feeds still work.

Restore `culture.opml` to its original content. Rebuild.

- [ ] **Step 7: Final commit (if any fixes were made)**

```bash
git add -A && git diff --cached --stat
git commit -m "chore: final verification and adjustments after manual testing

Co-Authored-By: Claude <noreply@anthropic.com>"
```
