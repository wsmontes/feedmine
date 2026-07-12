//
//  Reservoir.swift
//  feedmine
//
//  Created by FeedMine Team on 4/7/25.
//

import Foundation

/// In-memory buffer with fairness interleave and source/region diversity.
/// Extracted from FeedLoader. Does NOT touch SQLite — only holds FeedItem arrays.
final class Reservoir {
    static let maxBuffer = 300
    static let pageSize = 20
    static let loadMoreThreshold = 5
    static let discardBatchSize = 50
    static let reservoirLowWatermark = 30
    static let safetyZoneRadius = 50
    static let maxReservoirSize = 500
    static let surfacedCooldown: TimeInterval = 1800

    private(set) var visibleItems: [FeedItem] = []
    private(set) var reservoir: [FeedItem] = []
    var reservoirCount: Int { reservoir.count }

    /// Next N items from the reservoir (not yet visible). Used for prefetching.
    func upcomingItems(_ count: Int) -> [FeedItem] {
        Array(reservoir.prefix(count))
    }

    private var surfacedTimestamps: [String: Date] = [:]
    /// Items the user has explicitly marked as read (readItemIDs from FeedStore).
    /// Read items deprecate harder than surfaced items — pushed to the stale bucket.
    var readItemIDs: Set<String> = []

    /// URL → region lookup, provided by SourceRegistry
    var sourceRegionMap: [String: String] = [:]

    // MARK: - Seed (cold/warm start)

    func seed(items: [FeedItem]) {
        let interleaved = interleave(items)
        let w = min(Self.pageSize, interleaved.count)
        visibleItems = Array(interleaved.prefix(w))
        reservoir = Array(interleaved.dropFirst(w))
        capReservoir()
        markAsSurfaced(visibleItems)
    }

    // MARK: - Append new items from fetch

    func append(_ items: [FeedItem]) {
        let visibleIDs = Set(visibleItems.map(\.id))
        let trulyNew = items.filter { !visibleIDs.contains($0.id) }
        guard !trulyNew.isEmpty else { return }
        // Interleave only the NEW items among themselves and append them to the
        // tail; do not re-interleave the whole reservoir. Re-interleaving here
        // reordered items the user was about to scroll into, so content shifted
        // under them right before a tap. dedupReservoir is order-preserving
        // (keeps the first occurrence), so the existing front stays put.
        reservoir.append(contentsOf: interleave(trulyNew))
        dedupReservoir()
        capReservoir()
    }

    // MARK: - Scroll: move from reservoir to visible

    func moveToVisible(count: Int) {
        guard !reservoir.isEmpty else { return }
        // No periodic reshuffle here. Re-interleaving the reservoir every few
        // pages reordered upcoming items as the user scrolled toward them —
        // content shifted before they could tap. Diversity comes from
        // seed()/append(); order stays stable once set.
        let visibleIDs = Set(visibleItems.map(\.id))
        // Remove items already in visible to prevent duplicates
        reservoir.removeAll { visibleIDs.contains($0.id) }
        guard !reservoir.isEmpty else { return }
        let toMove = min(count, reservoir.count)
        let batch = Array(reservoir.prefix(toMove))
        visibleItems.append(contentsOf: batch)
        reservoir.removeFirst(toMove)
        markAsSurfaced(batch)
    }

    // MARK: - Trim buffer

    func trimBuffer(currentVisibleIndex: Int) {
        guard visibleItems.count > Self.maxBuffer else { return }
        let excess = visibleItems.count - Self.maxBuffer
        let toDiscard = min(Self.discardBatchSize, excess)
        // Only ever trim from the TAIL, and only items safely BELOW the viewport
        // (beyond the safety zone). Removing from the HEAD of a
        // ScrollView+LazyVStack shifts the scroll offset and makes the feed jump
        // under the reader — never do that. Tail items are ahead of the user and
        // get re-supplied from the reservoir when scrolled into. The head (already
        // seen) grows with scroll depth; that memory cost is accepted so that what
        // the user has scrolled past never moves. (Feed is sacred.)
        let safeEnd = min(visibleItems.count, currentVisibleIndex + Self.safetyZoneRadius)
        guard safeEnd < visibleItems.count else { return }
        let belowToDiscard = min(toDiscard, visibleItems.count - safeEnd)
        if belowToDiscard > 0 {
            visibleItems.removeLast(belowToDiscard)
        }
    }

