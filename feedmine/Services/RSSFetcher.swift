import Foundation
import FeedKit

actor RSSFetcher {
    private let session: URLSession

    init() {
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
        while !remaining.isEmpty && !Task.isCancelled {
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

    // MARK: - Audio extraction

    private func extractAudio(from item: RSSFeedItem, source: FeedSource) -> String? {
        // Standard enclosure
        if let enc = item.enclosure,
           let type = enc.attributes?.type?.lowercased(),
           let url = enc.attributes?.url,
           type.hasPrefix("audio/") {
            return url
        }
        // Media namespace
        if let contents = item.media?.mediaContents {
            for m in contents {
                if let t = m.attributes?.type?.lowercased(),
                   let u = m.attributes?.url,
                   t.hasPrefix("audio/") {
                    return u
                }
            }
        }
        // Fallback: any enclosure URL (audio player validates on playback)
        if let url = item.enclosure?.attributes?.url, !url.isEmpty {
            return url
        }
        return nil
    }

    private func extractAtomAudio(from entry: AtomFeedEntry) -> String? {
        guard let links = entry.links else { return nil }
        for link in links {
            if let type = link.attributes?.type?.lowercased(),
               let href = link.attributes?.href,
               type.hasPrefix("audio/") || type == "audio/mpeg" || type == "audio/mp3" {
                return href
            }
        }
        return nil
    }

    private func extractDuration(from item: RSSFeedItem) -> TimeInterval? {
        let dur = item.iTunes?.iTunesDuration ?? 0
        return dur > 0 ? dur : nil
    }

    // MARK: - Private

    private func extractItems(from feed: Feed, source: FeedSource) -> [FeedItem] {
        let entries: [FeedItem] = {
            switch feed {
            case .atom(let atomFeed):
                return (atomFeed.entries ?? []).compactMap { entry in
                    let rawContent = entry.content?.value ?? entry.summary?.value ?? ""
                    let audio = extractAtomAudio(from: entry)
                    return makeItem(
                        guid: entry.id,
                        link: entry.links?.first?.attributes?.href ?? entry.id,
                        title: entry.title,
                        publishedAt: entry.published ?? entry.updated,
                        source: source,
                        rawDescription: entry.summary?.value ?? entry.content?.value,
                        rawContent: entry.content?.value,
                        imageURL: extractFirstImageFromHTML(rawContent),
                        audioURL: audio
                    )
                }
            case .rss(let rssFeed):
                return (rssFeed.items ?? []).compactMap { item in
                    let audio = extractAudio(from: item, source: source)
                    let duration = extractDuration(from: item)
                    return makeItem(
                        guid: item.guid?.value,
                        link: item.link,
                        title: item.title,
                        publishedAt: item.pubDate,
                        source: source,
                        rawDescription: item.description,
                        rawContent: item.content?.contentEncoded,
                        imageURL: extractImageURL(from: item),
                        audioURL: audio,
                        duration: duration
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
        imageURL: String?,
        audioURL: String? = nil,
        duration: TimeInterval? = nil
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
            imageURL: imageURL,
            publishedAt: publishedAt ?? Date(),
            audioURL: audioURL,
            duration: duration
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
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}
