import Foundation

struct OPMLParser {
    // MARK: - Parse cache

    /// Bump when the parse logic or FeedSource shape changes so old caches are
    /// ignored regardless of the input fingerprint.
    private static let cacheFormatVersion = 1

    /// Codable envelope persisted to Caches/. `fingerprint` ties the payload to
    /// the exact OPML corpus that produced it (see parseAll).
    private struct CachedParse: Codable {
        let fingerprint: String
        let sources: [FeedSource]
        let fileCount: Int
        let failedFileCount: Int
        let invalidSourceCount: Int
        let duplicateSourceCount: Int
    }

    private static var cacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("opml-parse-cache.json")
    }

    private static func loadCache(fingerprint: String) -> OPMLParseResult? {
        guard let url = cacheURL,
              let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder().decode(CachedParse.self, from: data),
              cached.fingerprint == fingerprint else { return nil }
        return OPMLParseResult(
            sources: cached.sources,
            fileCount: cached.fileCount,
            failedFileCount: cached.failedFileCount,
            invalidSourceCount: cached.invalidSourceCount,
            duplicateSourceCount: cached.duplicateSourceCount
        )
    }

    private static func saveCache(_ result: OPMLParseResult, fingerprint: String) {
        guard let url = cacheURL else { return }
        let payload = CachedParse(
            fingerprint: fingerprint,
            sources: result.sources,
            fileCount: result.fileCount,
            failedFileCount: result.failedFileCount,
            invalidSourceCount: result.invalidSourceCount,
            duplicateSourceCount: result.duplicateSourceCount
        )
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Scan the app bundle for all .opml files and parse them into FeedSource entries.
    /// Uses Bundle.urls(forResourcesWithExtension:subdirectory:) with fallback to root.
    static func parseAll() async -> OPMLParseResult {
        // Recursively collect all OPML files under Feeds/ using FileManager.
        // Bundle.urls(forResourcesWithExtension:subdirectory:) does NOT recurse
        // into subdirectories, so we enumerate manually to discover files inside
        // Feeds/countries/{country}/ (country + region OPMLs).
        var opmlFiles: [URL] = []
        var totalBytes = 0
        if let feedsURL = Bundle.main.resourceURL?.appendingPathComponent("Feeds"),
           let enumerator = FileManager.default.enumerator(at: feedsURL, includingPropertiesForKeys: [.fileSizeKey]) {
            while let fileURL = enumerator.nextObject() as? URL {
                if fileURL.pathExtension == "opml" {
                    opmlFiles.append(fileURL)
                    totalBytes += (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
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

        // Disk-cache fast path. The bundled OPML corpus is identical across every
        // launch of a given app build, yet parsing it means ~1900 file reads + XML
        // parses. Fingerprint the inputs cheaply (file count + total bytes, both
        // from stat only — no content reads) and skip the whole parse when the
        // cached result matches. Any OPML edit changes the byte total, and the
        // format version guards against parse-logic changes. Cache lives in
        // Caches/ so the OS may purge it; a miss simply re-parses.
        let fingerprint = "\(cacheFormatVersion)-\(opmlFiles.count)-\(totalBytes)"
        if let cached = loadCache(fingerprint: fingerprint) {
            return cached
        }

        // Parse files concurrently — each file is independent (own Data read +
        // XMLParser instance), so this is embarrassingly parallel. Results are
        // re-collated into the original file-sorted order before dedup, so the
        // downstream first-occurrence-wins dedup keeps byte-identical ownership
        // to the previous serial parse.
        var perFile = [(sources: [FeedSource], invalids: Int, failed: Bool)?](
            repeating: nil, count: opmlFiles.count
        )
        await withTaskGroup(of: (index: Int, sources: [FeedSource], invalids: Int, failed: Bool).self) { group in
            for (idx, fileURL) in opmlFiles.enumerated() {
                group.addTask {
                    let fileName = fileURL.deletingPathExtension().lastPathComponent
                    let region = Self.region(for: fileURL, fileName: fileName)
                    do {
                        let kind = Self.mediaKind(for: fileName)
                        let (sources, invalids) = try Self.parseFile(
                            url: fileURL,
                            fallbackCategory: fileName.capitalized,
                            region: region,
                            mediaKind: kind
                        )
                        return (idx, sources, invalids, false)
                    } catch {
                        print("[OPMLParser] Failed to parse \(fileURL.lastPathComponent): \(error)")
                        return (idx, [], 0, true)
                    }
                }
            }
            for await result in group {
                perFile[result.index] = (result.sources, result.invalids, result.failed)
            }
        }

        // Flatten in the deterministic file-sorted order.
        var allSources: [FeedSource] = []
        var failedFileCount = 0
        var invalidSourceCount = 0
        for entry in perFile {
            guard let entry else { continue }
            allSources.append(contentsOf: entry.sources)
            invalidSourceCount += entry.invalids
            if entry.failed { failedFileCount += 1 }
        }

        let deduped = deduplicateSources(allSources)
        let duplicateSourceCount = allSources.count - deduped.count

        let result = OPMLParseResult(
            sources: deduped,
            fileCount: opmlFiles.count,
            failedFileCount: failedFileCount,
            invalidSourceCount: invalidSourceCount,
            duplicateSourceCount: duplicateSourceCount
        )
        saveCache(result, fingerprint: fingerprint)
        return result
    }

    // MARK: - Private

    /// Encode a file's region from its path/name:
    /// - "global" for root/category feeds
    /// - "countries/{country}" for a country-level feed (e.g. brazil.opml in brazil/)
    /// - "countries/{country}/{region}" for a sub-region feed (e.g. brazil-acre.opml)
    static func region(for fileURL: URL, fileName: String) -> String {
        let components = fileURL.pathComponents
        guard let countriesIdx = components.lastIndex(of: "countries"),
              countriesIdx + 1 < components.count else {
            return "global"
        }
        let countryDir = components[countriesIdx + 1]
        if fileName == countryDir {
            return "countries/\(countryDir)"
        }
        if fileName.hasPrefix("\(countryDir)-") {
            let regionSlug = String(fileName.dropFirst(countryDir.count + 1))
            return "countries/\(countryDir)/\(regionSlug)"
        }
        return "countries/\(countryDir)"
    }

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

        // Normalize scheme to https (http→https equivalence)
        components.scheme = "https"
        // Strip www. prefix
        if let host = components.host?.lowercased(), host.hasPrefix("www.") {
            components.host = String(host.dropFirst(4))
        }

        var urlString = components.string ?? trimmed
        if urlString.hasSuffix("/") {
            urlString.removeLast()
        }
        // Remove common tracking/analytics query params
        if var url = URL(string: urlString),
           var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let trackingParams = ["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "ref", "source", "fbclid", "gclid"]
            comps.queryItems = comps.queryItems?.filter { !trackingParams.contains($0.name) }
            if let cleaned = comps.string { urlString = cleaned }
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
        // Per-source mediaKind override: file-level mediaKind is a hint,
        // but the URL is authoritative. YouTube feeds inside country OPMLs
        // were getting mediaKind=.text and losing their video boost.
        let resolvedKind: MediaKind = {
            if xmlUrl.contains("youtube.com/feeds") { return .video }
            if xmlUrl.contains("anchor.fm") || xmlUrl.contains("spreaker.com") || xmlUrl.contains("podcast") { return .audio }
            return mediaKind
        }()
        sources.append(
            FeedSource(
                title: title.isEmpty ? category : title,
                url: xmlUrl,
                category: category,
                region: region,
                mediaKind: resolvedKind
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
