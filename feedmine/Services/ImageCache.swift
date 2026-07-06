import SwiftUI

/// Two-tier image cache: fast NSCache memory lookup, persistent disk fallback.
/// Images written to disk survive app restarts — cold launches show images instantly.
/// Disk cache is capped at 100 MB; oldest files are evicted when exceeded.
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    private let memoryCache = NSCache<NSString, UIImage>()
    private let diskCacheURL: URL
    private let fileManager = FileManager.default
    private var diskCacheSize: Int = 0
    private static let maxDiskCacheSize = 100 * 1024 * 1024  // 100 MB

    private init() {
        memoryCache.countLimit = 200
        memoryCache.totalCostLimit = 50 * 1024 * 1024  // 50 MB

        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        diskCacheURL = caches.appendingPathComponent("ImageCache", isDirectory: true)
        try? fileManager.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)

        // Warm memory cache with most recent disk entries on launch
        Task { await warmMemoryCache() }
    }

    // MARK: - Public

    func image(for url: URL) -> UIImage? {
        let key = cacheKey(for: url)

        // Tier 1: memory
        if let img = memoryCache.object(forKey: key as NSString) {
            return img
        }

        // Tier 2: disk
        let fileURL = diskCacheURL.appendingPathComponent(key)
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let img = UIImage(data: data) else {
            return nil
        }

        // Promote to memory
        let cost = Int(img.size.width * img.size.height * 4)
        memoryCache.setObject(img, forKey: key as NSString, cost: cost)
        return img
    }

    func setImage(_ image: UIImage, for url: URL) {
        let key = cacheKey(for: url)
        let cost = Int(image.size.width * image.size.height * 4)
        memoryCache.setObject(image, forKey: key as NSString, cost: cost)

        // Write-through to disk (background)
        let fileURL = diskCacheURL.appendingPathComponent(key)
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            guard let data = image.jpegData(compressionQuality: 0.85) else { return }
            do {
                try data.write(to: fileURL, options: .atomic)
                await self.didWriteToDisk(bytes: data.count)
            } catch {
                // Disk full or permissions — silently skip
            }
        }
    }

    /// Remove all cached images (both memory and disk)
    func clearAll() {
        memoryCache.removeAllObjects()
        try? fileManager.removeItem(at: diskCacheURL)
        try? fileManager.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
        diskCacheSize = 0
    }

    // MARK: - Private

    private func cacheKey(for url: URL) -> String {
        // Use last 2 path components + host for readability, fallback to hash
        let sanitized = url.absoluteString
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "?", with: "_")
            .replacingOccurrences(of: "=", with: "_")
            .replacingOccurrences(of: "&", with: "_")
        // Truncate — filenames over 255 bytes fail on some filesystems
        if sanitized.utf8.count <= 200 { return sanitized }
        return String(sanitized.prefix(200))
    }

    private func warmMemoryCache() async {
        guard let files = try? fileManager.contentsOfDirectory(
            at: diskCacheURL, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        // Load most recent files first, up to memory cache limit
        let sorted = files.sorted { url1, url2 in
            let d1 = (try? url1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let d2 = (try? url2.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return d1 > d2
        }

        var loaded = 0
        var totalSize = 0
        for fileURL in sorted {
            guard loaded < 50, // warm only the 50 most recent
                  let data = try? Data(contentsOf: fileURL),
                  let img = UIImage(data: data) else { continue }
            let cost = Int(img.size.width * img.size.height * 4)
            memoryCache.setObject(img, forKey: fileURL.lastPathComponent as NSString, cost: cost)
            totalSize += data.count
            loaded += 1
        }
        diskCacheSize = totalSize
    }

    private func didWriteToDisk(bytes: Int) {
        diskCacheSize += bytes

        guard diskCacheSize > Self.maxDiskCacheSize else { return }

        // Evict oldest files until under 80% of limit
        let target = Self.maxDiskCacheSize * 8 / 10
        guard let files = try? fileManager.contentsOfDirectory(
            at: diskCacheURL, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        let sorted = files.sorted { url1, url2 in
            let d1 = (try? url1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let d2 = (try? url2.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return d1 < d2  // oldest first
        }

        var freed = 0
        for fileURL in sorted {
            guard diskCacheSize - freed > target else { break }
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                freed += size
            }
            try? fileManager.removeItem(at: fileURL)
        }
        diskCacheSize -= freed
    }
}

/// Image view that checks memory cache → disk cache → network.
/// Uses a configured URLSession with URLCache for HTTP-level caching as final fallback.
struct CachedAsyncImage: View {
    let url: URL?
    var onResult: ((Bool) -> Void)?

    @State private var loadedImage: UIImage?
    @State private var didAttempt = false

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 40 * 1024 * 1024)
        config.httpMaximumConnectionsPerHost = 3
        return URLSession(configuration: config)
    }()

    var body: some View {
        Group {
            if let image = loadedImage {
                Image(uiImage: image)
                    .resizable()
            } else {
                // Tinted placeholder — matches circadian accent
                CircadianEngine.shared.accent.opacity(0.05)
                    .task { await load() }
            }
        }
    }

    private func load() async {
        guard let url else {
            didAttempt = true
            onResult?(false)
            return
        }
        // Tier 1 + 2: memory or disk cache
        if let cached = ImageCache.shared.image(for: url) {
            loadedImage = cached
            onResult?(true)
            return
        }
        // Tier 3: network with URLCache
        do {
            let (data, _) = try await Self.session.data(from: url)
            if let uiImage = UIImage(data: data) {
                ImageCache.shared.setImage(uiImage, for: url)
                loadedImage = uiImage
                onResult?(true)
            } else {
                didAttempt = true
                onResult?(false)
            }
        } catch {
            didAttempt = true
            onResult?(false)
        }
    }
}
