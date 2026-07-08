import Foundation

/// Selects which feed sources to fetch next based on reservoir entropy.
/// Uses √n fairness between regions, LRU ordering within regions,
/// and soft cooldown instead of hard timeouts.
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
        activeContentType: String? = nil  // "video", "audio", or nil for all
    ) -> [FeedSource] {
        // 1. Determine scope
        let regions = activeRegion.map { [$0] } ?? Array(sourcesByRegion.keys)
        guard !regions.isEmpty else { return [] }

        // 2. Measure consumption — how much buffer do we need?
        let bufferNeeded = estimatedBufferNeeded()
        let currentBuffer = reservoir.count
        guard currentBuffer < bufferNeeded else { return [] }

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

        // 6. Select sources that compensate deficits
        var selected: [FeedSource] = []
        var selectedURLs = Set<String>()
        let deficitNeeded = Int(ceil(Double(bufferNeeded - currentBuffer) / 3.0)) // ~3 items per source

        for _ in 0..<max(deficitNeeded, 10) {
            guard let best = bestSource(
                regions: regions,
                sourcesByRegion: sourcesByRegion,
                regionDeficits: regionDeficits,
                categoryDeficits: finalCategoryDeficits,
                selectedURLs: selectedURLs,
                activeContentType: activeContentType
            ) else { break }
            selected.append(best)
            selectedURLs.insert(best.url)
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

    private func bestSource(
        regions: [String],
        sourcesByRegion: [String: [FeedSource]],
        regionDeficits: [String: Double],
        categoryDeficits: [String: Double],
        selectedURLs: Set<String>,
        activeContentType: String?
    ) -> FeedSource? {
        var best: FeedSource?
        var bestScore = -Double.infinity

        for region in regions {
            guard let sources = sourcesByRegion[region] else { continue }
            for source in sources {
                guard !selectedURLs.contains(source.url) else { continue }
                // Check failure backoff
                let failures = consecutiveFailures[source.url] ?? 0
                if failures >= 3 {
                    let backoff = pow(2.0, Double(failures - 2)) * 60
                    if let last = lastFetchedAt[source.url],
                       Date().timeIntervalSince(last) < backoff {
                        continue // in backoff
                    }
                }
                // Deficits are (ideal - actual) and turn negative when a region
                // or category is over-represented. Clamp to 0: an
                // over-represented dimension should mean "no need" (score 0),
                // not a negative factor — otherwise two negative deficits
                // multiply into a positive score and the scheduler prefers the
                // very sources it already has too many of.
                let regionDeficit = max(0, regionDeficits[region] ?? 0)
                let catDeficit = max(0, categoryDeficits[source.category] ?? 0)
                // Content type boost: prefer sources matching active content filter
                let contentTypeBoost: Double
                switch activeContentType {
                case "video":  contentTypeBoost = source.isYouTube ? 3.0 : 1.0
                case "audio":  contentTypeBoost = 1.0  // no source-level podcast flag; item-level only
                case "text":   contentTypeBoost = source.isYouTube ? 0.3 : 1.0
                default:       contentTypeBoost = 1.0
                }
                // Soft cooldown: applies 0→1 weight over 30 min
                let timeFactor: Double
                if let last = lastFetchedAt[source.url] {
                    timeFactor = min(1.0, Date().timeIntervalSince(last) / 1800)
                } else {
                    timeFactor = 1.0 // never fetched → full priority
                }
                let score = regionDeficit * catDeficit * timeFactor * contentTypeBoost
                if score > bestScore {
                    bestScore = score
                    best = source
                }
            }
        }
        return best
    }
}
