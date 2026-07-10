import Foundation

/// Persisted identity of a single feed. Holds no content data — just the feed's
/// identity and its palette assignment. Content lives in the feed's own SQLite DB.
struct FeedDescriptor: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String?
    /// nil = adaptive/global palette (main feed only, follows CircadianEngine).
    /// non-nil = fixed family (secondary feeds).
    var paletteFamily: PaletteFamily?
    var order: Int
    var createdAt: Date

    /// Fixed id for the permanent main feed, so it persists across launches.
    static let mainID = UUID(uuidString: "00000000-0000-0000-0000-0000000000FE")!

    static func main() -> FeedDescriptor {
        FeedDescriptor(id: mainID, name: nil, paletteFamily: nil, order: 0, createdAt: Date(timeIntervalSince1970: 0))
    }

    var isMain: Bool { id == FeedDescriptor.mainID }

    /// First palette family in canonical enum order not present in `used`.
    static func firstFreeFamily(excluding used: Set<PaletteFamily>) -> PaletteFamily? {
        PaletteFamily.allCases.first { !used.contains($0) }
    }
}
