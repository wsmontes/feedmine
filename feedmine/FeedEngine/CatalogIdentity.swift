import CryptoKit
import Foundation

enum FeedEngineError: Error, Equatable, Sendable {
    case identityCollision(kind: String, id: UInt32, existingKey: String, newKey: String)
    case sourceNotFound(SourceID)
    case unsupportedTimelineRepository
    case invalidCatalog(String)
}

enum CatalogIdentity {
    static func sourceKey(for declaredURL: String) -> SourceKey {
        SourceKey(canonicalURLKey(declaredURL))
    }

    static func nodeKey(pathComponents: [String]) -> NodeKey {
        NodeKey(pathComponents.joined(separator: "/"))
    }

    static func sourceID(for key: SourceKey) -> SourceID {
        SourceID(rawValue: stableUInt32Digest(key.rawValue, reservedZero: true))
    }

    static func nodeID(for key: NodeKey) -> CatalogNodeID {
        CatalogNodeID(rawValue: stableUInt32Digest(key.rawValue, reservedZero: true))
    }

    /// Conservative URL canonicalization for identity.
    ///
    /// Lowercases scheme/host and trims whitespace, but does not collapse
    /// http/https, strip www, remove queries, or rewrite paths.
    static func canonicalURLKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else { return trimmed }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        return components.string ?? trimmed
    }

    static func displayHost(for raw: String) -> String? {
        URLComponents(string: raw)?.host?.lowercased()
    }

    static func slug(_ raw: String) -> String {
        let folded = raw
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        let allowed = CharacterSet.alphanumerics
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "untitled" : collapsed
    }

    private static func stableUInt32Digest(_ raw: String, reservedZero: Bool) -> UInt32 {
        let digest = SHA256.hash(data: Data(raw.utf8))
        let value = digest.prefix(4).reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        if reservedZero, value == 0 { return 1 }
        return value
    }
}