    // MARK: - Remove a single source (toggle one feed OFF)

    /// Remove only the items belonging to one feed URL, then top up the visible
    /// page from the reservoir if it fell below a full page. Unlike
    /// `removeRegion`, this leaves sibling feeds in the same region untouched —
    /// disabling one feed must not empty the whole region from the buffer.
    func removeSource(_ sourceURL: String) {
        let isDisabled: (FeedItem) -> Bool = { $0.sourceURL == sourceURL }
        visibleItems.removeAll(where: isDisabled)
        reservoir.removeAll(where: isDisabled)
        if visibleItems.count < Self.pageSize && !reservoir.isEmpty {
            let needed = min(Self.pageSize - visibleItems.count, reservoir.count)
            let batch = Array(reservoir.prefix(needed))
            visibleItems.append(contentsOf: batch)
            reservoir.removeFirst(needed)
            markAsSurfaced(batch)
        }
    }

    // MARK: - Remove region (toggle OFF)

    func removeRegion(_ region: String) {
        let isDisabled: (FeedItem) -> Bool = { [self] item in
            let itemRegion = sourceRegionMap[item.sourceURL] ?? "global"
            return itemRegion == region || itemRegion.hasPrefix(region + "/")
        }
        visibleItems.removeAll(where: isDisabled)
        reservoir.removeAll(where: isDisabled)
        // Top up visible if depleted
        if visibleItems.count < Self.pageSize && !reservoir.isEmpty {
            // Clamp to reservoir.count: removeFirst(k) crashes when k exceeds
            // the count, and the reservoir may hold fewer than `needed` items
            // after a region is removed.
            let needed = min(Self.pageSize - visibleItems.count, reservoir.count)
            let batch = Array(reservoir.prefix(needed))
            visibleItems.append(contentsOf: batch)
            reservoir.removeFirst(needed)
        }
    }

    // MARK: - Clear + emergency

    func clear() {
        visibleItems.removeAll()
        reservoir.removeAll()
        surfacedTimestamps.removeAll()
    }

    func emergencyTrim() {
        let safeCount = Self.safetyZoneRadius * 2
        if visibleItems.count > safeCount {
            visibleItems = Array(visibleItems.suffix(safeCount))
        }
        reservoir.removeAll()
    }

    /// Shake-to-refresh: dump visible items back into reservoir, re-interleave,
    /// and pull a fresh page. Items already surfaced get pushed to the back.
    func shakeReshuffle() {
        guard !visibleItems.isEmpty || !reservoir.isEmpty else { return }
        reservoir.append(contentsOf: visibleItems)
        visibleItems.removeAll()
        reservoir = interleave(reservoir)
        capReservoir()
        let w = min(Self.pageSize, reservoir.count)
        visibleItems = Array(reservoir.prefix(w))
        reservoir.removeFirst(w)
        markAsSurfaced(visibleItems)
    }

    // MARK: - Interleave

