import Foundation

struct OPMLParser {
    // MARK: - Parse cache

    /// Bump when the parse LOGIC or FeedSource shape changes (region derivation,
    /// mediaKind classification, dedup/normalize) so caches produced by the old
    /// logic are ignored even within the same app build.
    private static let cacheFormatVersion = 6  // +file stat in fingerprint (OPML reorg in ae17b903)

    /// Codable envelope persisted to Caches/.
    private struct CachedParse: Codable {
        let fingerprint: String
        let sources: [FeedSource]
        let fileCount: Int
        let failedFileCount: Int
        let invalidSourceCount: Int
        let duplicateSourceCount: Int
    }

    /// Cache key combining app version with file-system metadata so that
    /// reorganizing, adding, or removing OPML files automatically invalidates
    /// the cache. The file count and the newest mtime among bundled OPML files
    /// serve as a fast approximate fingerprint — no per-file hash walk.
    private static func cacheFingerprint() -> String {
        let info = Bundle.main.infoDictionary
        let build = info?["CFBundleVersion"] as? String ?? "0"
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        // Bundled resources are immutable for an installed build. One stat on
        // the executable plus one on the Feeds root invalidates development
        // installs without walking thousands of OPML files on every launch.
        let feedsURL = Bundle.main.resourceURL?.appendingPathComponent("Feeds")
        let executableMtime = Bundle.main.executableURL.flatMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        } ?? nil
        let feedsMtime = feedsURL.flatMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        } ?? nil
        let stamp = max(
            executableMtime?.timeIntervalSince1970 ?? 0,
            feedsMtime?.timeIntervalSince1970 ?? 0
        )
        return "\(cacheFormatVersion)-\(short)-\(build)-mt\(Int64(stamp * 1000))"
    }

    private static var cacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("opml-parse-cache.plist")
    }

    private static func loadCache(fingerprint: String) -> OPMLParseResult? {
        guard let url = cacheURL,
              let data = try? Data(contentsOf: url),
              let cached = try? PropertyListDecoder().decode(CachedParse.self, from: data),
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
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(payload)
            try data.write(to: url, options: .atomic)
        } catch {
            // Surface a persistently failing cache write (full disk, bad
            // permissions) instead of silently re-parsing on every launch.
            Log.feed.error("Failed to write parse cache: \(error)")
        }
    }

    /// Scan the app bundle for all .opml files and parse them into FeedSource entries.
    static func parseAll() async -> OPMLParseResult {
        // Cache fast path after a constant-time bundle fingerprint.
        let endFingerprintMetric = FeedMetrics.beginInterval("OPML.fingerprint")
        let fingerprint = cacheFingerprint()
        endFingerprintMetric()

        let endCacheReadMetric = FeedMetrics.beginInterval("OPML.cacheRead")
        let cached = loadCache(fingerprint: fingerprint)
        endCacheReadMetric()
        if let cached {
            FeedMetrics.event("OPML.cacheHit")
            return cached
        }
        FeedMetrics.event("OPML.cacheMiss")

        // Cache miss: enumerate all bundled OPML files. Bundle.urls(...) does not
        // recurse, so we walk Feeds/ manually to reach Feeds/countries/{c}/… feeds.
        let endFullParseMetric = FeedMetrics.beginInterval("OPML.fullParse")
        defer { endFullParseMetric() }
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

        // Parse concurrently but BOUNDED to ~core count in flight. Each parseFile
        // does synchronous blocking I/O (Data(contentsOf:) + XMLParser); spawning
        // one task per file (~1900) would over-subscribe the cooperative thread
        // pool and open ~1900 descriptors at once. A sliding window keeps at most
        // `maxConcurrency` tasks live while still collating results by original
        // index, so dedup ownership stays byte-identical to a serial parse.
        // Honors cancellation: if the parent task is cancelled mid-parse we stop
        // adding work and do NOT cache the partial result.
        var perFile = [(sources: [FeedSource], invalids: Int, failed: Bool)?](
            repeating: nil, count: opmlFiles.count
        )
        let maxConcurrency = max(2, ProcessInfo.processInfo.activeProcessorCount)
        var wasCancelled = false
        await withTaskGroup(of: (index: Int, sources: [FeedSource], invalids: Int, failed: Bool).self) { group in
            var submitted = 0
            let seed = min(maxConcurrency, opmlFiles.count)
            while submitted < seed {
                let idx = submitted, url = opmlFiles[idx]
                group.addTask { Self.parseOne(idx, url) }
                submitted += 1
            }
            while let result = await group.next() {
                perFile[result.index] = (result.sources, result.invalids, result.failed)
                if Task.isCancelled {
                    wasCancelled = true
                    group.cancelAll()
                    break
                }
                if submitted < opmlFiles.count {
                    let idx = submitted, url = opmlFiles[idx]
                    group.addTask { Self.parseOne(idx, url) }
                    submitted += 1
                }
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
        FeedMetrics.event(
            "OPML.parseCounts",
            "files=\(opmlFiles.count) sources=\(deduped.count) duplicates=\(duplicateSourceCount) invalid=\(invalidSourceCount)"
        )
        // Only cache a COMPLETE parse. A partial result from a transient file
        // failure or a cancellation must never be persisted, or it would be
        // served on every later launch until the app build changes.
        if failedFileCount == 0 && !wasCancelled {
            saveCache(result, fingerprint: fingerprint)
        }
        return result
    }

    /// Parse a single OPML file into sources, tagged with its derived region.
    /// Pure and Sendable — safe to run as a concurrent child task.
    private static func parseOne(_ index: Int, _ fileURL: URL) -> (index: Int, sources: [FeedSource], invalids: Int, failed: Bool) {
        let fileName = fileURL.deletingPathExtension().lastPathComponent
        let region = region(for: fileURL, fileName: fileName)
        do {
            let kind = mediaKind(for: fileName)
            let (sources, invalids) = try parseFile(
                url: fileURL,
                fallbackCategory: fileName.capitalized,
                region: region,
                mediaKind: kind
            )
            return (index, sources, invalids, false)
        } catch {
            Log.feed.error("Failed to parse \(fileURL.lastPathComponent): \(error)")
            return (index, [], 0, true)
        }
    }

    // MARK: - Private

    /// Encode a file's region from its path/name:
    /// - "global" for root/category feeds (flat, no parent directory)
    /// - "countries/{country}" for a country-level feed (e.g. brazil.opml in brazil/)
    /// - "countries/{country}/{region}" for a sub-region feed (e.g. brazil-acre.opml)
    /// - "topic/{group}" for a feed in a topic subdirectory (e.g. Sports/soccer.opml)
    /// - "topic/{group}/{subgroup}" for nested topic subdirectories
    private static func region(for fileURL: URL, fileName: String) -> String {
        let components = fileURL.pathComponents
        // Check for countries/ first (existing behavior preserved)
        if let countriesIdx = components.lastIndex(of: "countries"),
           countriesIdx + 1 < components.count {
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
        // Check if file is inside a subdirectory of Feeds/ (excluding languages/)
        if let feedsIdx = components.lastIndex(of: "Feeds"),
           feedsIdx + 2 < components.count {
            let relative = Array(components[(feedsIdx + 1)...])
            // Skip languages/ — those are language variants of global topics
            if relative.first == "languages" { return "global" }
            // Skip countries/ (handled above)
            if relative.first == "countries" { return "global" }
            // Encode the directory path as a topic region
            if relative.count >= 2 {
                let dirPath = relative.dropLast().joined(separator: "/")
                return "topic/\(dirPath)"
            }
        }
        return "global"
    }

    /// Extract <language> from the OPML <head> section by scanning the raw XML.
    private static func extractLanguage(from data: Data) -> String? {
        // Quick scan — look for <language>en</language> in the first 2KB
        let head = String(data: data.prefix(2048), encoding: .utf8) ?? ""
        guard let range = head.range(of: "<language>"),
              let endRange = head.range(of: "</language>", range: range.upperBound..<head.endIndex) else {
            return nil
        }
        let lang = String(head[range.upperBound..<endRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return lang.isEmpty ? nil : lang
    }

    private static func parseFile(url: URL, fallbackCategory: String, region: String, mediaKind: MediaKind = .text) throws -> (sources: [FeedSource], invalidCount: Int) {
        let data = try Data(contentsOf: url)
        let fileLanguage = extractLanguage(from: data)
        let parser = XMLParser(data: data)
        let delegate = OPMLDelegate(fallbackCategory: fallbackCategory, region: region, mediaKind: mediaKind,
                                    fileLanguage: fileLanguage)
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
        if lower.contains("reddit") || lower.contains("forum") { return .forum }
        return .text
    }

    /// Lowercase scheme and host only. Trim whitespace. Remove trailing slash. Preserve path/query case.
    /// Parse a single OPML file from any URL (for import)
    static func parseImportedFile(url: URL) throws -> [FeedSource] {
        let data = try Data(contentsOf: url)
        let fileLanguage = extractLanguage(from: data)
        let parser = XMLParser(data: data)
        let fileName = url.deletingPathExtension().lastPathComponent
        let delegate = OPMLDelegate(fallbackCategory: fileName.capitalized, fileLanguage: fileLanguage)
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
    private var languageStack: [String?] = []
    private var fileLanguage: String?  // from <head><language>

    init(fallbackCategory: String, region: String = "global", mediaKind: MediaKind = .text,
         fileLanguage: String? = nil) {
        self.fallbackCategory = fallbackCategory
        self.region = region
        self.mediaKind = mediaKind
        self.fileLanguage = fileLanguage
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard elementName == "outline" else { return }

        let xmlUrl = attributeDict["xmlUrl"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = attributeDict["title"] ?? attributeDict["text"] ?? ""

        let language = attributeDict["language"]

        if xmlUrl.isEmpty {
            // Category container — push onto stack, record that we pushed
            let category = attributeDict["title"] ?? attributeDict["text"]
            if let cat = category, !cat.isEmpty {
                categoryStack.append(cat)
                // Push language: outline attr → parent → file-level (all nil-safe)
                languageStack.append(language ?? languageStack.last ?? fileLanguage)
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
            if xmlUrl.contains("reddit.com/r/") { return .forum }
            return mediaKind
        }()
        let resolvedLanguage = language ?? languageStack.last ?? fileLanguage

        sources.append(
            FeedSource(
                title: title.isEmpty ? category : title,
                url: xmlUrl,
                category: category,
                region: region,
                mediaKind: resolvedKind,
                language: resolvedLanguage
            )
        )
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard elementName == "outline" else { return }

        let didPushCategory = outlinePushStack.popLast() ?? false
        if didPushCategory, !categoryStack.isEmpty {
            categoryStack.removeLast()
        }
        if didPushCategory, !languageStack.isEmpty {
            languageStack.removeLast()
        }
    }
}
