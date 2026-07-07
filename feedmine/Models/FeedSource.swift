import Foundation

struct FeedSource: Codable, Identifiable, Sendable {
    var id: String { url }
    let title: String
    let url: String
    let category: String
    let region: String  // "global" | "countries/brazil"

    /// YouTube RSS feeds follow this URL pattern — it's the standard endpoint.
    /// https://www.youtube.com/feeds/videos.xml?channel_id=...
    var isYouTube: Bool {
        url.contains("youtube.com/feeds")
    }

    var isCountryFeed: Bool {
        region.hasPrefix("countries/")
    }

    init(title: String, url: String, category: String, region: String = "global") {
        self.title = title
        self.url = url
        self.category = category
        self.region = region
    }

    enum CodingKeys: String, CodingKey {
        case title, url, category, region
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        url = try c.decode(String.self, forKey: .url)
        category = try c.decode(String.self, forKey: .category)
        region = (try? c.decode(String.self, forKey: .region)) ?? "global"
    }
}