    private func interleave(_ items: [FeedItem]) -> [FeedItem] {
        guard items.count > 1 else { return items }
        var bySource: [String: [FeedItem]] = [:]
        for item in items {
            bySource[item.sourceURL, default: []].append(item)
        }
        guard bySource.count > 1 else {
            return interleaveByTypeCategory(items)
        }
        // Within each source: surfaced → stale → recent, each spread by type+category
        let surfacedCutoff = Date().addingTimeInterval(-Self.surfacedCooldown)
        let staleNewsCutoff = Date().addingTimeInterval(-86400)
        let staleEvergreenCutoff = Date().addingTimeInterval(-604800)
        for key in bySource.keys {
            let bucket = bySource[key]!
            // Read items: always stale regardless of timestamp
            let readIDs = bucket.filter { readItemIDs.contains($0.id) }.map(\.id)
            let surfacedIDs = Set(bucket.filter { item in
                guard let ts = surfacedTimestamps[item.id] else { return false }
                return ts > surfacedCutoff
            }.map(\.id))
            let staleIDs = Set(bucket.filter { item in
                if surfacedIDs.contains(item.id) || readIDs.contains(item.id) { return false }
                let cutoff = item.isTimeless ? staleEvergreenCutoff : staleNewsCutoff
                return item.publishedAt < cutoff
            }.map(\.id) + readIDs)
            let recent = interleaveByTypeCategory(bucket.filter { !surfacedIDs.contains($0.id) && !staleIDs.contains($0.id) }.shuffled())
            let stale = interleaveByTypeCategory(bucket.filter { staleIDs.contains($0.id) }.shuffled())
            let surfaced = interleaveByTypeCategory(bucket.filter { surfacedIDs.contains($0.id) }.shuffled())
            bySource[key] = recent + stale + surfaced
        }
        // Weighted slots → spread → round-robin
        let minCount = max(1, bySource.values.map(\.count).min() ?? 1)
        let weights: [String: Int] = bySource.mapValues { min(5, max(1, $0.count / minCount)) }
        var slots: [String] = []
        for (sourceURL, srcItems) in bySource where !srcItems.isEmpty {
            let w = weights[sourceURL] ?? 1
            for _ in 0..<w { slots.append(sourceURL) }
        }
        slots = spreadSlots(slots)
        slots = spreadSlotsByCountry(slots)
        var result: [FeedItem] = []
        result.reserveCapacity(items.count)
        var indices: [String: Int] = Dictionary(uniqueKeysWithValues: bySource.keys.map { ($0, 0) })
        var added = true
        while added {
            added = false
            for sourceURL in slots {
                guard let list = bySource[sourceURL], indices[sourceURL]! < list.count else { continue }
                result.append(list[indices[sourceURL]!])
                indices[sourceURL]! += 1
                added = true
            }
        }
        return spreadConsecutive(result)
    }

    /// Post-processing pass: scan for back-to-back items that share an
    /// attribute (source, type, category) and swap with a later item that
    /// breaks the run. O(n) single pass — maintains a look-ahead pointer
    /// instead of scanning from i+2 each time.
    private func spreadConsecutive(_ items: [FeedItem]) -> [FeedItem] {
        guard items.count > 2 else { return items }
        var result = items
        var lookAhead = 2
        for i in 0..<(result.count - 1) {
            let a = result[i], b = result[i + 1]
            let clash = a.sourceURL == b.sourceURL
                || a.category == b.category
                || (a.isYouTube && b.isYouTube)
                || (a.isPodcast && b.isPodcast)
                || (!a.isYouTube && !a.isPodcast && !b.isYouTube && !b.isPodcast)
            guard clash else { continue }
            // Advance look-ahead pointer (never rewinds)
            lookAhead = max(lookAhead, i + 2)
            while lookAhead < result.count {
                let c = result[lookAhead]
                if a.sourceURL != c.sourceURL && b.sourceURL != c.sourceURL
                    && a.category != c.category
                    && !(a.isYouTube && c.isYouTube) && !(a.isPodcast && c.isPodcast)
                    && !(b.isYouTube && c.isYouTube) && !(b.isPodcast && c.isPodcast) {
                    result.swapAt(i + 1, lookAhead)
                    break
                }
                lookAhead += 1
            }
            if lookAhead >= result.count { break }
        }
        return result
    }

    private func interleaveByTypeCategory(_ items: [FeedItem]) -> [FeedItem] {
        guard items.count > 1 else { return items }
        var buckets: [String: [FeedItem]] = [:]
        for item in items {
            let type = item.isPodcast ? "audio" : (item.isYouTube ? "video" : "text")
            buckets["\(type):\(item.category)", default: []].append(item)
        }
        guard buckets.count > 1 else { return items.shuffled() }
        for key in buckets.keys { buckets[key] = buckets[key]?.shuffled() }
        var result: [FeedItem] = []
        result.reserveCapacity(items.count)
        let keys = buckets.keys.shuffled()
        var indices = Dictionary(uniqueKeysWithValues: keys.map { ($0, 0) })
        var added = true
        while added {
            added = false
            for key in keys {
                guard let list = buckets[key], indices[key]! < list.count else { continue }
                result.append(list[indices[key]!])
                indices[key]! += 1
                added = true
            }
        }
        return result
    }

    private func spreadSlots(_ slots: [String]) -> [String] {
        var groups: [String: [String]] = [:]
        for slot in slots { groups[slot, default: []].append(slot) }
        guard groups.count > 1 else { return slots }
        for key in groups.keys { groups[key] = groups[key]?.shuffled() }
        var result: [String] = []
        result.reserveCapacity(slots.count)
        let keys = groups.keys.shuffled()
        var indices = Dictionary(uniqueKeysWithValues: keys.map { ($0, 0) })
        var added = true
        while added {
            added = false
            for key in keys {
                guard let list = groups[key], indices[key]! < list.count else { continue }
                result.append(list[indices[key]!])
                indices[key]! += 1
                added = true
            }
        }
        return result
    }

