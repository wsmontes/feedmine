import Foundation

struct BookmarkList: Identifiable, Hashable {
    let id: Int64
    var name: String
    var sortOrder: Int
    var createdAt: Date
    var isDefault: Bool
    var searchQuery: String?
    var searchRegion: String?
    var searchCategory: String?
    var searchActive: Bool
    var itemCount: Int

    var isPersistentSearch: Bool { searchQuery != nil }
}
