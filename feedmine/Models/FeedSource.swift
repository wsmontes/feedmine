import Foundation

enum MediaKind: String, Codable, Sendable {
    case text
    case video
    case audio
}

struct FeedSource: Codable, Identifiable, Sendable {
    var id: String { url }
    let title: String
    let url: String
    let category: String
    let region: String  // "global" | "countries/brazil"
    let mediaKind: MediaKind

    /// YouTube RSS feeds follow this URL pattern — it's the standard endpoint.
    /// https://www.youtube.com/feeds/videos.xml?channel_id=...
    var isYouTube: Bool {
        url.contains("youtube.com/feeds")
    }

    /// Only text news/blog sources are "country feeds" that should be opt-in.
    /// YouTube and podcast sources keep their country tag for language/region
    /// filtering but are always globally available — their country association
    /// is a language overlay, not an enable/disable gate.
    /// Uses isYouTube / mediaKind.audio instead of just mediaKind because
    /// YouTube entries inside country OPMLs get mediaKind=.text (the parser
    /// only tags .video when the OPML *file name* contains "youtube").
    var isCountryFeed: Bool {
        region.hasPrefix("countries/") && !isYouTube && mediaKind != .audio
    }

    init(title: String, url: String, category: String, region: String = "global", mediaKind: MediaKind = .text) {
        self.title = title
        self.url = url
        self.category = category
        self.region = region
        self.mediaKind = mediaKind
    }

    enum CodingKeys: String, CodingKey {
        case title, url, category, region, mediaKind = "media_kind"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        url = try c.decode(String.self, forKey: .url)
        category = try c.decode(String.self, forKey: .category)
        region = (try? c.decode(String.self, forKey: .region)) ?? "global"
        mediaKind = (try? c.decode(MediaKind.self, forKey: .mediaKind)) ?? .text
    }
}
