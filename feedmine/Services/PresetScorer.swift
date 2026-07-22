import Foundation

/// Stateless utility that builds a preset multiplier dictionary for the fetch pipeline.
///
/// FeedStore calls `buildMultipliers` when the active preset changes (infrequent).
/// The resulting `[String: Double]` dictionary is then passed to SourceScheduler,
/// Reservoir, coverage mining, progressive fetch, and cold start — all O(1) lookups.
enum PresetScorer {
    /// Build a dictionary mapping source URL → scoring multiplier for the given preset.
    ///
    /// - Parameters:
    ///   - preset: The active preset selector
    ///   - sources: The full list of enabled sources from SourceRegistry
    ///   - collectionMemberURLs: Normalized URLs of sources in the active collection (only used for `.collection` presets)
    /// - Returns: Dictionary of source URL → multiplier. Missing keys default to 1.0.
    static func buildMultipliers(
        preset: PresetSelector,
        sources: [FeedSource],
        collectionMemberURLs: Set<String> = []
    ) -> [String: Double] {
        switch preset {
        case .everything:
            // Empty dict — all lookups fall through to 1.0 default.
            // This makes "Everything" zero-cost in hot paths.
            return [:]

        case .editorial(let feedPreset):
            return buildEditorialMultipliers(preset: feedPreset, sources: sources)

        case .collection(_, _):
            return buildCollectionMultipliers(memberURLs: collectionMemberURLs)
        }
    }

    // MARK: - Private

    private static func buildEditorialMultipliers(
        preset: FeedPreset,
        sources: [FeedSource]
    ) -> [String: Double] {
        let scoring = editorialScoring(for: preset)
        var dict: [String: Double] = [:]
        dict.reserveCapacity(sources.count)

        for source in sources {
            let mult = scoring.multiplier(for: source)
            if mult != 1.0 {
                dict[source.url] = mult
            }
            // Sources at exactly 1.0 are omitted — the caller's nil-coalescing
            // default (?? 1.0) handles them without taking dictionary space.
        }

        return dict
    }

    private static func buildCollectionMultipliers(
        memberURLs: Set<String>
    ) -> [String: Double] {
        guard !memberURLs.isEmpty else { return [:] }
        var dict: [String: Double] = [:]
        dict.reserveCapacity(memberURLs.count)
        for url in memberURLs {
            dict[url] = 2.0
        }
        return dict
    }

    /// Maps each FeedPreset to its EditorialScoring definition.
    /// Inline to keep the single source of truth in FeedPreset.swift's static lets.
    private static func editorialScoring(for preset: FeedPreset) -> EditorialScoring {
        switch preset {
        case .everything:     return .everything
        case .highQuality:    return .highQuality
        case .techAndScience: return .techAndScience
        case .currentEvents:  return .currentEvents
        case .evergreen:      return .evergreen
        case .globalMix:      return .globalMix
        }
    }
}
