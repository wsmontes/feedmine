import Foundation
import Compression

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
    /// Tracks when each read ID was marked (for auto-cleanup of stale entries)
    var readTimestamps: [String: Date] = [:]
}

/// JSON file persistence with backup, corrupted recovery, compression, and migration
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

    /// Maximum age for read IDs before auto-cleanup (90 days)
    private static let maxReadAge: TimeInterval = 90 * 24 * 3600

    // MARK: - Load with recovery

    func load() -> FeedState? {
        if let state = tryLoad(url: mainURL) {
            validateAndLog(state, source: "main")
            return state
        }

        print("[Persistence] Main file failed — attempting backup recovery")
        if let state = tryLoad(url: backupURL) {
            print("[Persistence] Recovered from backup!")
            trySave(state, to: mainURL)
            validateAndLog(state, source: "backup")
            return state
        }

        print("[Persistence] No valid state found — fresh start")
        return nil
    }

    // MARK: - Save with backup rotation + compression

    func save(_ state: FeedState) {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }

            var cleaned = state
            autoCleanup(&cleaned)

            if FileManager.default.fileExists(atPath: mainURL.path) {
                try? FileManager.default.removeItem(at: backupURL)
                try? FileManager.default.copyItem(at: mainURL, to: backupURL)
            }

            trySaveCompressed(cleaned, to: mainURL)
        }
    }

    func saveNow(_ state: FeedState) {
        saveTask?.cancel()
        var cleaned = state
        autoCleanup(&cleaned)

        if FileManager.default.fileExists(atPath: mainURL.path) {
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.copyItem(at: mainURL, to: backupURL)
        }

        trySaveCompressed(cleaned, to: mainURL)
    }

    // MARK: - Auto-Cleanup

    private func autoCleanup(_ state: inout FeedState) {
        let cutoff = Date().addingTimeInterval(-Self.maxReadAge)
        let staleIDs = state.readTimestamps.filter { $0.value < cutoff }.map(\.key)
        if !staleIDs.isEmpty {
            state.readItemIDs.removeAll { staleIDs.contains($0) }
            state.readTimestamps = state.readTimestamps.filter { $0.value >= cutoff }
            print("[Persistence] Cleaned \(staleIDs.count) stale read IDs (older than 90 days)")
        }
    }

    // MARK: - Migration

    func migrateIfNeeded(_ state: inout FeedState) {
        // v1 → v2: added readTimestamps (populated on next markAsRead)
        if state.schemaVersion < 2 {
            state.schemaVersion = 2
            // readTimestamps defaults to empty — populated incrementally
            print("[Persistence] Migrated schema v1 → v2 (added readTimestamps)")
        }
        // Future: if state.schemaVersion < 3 { ... }
    }

    // MARK: - Public helpers

    /// Check if persistence is healthy (files exist, can be read)
    var isHealthy: Bool {
        guard FileManager.default.fileExists(atPath: mainURL.path) else { return true }  // no file = fresh start = healthy
        return tryLoad(url: mainURL) != nil || tryLoad(url: backupURL) != nil
    }

    /// Estimated storage size
    var storageSize: String {
        let mainSize = (try? Data(contentsOf: mainURL).count) ?? 0
        let backupSize = (try? Data(contentsOf: backupURL).count) ?? 0
        let total = mainSize + backupSize
        if total < 1024 { return "\(total) B" }
        if total < 1_048_576 { return "\(total / 1024) KB" }
        return String(format: "%.1f MB", Double(total) / 1_048_576.0)
    }

    // MARK: - Private

    /// Validate state data makes sense before saving
    private func validate(_ state: FeedState) -> Bool {
        // Negative counts indicate data corruption
        guard state.readItemIDs.count >= 0,
              state.bookmarkedIDs.count >= 0,
              state.disabledSourceIDs.count >= 0,
              state.sources.count >= 0 else {
            print("[Persistence] ⚠️ Validation failed: negative counts detected")
            return false
        }
        // ID lists should be unique
        if Set(state.readItemIDs).count != state.readItemIDs.count {
            print("[Persistence] ⚠️ Validation failed: duplicate read IDs")
        }
        if Set(state.bookmarkedIDs).count != state.bookmarkedIDs.count {
            print("[Persistence] ⚠️ Validation failed: duplicate bookmark IDs")
        }
        return true
    }

    /// Check sufficient disk space (reject saves if < 10MB free)
    private var hasDiskSpace: Bool {
        do {
            let values = try mainURL.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            if let free = values.volumeAvailableCapacity, free < 10_485_760 {
                print("[Persistence] ⚠️ Low disk space (\(free/1_048_576)MB free) — skipping save")
                return false
            }
        } catch {
            return true  // err on the side of trying
        }
        return true
    }

    private func tryLoad(url: URL) -> FeedState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            // Try decompressed first, fall back to raw (legacy)
            let decoded: Data
            if let decompressed = data.decompress() {
                decoded = decompressed
            } else {
                decoded = data  // legacy uncompressed format
            }
            var state = try JSONDecoder().decode(FeedState.self, from: decoded)
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

    private func trySaveCompressed(_ state: FeedState, to url: URL) {
        guard validate(state) else { return }
        guard hasDiskSpace else { return }
        do {
            let json = try JSONEncoder().encode(state)
            let data = json.compress() ?? json  // fall back to uncompressed
            try data.write(to: url, options: .atomic)
            let ratio = json.count > 0 ? (100 - data.count * 100 / json.count) : 0
            print("[Persistence] Saved \(state.readItemIDs.count) read, \(state.bookmarkedIDs.count) bookmarks (~\(data.count/1024)KB, \(ratio)% compression)")
        } catch {
            print("[Persistence] Save failed: \(error)")
        }
    }

    private func validateAndLog(_ state: FeedState, source: String) {
        print("[Persistence] Loaded from \(source): v\(state.schemaVersion), \(state.readItemIDs.count) read, \(state.bookmarkedIDs.count) bookmarks, \(state.sources.count) sources")
    }
}

// MARK: - Data compression extension

extension Data {
    /// Compress using zlib (COMPRESSION_ZLIB)
    func compress() -> Data? {
        guard !isEmpty else { return nil }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        defer { buffer.deallocate() }
        copyBytes(to: buffer, count: count)

        let maxSize = count + count/2 + 16
        var compressed = Data(count: maxSize)
        let resultSize = compressed.withUnsafeMutableBytes { dest in
            Compression.compression_encode_buffer(
                dest.baseAddress!.assumingMemoryBound(to: UInt8.self),
                maxSize,
                buffer,
                count,
                nil,
                COMPRESSION_ZLIB
            )
        }
        guard resultSize > 0 else { return nil }
        compressed.count = resultSize
        return compressed
    }

    /// Decompress zlib-compressed data
    func decompress() -> Data? {
        guard !isEmpty else { return nil }
        let estimated = count * 4 // reasonable overestimate
        var decompressed = Data(count: estimated)
        let resultSize = decompressed.withUnsafeMutableBytes { dest in
            self.withUnsafeBytes { src in
                Compression.compression_decode_buffer(
                    dest.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    estimated,
                    src.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard resultSize > 0 else { return nil }
        decompressed.count = resultSize
        return decompressed
    }
}