    private func spreadSlotsByCountry(_ slots: [String]) -> [String] {
        guard slots.count > 2 else { return slots }
        var result = slots
        var pass = 0
        var swapped = true
        while swapped && pass < 3 {
            swapped = false; pass += 1
            for i in 0..<(result.count - 1) {
                let countryA = sourceRegionMap[result[i]] ?? "global"
                let countryB = sourceRegionMap[result[i + 1]] ?? "global"
                guard countryA == countryB else { continue }
                var swapIdx: Int?
                for j in (i + 2)..<result.count {
                    if (sourceRegionMap[result[j]] ?? "global") != countryA { swapIdx = j; break }
                }
                if swapIdx == nil {
                    for j in stride(from: i - 1, through: 0, by: -1) {
                        if (sourceRegionMap[result[j]] ?? "global") != countryA { swapIdx = j; break }
                    }
                }
                if let j = swapIdx { result.swapAt(i + 1, j); swapped = true }
            }
        }
        return result
    }

    private func dedupReservoir() {
        var seen = Set<String>()
        reservoir = reservoir.filter { seen.insert($0.id).inserted }
    }

    private func capReservoir() {
        guard reservoir.count > Self.maxReservoirSize else { return }
        var bySource: [String: [FeedItem]] = [:]
        for item in reservoir { bySource[item.sourceURL, default: []].append(item) }
        let sourceCount = bySource.count
        guard sourceCount > 1 else {
            reservoir = Array(reservoir.prefix(Self.maxReservoirSize))
            return
        }
        let floorPerSource = 1
        let floorSlots = min(sourceCount * floorPerSource, Self.maxReservoirSize)
        let proportionalSlots = Self.maxReservoirSize - floorSlots
        var selected: [FeedItem] = []
        var remainingBySource: [String: [FeedItem]] = [:]
        for (sourceURL, items) in bySource {
            let take = min(floorPerSource, items.count)
            selected.append(contentsOf: items.prefix(take))
            if items.count > take { remainingBySource[sourceURL] = Array(items.dropFirst(take)) }
        }
        if proportionalSlots > 0, !remainingBySource.isEmpty {
            let totalRemaining = remainingBySource.values.map(\.count).reduce(0, +)
            for (sourceURL, items) in remainingBySource {
                let fraction = Double(items.count) / Double(max(1, totalRemaining))
                let extra = min(Int(fraction * Double(proportionalSlots)), items.count)
                if extra > 0 {
                    selected.append(contentsOf: items.prefix(extra))
                    if items.count > extra {
                        remainingBySource[sourceURL] = Array(items.dropFirst(extra))
                    } else {
                        remainingBySource.removeValue(forKey: sourceURL)
                    }
                }
            }
        }
        if selected.count < Self.maxReservoirSize, !remainingBySource.isEmpty {
            let keys = remainingBySource.keys.shuffled()
            var indices = Dictionary(uniqueKeysWithValues: keys.map { ($0, 0) })
            while selected.count < Self.maxReservoirSize {
                var added = false
                for key in keys {
                    guard let list = remainingBySource[key],
                          indices[key]! < list.count,
                          selected.count < Self.maxReservoirSize else { continue }
                    selected.append(list[indices[key]!])
                    indices[key]! += 1
                    added = true
                }
                if !added { break }
            }
        }
        // Keep the selected diverse subset, but in the reservoir's existing
        // order — re-interleaving here would reorder items near the viewport,
        // the same instability fixed in append()/moveToVisible().
        let keepIDs = Set(selected.map(\.id))
        reservoir = reservoir.filter { keepIDs.contains($0.id) }
    }

    private func markAsSurfaced(_ items: [FeedItem]) {
        let now = Date()
        for item in items {
            if surfacedTimestamps[item.id] == nil {
                surfacedTimestamps[item.id] = now
            }
        }
        if surfacedTimestamps.count > 2000 {
            let cutoff = now.addingTimeInterval(-Self.surfacedCooldown)
            surfacedTimestamps = surfacedTimestamps.filter { $0.value > cutoff }
        }
    }
}
