import Foundation

// MARK: - Import Models

/// Outcome of a single feed URL import attempt.
enum ImportItemStatus: Sendable {
    case imported            // New, validated, added
    case duplicate           // Already exists in registry
    case invalid(String)     // URL malformed or not a feed (reason)
    case unreachable         // Network timeout or non-2xx
}

/// Per-item result returned by the pipeline.
struct ImportItemResult: Sendable {
    let url: String
    let title: String?
    let status: ImportItemStatus
}

/// Aggregate result of an import operation.
struct ImportResult: Sendable {
    let items: [ImportItemResult]
    var importedCount: Int { items.filter { if case .imported = $0.status { return true }; return false }.count }
    var duplicateCount: Int { items.filter { if case .duplicate = $0.status { return true }; return false }.count }
    var invalidCount: Int { items.filter { if case .invalid = $0.status { return true }; return false }.count }
    var unreachableCount: Int { items.filter { if case .unreachable = $0.status { return true }; return false }.count }

    var summary: String {
        var parts: [String] = []
        if importedCount > 0 { parts.append("\(importedCount) imported") }
        if duplicateCount > 0 { parts.append("\(duplicateCount) duplicates") }
        if invalidCount > 0 { parts.append("\(invalidCount) invalid") }
        if unreachableCount > 0 { parts.append("\(unreachableCount) unreachable") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Import Pipeline

/// Unified ingestion pipeline for feed sources.
/// Every import path (OPML file, pasted URL, remote URL, share sheet) feeds
/// through this single service, ensuring consistent dedup, validation,
/// classification, persistence, and feed reload.
///
/// Usage:
/// ```
/// let result = await pipeline.ingest(urls: ["https://example.com/feed.xml"])
/// let result = await pipeline.ingest(opmlData: data, fileName: "my_feeds")
/// let result = await pipeline.ingest(opmlURL: remoteURL)
/// ```
actor ImportPipeline {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.httpAdditionalHeaders = [
            "User-Agent": "FeedminePrototype/1.0",
            "Accept": "application/rss+xml, application/atom+xml, application/json, text/xml, */*"
        ]
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Import from raw feed URLs (pasted, share sheet, etc.)
    func ingest(
        urls: [String],
        category: String = "Imported",
        existingURLs: Set<String>
    ) async -> (result: ImportResult, sources: [FeedSource]) {
        var results: [ImportItemResult] = []
        var newSources: [FeedSource] = []

        // Separate dedup/invalid URLs (no network needed) from probe candidates
        var toProbe: [(index: Int, normalized: String, rawURL: String)] = []
        for (i, rawURL) in urls.enumerated() {
            let normalized = OPMLParser.normalizeURL(rawURL)

            // Dedup check
            if existingURLs.contains(normalized) {
                results.append(ImportItemResult(url: rawURL, title: nil, status: .duplicate))
                continue
            }

            // Validate URL format
            guard URL(string: normalized) != nil else {
                results.append(ImportItemResult(url: rawURL, title: nil, status: .invalid("Malformed URL")))
                continue
            }

            toProbe.append((i, normalized, rawURL))
        }

        // Probe feeds concurrently (max 5 at a time)
        let probeResults: [(rawURL: String, normalized: String, probe: ProbeResult)] = await withTaskGroup(of: (String, String, ProbeResult).self) { group in
            var collected: [(String, String, ProbeResult)] = []
            var running = 0

            for item in toProbe {
                if running >= 5 {
                    if let result = await group.next() {
                        collected.append(result)
                        running -= 1
                    }
                }
                let normalized = item.normalized
                let rawURL = item.rawURL
                group.addTask {
                    let probe = await self.probeFeed(url: normalized)
                    return (rawURL, normalized, probe)
                }
                running += 1
            }

            for await result in group {
                collected.append(result)
            }
            return collected
        }

        for (rawURL, normalized, probe) in probeResults {
            switch probe {
            case .success(let title):
                let kind = Self.detectMediaKind(url: normalized, title: title)
                let source = FeedSource(
                    title: title ?? Self.titleFromURL(normalized),
                    url: normalized,
                    category: category,
                    region: "imported",
                    mediaKind: kind
                )
                newSources.append(source)
                results.append(ImportItemResult(url: normalized, title: title, status: .imported))

            case .invalid(let reason):
                results.append(ImportItemResult(url: normalized, title: nil, status: .invalid(reason)))

            case .unreachable:
                results.append(ImportItemResult(url: normalized, title: nil, status: .unreachable))
            }
        }

        return (ImportResult(items: results), newSources)
    }

    /// Import from OPML file data (local file picker, AirDrop, etc.)
    func ingest(
        opmlData: Data,
        fileName: String,
        existingURLs: Set<String>,
        validate: Bool = true
    ) async -> (result: ImportResult, sources: [FeedSource]) {
        // Parse OPML
        let parser = XMLParser(data: opmlData)
        let delegate = OPMLImportDelegate(fallbackCategory: fileName.capitalized)
        parser.delegate = delegate
        parser.parse()

        let parsedSources = delegate.sources

        if !validate {
            // Skip validation — trust the OPML file (faster bulk import)
            var results: [ImportItemResult] = []
            var newSources: [FeedSource] = []
            for source in parsedSources {
                let normalized = OPMLParser.normalizeURL(source.url)
                if existingURLs.contains(normalized) {
                    results.append(ImportItemResult(url: source.url, title: source.title, status: .duplicate))
                } else {
                    let kind = Self.detectMediaKind(url: source.url, title: source.title)
                    let corrected = FeedSource(
                        title: source.title,
                        url: normalized,
                        category: source.category,
                        region: "imported",
                        mediaKind: kind
                    )
                    newSources.append(corrected)
                    results.append(ImportItemResult(url: source.url, title: source.title, status: .imported))
                }
            }
            return (ImportResult(items: results), newSources)
        }

        // With validation: probe each feed
        let urls = parsedSources.map(\.url)
        let titleMap = Dictionary(uniqueKeysWithValues: parsedSources.map { ($0.url, $0) })
        let (result, sources) = await ingest(
            urls: urls,
            category: fileName.capitalized,
            existingURLs: existingURLs
        )
        // Preserve original titles from OPML where available
        let corrected = sources.map { source -> FeedSource in
            if let original = titleMap[source.url] ?? titleMap[OPMLParser.normalizeURL(source.url)] {
                return FeedSource(
                    title: original.title.isEmpty ? source.title : original.title,
                    url: source.url,
                    category: original.category.isEmpty ? source.category : original.category,
                    region: "imported",
                    mediaKind: source.mediaKind
                )
            }
            return source
        }
        return (result, corrected)
    }

    /// Import from a remote OPML URL (fetch then parse)
    func ingest(
        opmlURL: URL,
        existingURLs: Set<String>,
        validate: Bool = true
    ) async -> (result: ImportResult, sources: [FeedSource])? {
        do {
            let (data, response) = try await session.data(from: opmlURL)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                return (ImportResult(items: [
                    ImportItemResult(url: opmlURL.absoluteString, title: nil, status: .unreachable)
                ]), [])
            }
            let fileName = opmlURL.deletingPathExtension().lastPathComponent
            return await ingest(opmlData: data, fileName: fileName, existingURLs: existingURLs, validate: validate)
        } catch {
            return (ImportResult(items: [
                ImportItemResult(url: opmlURL.absoluteString, title: nil, status: .unreachable)
            ]), [])
        }
    }

    // MARK: - Media Kind Detection

    /// Detect media kind from URL patterns and title hints.
    static func detectMediaKind(url: String, title: String?) -> MediaKind {
        let lower = url.lowercased()

        // YouTube feeds
        if lower.contains("youtube.com/feeds") || lower.contains("youtube.com/channel") {
            return .video
        }

        // Podcast indicators in URL
        let podcastPatterns = ["/podcast", "/episodes", "/audio", "anchor.fm", "feeds.buzzsprout",
                               "feeds.simplecast", "feeds.megaphone", "rss.art19", "feeds.transistor",
                               "feeds.acast", "feeds.libsyn", "pinecast.com", "omny.fm",
                               "podcasts.apple.com", "podbean.com/feed"]
        if podcastPatterns.contains(where: { lower.contains($0) }) {
            return .audio
        }

        // Title-based hints
        if let t = title?.lowercased() {
            if t.contains("podcast") || t.contains("episode") { return .audio }
            if t.contains("youtube") || t.contains("video") { return .video }
        }

        return .text
    }

    /// Derive a display title from a feed URL when no title is available.
    static func titleFromURL(_ url: String) -> String {
        guard let parsed = URL(string: url),
              let host = parsed.host else { return url }
        // Strip www. and common TLDs for readability
        var name = host
            .replacingOccurrences(of: "www.", with: "")
            .replacingOccurrences(of: "feeds.", with: "")
            .replacingOccurrences(of: "rss.", with: "")
        // Capitalize first letter
        if let first = name.first {
            name = String(first).uppercased() + name.dropFirst()
        }
        return name
    }

    // MARK: - Feed Probe

    private enum ProbeResult {
        case success(title: String?)
        case invalid(String)
        case unreachable
    }

    /// Fetch a URL and verify it contains a parseable RSS/Atom/JSON feed.
    /// Returns the feed title if found.
    private func probeFeed(url: String) async -> ProbeResult {
        guard let feedURL = URL(string: url) else { return .invalid("Malformed URL") }

        do {
            let (data, response) = try await session.data(from: feedURL)
            guard let http = response as? HTTPURLResponse else { return .unreachable }

            guard (200...299).contains(http.statusCode) else {
                return .unreachable
            }

            // Try parsing with FeedKit-style detection
            // Check for XML feed markers
            let prefix = String(data.prefix(500).compactMap { $0 < 128 ? Character(UnicodeScalar($0)) : nil })
            let isXML = prefix.contains("<rss") || prefix.contains("<feed") || prefix.contains("<RDF")
            let isJSON = prefix.trimmingCharacters(in: .whitespaces).hasPrefix("{")

            guard isXML || isJSON else {
                // Check content-type header
                let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
                if contentType.contains("html") {
                    return .invalid("HTML page, not a feed")
                }
                return .invalid("Unrecognized format")
            }

            // Extract title from feed
            let title = Self.extractTitle(from: data, isJSON: isJSON)
            return .success(title: title)
        } catch {
            return .unreachable
        }
    }

    /// Quick title extraction without full feed parse.
    private static func extractTitle(from data: Data, isJSON: Bool) -> String? {
        if isJSON {
            // JSON Feed: {"title": "..."}
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let title = json["title"] as? String {
                return title
            }
            return nil
        }
        // XML: <title>...</title> — grab the first one
        let str = String(data: data.prefix(2000), encoding: .utf8) ?? ""
        if let range = str.range(of: "<title>"),
           let end = str[range.upperBound...].range(of: "</title>") {
            let title = String(str[range.upperBound..<end.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip CDATA wrapper
            if title.hasPrefix("<![CDATA[") && title.hasSuffix("]]>") {
                return String(title.dropFirst(9).dropLast(3))
            }
            return title.isEmpty ? nil : title
        }
        return nil
    }
}

// MARK: - Minimal OPML Parser for Import (actor-safe)

private final class OPMLImportDelegate: NSObject, XMLParserDelegate, @unchecked Sendable {
    let fallbackCategory: String
    var sources: [FeedSource] = []
    private var categoryStack: [String] = []
    private var isLeafNode = false

    init(fallbackCategory: String) {
        self.fallbackCategory = fallbackCategory
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        guard element == "outline" else { return }
        if let xmlUrl = attributes["xmlUrl"] ?? attributes["xmlurl"] {
            // Leaf node (feed): use current category from stack, don't push
            let title = attributes["title"] ?? attributes["text"] ?? ""
            let category = categoryStack.last ?? fallbackCategory
            sources.append(FeedSource(title: title, url: xmlUrl, category: category, region: "imported"))
            isLeafNode = true
        } else {
            // Group node: push category onto stack
            let groupName = attributes["text"] ?? attributes["title"] ?? fallbackCategory
            categoryStack.append(groupName)
            isLeafNode = false
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        guard element == "outline" else { return }
        // Only pop when closing a group (non-leaf) outline
        if !isLeafNode && !categoryStack.isEmpty {
            categoryStack.removeLast()
        }
        isLeafNode = false
    }
}
