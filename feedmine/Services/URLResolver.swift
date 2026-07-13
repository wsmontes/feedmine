import Foundation

// MARK: - Resolve Result

struct ResolvedFeed: Sendable {
    let feedURL: String
    let title: String?
    let sourceURL: String      // Original URL that was resolved
    let mediaKind: MediaKind
}

enum ResolveError: Sendable {
    case noFeedFound
    case unreachable
    case timeout
    case invalidURL
}

struct ResolveResult: Sendable {
    let source: ClassifiedURL
    let feeds: [ResolvedFeed]
    let error: ResolveError?

    static func success(_ source: ClassifiedURL, feeds: [ResolvedFeed]) -> ResolveResult {
        ResolveResult(source: source, feeds: feeds, error: nil)
    }
    static func failure(_ source: ClassifiedURL, _ error: ResolveError) -> ResolveResult {
        ResolveResult(source: source, feeds: [], error: error)
    }
}

// MARK: - URL Resolver

/// Resolves classified URLs into actual feed URLs.
/// Handles: websites (feed discovery), YouTube (channel/video/playlist),
/// GitHub (releases/commits), podcasts (Apple lookup), direct feeds, OPMLs.
actor URLResolver {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15"
        ]
        self.session = URLSession(configuration: config)
    }

    /// Resolve a batch of classified URLs into feed URLs.
    /// Runs up to 5 concurrent resolutions.
    func resolveAll(_ classified: [ClassifiedURL]) async -> [ResolveResult] {
        await withTaskGroup(of: ResolveResult.self, returning: [ResolveResult].self) { group in
            var results: [ResolveResult] = []
            var started = 0
            let maxConcurrent = 5
            var iterator = classified.makeIterator()

            while started < maxConcurrent, let item = iterator.next() {
                group.addTask { await self.resolve(item) }
                started += 1
            }
            while let result = await group.next() {
                results.append(result)
                if let item = iterator.next() {
                    group.addTask { await self.resolve(item) }
                }
            }
            return results
        }
    }

    /// Resolve a single classified URL.
    func resolve(_ classified: ClassifiedURL) async -> ResolveResult {
        switch classified.kind {
        case .feed:
            return .success(classified, feeds: [
                ResolvedFeed(feedURL: classified.url.absoluteString, title: nil,
                            sourceURL: classified.raw, mediaKind: .text)
            ])
        case .website:
            return await discoverFeeds(classified)
        case .youtube:
            return await resolveYouTube(classified)
        case .github:
            return await resolveGitHub(classified)
        case .podcast:
            return await resolvePodcast(classified)
        case .opml:
            // OPMLs are handled separately by ImportPipeline
            return .success(classified, feeds: [])
        case .unknown:
            // Try website discovery as fallback
            return await discoverFeeds(classified)
        }
    }

    // MARK: - Feed Discovery (Website → Feed URL)

    private func discoverFeeds(_ classified: ClassifiedURL) async -> ResolveResult {
        let url = classified.url

        // Strategy 1: Check <link rel="alternate"> in HTML
        if let htmlFeeds = await parseHTMLForFeeds(url), !htmlFeeds.isEmpty {
            return .success(classified, feeds: htmlFeeds)
        }

        // Strategy 2: Try common feed paths
        let root = "\(url.scheme ?? "https")://\(url.host ?? "")"
        let commonPaths = ["/feed", "/rss", "/atom.xml", "/feed.xml", "/rss.xml",
                          "/index.xml", "/feed/", "/feeds/posts/default", "/?feed=rss2"]
        for path in commonPaths {
            let candidate = root + path
            if await probeFeedURL(candidate) {
                return .success(classified, feeds: [
                    ResolvedFeed(feedURL: candidate, title: nil, sourceURL: classified.raw, mediaKind: .text)
                ])
            }
        }

        return .failure(classified, .noFeedFound)
    }

    /// Parse HTML page for <link rel="alternate" type="application/rss+xml">
    private func parseHTMLForFeeds(_ url: URL) async -> [ResolvedFeed]? {
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { return nil }

        guard let html = String(data: data.prefix(50000), encoding: .utf8) else { return nil }

        var feeds: [ResolvedFeed] = []
        let pattern = #"<link[^>]+rel\s*=\s*["']alternate["'][^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))

        for match in matches {
            guard let range = Range(match.range, in: html) else { continue }
            let tag = String(html[range])

            // Check type is RSS/Atom
            let types = ["application/rss+xml", "application/atom+xml", "application/json", "application/feed+json"]
            guard types.contains(where: { tag.lowercased().contains($0) }) else { continue }

            // Extract href
            let hrefPattern = #"href\s*=\s*["']([^"']+)["']"#
            guard let hrefRegex = try? NSRegularExpression(pattern: hrefPattern),
                  let hrefMatch = hrefRegex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
                  let hrefRange = Range(hrefMatch.range(at: 1), in: tag) else { continue }
            var href = String(tag[hrefRange])

            // Resolve relative URLs
            if href.hasPrefix("/") {
                href = "\(url.scheme ?? "https")://\(url.host ?? "")\(href)"
            } else if !href.hasPrefix("http") {
                href = url.deletingLastPathComponent().absoluteString + href
            }

            // Extract title
            let titlePattern = #"title\s*=\s*["']([^"']+)["']"#
            var title: String?
            if let titleRegex = try? NSRegularExpression(pattern: titlePattern),
               let titleMatch = titleRegex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
               let titleRange = Range(titleMatch.range(at: 1), in: tag) {
                title = String(tag[titleRange])
            }

            feeds.append(ResolvedFeed(feedURL: href, title: title, sourceURL: url.absoluteString, mediaKind: .text))
        }

        return feeds.isEmpty ? nil : feeds
    }

    // MARK: - YouTube Resolver

    private func resolveYouTube(_ classified: ClassifiedURL) async -> ResolveResult {
        let url = classified.url
        let path = url.path.lowercased()
        let components = url.pathComponents

        // youtube.com/feeds/videos.xml?channel_id=X — already a feed
        if path.contains("/feeds/") {
            return .success(classified, feeds: [
                ResolvedFeed(feedURL: url.absoluteString, title: nil, sourceURL: classified.raw, mediaKind: .video)
            ])
        }

        // youtube.com/channel/UCxxxx
        if components.count >= 3, components[1].lowercased() == "channel" {
            let channelID = components[2]
            let feedURL = "https://www.youtube.com/feeds/videos.xml?channel_id=\(channelID)"
            return .success(classified, feeds: [
                ResolvedFeed(feedURL: feedURL, title: nil, sourceURL: classified.raw, mediaKind: .video)
            ])
        }

        // youtube.com/playlist?list=PLxxxx
        if let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let playlistID = queryItems.first(where: { $0.name == "list" })?.value {
            let feedURL = "https://www.youtube.com/feeds/videos.xml?playlist_id=\(playlistID)"
            return .success(classified, feeds: [
                ResolvedFeed(feedURL: feedURL, title: nil, sourceURL: classified.raw, mediaKind: .video)
            ])
        }

        // youtube.com/@handle or youtube.com/c/name or youtube.com/user/name
        // youtube.com/watch?v=xxx (resolve channel from video page)
        // All require fetching the page to extract channel ID
        if let channelID = await extractYouTubeChannelID(url) {
            let feedURL = "https://www.youtube.com/feeds/videos.xml?channel_id=\(channelID)"
            return .success(classified, feeds: [
                ResolvedFeed(feedURL: feedURL, title: nil, sourceURL: classified.raw, mediaKind: .video)
            ])
        }

        return .failure(classified, .noFeedFound)
    }

    /// Fetch a YouTube page and extract the channel ID from meta tags or page data.
    private func extractYouTubeChannelID(_ url: URL) async -> String? {
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let html = String(data: data.prefix(100000), encoding: .utf8) else { return nil }

        // Try: <meta itemprop="channelId" content="UCxxxx">
        let metaPattern = #"<meta[^>]+itemprop\s*=\s*["']channelId["'][^>]+content\s*=\s*["']([^"']+)["']"#
        if let regex = try? NSRegularExpression(pattern: metaPattern),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            return String(html[range])
        }

        // Try: "channelId":"UCxxxx"
        let jsonPattern = #""channelId"\s*:\s*"(UC[^"]+)""#
        if let regex = try? NSRegularExpression(pattern: jsonPattern),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            return String(html[range])
        }

        // Try: /channel/UCxxxx in canonical or og:url
        let canonicalPattern = #"/channel/(UC[a-zA-Z0-9_-]+)"#
        if let regex = try? NSRegularExpression(pattern: canonicalPattern),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            return String(html[range])
        }

        return nil
    }

    // MARK: - GitHub Resolver

    private func resolveGitHub(_ classified: ClassifiedURL) async -> ResolveResult {
        let components = classified.url.pathComponents
        // github.com/user/repo → releases.atom
        // github.com/user → user.atom
        guard components.count >= 2 else { return .failure(classified, .invalidURL) }

        let user = components[1]
        if components.count >= 3 {
            let repo = components[2]
            // Repo: offer releases feed
            let feedURL = "https://github.com/\(user)/\(repo)/releases.atom"
            return .success(classified, feeds: [
                ResolvedFeed(feedURL: feedURL, title: "\(repo) releases",
                            sourceURL: classified.raw, mediaKind: .text)
            ])
        } else {
            // User profile: activity feed
            let feedURL = "https://github.com/\(user).atom"
            return .success(classified, feeds: [
                ResolvedFeed(feedURL: feedURL, title: "\(user) activity",
                            sourceURL: classified.raw, mediaKind: .text)
            ])
        }
    }

    // MARK: - Podcast Resolver

    private func resolvePodcast(_ classified: ClassifiedURL) async -> ResolveResult {
        let host = classified.url.host?.lowercased() ?? ""

        // Apple Podcasts: use iTunes Lookup API
        if host.contains("podcasts.apple.com") || host.contains("itunes.apple.com") {
            if let feedURL = await resolveApplePodcast(classified.url) {
                return .success(classified, feeds: [
                    ResolvedFeed(feedURL: feedURL, title: nil, sourceURL: classified.raw, mediaKind: .audio)
                ])
            }
        }

        // Anchor.fm → RSS pattern
        if host.contains("anchor.fm") {
            let path = classified.url.path
            let feedURL = "https://anchor.fm\(path)/rss"
            return .success(classified, feeds: [
                ResolvedFeed(feedURL: feedURL, title: nil, sourceURL: classified.raw, mediaKind: .audio)
            ])
        }

        // Direct podcast feed hosts (buzzsprout, simplecast, etc.) — likely already a feed
        let directFeedHosts = ["feeds.buzzsprout.com", "feeds.simplecast.com", "feeds.megaphone.fm",
                              "rss.art19.com", "feeds.transistor.fm", "feeds.acast.com",
                              "feeds.libsyn.com", "pinecast.com", "omny.fm"]
        if directFeedHosts.contains(where: { host.contains($0) }) {
            return .success(classified, feeds: [
                ResolvedFeed(feedURL: classified.url.absoluteString, title: nil,
                            sourceURL: classified.raw, mediaKind: .audio)
            ])
        }

        // Fallback: try feed discovery on the page
        return await discoverFeeds(classified)
    }

    /// Resolve Apple Podcasts URL via iTunes Lookup API.
    private func resolveApplePodcast(_ url: URL) async -> String? {
        // Extract podcast ID from URL: /podcast/name/id123456
        let path = url.path
        let idPattern = #"id(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: idPattern),
              let match = regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
              let range = Range(match.range(at: 1), in: path) else { return nil }
        let podcastID = String(path[range])

        // iTunes Lookup API
        guard let lookupURL = URL(string: "https://itunes.apple.com/lookup?id=\(podcastID)&entity=podcast"),
              let (data, _) = try? await session.data(from: lookupURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let first = results.first,
              let feedURL = first["feedUrl"] as? String else { return nil }

        return feedURL
    }

    // MARK: - Probe Helper

    /// Quick check if a URL returns a valid feed (HTTP 200 + XML/JSON feed content).
    private func probeFeedURL(_ urlString: String) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { return false }
        let prefix = String(data.prefix(200).compactMap { $0 < 128 ? Character(UnicodeScalar($0)) : nil })
        return prefix.contains("<rss") || prefix.contains("<feed") || prefix.contains("<RDF")
            || prefix.trimmingCharacters(in: .whitespaces).hasPrefix("{")
    }
}
