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

    var isCountryFeed: Bool {
        region.hasPrefix("countries/")
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
