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

    /// Formatted duration string, e.g. "34 min"
    var durationFormatted: String? {
        guard let d = duration, d > 0 else { return nil }
        let mins = Int(d / 60)
        if mins < 60 { return "\(mins) min" }
        let hrs = mins / 60
        let rem = mins % 60
        return rem > 0 ? "\(hrs)h \(rem)m" : "\(hrs)h"
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
