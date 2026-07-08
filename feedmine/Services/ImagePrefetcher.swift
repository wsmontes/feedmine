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

        // Sliding-window concurrency: keep up to `maxConcurrent` downloads in
        // flight and refill each freed slot immediately. The previous fixed
        // batches of 8 waited for the slowest download in each batch (up to the
        // 20s resource timeout) before starting the next batch, so one slow
        // image stalled the rest. Every URL is still processed, so download()'s
        // defer clears it from inFlightURLs.
        let maxConcurrent = 8
        await withTaskGroup(of: Void.self) { group in
            var iterator = toFetch.makeIterator()
            var started = 0
            while started < maxConcurrent, let url = iterator.next() {
                group.addTask { await self.download(url) }
                started += 1
            }
            while await group.next() != nil {
                if let url = iterator.next() {
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
