import Foundation
import FeedKit

actor RSSFetcher {
    private let session: URLSession

    /// Cache of audio-URL → playable? so repeat fetches never re-probe the same
    /// enclosure (podcast episode URLs are stable).
    private var audioPlayability: [String: Bool] = [:]

    private static let playabilityCacheKey = "audio_playability_cache"

    init() {
        // Restore persisted playability cache (#34) so probes survive restart
        if let saved = UserDefaults.standard.dictionary(forKey: Self.playabilityCacheKey) as? [String: Bool] {
            audioPlayability = saved
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = true       // wait for network instead of failing immediately
        config.allowsCellularAccess = true
        config.httpMaximumConnectionsPerHost = 2 // be a good citizen
        config.urlCache = URLCache(memoryCapacity: 4_194_304, diskCapacity: 20_971_520) // 4MB mem, 20MB disk
        config.httpAdditionalHeaders = [
            "User-Agent": "FeedminePrototype/1.0",
            "Accept": "application/rss+xml, application/atom+xml, application/json, text/xml"
        ]
        self.session = URLSession(configuration: config)
    }

    /// Fetch and parse a single feed. Never throws — returns FeedFetchResult with status.
    func fetch(_ source: FeedSource) async -> FeedFetchResult {
        guard !Task.isCancelled else {
            return FeedFetchResult(source: source, items: [], status: .failed)
        }
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
                let validated = await validateAudio(in: items)
                return FeedFetchResult(source: source, items: validated, status: .success)
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
        var sourceStatuses: [String: FeedFetchStatus] = [:]

        // Sliding-window concurrency: keep up to `maxConcurrent` fetches in
        // flight at all times. As each one finishes we immediately start the
        // next, so a single slow feed can only occupy its own slot — it can't
        // stall the whole batch. (The previous chunked approach blocked every
        // free slot until the slowest feed in the chunk returned, so with
        // maxConcurrent=15 one hung feed idled up to 14 others for the full
        // request timeout.)
        let cap = max(1, maxConcurrent)

        await withTaskGroup(of: FeedFetchResult.self) { group in
            var iterator = sources.makeIterator()

            // Prime the window.
            var started = 0
            while started < cap, let source = iterator.next() {
                group.addTask { await self.fetch(source) }
                started += 1
            }

            // Drain as results arrive, refilling each freed slot.
            while let result = await group.next() {
                sourceStatuses[result.source.url] = result.status
                switch result.status {
                case .success:
                    fetchedSourceCount += 1
                    allItems.append(contentsOf: result.items)
                case .empty:
                    emptySourceCount += 1
                case .failed:
                    failedSourceCount += 1
                }

                if Task.isCancelled {
                    // Stop starting new work; signal in-flight fetches to bail
                    // early, then keep draining until the window empties.
                    group.cancelAll()
                } else if let source = iterator.next() {
                    group.addTask { await self.fetch(source) }
                }
            }
        }

        return FeedFetchBatch(
            items: allItems,
            fetchedSourceCount: fetchedSourceCount,
            failedSourceCount: failedSourceCount,
            emptySourceCount: emptySourceCount,
            sourceStatuses: sourceStatuses
        )
    }

    // MARK: - Audio extraction

    private struct AudioEnclosure {
        let url: String
        let duration: TimeInterval?
    }

    private func extractAudio(from item: RSSFeedItem, source: FeedSource) -> AudioEnclosure? {
        // Standard enclosure
        if let enc = item.enclosure?.attributes,
           let url = enc.url,
           Self.isAudioCandidate(url: url, type: enc.type, medium: nil),
           let resolved = resolvedAudioURL(url, source: source) {
            return AudioEnclosure(url: resolved, duration: nil)
        }

        // Media namespace
        let mediaContents = (item.media?.mediaContents ?? []) + (item.media?.mediaGroup?.mediaContents ?? [])
        if !mediaContents.isEmpty {
            for m in mediaContents {
                guard let attr = m.attributes, let url = attr.url else { continue }
                if Self.isAudioCandidate(url: url, type: attr.type, medium: attr.medium),
                   let resolved = resolvedAudioURL(url, source: source) {
                    let duration = attr.duration.map(TimeInterval.init)
                    return AudioEnclosure(url: resolved, duration: duration)
                }
            }
        }

        return nil
    }

    /// True if the URL path ends in a common audio file extension. Uses the URL
    /// path so query strings (e.g. "…/ep.mp3?token=…") don't defeat the match.
    private static func hasAudioFileExtension(_ url: String) -> Bool {
        let path = (URL(string: url)?.path ?? url).lowercased()
        let exts = [".mp3", ".m4a", ".m4b", ".aac", ".ogg", ".oga", ".opus", ".wav", ".flac"]
        return exts.contains { path.hasSuffix($0) }
    }

    private static func isAudioCandidate(url: String, type: String?, medium: String?) -> Bool {
        let mediaType = type?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let mediaMedium = medium?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if mediaMedium == "audio" || mediaType.hasPrefix("audio/") { return true }
        if mediaType.hasPrefix("image/") || mediaType.hasPrefix("video/") || mediaType.hasPrefix("text/") {
            return false
        }
        return hasAudioFileExtension(url)
    }

    private func resolvedAudioURL(_ raw: String?, source: FeedSource) -> String? {
        FeedItem.resolvedMediaURL(from: raw, baseURL: source.url)?.absoluteString
    }

    private func extractAtomAudio(from entry: AtomFeedEntry, source: FeedSource) -> String? {
        guard let links = entry.links else { return nil }
        for link in links {
            guard let attr = link.attributes, let href = attr.href else { continue }
            let isEnclosure = attr.rel?.lowercased() == "enclosure"
            if Self.isAudioCandidate(url: href, type: attr.type, medium: nil) || (isEnclosure && Self.hasAudioFileExtension(href)) {
                return resolvedAudioURL(href, source: source)
            }
        }
        return nil
    }

    private func extractJSONAudio(from item: JSONFeedItem, source: FeedSource) -> AudioEnclosure? {
        guard let attachment = item.attachments?.first(where: {
            guard let url = $0.url else { return false }
            return Self.isAudioCandidate(url: url, type: $0.mimeType, medium: nil)
        }),
              let resolved = resolvedAudioURL(attachment.url, source: source) else {
            return nil
        }
        return AudioEnclosure(url: resolved, duration: attachment.durationInSeconds)
    }

    private func extractDuration(from item: RSSFeedItem) -> TimeInterval? {
        let dur = item.iTunes?.iTunesDuration ?? 0
        return dur > 0 ? dur : nil
    }

    // MARK: - Audio playability validation

    /// Probe the audio enclosures of freshly-parsed items and strip `audioURL`
    /// from any that don't actually serve playable audio, so unplayable
    /// "podcasts" never reach the feed. Bounded, cached, and only touches items
    /// that claim audio — text feeds pay nothing.
    private func validateAudio(in items: [FeedItem]) async -> [FeedItem] {
        // Cap probes per feed so a huge episode list can't stall a fetch; the
        // newest items matter most and appear first.
        let audioIndices = items.indices.filter { items[$0].audioURL != nil }
        guard !audioIndices.isEmpty else { return items }
        let toProbe = Array(audioIndices.prefix(12))

        var playable: [String: Bool] = [:]
        let cap = 6
        await withTaskGroup(of: (String, Bool).self) { group in
            var iterator = toProbe.makeIterator()
            var started = 0
            while started < cap, let idx = iterator.next() {
                guard let audio = items[idx].audioURL else { continue }
                group.addTask { (audio, await self.isPlayableAudio(audio)) }
                started += 1
            }
            while let (audio, ok) = await group.next() {
                playable[audio] = ok
                if let idx = iterator.next(), let next = items[idx].audioURL {
                    group.addTask { (next, await self.isPlayableAudio(next)) }
                }
            }
        }

        guard !playable.isEmpty else { return items }
        var result = items
        for idx in toProbe {
            if let audio = result[idx].audioURL, playable[audio] == false {
                result[idx] = result[idx].withoutAudio()
            }
        }
        return result
    }

    private enum AudioProbe { case playable, notAudio, unknown }

    /// Whether `urlString` should be treated as playable audio. Only a
    /// *definitive* negative — a 2xx with a text/image body, or a gone status
    /// (404/410) — is cached as false and strips the item. Transient failures
    /// (timeouts, 5xx, rate limits) return true (keep) and are NOT cached, so a
    /// network blip can't permanently demote a good podcast.
    private func isPlayableAudio(_ urlString: String) async -> Bool {
        if let cached = audioPlayability[urlString] { return cached }
        guard let url = URL(string: urlString) else {
            audioPlayability[urlString] = false
            savePlayabilityCache()
            return false
        }
        switch await probeAudio(url) {
        case .playable:
            audioPlayability[urlString] = true
            trimPlayabilityCache()
            savePlayabilityCache()
            return true
        case .notAudio:
            audioPlayability[urlString] = false
            trimPlayabilityCache()
            savePlayabilityCache()
            return false
        case .unknown:
            return true   // couldn't confirm — keep it, retry on a later fetch
        }
    }

    private func trimPlayabilityCache() {
        guard audioPlayability.count > 500 else { return }
        // Drop earliest entries to keep cache bounded
        let keysToRemove = audioPlayability.keys.prefix(audioPlayability.count - 300)
        for key in keysToRemove { audioPlayability.removeValue(forKey: key) }
        savePlayabilityCache()
    }

    private func savePlayabilityCache() {
        UserDefaults.standard.set(audioPlayability, forKey: Self.playabilityCacheKey)
    }

    private func probeAudio(_ url: URL) async -> AudioProbe {
        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        head.timeoutInterval = 6
        do {
            let (_, response) = try await session.data(for: head)
            guard let http = response as? HTTPURLResponse else { return .unknown }
            // Some servers reject HEAD — retry with a 1-byte ranged GET.
            if http.statusCode == 405 || http.statusCode == 501 {
                return await probeAudioRanged(url)
            }
            return classify(http)
        } catch {
            return await probeAudioRanged(url)
        }
    }

    private func probeAudioRanged(_ url: URL) async -> AudioProbe {
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        do {
            let (_, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { return .unknown }
            return classify(http)
        } catch {
            return .unknown   // network error — can't determine, don't strip
        }
    }

    /// Classify a probe response. Lenient on content-type (many audio CDNs send
    /// octet-stream / video-mp4); only a 2xx with a text/image body or a gone
    /// status (404/410) is a definitive non-audio. Everything else
    /// (3xx/403/429/5xx) is transient/ambiguous → unknown (keep, don't cache).
    private func classify(_ http: HTTPURLResponse) -> AudioProbe {
        let code = http.statusCode
        if (200...299).contains(code) || code == 206 {
            let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if type.hasPrefix("text/") || type.hasPrefix("image/") { return .notAudio }
            return .playable
        }
        if code == 404 || code == 410 { return .notAudio }
        return .unknown
    }

    // MARK: - Private

    private func extractItems(from feed: Feed, source: FeedSource) -> [FeedItem] {
        // Channel-level image fallback for podcasts (many RSS feeds have
        // artwork at the channel level but not per-episode).
        let feedImage: String? = {
            switch feed {
            case .atom(let a): return a.logo ?? a.icon
            case .rss(let r):  return r.image?.url
            case .json(let j): return j.icon ?? j.favicon
            }
        }()

        let entries: [FeedItem] = {
            switch feed {
            case .atom(let atomFeed):
                return (atomFeed.entries ?? []).compactMap { entry in
                    let rawContent = entry.content?.value ?? entry.summary?.value ?? ""
                    let audio = extractAtomAudio(from: entry, source: source)
                    let img = extractFirstImageFromHTML(rawContent) ?? feedImage
                    return makeItem(
                        guid: entry.id,
                        link: entry.links?.first?.attributes?.href ?? entry.id,
                        title: entry.title,
                        publishedAt: entry.published ?? entry.updated,
                        source: source,
                        rawDescription: entry.summary?.value ?? entry.content?.value,
                        rawContent: entry.content?.value,
                        imageURL: img,
                        audioURL: audio
                    )
                }
            case .rss(let rssFeed):
                return (rssFeed.items ?? []).compactMap { item in
                    let audio = extractAudio(from: item, source: source)
                    let duration = extractDuration(from: item) ?? audio?.duration
                    let img = extractImageURL(from: item) ?? feedImage
                    return makeItem(
                        guid: item.guid?.value,
                        link: item.link,
                        title: item.title,
                        publishedAt: item.pubDate,
                        source: source,
                        rawDescription: item.description,
                        rawContent: item.content?.contentEncoded,
                        imageURL: img,
                        audioURL: audio?.url,
                        duration: duration
                    )
                }
            case .json(let jsonFeed):
                return (jsonFeed.items ?? []).compactMap { jsonItem in
                    let audio = extractJSONAudio(from: jsonItem, source: source)
                    let img = jsonItem.image ?? jsonItem.bannerImage ?? feedImage
                    return makeItem(
                        guid: jsonItem.id,
                        link: jsonItem.url,
                        title: jsonItem.title,
                        publishedAt: jsonItem.datePublished,
                        source: source,
                        rawDescription: jsonItem.summary ?? jsonItem.contentText,
                        rawContent: jsonItem.contentHtml,
                        imageURL: img,
                        audioURL: audio?.url,
                        duration: audio?.duration
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
        imageURL: String?,
        audioURL: String? = nil,
        duration: TimeInterval? = nil
    ) -> FeedItem? {
        let resolvedLink = [link, audioURL]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        // Text items need a clickable URL. Podcast items can use their
        // enclosure URL, because tapping them starts playback instead.
        guard let resolvedLink else { return nil }

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

        // Resolve relative image URLs against the article URL
        let resolvedImageURL = resolveImageURL(imageURL, baseURL: link ?? source.url)

        // Sanitize: truncate long titles, strip HTML, cap source names
        let sanitizedTitle = strippingHTMLTags(title ?? "Untitled")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let truncatedTitle = String(sanitizedTitle.prefix(200))
        let sanitizedSource = String(source.title.prefix(50))

        return FeedItem(
            id: id,
            sourceTitle: sanitizedSource,
            sourceURL: source.url,
            category: source.category,
            title: truncatedTitle.isEmpty ? "Untitled" : truncatedTitle,
            excerpt: excerpt,
            url: resolvedLink,
            imageURL: resolvedImageURL,
            publishedAt: publishedAt ?? Date(),
            audioURL: audioURL,
            duration: duration,
            region: source.region
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

    /// Resolve a possibly-relative image URL against the article's base URL.
    private func resolveImageURL(_ imageURL: String?, baseURL: String?) -> String? {
        guard let raw = imageURL?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        // Reject tracking pixels and spacer GIFs at the source so they never
        // enter the database or pollute the What's New carousel.
        let lower = raw.lowercased()
        if lower.contains("tracking") && lower.contains("pixel") { return nil }
        if lower.contains("spacer") && (lower.hasSuffix(".gif") || lower.hasSuffix(".png")) { return nil }
        if lower.hasSuffix("1x1.gif") || lower.hasSuffix("1x1.png") { return nil }
        // Already absolute — upgrade HTTP to HTTPS so images don't fail
        // under ATS (NSAllowsArbitraryLoadsForMedia only covers AV media).
        if raw.hasPrefix("http://") { return raw.replacingOccurrences(of: "http://", with: "https://") }
        if raw.hasPrefix("https://") { return raw }
        // Data URIs — pass through as-is (CachedAsyncImage handles)
        if raw.hasPrefix("data:") { return raw }
        // Protocol-relative URL
        if raw.hasPrefix("//") { return "https:\(raw)" }
        // Relative URL — resolve against base
        guard let base = baseURL, let baseURL = URL(string: base) else { return nil }
        guard let resolved = URL(string: raw, relativeTo: baseURL) else { return nil }
        return resolved.absoluteString
    }

    /// Extract first <img src> from an HTML string.
    private func extractFirstImageFromHTML(_ html: String) -> String? {
        // Quick pre-check — skip if no img tag present
        guard html.contains("<img") || html.contains("&lt;img") else { return nil }

        let decoded = html
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
        for candidate in [decoded, html] {
            guard let match = Self.imgSrcRegex.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)),
                  let range = Range(match.range(at: 1), in: candidate) else {
                continue
            }
            return String(candidate[range])
        }
        return nil
    }

    /// Extract excerpt from available fields in priority order.
    private func extractExcerpt(description: String?, content: String?) -> String {
        let raw = description ?? content ?? ""
        let stripped = strippingHTMLTags(raw)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty { return "No description" }
        // Find last full word within 200 char limit
        let capped = String(stripped.prefix(200))
        if let lastSpace = capped.lastIndex(of: " "), lastSpace > capped.startIndex {
            return String(capped[..<lastSpace]).trimmingCharacters(in: .whitespaces)
        }
        return capped
    }

    private static let htmlTagRegex = try! NSRegularExpression(pattern: "<[^>]+>")
    private static let imgSrcRegex = try! NSRegularExpression(pattern: #"<img[^>]+src=["']([^"']+)["']"#, options: .caseInsensitive)

    /// Strip HTML tags using regex — avoids WebKit NSAttributedString overhead.
    private func strippingHTMLTags(_ html: String) -> String {
        // Use the precompiled regex instead of `.regularExpression`, which
        // recompiles the pattern on every call (this runs twice per feed item).
        let range = NSRange(html.startIndex..., in: html)
        let stripped = Self.htmlTagRegex.stringByReplacingMatches(in: html, range: range, withTemplate: "")
        // Decode entities with `&amp;` LAST: decoding it first would double-
        // unescape sequences like `&amp;lt;` into `<` instead of literal `&lt;`.
        return stripped
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
