import Foundation

struct FeedEngineCatalogDiagnosticsStatus: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case opening
        case compiling
        case ready
        case failed
    }

    let phase: Phase
    let sourceCount: Int
    let nodeCount: Int
    let placementCount: Int
    let duplicateOccurrenceCount: Int
    let rootNodeCount: Int
    let rootSourceCount: Int
    let elapsed: TimeInterval
    let errorDescription: String?

    static let idle = FeedEngineCatalogDiagnosticsStatus(
        phase: .idle,
        sourceCount: 0,
        nodeCount: 0,
        placementCount: 0,
        duplicateOccurrenceCount: 0,
        rootNodeCount: 0,
        rootSourceCount: 0,
        elapsed: 0,
        errorDescription: nil
    )

    static func compiling(sourceCount: Int) -> FeedEngineCatalogDiagnosticsStatus {
        FeedEngineCatalogDiagnosticsStatus(
            phase: .compiling,
            sourceCount: sourceCount,
            nodeCount: 0,
            placementCount: 0,
            duplicateOccurrenceCount: 0,
            rootNodeCount: 0,
            rootSourceCount: 0,
            elapsed: 0,
            errorDescription: nil
        )
    }

    static let opening = FeedEngineCatalogDiagnosticsStatus(
        phase: .opening,
        sourceCount: 0,
        nodeCount: 0,
        placementCount: 0,
        duplicateOccurrenceCount: 0,
        rootNodeCount: 0,
        rootSourceCount: 0,
        elapsed: 0,
        errorDescription: nil
    )

    static func failed(_ error: Error) -> FeedEngineCatalogDiagnosticsStatus {
        FeedEngineCatalogDiagnosticsStatus(
            phase: .failed,
            sourceCount: 0,
            nodeCount: 0,
            placementCount: 0,
            duplicateOccurrenceCount: 0,
            rootNodeCount: 0,
            rootSourceCount: 0,
            elapsed: 0,
            errorDescription: error.localizedDescription
        )
    }

    var compactLabel: String {
        switch phase {
        case .idle:
            return "catalog idle"
        case .opening:
            return "catalog opening"
        case .compiling:
            return "catalog compiling \(sourceCount)"
        case .ready:
            return "catalog \(sourceCount)s/\(nodeCount)n \(String(format: "%.2fs", elapsed))"
        case .failed:
            return "catalog failed"
        }
    }
}

actor FeedEngineCatalogDiagnostics {
    static func bundledDatabaseURL() -> URL? {
        Bundle.main.url(forResource: "catalog", withExtension: "sqlite", subdirectory: "FeedEngine")
    }

    static func activeDatabaseURL() -> URL? {
        CatalogRuntime.activeCatalogURL()
    }

    static func defaultDatabaseURL() throws -> URL {
        let baseURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directoryURL = baseURL.appendingPathComponent("FeedEngine", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL.appendingPathComponent("catalog.sqlite")
    }

    func openBundledCatalog() async throws -> FeedEngineCatalogDiagnosticsStatus {
        guard let databaseURL = Self.bundledDatabaseURL() else {
            throw FeedEngineError.invalidCatalog("Bundled FeedEngine/catalog.sqlite is missing")
        }

        let finishInterval = FeedMetrics.beginInterval("CatalogDiagnostics.openBundled")
        defer { finishInterval() }

        let repository = try SQLiteCatalogRepository(databaseURL: databaseURL, readOnly: true)
        let report = try await repository.compileReport(
            mode: .full,
            changedFileCount: 0,
            deletedFileCount: 0,
            elapsed: 0
        )
        let rootPage = try await repository.browseCatalog(
            query: CatalogBrowseQuery(parentID: .root, includeSources: true),
            cursor: nil,
            limit: 50
        )
        FeedMetrics.event(
            "CatalogDiagnostics.bundledReady",
            "sources=\(report.sourceCount) nodes=\(report.nodeCount) placements=\(report.placementCount)"
        )

        return FeedEngineCatalogDiagnosticsStatus(
            phase: .ready,
            sourceCount: report.sourceCount,
            nodeCount: report.nodeCount,
            placementCount: report.placementCount,
            duplicateOccurrenceCount: report.duplicateOccurrenceCount,
            rootNodeCount: rootPage.nodes.count,
            rootSourceCount: rootPage.sources.count,
            elapsed: report.elapsed,
            errorDescription: nil
        )
    }

    func openActiveCatalog() async throws -> FeedEngineCatalogDiagnosticsStatus {
        guard let databaseURL = Self.activeDatabaseURL() else {
            throw FeedEngineError.invalidCatalog("Active local FeedEngine catalog is missing")
        }

        let finishInterval = FeedMetrics.beginInterval("CatalogDiagnostics.openActive")
        defer { finishInterval() }
        let repository = try SQLiteCatalogRepository(databaseURL: databaseURL, readOnly: true)
        let report = try await repository.compileReport(
            mode: .full,
            changedFileCount: 0,
            deletedFileCount: 0,
            elapsed: 0
        )
        let rootPage = try await repository.browseCatalog(
            query: CatalogBrowseQuery(parentID: .root, includeSources: true),
            cursor: nil,
            limit: 50
        )
        return FeedEngineCatalogDiagnosticsStatus(
            phase: .ready,
            sourceCount: report.sourceCount,
            nodeCount: report.nodeCount,
            placementCount: report.placementCount,
            duplicateOccurrenceCount: report.duplicateOccurrenceCount,
            rootNodeCount: rootPage.nodes.count,
            rootSourceCount: rootPage.sources.count,
            elapsed: report.elapsed,
            errorDescription: nil
        )
    }

    func compileLegacyCatalog(sources: [FeedSource]) async throws -> FeedEngineCatalogDiagnosticsStatus {
        let databaseURL = try Self.defaultDatabaseURL()
        let finishInterval = FeedMetrics.beginInterval("CatalogDiagnostics.compileLegacy")
        defer { finishInterval() }

        FeedMetrics.event("CatalogDiagnostics.started", "sources=\(sources.count)")
        FeedMetrics.memory("catalogDiagnosticsStarted")

        let compiler = SQLiteCatalogCompiler(input: .legacySources(sources), databaseURL: databaseURL)
        let report = try await compiler.compileFull()
        let repository = try SQLiteCatalogRepository(databaseURL: databaseURL)
        let rootPage = try await repository.browseCatalog(
            query: CatalogBrowseQuery(parentID: .root, includeSources: true),
            cursor: nil,
            limit: 50
        )

        FeedMetrics.event(
            "CatalogDiagnostics.ready",
            "sources=\(report.sourceCount) nodes=\(report.nodeCount) placements=\(report.placementCount)"
        )
        FeedMetrics.memory("catalogDiagnosticsReady")

        return FeedEngineCatalogDiagnosticsStatus(
            phase: .ready,
            sourceCount: report.sourceCount,
            nodeCount: report.nodeCount,
            placementCount: report.placementCount,
            duplicateOccurrenceCount: report.duplicateOccurrenceCount,
            rootNodeCount: rootPage.nodes.count,
            rootSourceCount: rootPage.sources.count,
            elapsed: report.elapsed,
            errorDescription: nil
        )
    }
}
