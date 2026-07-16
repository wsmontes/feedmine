import Foundation

/// Selects which feed sources to fetch next based on reservoir entropy.
/// Uses √n fairness between regions, LRU ordering within regions,
/// and soft cooldown instead of hard timeouts.
@MainActor
final class SourceScheduler {
    private(set) var lastFetchedAt: [String: Date] = [:]
    private(set) var consecutiveFailures: [String: Int] = [:]
    private var consumptionTimestamps: [Date] = []

    // MARK: - Public API

    func nextBatch(
        reservoir: [FeedItem],
        sourcesByRegion: [String: [FeedSource]],
        activeRegion: String?,
        activeCategory: String?,
        activeContentType: String? = nil,  // "video", "audio", or nil for all
        prioritySourceURLs: Set<String> = [],
        activeLanguages: Set<String> = []
    ) -> [FeedSource] {
        // 1. Determine scope
        let regions = activeRegion.map { [$0] } ?? Array(sourcesByRegion.keys)
        guard !regions.isEmpty else { return [] }

        // 2. Measure consumption — how much buffer do we need?
        let bufferNeeded = estimatedBufferNeeded()
        // Content-type-aware buffer gate. When no filter is active (default
        // mixed feed), count each type independently — text items shouldn't
        // starve video/audio sources. Gate opens if ANY type is below its
        // per-type ceiling.
        let currentBuffer: Int
        if let ct = activeContentType {
            currentBuffer = reservoir.filter { item in
                switch ct {
                case "video": return item.isYouTube
                case "audio": return item.isPodcast
                case "text": return !item.isYouTube && !item.isPodcast
                default: return true
                }
            }.count
            guard currentBuffer < bufferNeeded else { return [] }
        } else {
            // Mixed feed: per-type ceilings. Text items are abundant; video
            // and audio are scarce. If any type is below its ceiling, the
            // scheduler can still pick sources of that type.
            let textCount = reservoir.filter { !$0.isYouTube && !$0.isPodcast }.count
            let videoCount = reservoir.filter { $0.isYouTube }.count
            let audioCount = reservoir.filter { $0.isPodcast }.count
            let textTarget = max(bufferNeeded, 300)
            let videoTarget = max(bufferNeeded / 2, 50)
            let audioTarget = max(bufferNeeded / 2, 50)
            let textDeficit = max(textTarget - textCount, 0)
            let videoDeficit = max(videoTarget - videoCount, 0)
            let audioDeficit = max(audioTarget - audioCount, 0)
            let totalDeficit = textDeficit + videoDeficit + audioDeficit
            guard totalDeficit > 0 else { return [] }
            currentBuffer = bufferNeeded - Int(ceil(Double(totalDeficit) / 3.0))
        }

        // 3. Measure entropy — distribution of regions/categories in reservoir
        let urlToRegion: [String: String] = sourcesByRegion.flatMap { region, sources in
            sources.map { ($0.url, region) }
        }.reduce(into: [:]) { $0[$1.0] = $1.1 }

        let regionDistribution = distribution(of: reservoir, key: { item -> String in
            urlToRegion[item.sourceURL] ?? "unknown"
        })
        let categoryDistribution = distribution(of: reservoir, key: \.category)

        // 4. Calculate ideal distribution (√n for regions, uniform for categories)
        let regionWeights = sqrtWeights(for: sourcesByRegion)
        let allCategories = Set(sourcesByRegion.values.flatMap { $0 }.map(\.category))
        let idealRegionDist = normalize(regionWeights)
        let idealCategoryDist = normalize(Dictionary(uniqueKeysWithValues: allCategories.map { ($0, 1.0) }))

        // 5. Calculate deficits
        let regionDeficits = deficits(ideal: idealRegionDist, actual: regionDistribution)
        let categoryDeficits = deficits(ideal: idealCategoryDist, actual: categoryDistribution)

        // Boost the active category's deficit if one is set
        var finalCategoryDeficits = categoryDeficits
        if let cat = activeCategory {
            finalCategoryDeficits[cat] = max(finalCategoryDeficits[cat] ?? 0, 1.0)
        }

        // 6. Precompute scores for all eligible sources once, then greedily
        // select the top N. Previously bestSource() was called in a loop,
        // re-scanning all 800+ sources each time (O(N × S)). Now we score
        // once, sort once, and pick from the front (O(S log S)).
        let deficitNeeded = Int(ceil(Double(bufferNeeded - currentBuffer) / 3.0))
        let maxSelect = max(deficitNeeded, 10)

        // Phase 1: Priority sources jump the queue (Disney Fast Pass)
        var selected: [FeedSource] = []
        var selectedURLs = Set<String>()
        selectedURLs.reserveCapacity(maxSelect)

        if !prioritySourceURLs.isEmpty {
            priorityLoop: for region in regions {
                guard let sources = sourcesByRegion[region] else { continue }
                for source in sources {
                    guard selected.count < maxSelect else { break priorityLoop }
                    guard prioritySourceURLs.contains(source.url) else { continue }
                    guard selectedURLs.insert(source.url).inserted else { continue }
                    // Clear cooldown — treat as never-fetched
                    lastFetchedAt.removeValue(forKey: source.url)
                    consecutiveFailures.removeValue(forKey: source.url)
                    selected.append(source)
                }
            }
        }

        // Phase 2: Fill remaining slots with normal scoring
        let remaining = maxSelect - selected.count
        if remaining > 0 {
            let now = Date()
            var scored: [(source: FeedSource, score: Double)] = []
            scored.reserveCapacity(sourcesByRegion.values.map(\.count).reduce(0, +))

            for region in regions {
                guard let sources = sourcesByRegion[region] else { continue }
                let regionDeficit = max(0, regionDeficits[region] ?? 0)
                for source in sources {
                    guard !selectedURLs.contains(source.url) else { continue }
                    let failures = consecutiveFailures[source.url] ?? 0
                    if failures >= 3 {
                        let backoff = pow(2.0, Double(failures - 2)) * 60
                        if let last = lastFetchedAt[source.url],
                           now.timeIntervalSince(last) < backoff { continue }
                    }
                    let catDeficit = max(0, finalCategoryDeficits[source.category] ?? 0)

                    let contentTypeBoost: Double = switch activeContentType {
                    case "video": source.mediaKind == .video ? 3.0 : 1.0
                    case "audio": source.mediaKind == .audio ? 3.0 : 1.0
                    case "text":  source.mediaKind == .video ? 0.3 : (source.mediaKind == .audio ? 0.3 : 1.0)
                    default:      source.isYouTube ? 2.0 : (source.mediaKind == .audio ? 2.0 : 1.0)
                    }

                    let timeFactor: Double
                    if let last = lastFetchedAt[source.url] {
                        timeFactor = min(1.0, now.timeIntervalSince(last) / 1800)
                    } else {
                        timeFactor = 1.0
                    }

                    let sourceLang = source.language.flatMap { $0.isEmpty ? nil : $0 }
                    let languageBoost: Double = activeLanguages.isEmpty ? 1.0
                        : (sourceLang.map { activeLanguages.contains($0) } == true ? 3.0 : 0.5)

                    let score = regionDeficit * catDeficit * timeFactor * contentTypeBoost * languageBoost
                    let finalScore = max(score, 0.01)
                    if finalScore > 0 { scored.append((source, finalScore)) }
                }
            }

            scored.sort(by: { $0.score > $1.score })
            for (source, _) in scored {
                guard selected.count < maxSelect else { break }
                guard selectedURLs.insert(source.url).inserted else { continue }
                selected.append(source)
            }
        }

        return selected
    }

