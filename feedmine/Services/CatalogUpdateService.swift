import CryptoKit
import Foundation

struct CatalogUpdateFile: Codable, Equatable, Sendable {
    let path: String
    let sha256: String
    let bytes: Int
}

struct CatalogUpdateManifest: Codable, Equatable, Sendable {
    static let supportedSchemaVersion = 1

    let schemaVersion: Int
    let revision: Int
    let generatedAt: String
    let sourceCount: Int
    let fileCount: Int
    let files: [CatalogUpdateFile]

    func validate() throws {
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw CatalogUpdateError.unsupportedSchema(schemaVersion)
        }
        guard revision > 0, sourceCount > 0, fileCount == files.count, !files.isEmpty else {
            throw CatalogUpdateError.invalidManifest("invalid revision or catalog counts")
        }

        var uniquePaths = Set<String>()
        for file in files {
            guard Self.isSafeOPMLPath(file.path),
                  uniquePaths.insert(file.path).inserted,
                  file.bytes > 0,
                  file.sha256.count == 64,
                  file.sha256.allSatisfy({ $0.isHexDigit }) else {
                throw CatalogUpdateError.invalidManifest("invalid file entry: \(file.path)")
            }
        }
    }

    private static func isSafeOPMLPath(_ path: String) -> Bool {
        guard path.hasPrefix("Feeds/"), path.hasSuffix(".opml"), !path.hasPrefix("/") else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.count >= 2
            && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

struct CatalogSnapshot: Sendable {
    let feedsURL: URL
    let catalogURL: URL
    let manifestURL: URL
    let manifest: CatalogUpdateManifest
}

struct CatalogRuntimePaths: Sendable {
    let managedRootURL: URL
    let bundledFeedsURL: URL?
    let bundledCatalogURL: URL?
    let bundledManifestURL: URL?

    static var live: CatalogRuntimePaths {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let resources = Bundle.main.resourceURL
        return CatalogRuntimePaths(
            managedRootURL: applicationSupport.appendingPathComponent("ManagedCatalog", isDirectory: true),
            bundledFeedsURL: resources?.appendingPathComponent("Feeds", isDirectory: true),
            bundledCatalogURL: Bundle.main.url(
                forResource: "catalog",
                withExtension: "sqlite",
                subdirectory: "FeedEngine"
            ),
            bundledManifestURL: Bundle.main.url(
                forResource: "catalog-update-manifest",
                withExtension: "json",
                subdirectory: "FeedEngine"
            )
        )
    }

    var currentURL: URL {
        managedRootURL.appendingPathComponent("current", isDirectory: true)
    }

    func activeSnapshot(fileManager: FileManager = .default) -> CatalogSnapshot? {
        let bundled = snapshot(
            feedsURL: bundledFeedsURL,
            catalogURL: bundledCatalogURL,
            manifestURL: bundledManifestURL,
            fileManager: fileManager
        )
        let localRoot = currentURL
        let local = snapshot(
            feedsURL: localRoot.appendingPathComponent("Feeds", isDirectory: true),
            catalogURL: localRoot.appendingPathComponent("catalog.sqlite"),
            manifestURL: localRoot.appendingPathComponent("manifest.json"),
            fileManager: fileManager
        )

        switch (bundled, local) {
        case let (bundle?, local?):
            return local.manifest.revision >= bundle.manifest.revision ? local : bundle
        case let (bundle?, nil):
            return bundle
        case let (nil, local?):
            return local
        case (nil, nil):
            return nil
        }
    }

    private func snapshot(
        feedsURL: URL?,
        catalogURL: URL?,
        manifestURL: URL?,
        fileManager: FileManager
    ) -> CatalogSnapshot? {
        guard let feedsURL, let catalogURL, let manifestURL,
              fileManager.fileExists(atPath: feedsURL.path),
              fileManager.fileExists(atPath: catalogURL.path),
              fileManager.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(CatalogUpdateManifest.self, from: data),
              (try? manifest.validate()) != nil else { return nil }
        return CatalogSnapshot(
            feedsURL: feedsURL,
            catalogURL: catalogURL,
            manifestURL: manifestURL,
            manifest: manifest
        )
    }
}

enum CatalogRuntime {
    static func activeSnapshot() -> CatalogSnapshot? {
        CatalogRuntimePaths.live.activeSnapshot()
    }

    static func activeFeedsURL() -> URL? {
        activeSnapshot()?.feedsURL
            ?? Bundle.main.resourceURL?.appendingPathComponent("Feeds", isDirectory: true)
    }

    static func activeCatalogURL() -> URL? {
        activeSnapshot()?.catalogURL
            ?? Bundle.main.url(forResource: "catalog", withExtension: "sqlite", subdirectory: "FeedEngine")
    }

    static func activeManifest() -> CatalogUpdateManifest? {
        activeSnapshot()?.manifest
    }
}

protocol CatalogUpdateTransport: Sendable {
    func data(from url: URL) async throws -> Data
}

struct URLSessionCatalogUpdateTransport: CatalogUpdateTransport {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 45
        configuration.waitsForConnectivity = false
        configuration.networkServiceType = .background
        session = URLSession(configuration: configuration)
    }

    func data(from url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CatalogUpdateError.badHTTPResponse((response as? HTTPURLResponse)?.statusCode)
        }
        return data
    }
}

