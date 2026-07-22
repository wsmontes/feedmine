import Foundation

// MARK: - Feed Preset Selector

/// Editorial presets that define scoring profiles for feed sources.
/// Each preset is an additive scoring multiplier — it boosts preferred sources
/// without excluding any. Floor is always 1.0 to guarantee permissive behavior.
enum FeedPreset: String, Codable, Sendable, CaseIterable, Identifiable {
    /// No scoring multiplier — all sources treated equally. Backward-compatible
    /// with the old "Selected Feeds" toggle ON behavior.
    case everything = "Everything"

    /// Prioritizes sources with high `qualityScore` plus evergreen content.
    case highQuality = "High Quality"

    /// Boosts sources tagged with technology, science, and engineering topics.
    case techAndScience = "Tech & Science"

    /// Favors current-sensitive, prolific sources — breaking news and live coverage.
    case currentEvents = "Current Events"

    /// Prefers evergreen and periodic content that stays relevant longer.
    case evergreen = "Evergreen"

    /// Mild quality weighting with broad diversity across all topics.
    case globalMix = "Global Mix"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .everything:     return "circle.grid.3x3.fill"
        case .highQuality:    return "star.fill"
        case .techAndScience: return "gearshape.2.fill"
        case .currentEvents:  return "newspaper.fill"
        case .evergreen:      return "leaf.fill"
        case .globalMix:      return "globe.americas.fill"
        }
    }

    var shortDescription: String {
        switch self {
        case .everything:     return "All sources equally"
        case .highQuality:    return "Top-rated sources first"
        case .techAndScience: return "Technology & science focus"
        case .currentEvents:  return "Breaking news & live coverage"
        case .evergreen:      return "Timeless, lasting content"
        case .globalMix:      return "Broad, diverse coverage"
        }
    }
}

// MARK: - Persisted Selector

/// The active preset choice, persisted to UserDefaults.
/// Supports editorial presets, user-created collections, and the "everything" default.
enum PresetSelector: Codable, Sendable, Hashable {
    case everything
    case editorial(FeedPreset)
    case collection(collectionID: Int64, collectionName: String)

    var displayName: String {
        switch self {
        case .everything:               return "Everything"
        case .editorial(let preset):    return preset.rawValue
        case .collection(_, let name):  return name
        }
    }

    var icon: String {
        switch self {
        case .everything:          return "circle.grid.3x3.fill"
        case .editorial(let p):    return p.icon
        case .collection:          return "folder.fill"
        }
    }

    var isCollection: Bool {
        if case .collection = self { return true }
        return false
    }

    var collectionID: Int64? {
        if case .collection(let id, _) = self { return id }
        return nil
    }
}

// MARK: - Editorial Scoring Profile

/// Encodes the scoring policy for an editorial preset. All fields are optional
/// and default to no-op values, making it easy to define presets that only
/// tweak specific dimensions.
struct EditorialScoring: Sendable {
    /// Weight applied to the source's `qualityScore` (0–100 scale).
    /// The contribution is `qualityWeight * (qualityScore / 100.0)`
    /// added to the base multiplier.
    var qualityWeight: Double = 0.0

    /// Per-tag bonus multipliers. Applied multiplicatively for each matching tag.
    var tagBoosts: [String: Double] = [:]

    /// Per-nature multipliers. Nature values found in OPML data:
    /// `current-sensitive`, `evergreen`, `periodic`, `personal`
    var natureBoosts: [String: Double] = [:]

    /// Per-activity multipliers. Activity values found in OPML data:
    /// `active`, `prolific`, `dormant`, `quiet`
    var activityBoosts: [String: Double] = [:]

    /// Per-category (OPML subcategory) multipliers.
    var categoryBoosts: [String: Double] = [:]

    /// The minimum multiplier any source can receive.
    /// Always 1.0 — guarantees permissive, never-exclude behavior.
    var floorMultiplier: Double = 1.0

    /// Base multiplier for sources that don't match any boost criteria.
    var defaultMultiplier: Double = 1.0

    // MARK: - Scoring