    func recordConsumption() {
        consumptionTimestamps.append(Date())
        // Keep only last 5 minutes
        let cutoff = Date().addingTimeInterval(-300)
        consumptionTimestamps = consumptionTimestamps.filter { $0 > cutoff }
    }

    func recordFetch(sourceURL: String, success: Bool) {
        lastFetchedAt[sourceURL] = Date()
        if success {
            consecutiveFailures[sourceURL] = 0
        } else {
            consecutiveFailures[sourceURL, default: 0] += 1
        }
    }

    func prioritize(sourceURLs: [String]) {
        // Clear lastFetchedAt so these sources appear at the front of LRU
        for url in sourceURLs {
            lastFetchedAt.removeValue(forKey: url)
            consecutiveFailures.removeValue(forKey: url)
        }
    }

    func remove(sourceURLs: [String]) {
        for url in sourceURLs {
            lastFetchedAt.removeValue(forKey: url)
            consecutiveFailures.removeValue(forKey: url)
        }
    }

    // MARK: - Persistence hooks (called by FeedStore)

    /// Restore persisted health after app restart.
    func loadHealth(url: String, lastFetchAt: Date, consecutiveFailures: Int) {
        if self.lastFetchedAt[url] == nil {
            self.lastFetchedAt[url] = lastFetchAt
        }
        if self.consecutiveFailures[url] == nil {
            self.consecutiveFailures[url] = consecutiveFailures
        }
    }

    /// Snapshot for saving to DB.
    struct HealthSnapshot {
        let lastFetchAt: Date
        let consecutiveFailures: Int
        let lastStatus: String?
        let lastItemCount: Int?
    }

    func healthSnapshot(for url: String, itemCount: Int? = nil) -> HealthSnapshot {
        HealthSnapshot(
            lastFetchAt: lastFetchedAt[url] ?? Date(timeIntervalSince1970: 0),
            consecutiveFailures: consecutiveFailures[url] ?? 0,
            lastStatus: consecutiveFailures[url, default: 0] > 0 ? "error" : "ok",
            lastItemCount: itemCount
        )
    }

    // MARK: - Private

    private func estimatedBufferNeeded() -> Int {
        let recent = consumptionTimestamps.filter { $0 > Date().addingTimeInterval(-120) }
        let rate = Double(recent.count) / 120.0 // scrolls per second over last 2 min
        let target = Int(rate * 180) // 3 min buffer
        return max(50, min(500, target))
    }

    private func distribution<T: Hashable>(of items: [FeedItem], key: (FeedItem) -> T) -> [T: Double] {
        guard !items.isEmpty else { return [:] }
        var counts: [T: Int] = [:]
        for item in items { counts[key(item), default: 0] += 1 }
        let total = Double(items.count)
        return counts.mapValues { Double($0) / total }
    }

    private func sqrtWeights(for sourcesByRegion: [String: [FeedSource]]) -> [String: Double] {
        sourcesByRegion.mapValues { sqrt(Double($0.count)) }
    }

    private func normalize(_ weights: [String: Double]) -> [String: Double] {
        let total = weights.values.reduce(0, +)
        guard total > 0 else { return weights }
        return weights.mapValues { $0 / total }
    }

    private func deficits(ideal: [String: Double], actual: [String: Double]) -> [String: Double] {
        var result: [String: Double] = [:]
        for (key, idealVal) in ideal {
            let actualVal = actual[key] ?? 0
            result[key] = idealVal - actualVal
        }
        return result
    }
}
