import Foundation

// MARK: - URL Classification

enum URLKind: Sendable {
    case feed           // Direct RSS/Atom/JSON feed URL
    case website        // HTML page — needs feed discovery
    case youtube        // youtube.com URL (channel, video, playlist, handle)
    case github         // github.com repo or user
    case podcast        // podcasts.apple.com, spotify, anchor, etc.
    case opml           // .opml file URL
    case unknown        // Unrecognizable
}

struct ClassifiedURL: Sendable {
    let raw: String
    let url: URL
    let kind: URLKind
}

// MARK: - Input Parser

/// Extracts and classifies URLs from free-form user input.
/// Handles: single URL, multiple URLs, mixed text with URLs,
/// newline/comma/space separated lists.
enum InputParser {

    /// Parse arbitrary user input into classified URLs.
    /// Input can be: a single URL, multiple URLs separated by whitespace/newlines/commas,
    /// or prose text containing embedded URLs.
    static func parse(_ input: String) -> [ClassifiedURL] {
        let urls = extractURLs(from: input)
        return urls.compactMap { raw -> ClassifiedURL? in
            guard let url = normalize(raw) else { return nil }
            let kind = classify(url)
            return ClassifiedURL(raw: raw, url: url, kind: kind)
        }
    }

    // MARK: - URL Extraction

    /// Extract all URLs from text using NSDataDetector + regex fallback.
    private static func extractURLs(from text: String) -> [String] {
        var found: [String] = []
        var seen = Set<String>()

        // Strategy 1: NSDataDetector (handles most URL formats)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = detector.matches(in: text, range: range)
            for match in matches {
                if let url = match.url?.absoluteString, seen.insert(url).inserted {
                    found.append(url)
                }
            }
        }

        // Strategy 2: Line-by-line for bare domains (site.com without http)
        // Split by common separators and check each token
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;|"))
        let tokens = text.components(separatedBy: separators)
        for token in tokens {
            let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'<>()[]{}"))
            guard !trimmed.isEmpty, trimmed.contains("."), !seen.contains(trimmed) else { continue }
            // Add scheme if missing
            let withScheme = trimmed.hasPrefix("http") ? trimmed : "https://\(trimmed)"
            if let url = URL(string: withScheme), url.host != nil, !seen.contains(withScheme) {
                seen.insert(withScheme)
                found.append(withScheme)
            }
        }

        return found
    }

    // MARK: - URL Normalization

    private static func normalize(_ raw: String) -> URL? {
        var str = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !str.hasPrefix("http") { str = "https://\(str)" }
        return URL(string: str)
    }

    // MARK: - Classification

    private static func classify(_ url: URL) -> URLKind {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        let fullURL = url.absoluteString.lowercased()

        // OPML
        if path.hasSuffix(".opml") || path.hasSuffix(".opml.xml") {
            return .opml
        }

        // YouTube
        if host.contains("youtube.com") || host.contains("youtu.be") {
            return .youtube
        }

        // GitHub
        if host == "github.com" || host == "www.github.com" {
            return .github
        }

        // Podcast platforms
        let podcastHosts = ["podcasts.apple.com", "itunes.apple.com",
                           "open.spotify.com", "anchor.fm",
                           "feeds.buzzsprout.com", "feeds.simplecast.com",
                           "feeds.megaphone.fm", "rss.art19.com",
                           "feeds.transistor.fm", "feeds.acast.com",
                           "feeds.libsyn.com", "pinecast.com", "omny.fm",
                           "podbean.com", "spreaker.com", "castbox.fm"]
        if podcastHosts.contains(where: { host.contains($0) }) {
            return .podcast
        }

        // Direct feed indicators
        let feedIndicators = ["/feed", "/rss", "/atom", ".xml", ".json",
                             "/feeds/", "feed.xml", "rss.xml", "atom.xml",
                             "index.xml", "/feed/"]
        if feedIndicators.contains(where: { path.contains($0) || fullURL.contains($0) }) {
            return .feed
        }

        // Content-type hints in URL
        if fullURL.contains("application/rss") || fullURL.contains("application/atom") {
            return .feed
        }

        // Default: treat as website (will attempt feed discovery)
        return .website
    }
}
