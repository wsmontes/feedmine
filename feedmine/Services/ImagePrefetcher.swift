import UIKit

/// Pre-downloads images into ImageCache so CachedAsyncImage renders instantly.
/// Deduplicates in-flight requests and caps concurrent downloads at 8.
actor ImagePrefetcher {
    private let session: URLSession
    private var inFlightURLs: Set<URL> = []

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        config.httpMaximumConnectionsPerHost = 4
        config.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 60 * 1024 * 1024)
        self.session = URLSession(configuration: config)
    }

    /// Prefetch with priority ordering: priorityURLs download first, then the rest.
    /// Deduplicates against in-flight URLs and cache.
    func prefetch(urls: [String], priorityURLs: [String] = []) async {
        let all = (priorityURLs + urls).compactMap { URL(string: $0) }
        guard !all.isEmpty else { return }

        // Filter out cached or in-flight — uses nonisolated static check
        // to avoid MainActor hops per URL
        var toFetch: [URL] = []
        for url in all {
            if ImageCache.hasCachedImageData(for: url) { continue }
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
        let maxConcurrent = 16
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
            guard UIImage(data: data) != nil else { return }
            // setImage(data:) downsamples before memory cache; JPEG goes to disk
            await ImageCache.shared.setImage(data: data, for: url)
        } catch {
            // Silent fail — will retry on next appearance
        }
    }
}
