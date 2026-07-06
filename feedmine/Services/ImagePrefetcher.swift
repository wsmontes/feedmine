import UIKit

/// Pre-downloads images into ImageCache so CachedAsyncImage renders instantly.
/// Deduplicates in-flight requests and caps concurrent downloads at 8.
actor ImagePrefetcher {
    private let session: URLSession
    private var inFlightURLs: Set<URL> = []

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.httpMaximumConnectionsPerHost = 3
        config.urlCache = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 40 * 1024 * 1024)
        self.session = URLSession(configuration: config)
    }

    /// Prefetch with priority ordering: priorityURLs download first, then the rest.
    /// Deduplicates against in-flight URLs and cache.
    func prefetch(urls: [String], priorityURLs: [String] = []) async {
        let all = (priorityURLs + urls).compactMap { URL(string: $0) }
        guard !all.isEmpty else { return }

        // Filter out cached or in-flight
        var toFetch: [URL] = []
        for url in all {
            if await ImageCache.shared.image(for: url) != nil { continue }
            if inFlightURLs.contains(url) { continue }
            if toFetch.contains(url) { continue }
            toFetch.append(url)
        }
        guard !toFetch.isEmpty else { return }

        for url in toFetch { inFlightURLs.insert(url) }

        // Download in batches of 8 to cap concurrency
        let batchSize = 8
        for i in stride(from: 0, to: toFetch.count, by: batchSize) {
            let batch = Array(toFetch[i..<min(i + batchSize, toFetch.count)])
            await withTaskGroup(of: Void.self) { group in
                for url in batch {
                    group.addTask { await self.download(url) }
                }
            }
        }
    }

    private func download(_ url: URL) async {
        defer { inFlightURLs.remove(url) }
        do {
            let (data, _) = try await session.data(from: url)
            if let uiImage = UIImage(data: data) {
                await ImageCache.shared.setImage(uiImage, for: url)
            }
        } catch {
            // Silent fail — will retry on next appearance
        }
    }
}
