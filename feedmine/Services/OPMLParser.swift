import Foundation

struct OPMLParser {
    /// Scan the app bundle for all .opml files and parse them into FeedSource entries.
    /// Uses Bundle.urls(forResourcesWithExtension:subdirectory:) with fallback to root.
    static func parseAll() async -> OPMLParseResult {
        // Recursively collect all OPML files under Feeds/ using FileManager.
        // Bundle.urls(forResourcesWithExtension:subdirectory:) does NOT recurse
        // into subdirectories, so we enumerate manually to discover files inside
        // Feeds/countries/{country}/ (country + region OPMLs).
        var opmlFiles: [URL] = []
        if let feedsURL = Bundle.main.resourceURL?.appendingPathComponent("Feeds"),
           let enumerator = FileManager.default.enumerator(at: feedsURL, includingPropertiesForKeys: nil) {
            while let fileURL = enumerator.nextObject() as? URL {
                if fileURL.pathExtension == "opml" {
                    opmlFiles.append(fileURL)
                }
            }
        }

        // Sort files for a STABLE, deterministic parse order. Dedup keeps the
        // first occurrence of a duplicated feed URL, so ordering decides which
        // region/category owns it — that ownership must not change across
        // launches. (Randomizing fetch order, if wanted, belongs in the
        // scheduler, not here where it corrupts canonical source metadata.)
        opmlFiles.sort { $0.path < $1.path }

        guard !opmlFiles.isEmpty else {
            return OPMLParseResult(sources: [], fileCount: 0, failedFileCount: 0, invalidSourceCount: 0, duplicateSourceCount: 0)
        }

        var allSources: [FeedSource] = []
        var failedFileCount = 0
        var invalidSourceCount = 0

        for fileURL in opmlFiles {
            let fileName = fileURL.deletingPathExtension().lastPathComponent
            let region: String = {
                let components = fileURL.pathComponents
                // Region encoding: "countries/{country}" for country-level feeds,
                // "countries/{country}/{region}" for sub-region feeds.
                guard let countriesIdx = components.lastIndex(of: "countries"),
                      countriesIdx + 1 < components.count else {
                    return "global"
                }
                let countryDir = components[countriesIdx + 1]
                // Main country feed: e.g. brazil.opml inside brazil/ dir
                if fileName == countryDir {
                    return "countries/\(countryDir)"
                }
                // Region feed: e.g. brazil-acre.opml → countries/brazil/acre
                if fileName.hasPrefix("\(countryDir)-") {
                    let regionSlug = String(fileName.dropFirst(countryDir.count + 1))
                    return "countries/\(countryDir)/\(regionSlug)"
                }
                // Fallback for any other file inside a country directory
                return "countries/\(countryDir)"
            }()
            do {
                let kind = mediaKind(for: fileName)
                let (sources, invalids) = try parseFile(url: fileURL, fallbackCategory: fileName.capitalized, region: region, mediaKind: kind)
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

    private static func parseFile(url: URL, fallbackCategory: String, region: String, mediaKind: MediaKind = .text) throws -> (sources: [FeedSource], invalidCount: Int) {
        let data = try Data(contentsOf: url)
        let parser = XMLParser(data: data)
        let delegate = OPMLDelegate(fallbackCategory: fallbackCategory, region: region, mediaKind: mediaKind)
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

    /// Derive the media kind from an OPML filename, so the scheduler can
    /// differentiate podcast/video/text sources at the collection level.
    static func mediaKind(for fileName: String) -> MediaKind {
        let lower = fileName.lowercased()
        if lower.contains("podcast") { return .audio }
        if lower.contains("youtube") { return .video }
        return .text
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
            xml += "    <outline text=\"\(xmlEscape(category))\">\n"
            for feed in feeds {
                xml += "      <outline title=\"\(xmlEscape(feed.title))\" xmlUrl=\"\(xmlEscape(feed.url))\" type=\"rss\"/>\n"
            }
            xml += "    </outline>\n"
        }
        xml += """
          </body>
        </opml>
        """
        return xml
    }

    /// Escape text for safe inclusion in an XML attribute value. `&` must be
    /// replaced first, or the entities produced by the later replacements would
    /// themselves be re-escaped. Without this, titles/URLs containing `"`, `&`,
    /// or `<` produce malformed OPML that fails to re-import.
    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
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
    let region: String
    let mediaKind: MediaKind
    var sources: [FeedSource] = []
    var invalidSourceCount = 0

    private var categoryStack: [String] = []
    private var outlinePushStack: [Bool] = []  // tracks which opens pushed a category

    init(fallbackCategory: String, region: String = "global", mediaKind: MediaKind = .text) {
        self.fallbackCategory = fallbackCategory
        self.region = region
        self.mediaKind = mediaKind
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
                category: category,
                region: region,
                mediaKind: mediaKind
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