    /// Compute the final multiplier for a given source. Returns a value ≥ floorMultiplier.
    func multiplier(for source: FeedSource) -> Double {
        var mult = defaultMultiplier

        // Quality score — additive contribution based on editorial rating
        if qualityWeight > 0, let qs = source.qualityScore {
            mult += qualityWeight * (Double(qs) / 100.0)
        }

        // Tag boosts — multiplicative, each matching tag stacks
        for tag in source.tags {
            if let boost = tagBoosts[tag] {
                mult *= boost
            }
        }

        // Nature boost — multiplicative, single match
        if let nature = source.nature, let boost = natureBoosts[nature] {
            mult *= boost
        }

        // Activity boost — multiplicative, single match
        if let activity = source.activity, let boost = activityBoosts[activity] {
            mult *= boost
        }

        // Category boost — multiplicative, single match
        if let boost = categoryBoosts[source.category] {
            mult *= boost
        }

        return max(mult, floorMultiplier)
    }
}

// MARK: - Predefined Scoring Profiles

extension EditorialScoring {
    /// Default: every source gets 1.0x. Identical to the old toggle ON behavior.
    static let everything = EditorialScoring(floorMultiplier: 1.0)

    /// Prioritizes curator-rated quality. High qualityScore sources get up to
    /// ~2.8x boost (qualityWeight 2.0 × 94/100 = +1.88 on top of 1.0 base).
    /// Evergreen gets a mild preference over current-sensitive churn.
    static let highQuality = EditorialScoring(
        qualityWeight: 2.0,
        natureBoosts: ["evergreen": 1.3, "periodic": 1.1],
        activityBoosts: ["prolific": 1.1, "active": 1.05],
        floorMultiplier: 1.0
    )

    /// Boosts sources whose tags or categories align with tech and science.
    /// Tags are matched against the free-form `category` attribute from OPML,
    /// which uses lowercase, space-separated multi-word tokens.
    static let techAndScience = EditorialScoring(
        qualityWeight: 1.5,
        tagBoosts: [
            "science": 1.8, "technology": 1.8, "physics": 2.0,
            "space": 2.0, "astronomy": 2.0, "biotech": 2.0,
            "robotics": 2.0, "computing": 1.8, "engineering": 1.5,
            "research": 1.3, "data science": 2.0, "machine learning": 2.0,
            "artificial intelligence": 2.0, "neuroscience": 2.0,
            "quantum": 2.0, "climate": 1.8, "energy": 1.5,
            "mathematics": 1.8, "chemistry": 1.8, "biology": 1.5,
        ],
        categoryBoosts: [
            "Science": 2.0,
            "Technology": 1.8,
            "Earth & Life Sciences": 1.8,
            "Physics & Mathematics": 2.0,
            "Engineering & Innovation": 1.8,
            "Space & Astronomy": 2.0,
            "Computing & AI": 2.0,
            "Energy & Environment": 1.5,
            "Health & Medicine": 1.3,
        ],
        floorMultiplier: 1.0
    )

    /// Favors current-sensitive sources that publish frequently — breaking news,
    /// live coverage, daily updates. Evergreen and dormant sources get no penalty
    /// (floor is still 1.0) but don't receive the boost.
    static let currentEvents = EditorialScoring(
        qualityWeight: 0.8,
        natureBoosts: ["current-sensitive": 2.0],
        activityBoosts: ["prolific": 1.5, "active": 1.3],
        floorMultiplier: 1.0
    )

    /// Prefers evergreen and periodic content that ages well. Current-sensitive
    /// sources still appear but without the boost. Dormant sources get a slight
    /// bump because their infrequent publishing often means higher editorial
    /// investment per piece.
    static let evergreen = EditorialScoring(
        qualityWeight: 1.5,
        natureBoosts: ["evergreen": 2.5, "periodic": 1.5],
        activityBoosts: ["dormant": 1.2, "quiet": 1.1],
        floorMultiplier: 1.0
    )

    /// Broad diversity with a mild quality signal. Designed as a "better than
    /// nothing" default that surfaces higher-quality content without narrowing
    /// the topic scope. Good first-run preset until the user explores curation.
    static let globalMix = EditorialScoring(
        qualityWeight: 1.0,
        natureBoosts: ["evergreen": 1.2, "periodic": 1.1],
        floorMultiplier: 1.0
    )
}
