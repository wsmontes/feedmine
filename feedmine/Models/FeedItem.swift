import Foundation
import CryptoKit

struct FeedItem: Identifiable, Sendable, Codable {
    let id: String
    let sourceTitle: String
    let sourceURL: String
    let category: String
    let title: String
    let excerpt: String
    let url: String
    let imageURL: String?
    let publishedAt: Date
    let audioURL: String?
    let duration: TimeInterval?

    /// True if this article links to a YouTube video
    var isYouTube: Bool { youTubeVideoID != nil }

    /// Extracts the YouTube video ID from the URL, if any
    var youTubeVideoID: String? {
        // Fast reject before allocating URL/URLComponents: this is called per
        // item during filtering, interleaving, isTimeless, and rendering, and
        // almost no items are YouTube links. "youtu" covers youtube.com and
        // youtu.be, and the host checks below still gate real matches.
        guard url.contains("youtu") else { return nil }
        guard let url = URL(string: url) else { return nil }
        // youtube.com/watch?v=VIDEO_ID
        if url.host?.contains("youtube.com") == true || url.host?.contains("youtu.be") == true {
            if url.host?.contains("youtu.be") == true {
                return url.pathComponents.last.flatMap { $0.isEmpty ? nil : $0 }
            }
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let queryItems = components.queryItems,
               let videoID = queryItems.first(where: { $0.name == "v" })?.value {
                return videoID
            }
        }
        return nil
    }

    /// YouTube thumbnail URL — hqdefault.jpg always exists for any video.
    /// maxresdefault.jpg only exists for 1080p+ and returns an ugly gray placeholder otherwise.
    var youTubeThumbnailURL: String? {
        guard let videoID = youTubeVideoID else { return nil }
        return "https://img.youtube.com/vi/\(videoID)/hqdefault.jpg"
    }

    /// Best available image URL — YouTube thumbnail takes priority over RSS image.
    /// If the image fails to load, the card falls back to text-only layout.
    var bestImageURL: String? {
        youTubeThumbnailURL ?? imageURL
    }

    /// True if this item has an audio enclosure (podcast episode)
    var isPodcast: Bool { audioURL != nil }

    /// URL that can be handed to AVFoundation. Podcast feeds occasionally
    /// publish protocol-relative or feed-relative enclosure URLs.
    var audioPlaybackURL: URL? {
        Self.resolvedMediaURL(from: audioURL, baseURL: sourceURL)
    }

    /// Atemporal content (blogs, science, tutorials) ages slowly.
    /// News and sports are time-sensitive. Used for stale cutoff and sorting.
    var isTimeless: Bool {
        let lower = category.lowercased()
        if lower.contains("news") || lower.contains("sport") { return false }
        if lower.contains("blog") || lower.contains("science") || lower.contains("tech")
            || lower.contains("programming") || lower.contains("culture")
            || lower.contains("history") || lower.contains("design")
            || lower.contains("food") || lower.contains("diy")
            || lower.contains("music") || lower.contains("movie")
            || lower.contains("photography") || lower.contains("travel")
            || lower.contains("environment") || lower.contains("architecture") { return true }
        // Video/podcast content is timeless
        if isYouTube || isPodcast { return true }
        return false
    }

    /// Formatted duration string, e.g. "34 min"
    var durationFormatted: String? {
        guard let d = duration, d > 0 else { return nil }
        let mins = Int(d / 60)
        if mins < 60 { return "\(mins) min" }
        let hrs = mins / 60
        let rem = mins % 60
        return rem > 0 ? "\(hrs)h \(rem)m" : "\(hrs)h"
    }

    /// A copy with audio stripped — used when an enclosure fails playability
    /// validation, so the item is no longer treated as a podcast.
    func withoutAudio() -> FeedItem {
        FeedItem(
            id: id, sourceTitle: sourceTitle, sourceURL: sourceURL, category: category,
            title: title, excerpt: excerpt, url: url, imageURL: imageURL,
            publishedAt: publishedAt, audioURL: nil, duration: nil
        )
    }

    static func resolvedMediaURL(from rawValue: String?, baseURL: String? = nil) -> URL? {
        guard var raw = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        raw = raw
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")

        let base = baseURL.flatMap(URL.init(string:))
        if raw.hasPrefix("//") {
            raw = "\(base?.scheme ?? "https"):\(raw)"
        }

        guard let url = URL(string: raw, relativeTo: base)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return nil
        }
        return url
    }

    /// SHA256("sourceURL|guid_or_link") — unique across feeds
    static func generateID(sourceURL: String, guid: String?, link: String?, title: String? = nil, publishedAt: Date? = nil) -> String {
        let token: String = {
            if let guid = guid, !guid.isEmpty { return guid }
            if let link = link, !link.isEmpty { return link }
            // Fallback: source + title + timestamp — imperfect but prevents data loss
            let ts = publishedAt.map { String($0.timeIntervalSince1970) } ?? "0"
            let t = title ?? "untitled"
            return "\(t)|\(ts)"
        }()
        let raw = "\(sourceURL)|\(token)"
        let data = Data(raw.utf8)
        return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }
}
