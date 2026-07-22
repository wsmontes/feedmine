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
            Log.network.error("Invalid URL for \(source.title): \(source.url)")
            return FeedFetchResult(source: source, items: [], status: .failed)
        }

        do {
            let (data, response) = try await session.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                Log.network.warning("Bad status for \(source.title)")
                return FeedFetchResult(source: source, items: [], status: .failed)
            }

            let parser = FeedParser(data: data)
            let result = parser.parse()

            switch result {
            case .success(let feed):
                let items = extractItems(from: feed, source: source)
                if items.isEmpty {
                    Log.network.info("Empty feed: \(source.title)")
                    return FeedFetchResult(source: source, items: [], status: .empty)
                }
                let validated = await validateAudio(in: items)
                return FeedFetchResult(source: source, items: validated, status: .success)
            case .failure(let error):
                Log.network.error("Parse failure for \(source.title): \(error)")
                return FeedFetchResult(source: source, items: [], status: .failed)
            }
        } catch is CancellationError {
            return FeedFetchResult(source: source, items: [], status: .failed)
        } catch let error as URLError where error.code == .cancelled {
            return FeedFetchResult(source: source, items: [], status: .failed)
        } catch {
            Log.network.error("Network error for \(source.title): \(error)")
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

    /// Cold-start fetch that stops waiting as soon as there is enough content
    /// for the first page and its runway. Slow feeds are cancelled for this
    /// pass and remain eligible for the progressive background fetch.
    func fetchStarter(
        _ sources: [FeedSource],
        maxConcurrent: Int = 15,
        minimumSuccessfulSources: Int = 4,
        minimumItemCount: Int = 40,
        deadline: Duration = .milliseconds(2_250),
        onProgress: (@MainActor @Sendable (FeedFetchResult) -> Void)? = nil
    ) async -> FeedFetchBatch {
        enum Event: Sendable {
            case result(FeedFetchResult)
            case deadline
            case cancelled
        }

        var allItems: [FeedItem] = []
        var fetchedSourceCount = 0
        var failedSourceCount = 0
        var emptySourceCount = 0
        var sourceStatuses: [String: FeedFetchStatus] = [:]
        let cap = max(1, maxConcurrent)

        await withTaskGroup(of: Event.self) { group in
            var iterator = sources.makeIterator()
            var activeFetches = 0

            while activeFetches < cap, let source = iterator.next() {
                group.addTask { .result(await self.fetch(source)) }
                activeFetches += 1
            }
            group.addTask {
                do {
                    try await Task.sleep(for: deadline)
                    return .deadline
                } catch {
                    return .cancelled
                }
            }

            eventLoop: while let event = await group.next() {
                switch event {
                case .cancelled:
                    continue
                case .deadline:
                    group.cancelAll()
                    break eventLoop
                case .result(let result):
                    activeFetches -= 1
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
                    await onProgress?(result)

                    let runwayReady = fetchedSourceCount >= minimumSuccessfulSources
                        && allItems.count >= minimumItemCount
                    if runwayReady {
                        group.cancelAll()
                        break eventLoop
                    }

                    if let source = iterator.next() {
                        group.addTask { .result(await self.fetch(source)) }
                        activeFetches += 1
                    } else if activeFetches == 0 {
                        group.cancelAll()
                        break eventLoop
                    }
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

    func extractItems(fromFeedData data: Data, source: FeedSource) -> [FeedItem] {
        guard case .success(let feed) = FeedParser(data: data).parse() else { return [] }
        return extractItems(from: feed, source: source)
    }

    private func extractItems(from feed: Feed, source: FeedSource) -> [FeedItem] {
        // Channel-level image fallback for podcasts (many RSS feeds have
        // artwork at the channel level but not per-episode).
        let feedImage: String? = {
            // Aggregator channel artwork identifies the transport, not the
            // article. Reusing the Google News logo on every card makes many
            // publishers look like one repeated feed.
            if URL(string: source.url)?.host?.lowercased() == "news.google.com" {
                return nil
            }
            let image: String? = {
                switch feed {
                case .atom(let a): return a.logo ?? a.icon
                case .rss(let r):  return r.iTunes?.iTunesImage?.attributes?.href ?? r.image?.url
                case .json(let j): return j.icon ?? j.favicon
                }
            }()
            // Skip obvious favicons and tiny site logos — they block article
            // image resolution. A missing image triggers ArticleImageResolver
            // which finds the actual article artwork.
            if let image, Self.isLikelyFaviconOrLogo(image) { return nil }
            return image
        }()

        let entries: [FeedItem] = {
            switch feed {
            case .atom(let atomFeed):
                return (atomFeed.entries ?? []).compactMap { entry in
                    let rawContent = entry.content?.value ?? entry.summary?.value ?? ""
                    let audio = extractAtomAudio(from: entry, source: source)
                    let entryLink = entry.links?.first(where: { link in
                        let rel = link.attributes?.rel?.lowercased()
                        let type = link.attributes?.type?.lowercased() ?? ""
                        return (rel == nil || rel == "alternate")
                            && !type.contains("atom")
                            && !type.contains("rss")
                    })?.attributes?.href
                        ?? entry.links?.first(where: {
                            $0.attributes?.rel?.lowercased() != "enclosure"
                        })?.attributes?.href
                    let img = bestMediaImageURL(from: entry.media)
                        ?? extractFirstImageFromHTML(rawContent)
                        ?? feedImage
                    return makeItem(
                        guid: entry.id,
                        link: entryLink ?? entry.id,
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
                        itemSourceTitle: item.source?.value,
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
                    // Check attachments for image types (e.g., "image/jpeg")
                    let attachmentImage = jsonItem.attachments?.first { attachment in
                        Self.isSupportedRasterMIMEType(attachment.mimeType)
                    }?.url
                    let img = jsonItem.image ?? jsonItem.bannerImage ?? attachmentImage ?? feedImage
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
        itemSourceTitle: String? = nil,
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

        // A visible card without a real headline is worse than skipping an
        // incomplete feed item. Some malformed feeds encode CDATA as text;
        // sanitizedHTMLText unwraps that form before this check.
        let sanitizedTitle = Self.sanitizedHTMLText(title ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitizedTitle.isEmpty else { return nil }
        let truncatedTitle = String(sanitizedTitle.prefix(200))

        let id = FeedItem.generateID(
            sourceURL: source.url,
            guid: guid,
            link: link,
            title: sanitizedTitle,
            publishedAt: publishedAt
        )

        let excerpt = extractExcerpt(
            description: rawDescription,
            content: rawContent
        )

        // Resolve relative image URLs against the article URL
        let resolvedImageURL = resolveImageURL(imageURL, baseURL: link ?? source.url)

        // Sanitize: truncate long titles, strip HTML, cap source names
        let isGoogleNews = URL(string: source.url)?.host?.lowercased() == "news.google.com"
        let preferredSourceTitle: String? = if isGoogleNews {
            if let publisher = itemSourceTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
               !publisher.isEmpty {
                publisher
            } else {
                "Google News"
            }
        } else {
            nil
        }
        let sanitizedSource = String(
            Self.sanitizedHTMLText(
                preferredSourceTitle?.isEmpty == false ? preferredSourceTitle! : source.title
            ).prefix(80)
        )

        return FeedItem(
            id: id,
            sourceTitle: sanitizedSource,
            sourceURL: source.url,
            category: source.category,
            title: truncatedTitle,
            excerpt: excerpt,
            url: resolvedLink,
            imageURL: resolvedImageURL,
            publishedAt: publishedAt ?? Date(),
            audioURL: audioURL,
            duration: duration,
            region: source.region,
            // The source language is catalogue metadata, not an item-level
            // declaration. FeedStore combines it with content detection.
            language: nil
        )
    }

    /// Pick the best image URL from a Media RSS namespace — largest width
    /// wins; "image/*" type preferred over "thumbnail/*" when sizes match.
    private func bestMediaImageURL(from media: MediaNamespace?) -> String? {
        guard let media else { return nil }

        // media:content may represent audio, video, documents, or browser
        // players. Only direct raster images are valid card artwork.
        let imageContents = (media.mediaContents ?? []).filter { content in
            guard let attributes = content.attributes else { return false }
            if attributes.medium?.lowercased() == "image" {
                return !Self.isUnsupportedImageURL(attributes.url)
            }
            if Self.isSupportedRasterMIMEType(attributes.type) {
                return !Self.isUnsupportedImageURL(attributes.url)
            }
            guard attributes.medium == nil, attributes.type == nil else { return false }
            return Self.hasRasterImageExtension(attributes.url)
        }
        if !imageContents.isEmpty {
            let best = imageContents.max { a, b in
                let aW = a.attributes?.width.flatMap(Int.init) ?? 0
                let bW = b.attributes?.width.flatMap(Int.init) ?? 0
                return aW < bW
            }
            if let url = best?.attributes?.url { return url }
        }

        // 2. media:thumbnails — pick largest by width
        if let thumbs = media.mediaThumbnails, !thumbs.isEmpty {
            let best = thumbs.max { a, b in
                let aW = a.attributes?.width.flatMap(Int.init) ?? 0
                let bW = b.attributes?.width.flatMap(Int.init) ?? 0
                return aW < bW
            }
            if let url = best?.attributes?.url { return url }
        }

        return nil
    }

    /// Extract image URL from RSS item, picking the best available image.
    private func extractImageURL(from item: RSSFeedItem) -> String? {
        // 1. media:content / media:thumbnail (Media RSS namespace)
        if let url = bestMediaImageURL(from: item.media) { return url }

        // 2. Episode artwork used by most podcast publishers.
        if let url = item.iTunes?.iTunesImage?.attributes?.href { return url }

        // 3. enclosure with a supported raster image type
        if let enclosure = item.enclosure,
           let type = enclosure.attributes?.type,
           Self.isSupportedRasterMIMEType(type),
           let url = enclosure.attributes?.url {
            return url
        }

        // 4. First <img> in content
        if let content = item.content?.contentEncoded ?? item.description {
            return extractFirstImageFromHTML(content)
        }

        return nil
    }

    /// Resolve a possibly-relative image URL against the article's base URL.
    private func resolveImageURL(_ imageURL: String?, baseURL: String?) -> String? {
        guard let original = imageURL?.trimmingCharacters(in: .whitespacesAndNewlines), !original.isEmpty else { return nil }
        let raw = original
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#038;", with: "&")
            .replacingOccurrences(of: "&#38;", with: "&")
        // Reject tracking pixels and spacer GIFs at the source so they never
        // enter the database or pollute the What's New carousel.
        let lower = raw.lowercased()
        if lower.contains("tracking") && lower.contains("pixel") { return nil }
        if lower.contains("/tracker/") || lower.contains("count.gif") || lower.contains("track-rss-story") { return nil }
        if lower.contains("spacer") && (lower.hasSuffix(".gif") || lower.hasSuffix(".png")) { return nil }
        if lower.hasSuffix("1x1.gif") || lower.hasSuffix("1x1.png") { return nil }
        if Self.isUnsupportedImageURL(raw) { return nil }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            let tail = lower.dropFirst(8)
            let nestedSchemes = ["http://", "https://"].compactMap { tail.range(of: $0) }
            if let firstNested = nestedSchemes.min(by: { $0.lowerBound < $1.lowerBound }) {
                let prefix = tail[..<firstNested.lowerBound]
                // URL proxies commonly use /https://... or ?url=https://...
                // A bare image.jpghttps://... sequence is malformed.
                if prefix.last != "/" && prefix.last != "=" { return nil }
            }
        }
        // Already absolute — upgrade HTTP to HTTPS so images don't fail
        // under ATS (NSAllowsArbitraryLoadsForMedia only covers AV media).
        if raw.hasPrefix("http://") {
            let upgraded = "https://" + raw.dropFirst("http://".count)
            return Self.validHTTPImageURL(String(upgraded))
        }
        if raw.hasPrefix("https://") { return Self.validHTTPImageURL(raw) }
        // Data URIs are accepted only for raster formats supported by ImageIO.
        if lower.hasPrefix("data:image/") { return raw }
        if lower.hasPrefix("data:") { return nil }
        // Protocol-relative URL
        if raw.hasPrefix("//") { return Self.validHTTPImageURL("https:\(raw)") }
        // Relative URL — resolve against base
        guard let base = baseURL, let baseURL = URL(string: base) else { return nil }
        guard let resolved = URL(string: raw, relativeTo: baseURL) else { return nil }
        return Self.validHTTPImageURL(resolved.absoluteString)
    }

    private static func isSupportedRasterMIMEType(_ value: String?) -> Bool {
        guard let type = value?.lowercased(), type.hasPrefix("image/") else { return false }
        return !type.contains("svg")
    }

    private static func hasRasterImageExtension(_ value: String?) -> Bool {
        guard let value, let components = URLComponents(string: value) else { return false }
        let extensions = Set(["jpg", "jpeg", "jfif", "png", "gif", "webp", "avif", "heic", "heif", "bmp", "tif", "tiff"])
        return extensions.contains((components.path as NSString).pathExtension.lowercased())
    }

    private static func isUnsupportedImageURL(_ value: String?) -> Bool {
        guard let value else { return true }
        let lower = value.lowercased()
        if lower.hasPrefix("data:image/svg") { return true }
        if lower.contains("youtube.com/embed/") { return true }
        guard let components = URLComponents(string: value) else { return true }
        let ext = (components.path as NSString).pathExtension.lowercased()
        return ["svg", "mp3", "m4a", "aac", "wav", "ogg", "opus", "mp4", "mov", "webm"].contains(ext)
    }

    private static func validHTTPImageURL(_ value: String) -> String? {
        guard let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil,
              !isUnsupportedImageURL(value) else { return nil }
        return url.absoluteString
    }

    /// Extract the first plausible content image from an HTML fragment. Feed
    /// bodies often begin with a favicon, avatar, sharing button, or tracking
    /// image; when an img has srcset, use its largest declared variant.
    private func extractFirstImageFromHTML(_ html: String) -> String? {
        // Quick pre-check — skip if no img tag present
        guard html.contains("<img") || html.contains("&lt;img") else { return nil }

        let decoded = html
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
        for candidate in [decoded, html] {
            let fullRange = NSRange(candidate.startIndex..., in: candidate)
            for match in Self.imgTagRegex.matches(in: candidate, range: fullRange) {
                guard let tagRange = Range(match.range, in: candidate) else { continue }
                let tag = String(candidate[tagRange])
                let attributes = Self.imageAttributeRegex.matches(
                    in: tag,
                    range: NSRange(tag.startIndex..., in: tag)
                ).compactMap { attribute -> (name: String, value: String)? in
                    guard let nameRange = Range(attribute.range(at: 1), in: tag),
                          let valueRange = Range(attribute.range(at: 2), in: tag) else { return nil }
                    return (String(tag[nameRange]).lowercased(), String(tag[valueRange]))
                }

                let valueForFirstAttribute: ([String]) -> String? = { names in
                    names.lazy.compactMap { name in
                        attributes.first(where: { $0.name == name })?.value
                    }.first
                }
                let srcset = valueForFirstAttribute(["data-lazy-srcset", "data-srcset", "srcset"])
                let src = valueForFirstAttribute([
                    "data-lazy-src", "data-original", "data-orig-file", "data-src", "src",
                ])
                let imageURL = Self.preferredSrcsetCandidate(srcset) ?? src
                guard let imageURL, !Self.isLikelyDecorativeImageURL(imageURL) else { continue }
                return Self.upgradedKnownThumbnailURL(imageURL)
            }
        }
        return nil
    }

    private static func preferredSrcsetCandidate(_ srcset: String?) -> String? {
        guard let srcset else { return nil }
        let candidates = srcset.split(separator: ",")
            .compactMap { entry -> (url: String, value: Double, unit: Character)? in
                let parts = entry.split(whereSeparator: \Character.isWhitespace)
                guard let first = parts.first else { return nil }
                let descriptor = parts.dropFirst().last.map(String.init) ?? ""
                guard let unit = descriptor.last,
                      unit == "w" || unit == "x",
                      let number = Double(descriptor.dropLast()) else { return nil }
                return (String(first), number, unit)
            }
        let widthCandidates = candidates.filter { $0.unit == "w" }.sorted { $0.value < $1.value }
        if let sufficient = widthCandidates.first(where: { $0.value >= 960 }) { return sufficient.url }
        if let largest = widthCandidates.last { return largest.url }
        let densityCandidates = candidates.filter { $0.unit == "x" }.sorted { $0.value < $1.value }
        if let retina = densityCandidates.first(where: { $0.value >= 2 }) { return retina.url }
        return densityCandidates.last?.url
    }

    private static func isLikelyDecorativeImageURL(_ value: String) -> Bool {
        let lower = value.lowercased()
        let markers = [
            "favicon", "gravatar.com/avatar", "/emoji/", "s.w.org/images/core/emoji",
            "addtoany.com/buttons", "share_save", "icon_facebook", "tracking",
            "spacer", "pixel.gif", "count.gif",
        ]
        if markers.contains(where: lower.contains) { return true }
        return lower.range(of: #"(?:^|[-_/])(16|18|24|32)x(?:11|12|16|18|24|29|30|31|32)(?:[-_.?/]|$)"#,
                           options: .regularExpression) != nil
    }

    /// Rejects channel-level images that are obviously favicons or tiny logos.
    /// Using these as article images blocks ArticleImageResolver from finding
    /// the actual article artwork.
    private static func isLikelyFaviconOrLogo(_ url: String) -> Bool {
        let lower = url.lowercased()
        if lower.contains("favicon") || lower.contains("cropped") { return true }
        // Match tiny favicon dimensions (-32x32, -150x150) but not large
        // artwork (-1400x1400, -3000x3000). Threshold: ≤150px on either side.
        if let range = lower.range(of: #"[-.](\d{2,4})x(\d{2,4})"#, options: .regularExpression) {
            let match = String(lower[range]).dropFirst()  // strip leading - or .
            let parts = match.split(separator: "x").compactMap { Int($0) }
            if let w = parts.first, let h = parts.last, w <= 150 && h <= 150 {
                return true
            }
        }
        // Site logos used as channel images (not article artwork)
        if lower.contains("/logo") || lower.contains("-logo") || lower.contains("_logo") {
            return true
        }
        return false
    }

    private static func upgradedKnownThumbnailURL(_ value: String) -> String {
        guard let url = URL(string: value),
              let host = url.host?.lowercased(),
              host.contains("blogger.googleusercontent.com") || host.hasSuffix(".blogspot.com") else {
            return value
        }
        return value.replacingOccurrences(
            of: #"/s(?:72|144|320)(?:-w\d+-h\d+)?(?:-[a-z]+)?/"#,
            with: "/s1200/",
            options: .regularExpression
        )
    }

    /// Extract excerpt from available fields in priority order.
    private func extractExcerpt(description: String?, content: String?) -> String {
        let raw = description ?? content ?? ""
        let stripped = Self.sanitizedHTMLText(raw)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty { return "No description" }
        // Find last full word within 200 char limit
        let capped = String(stripped.prefix(200))
        if let lastSpace = capped.lastIndex(of: " "), lastSpace > capped.startIndex {
            return String(capped[..<lastSpace]).trimmingCharacters(in: .whitespaces)
        }
        return capped
    }

    private static let imgTagRegex = try! NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: .caseInsensitive)
    private static let imageAttributeRegex = try! NSRegularExpression(
        pattern: #"\s(data-lazy-srcset|data-srcset|srcset|data-lazy-src|data-original|data-orig-file|data-src|src)\s*=\s*["']([^"']+)["']"#,
        options: .caseInsensitive
    )

    /// Convert feed HTML/XML fragments into display text without pulling in
    /// NSAttributedString's HTML parser for every item.
    nonisolated static func sanitizedHTMLText(_ html: String) -> String {
        FeedTextSanitizer.sanitizedHTMLText(html)
    }
}

enum FeedTextSanitizer {
    private static let htmlTagRegex = try! NSRegularExpression(pattern: "<[^>]+>")
    private static let htmlEntityRegex = try! NSRegularExpression(
        pattern: #"&#(?:x[0-9A-Fa-f]+|[0-9]+);?|&[A-Za-z][A-Za-z0-9]{1,31};"#
    )

    /// Convert feed HTML/XML fragments into display text without pulling in
    /// NSAttributedString's HTML parser for every item.
    static func sanitizedHTMLText(_ html: String) -> String {
        let decodedMarkup = unwrapCDATA(in: decodeHTMLEntities(in: html))
        let range = NSRange(decodedMarkup.startIndex..., in: decodedMarkup)
        let stripped = htmlTagRegex.stringByReplacingMatches(in: decodedMarkup, range: range, withTemplate: " ")
        return decodeHTMLEntities(in: stripped)
    }

    /// A few publishers write an escaped CDATA wrapper inside an XML element
    /// (`&lt;![CDATA[headline]]&gt;`). Once entities are decoded it looks like a
    /// tag, so the normal HTML stripper would erase the headline entirely.
    private static func unwrapCDATA(in input: String) -> String {
        var text = input
        while let start = text.range(of: "<![CDATA["),
              let end = text.range(of: "]]>", range: start.upperBound..<text.endIndex) {
            text.replaceSubrange(start.lowerBound..<end.upperBound, with: text[start.upperBound..<end.lowerBound])
        }
        return text
    }

    private static func decodeHTMLEntities(in text: String) -> String {
        guard text.contains("&") else { return text }

        let matches = htmlEntityRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }

        var decoded = ""
        decoded.reserveCapacity(text.count)
        var cursor = text.startIndex

        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            decoded.append(contentsOf: text[cursor..<range.lowerBound])
            let token = String(text[range])
            decoded.append(decodedHTMLEntity(token) ?? token)
            cursor = range.upperBound
        }

        decoded.append(contentsOf: text[cursor...])
        return decoded
    }

    private static func decodedHTMLEntity(_ token: String) -> String? {
        guard token.hasPrefix("&") else { return nil }
        var body = String(token.dropFirst())
        if body.hasSuffix(";") {
            body.removeLast()
        }

        if body.hasPrefix("#x") || body.hasPrefix("#X") {
            let hex = String(body.dropFirst(2))
            guard let value = UInt32(hex, radix: 16), let scalar = UnicodeScalar(value) else { return nil }
            return scalar.value == 160 ? " " : String(scalar)
        }

        if body.hasPrefix("#") {
            let decimal = String(body.dropFirst())
            guard let value = UInt32(decimal, radix: 10), let scalar = UnicodeScalar(value) else { return nil }
            return scalar.value == 160 ? " " : String(scalar)
        }

        return namedHTMLEntities[body.lowercased()]
    }

    private static let namedHTMLEntities: [String: String] = [
        "amp": "&",
        "apos": "'",
        "bdquo": "\"",
        "bull": "*",
        "copy": "(c)",
        "euro": "EUR",
        "gt": ">",
        "hellip": "...",
        "laquo": "<<",
        "ldquo": "\"",
        "lsquo": "'",
        "lt": "<",
        "mdash": "-",
        "middot": "*",
        "nbsp": " ",
        "ndash": "-",
        "pound": "GBP",
        "quot": "\"",
        "raquo": ">>",
        "rdquo": "\"",
        "reg": "(r)",
        "rsquo": "'",
        "sbquo": "'",
        "trade": "TM",
    ]
}
