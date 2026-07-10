import Foundation
import Observation

@MainActor
@Observable
final class FeedManager {
    struct FeedInstance: Identifiable {
        let descriptor: FeedDescriptor
        let loader: FeedLoader
        var id: UUID { descriptor.id }
    }

    private static let indexKey = "feeds_index"
    private let maxFeeds = 5

    private(set) var feeds: [FeedInstance] = []
    var activeIndex: Int = 0

    var canCreateMore: Bool { feeds.count < maxFeeds }

    init() {
        let descriptors = Self.loadIndex()
        feeds = descriptors
            .sorted { $0.order < $1.order }
            .map { FeedInstance(descriptor: $0, loader: Self.makeLoader(for: $0)) }
    }

    // MARK: - Loader factory (per-feed DB + UserDefaults suite)

    private static func makeLoader(for descriptor: FeedDescriptor) -> FeedLoader {
        let suite = UserDefaults(suiteName: "com.feedmine.feed.\(descriptor.id.uuidString)") ?? .standard
        return FeedLoader(feedID: descriptor.id, defaults: suite)
    }

    // MARK: - Index persistence

    private static func loadIndex() -> [FeedDescriptor] {
        guard let data = UserDefaults.standard.data(forKey: indexKey),
              let list = try? JSONDecoder().decode([FeedDescriptor].self, from: data),
              !list.isEmpty else {
            return [FeedDescriptor.main()]   // first launch / corrupt → main only
        }
        return list
    }

    private func persistIndex() {
        let descriptors = feeds.map(\.descriptor)
        guard let data = try? JSONEncoder().encode(descriptors) else { return }
        UserDefaults.standard.set(data, forKey: Self.indexKey)
    }

    // MARK: - Palette assignment

    /// Families currently in use. The main's effective family (from CircadianEngine)
    /// counts as occupied. `excludeID` lets a secondary's own family be ignored.
    func occupiedFamilies(excludingSecondary excludeID: UUID? = nil) -> Set<PaletteFamily> {
        var used = Set<PaletteFamily>()
        for f in feeds {
            if f.descriptor.id == excludeID { continue }
            if f.descriptor.isMain {
                used.insert(CircadianEngine.shared.paletteFamily)
            } else if let fam = f.descriptor.paletteFamily {
                used.insert(fam)
            }
        }
        return used
    }

    var nextFreeFamily: PaletteFamily? {
        FeedDescriptor.firstFreeFamily(excluding: occupiedFamilies())
    }

    func theme(for descriptor: FeedDescriptor) -> FeedTheme {
        FeedTheme(family: descriptor.isMain ? nil : descriptor.paletteFamily)
    }

    // MARK: - Create / Delete

    @discardableResult
    func createFeed(name: String?) -> Int {
        guard canCreateMore, let family = nextFreeFamily else { return activeIndex }
        let descriptor = FeedDescriptor(
            id: UUID(),
            name: (name?.isEmpty == true) ? nil : name,
            paletteFamily: family,
            order: feeds.count,
            createdAt: Date()
        )
        let instance = FeedInstance(descriptor: descriptor, loader: Self.makeLoader(for: descriptor))
        feeds.append(instance)
        persistIndex()
        let newIndex = feeds.count - 1
        activeIndex = newIndex
        return newIndex
    }

    func deleteFeed(id: UUID) {
        guard let idx = feeds.firstIndex(where: { $0.descriptor.id == id }),
              !feeds[idx].descriptor.isMain else { return }
        // Slide to a safe neighbor BEFORE removing, so no dead loader renders.
        let neighbor = max(0, idx - 1)
        activeIndex = neighbor
        feeds.remove(at: idx)
        // Reindex order.
        feeds = feeds.enumerated().map { i, inst in
            var d = inst.descriptor; d.order = i
            return FeedInstance(descriptor: d, loader: inst.loader)
        }
        persistIndex()
        FeedStore.deleteDatabaseFiles(feedID: id)
        UserDefaults.standard.removeSuite(named: "com.feedmine.feed.\(id.uuidString)")
        if activeIndex >= feeds.count { activeIndex = max(0, feeds.count - 1) }
    }

    func setActive(_ index: Int) {
        guard feeds.indices.contains(index) else { return }
        activeIndex = index
    }
}

#if DEBUG
extension FeedManager {
    /// Cheap runtime self-check — call once from app launch in DEBUG.
    static func _selfCheckPalettePool() {
        let mainFam = CircadianEngine.shared.paletteFamily
        // firstFreeFamily must skip an excluded family
        let free = FeedDescriptor.firstFreeFamily(excluding: [mainFam])
        assert(free != nil && free != mainFam, "free family must exclude the occupied one")
        // excluding all families yields nil (pool exhausted)
        assert(FeedDescriptor.firstFreeFamily(excluding: Set(PaletteFamily.allCases)) == nil, "full pool → nil")
        print("[FeedManager] palette self-check passed (main=\(mainFam.rawValue), free=\(free!.rawValue))")
    }
}
#endif
