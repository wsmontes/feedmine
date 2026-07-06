import Foundation

struct OPMLParser {
    /// Scan the app bundle for all .opml files and parse them into FeedSource entries.
    /// Uses Bundle.urls(forResourcesWithExtension:subdirectory:) with fallback to root.
    static func parseAll() async -> OPMLParseResult {
        // Try subdirectory "Feeds" first, then root as fallback
        var opmlFiles = Bundle.main.urls(forResourcesWithExtension: "opml", subdirectory: "Feeds") ?? []
        if opmlFiles.isEmpty {
            // Fallback: OPML files at bundle root
            opmlFiles = Bundle.main.urls(forResourcesWithExtension: "opml", subdirectory: nil) ?? []
        }
        opmlFiles.shuffle()

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

    static func deduplicateSources(_ sources: [FeedSource]) -> [FeedSource] {
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
    /// Parse a single OPML file from any URL (for import)
    static func parseImportedFile(url: URL) throws -> [FeedSource] {
        let data = try Data(contentsOf: url)
        let parser = XMLParser(data: data)
        let fileName = url.deletingPathExtension().lastPathComponent
        let delegate = OPMLDelegate(fallbackCategory: fileName.capitalized)
        parser.delegate = delegate
        parser.parse()
        if let error = parser.parserError { throw error }
        return delegate.sources
    }

    /// Export current sources as an OPML string
    static func exportOPML(sources: [FeedSource]) -> String {
        let grouped = Dictionary(grouping: sources, by: \.category)
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="1.0">
          <head><title>Feedmine Export</title></head>
          <body>

        """
        for (category, feeds) in grouped.sorted(by: { $0.key < $1.key }) {
            xml += "    <outline text=\"\(category)\">\n"
            for feed in feeds {
                xml += "      <outline title=\"\(feed.title)\" xmlUrl=\"\(feed.url)\" type=\"rss\"/>\n"
            }
            xml += "    </outline>\n"
        }
        xml += """
          </body>
        </opml>
        """
        return xml
    }

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
