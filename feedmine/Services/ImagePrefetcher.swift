import UIKit

/// Pre-downloads images into ImageCache so CachedAsyncImage renders instantly.
actor ImagePrefetcher {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.httpMaximumConnectionsPerHost = 3
        self.session = URLSession(configuration: config)
    }

    func prefetch(urls: [String]) async {
        let validURLs = urls.compactMap { URL(string: $0) }
        guard !validURLs.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            for url in validURLs {
                // Skip if already cached
                if await ImageCache.shared.image(for: url) != nil {
                    continue
                }
                group.addTask {
                    do {
                        let (data, _) = try await self.session.data(from: url)
                        if let uiImage = UIImage(data: data) {
                            await ImageCache.shared.setImage(uiImage, for: url)
                        }
                    } catch {
                        // Silent fail
                    }
                }
            }
        }
    }
}
