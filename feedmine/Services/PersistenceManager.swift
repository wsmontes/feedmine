import Foundation

/// All user data that survives app restarts
struct FeedState: Codable {
    var readItemIDs: [String] = []
    var bookmarkedIDs: [String] = []
    var disabledSourceIDs: [String] = []
    var sources: [FeedSource] = []
    var lastRefreshDate: Date?
    var streakCount: Int = 0
    var lastOpenDate: TimeInterval = Date().timeIntervalSinceReferenceDate
}

/// Simple JSON file persistence — saves on background, loads on launch
@MainActor
final class PersistenceManager {
    static let shared = PersistenceManager()

    private var saveURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("feedmine_state.json")
    }

    private var saveTask: Task<Void, Never>?

    func load() -> FeedState? {
        guard FileManager.default.fileExists(atPath: saveURL.path) else {
            print("[Persistence] No saved state found — fresh start")
            return nil
        }
        do {
            let data = try Data(contentsOf: saveURL)
            let state = try JSONDecoder().decode(FeedState.self, from: data)
            print("[Persistence] Loaded state: \(state.readItemIDs.count) read, \(state.bookmarkedIDs.count) bookmarks, \(state.sources.count) sources")
            return state
        } catch {
            print("[Persistence] Failed to load: \(error)")
            return nil
        }
    }

    func save(_ state: FeedState) {
        // Debounce saves — only keep the latest
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))  // debounce
            guard !Task.isCancelled else { return }
            do {
                let data = try JSONEncoder().encode(state)
                try data.write(to: saveURL, options: .atomic)
                print("[Persistence] Saved \(state.readItemIDs.count) read, \(state.bookmarkedIDs.count) bookmarks")
            } catch {
                print("[Persistence] Save failed: \(error)")
            }
        }
    }
}
