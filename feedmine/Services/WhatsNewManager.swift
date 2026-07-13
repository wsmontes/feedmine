import Foundation
import GRDB
import Observation

@MainActor
@Observable
final class WhatsNewManager {
    let db: DatabaseQueue

    // MARK: - State
    private(set) var whatsNewPool: [FeedItem] = []
    private(set) var whatsNewItems: [FeedItem] = []
    var whatsNewBoosterTask: Task<Void, Never>?
    var whatsNewBaselineDate: Date?

    private let whatsNewThreshold = 10
    private static let lastWhatsNewSeenAtKey = "last_whats_new_seen_at"

    init(db: DatabaseQueue) {
        self.db = db
    }

    // MARK: - Candidate Collection

    /// Items fetched since the baseline snapshot, respecting all active filters.
    /// Called every time new items are persisted into the database.
    /// Feeds the What's New candidate pool — items accumulate in the
    /// background until the threshold is reached, then the carousel appears.
    func collectWhatsNewCandidates(
        _ newItems: [FeedItem],
        visibleIDs: Set<String>,
        readIDs: Set<String>,
        isItemEnabled: (FeedItem) -> Bool,
        filterContentType: (FeedItem) -> Bool,
        contentFilterExcludes: (FeedItem) -> Bool,
        markSurfaced: ([FeedItem]) -> Void
    ) {
        let weekAgo = Date().addingTimeInterval(-604800)  // 7 days
        let candidates = newItems.filter { item in
            item.publishedAt > weekAgo
            && isItemEnabled(item)
            && filterContentType(item)
            && !contentFilterExcludes(item)
            && !visibleIDs.contains(item.id)
            && !readIDs.contains(item.id)
        }
        guard !candidates.isEmpty else { return }
        // Merge into pool: one per source, newest first
        var pool = (candidates + whatsNewPool).sorted { $0.publishedAt > $1.publishedAt }
        var seen = Set<String>()
        pool = pool.filter { seen.insert($0.sourceURL).inserted }
        whatsNewPool = pool
        // Promote when threshold reached
        promoteWhatsNewIfReady(markSurfaced: markSurfaced)
    }

    /// Promote candidates to the visible carousel when the pool is full.
    func promoteWhatsNewIfReady(markSurfaced: ([FeedItem]) -> Void) {
        guard whatsNewItems.isEmpty, whatsNewPool.count >= whatsNewThreshold else { return }
        whatsNewItems = Array(whatsNewPool.prefix(whatsNewThreshold))
        whatsNewPool.removeFirst(min(whatsNewThreshold, whatsNewPool.count))
        // Carousel items are visible on screen — mark as surfaced
        markSurfaced(whatsNewItems)
    }

    /// Advance the carousel: return shown (unclicked) items to the pool so
    /// they remain available for future selections, then promote next batch.
    func advanceWhatsNew(markSurfaced: ([FeedItem]) -> Void) {
        // Return unclicked items to the pool — they were only previewed, not consumed
        if !whatsNewItems.isEmpty {
            whatsNewPool = (whatsNewItems + whatsNewPool)
                .sorted { $0.publishedAt > $1.publishedAt }
        }
        whatsNewItems = []
        promoteWhatsNewIfReady(markSurfaced: markSurfaced)
    }

    /// Kick off an aggressive fetch to fill the What's New pool quickly at
    /// cold start. Runs alongside the DB seed — if the database has nothing,
    /// this fetches fresh content from the network immediately.
    func fetchWhatsNewBooster(
        enabledSources: [FeedSource],
        fetcher: RSSFetcher,
        persistFetchedItems: @escaping ([FeedItem]) async -> [FeedItem],
        throttledReservoirAppend: @escaping ([FeedItem]) -> Void,
        collectCandidates: @escaping ([FeedItem]) -> Void,
        prefetchImages: @escaping ([FeedItem]) -> Void,
        recordFetch: @escaping (String, Bool) -> Void
    ) {
        whatsNewBoosterTask?.cancel()
        whatsNewBoosterTask = Task {
            let sources = enabledSources.shuffled().prefix(30)
            let result = await fetcher.fetchAll(Array(sources), maxConcurrent: 5)
            guard !Task.isCancelled else { return }
            await Task.yield()
            let actualNew = await persistFetchedItems(result.items)
            guard !Task.isCancelled else { return }
            if !actualNew.isEmpty {
                throttledReservoirAppend(actualNew)
                collectCandidates(actualNew)
                prefetchImages(actualNew)
                for source in sources {
                    let ok = result.sourceStatuses[source.url] != .failed
                    recordFetch(source.url, ok)
                }
            }
        }
    }

    /// Refresh What's New: clear the pool, re-seed from DB, and trigger
    /// a booster fetch. Called on any user-triggered update (startup, shake,
    /// filter change) so the carousel always reflects the current context.
    func refreshWhatsNew(
        seedFromDB: @escaping () async -> Void,
        booster: @escaping () -> Void
    ) {
        whatsNewItems = []
        whatsNewPool = []
        Task { await seedFromDB() }
        booster()
    }

    /// Seed the pool from existing SQLite content — runs once at startup
    /// so the carousel isn't empty while waiting for the first fetch batch.
    func seedWhatsNewFromDB(
        surfacedIDs: Set<String>,
        readIDs: Set<String>,
        isItemEnabled: (FeedItem) -> Bool,
        filterContentType: (FeedItem) -> Bool,
        contentFilterExcludes: (FeedItem) -> Bool,
        markSurfaced: ([FeedItem]) -> Void
    ) async {
        guard whatsNewPool.isEmpty else { return }
        do {
            let records: [FeedItemRecord] = try await db.read { db in
                try FeedItemRecord
                    .filter(Column("published_at") > Int(Date().addingTimeInterval(-2592000).timeIntervalSince1970))
                    .filter(Column("is_read") == 0)
                    .order(Column("published_at").desc)
                    .limit(500)
                    .fetchAll(db)
            }
            let items = records.map { $0.toFeedItem() }
                .filter(isItemEnabled).filter(filterContentType)
                .filter { !surfacedIDs.contains($0.id) && !readIDs.contains($0.id) }
                .filter { !contentFilterExcludes($0) }
            var seen = Set<String>()
            whatsNewPool = items.filter { seen.insert($0.sourceURL).inserted }
            promoteWhatsNewIfReady(markSurfaced: markSurfaced)
        } catch {}
    }

    /// Advance the baseline to now and persist it — so items already shown
    /// in the carousel aren't treated as "new" again next session.
    func advanceWhatsNewBaseline() {
        let now = Date()
        whatsNewBaselineDate = now
        UserDefaults.standard.set(now, forKey: Self.lastWhatsNewSeenAtKey)
    }

    /// Reset the What's New baseline to now so newly enabled content appears.
    func resetWhatsNewBaseline() {
        let now = Date()
        whatsNewBaselineDate = now
        UserDefaults.standard.set(now, forKey: Self.lastWhatsNewSeenAtKey)
    }
}
