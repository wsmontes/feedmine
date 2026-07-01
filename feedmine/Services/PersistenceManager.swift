import Foundation

/// All user data that survives app restarts
struct FeedState: Codable {
    /// Bump on format changes to trigger migration
    var schemaVersion: Int = 1
    var readItemIDs: [String] = []
    var bookmarkedIDs: [String] = []
    var disabledSourceIDs: [String] = []
    var sources: [FeedSource] = []
    var lastRefreshDate: Date?
    var streakCount: Int = 0
    var lastOpenDate: TimeInterval = Date().timeIntervalSinceReferenceDate
}

/// JSON file persistence with backup, corrupted recovery, and migration support
@MainActor
final class PersistenceManager {
    static let shared = PersistenceManager()

    private var mainURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("feedmine_state.json")
    }

    private var backupURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("feedmine_state.backup.json")
    }

    private var saveTask: Task<Void, Never>?

    // MARK: - Load with recovery

    func load() -> FeedState? {
        // Try main file first
        if let state = tryLoad(url: mainURL) {
            validateAndLog(state, source: "main")
            return state
        }

        // Corrupted? Try backup
        print("[Persistence] Main file failed — attempting backup recovery")
        if let state = tryLoad(url: backupURL) {
            print("[Persistence] Recovered from backup!")
            // Restore main from backup
            trySave(state, to: mainURL)
            validateAndLog(state, source: "backup")
            return state
        }

        print("[Persistence] No valid state found — fresh start")
        return nil
    }

    // MARK: - Save with backup rotation

    func save(_ state: FeedState) {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }

            // Rotate: current main → backup, then write new main
            if FileManager.default.fileExists(atPath: mainURL.path) {
                try? FileManager.default.removeItem(at: backupURL)
                try? FileManager.default.copyItem(at: mainURL, to: backupURL)
            }

            trySave(state, to: mainURL)
        }
    }

    /// Force immediate save (for critical moments like background)
    func saveNow(_ state: FeedState) {
        saveTask?.cancel()
        if FileManager.default.fileExists(atPath: mainURL.path) {
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.copyItem(at: mainURL, to: backupURL)
        }
        trySave(state, to: mainURL)
    }

    // MARK: - Migration

    func migrateIfNeeded(_ state: inout FeedState) {
        // v1 → future: add fields here
        // if state.schemaVersion < 2 { state.newField = default; state.schemaVersion = 2 }
    }

    // MARK: - Private

    private func tryLoad(url: URL) -> FeedState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            var state = try JSONDecoder().decode(FeedState.self, from: data)
            migrateIfNeeded(&state)
            return state
        } catch {
            print("[Persistence] Load error for \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    private func trySave(_ state: FeedState, to url: URL) {
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: url, options: .atomic)
            print("[Persistence] Saved \(state.readItemIDs.count) read, \(state.bookmarkedIDs.count) bookmarks")
        } catch {
            print("[Persistence] Save failed: \(error)")
        }
    }

    private func validateAndLog(_ state: FeedState, source: String) {
        let sizeEstimate = (state.readItemIDs.count + state.bookmarkedIDs.count) * 64  // ~64 bytes per SHA256
        print("[Persistence] Loaded from \(source): \(state.readItemIDs.count) read, \(state.bookmarkedIDs.count) bookmarks, \(state.sources.count) sources (~\(sizeEstimate/1024)KB)")
        if state.schemaVersion < 1 {
            print("[Persistence] ⚠️ Unknown schema version — may need migration")
        }
    }
}