enum CatalogUpdateOutcome: Equatable, Sendable {
    case current(revision: Int)
    case updated(fromRevision: Int, toRevision: Int, changedFiles: Int, deletedFiles: Int)
}

enum CatalogUpdateError: Error, Equatable, LocalizedError, Sendable {
    case noLocalSnapshot
    case unsupportedSchema(Int)
    case invalidManifest(String)
    case badHTTPResponse(Int?)
    case revisionCollision(Int)
    case checksumMismatch(String)
    case sizeMismatch(String)
    case compiledSourceCount(expected: Int, actual: Int)
    case activationFailed(String)

    var errorDescription: String? {
        switch self {
        case .noLocalSnapshot:
            return "No valid bundled or local catalog snapshot is available."
        case .unsupportedSchema(let version):
            return "Unsupported catalog update schema \(version)."
        case .invalidManifest(let reason):
            return "Invalid catalog update manifest: \(reason)."
        case .badHTTPResponse(let status):
            return "Catalog server returned HTTP \(status.map(String.init) ?? "unknown")."
        case .revisionCollision(let revision):
            return "Catalog revision \(revision) has conflicting contents."
        case .checksumMismatch(let path):
            return "Catalog file failed checksum validation: \(path)."
        case .sizeMismatch(let path):
            return "Catalog file failed size validation: \(path)."
        case .compiledSourceCount(let expected, let actual):
            return "Compiled catalog contains \(actual) sources; expected \(expected)."
        case .activationFailed(let reason):
            return "Catalog activation failed: \(reason)."
        }
    }
}

