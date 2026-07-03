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
