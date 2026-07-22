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
        for candidate in ImageURLCandidates.candidates(for: url) {
            do {
                let (data, response) = try await session.data(from: candidate)
                if let http = response as? HTTPURLResponse,
                   !(200...299).contains(http.statusCode) { continue }
                guard UIImage(data: data) != nil else { continue }
                // Cache fallback bytes under the requested URL so the view's
                // normal memory/disk lookup finds them.
                await ImageCache.shared.setImage(data: data, for: url)
                return
            } catch {
                continue
            }
        }
    }

    /// Resolve article-page artwork (Open Graph / Twitter / srcset) and cache
    /// it under the article URL so CachedAsyncImage finds it on first render.
    func prefetchArticleImage(for articleURL: URL) async {
        let candidates = await ArticleImageResolver.shared.imageURLs(
            for: articleURL,
            replacing: nil
        )
        guard let best = await ImageUpgradePolicy.firstDisplayable(
            from: candidates,
            session: session
        ) else { return }
        await ImageCache.shared.setImage(data: best.data, for: articleURL)
    }
}