actor CatalogUpdateService {
    static let shared = CatalogUpdateService()

    private static let defaultRemoteRoot = URL(
        string: "https://raw.githubusercontent.com/wawasoft/feed-repository/main/"
    )!

    private let paths: CatalogRuntimePaths
    private let remoteRootURL: URL
    private let transport: any CatalogUpdateTransport
    private let fileManager: FileManager

    init(
        paths: CatalogRuntimePaths = .live,
        remoteRootURL: URL = CatalogUpdateService.defaultRemoteRoot,
        transport: any CatalogUpdateTransport = URLSessionCatalogUpdateTransport(),
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.remoteRootURL = remoteRootURL
        self.transport = transport
        self.fileManager = fileManager
    }

    func updateIfAvailable() async throws -> CatalogUpdateOutcome {
        guard let active = paths.activeSnapshot(fileManager: fileManager) else {
            throw CatalogUpdateError.noLocalSnapshot
        }

        let manifestData = try await transport.data(from: remoteRootURL.appendingPathComponent("manifest.json"))
        guard manifestData.count <= 5_000_000 else {
            throw CatalogUpdateError.invalidManifest("manifest exceeds 5 MB")
        }
        let remote = try JSONDecoder().decode(CatalogUpdateManifest.self, from: manifestData)
        try remote.validate()

        if remote.revision < active.manifest.revision {
            return .current(revision: active.manifest.revision)
        }
        if remote.revision == active.manifest.revision {
            guard remote == active.manifest else {
                throw CatalogUpdateError.revisionCollision(remote.revision)
            }
            return .current(revision: remote.revision)
        }

        try fileManager.createDirectory(at: paths.managedRootURL, withIntermediateDirectories: true)
        let stagingURL = paths.managedRootURL.appendingPathComponent(
            "staging-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        var shouldRemoveStaging = true
        defer {
            if shouldRemoveStaging {
                try? fileManager.removeItem(at: stagingURL)
            }
        }

        let stagedFeedsURL = stagingURL.appendingPathComponent("Feeds", isDirectory: true)
        try fileManager.copyItem(at: active.feedsURL, to: stagedFeedsURL)

        let expectedPaths = Set(remote.files.map(\.path))
        try removeFilesNotPresent(in: expectedPaths, stagingURL: stagingURL)

        var changedFileCount = 0
        for entry in remote.files.sorted(by: { $0.path < $1.path }) {
            let destination = Self.appending(relativePath: entry.path, to: stagingURL)
            if try fileMatches(entry, at: destination) {
                continue
            }

            let data = try await transport.data(from: Self.appending(relativePath: entry.path, to: remoteRootURL))
            guard data.count == entry.bytes else {
                throw CatalogUpdateError.sizeMismatch(entry.path)
            }
            guard Self.sha256(data) == entry.sha256.lowercased() else {
                throw CatalogUpdateError.checksumMismatch(entry.path)
            }
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
            changedFileCount += 1
        }

        for entry in remote.files {
            let fileURL = Self.appending(relativePath: entry.path, to: stagingURL)
            guard try fileMatches(entry, at: fileURL) else {
                throw CatalogUpdateError.checksumMismatch(entry.path)
            }
        }

        let catalogURL = stagingURL.appendingPathComponent("catalog.sqlite")
        let report = try await SQLiteCatalogCompiler(
            input: .opmlRoot(stagedFeedsURL),
            databaseURL: catalogURL
        ).compileFull()
        guard report.sourceCount == remote.sourceCount else {
            throw CatalogUpdateError.compiledSourceCount(
                expected: remote.sourceCount,
                actual: report.sourceCount
            )
        }

        try manifestData.write(
            to: stagingURL.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        let deletedFileCount = max(0, active.manifest.fileCount - expectedPaths.intersection(
            Set(active.manifest.files.map(\.path))
        ).count)
        try activate(stagingURL: stagingURL)
        shouldRemoveStaging = false

        return .updated(
            fromRevision: active.manifest.revision,
            toRevision: remote.revision,
            changedFiles: changedFileCount,
            deletedFiles: deletedFileCount
        )
    }

    private func removeFilesNotPresent(in expectedPaths: Set<String>, stagingURL: URL) throws {
        let feedsURL = stagingURL.appendingPathComponent("Feeds", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: feedsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var obsolete: [URL] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let relative = "Feeds/" + fileURL.path.replacingOccurrences(of: feedsURL.path + "/", with: "")
            if !expectedPaths.contains(relative) {
                obsolete.append(fileURL)
            }
        }
        for fileURL in obsolete {
            try fileManager.removeItem(at: fileURL)
        }
    }

    private func fileMatches(_ entry: CatalogUpdateFile, at url: URL) throws -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard values.fileSize == entry.bytes else { return false }
        return try Self.sha256(Data(contentsOf: url)) == entry.sha256.lowercased()
    }

    private func activate(stagingURL: URL) throws {
        let currentURL = paths.currentURL
        let backupURL = paths.managedRootURL.appendingPathComponent("backup", isDirectory: true)
        try? fileManager.removeItem(at: backupURL)

        if fileManager.fileExists(atPath: currentURL.path) {
            try fileManager.moveItem(at: currentURL, to: backupURL)
        }
        do {
            try fileManager.moveItem(at: stagingURL, to: currentURL)
            try? fileManager.removeItem(at: backupURL)
        } catch {
            if fileManager.fileExists(atPath: backupURL.path),
               !fileManager.fileExists(atPath: currentURL.path) {
                try? fileManager.moveItem(at: backupURL, to: currentURL)
            }
            throw CatalogUpdateError.activationFailed(error.localizedDescription)
        }
    }

    private static func appending(relativePath: String, to root: URL) -> URL {
        relativePath.split(separator: "/").reduce(root) { partial, component in
            partial.appendingPathComponent(String(component))
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
