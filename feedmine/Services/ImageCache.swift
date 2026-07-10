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
        if let img = memoryCache.object(forKey: key as NSString) { return img }
        let fileURL = diskCacheURL.appendingPathComponent(key)
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let img = UIImage(data: data) else { return nil }
        let cost = Int(img.size.width * img.size.height * 4)
        memoryCache.setObject(img, forKey: key as NSString, cost: cost)
        return img
    }

    /// Off-MainActor disk lookup. Captures the cache key and file URL
    /// synchronously, then does blocking I/O in a Task.detached.
    func diskImage(for url: URL) async -> UIImage? {
        let key = cacheKey(for: url)
        // Memory hit — return immediately
        if let img = memoryCache.object(forKey: key as NSString) { return img }
        let fileURL = diskCacheURL.appendingPathComponent(key)
        return await Task.detached {
            guard FileManager.default.fileExists(atPath: fileURL.path),
                  let data = try? Data(contentsOf: fileURL),
                  let img = UIImage(data: data) else { return nil }
            return img
        }.value
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

    func evict(url: URL) {
        let key = cacheKey(for: url) as NSString
        memoryCache.removeObject(forKey: key)
        let fileURL = diskCacheURL.appendingPathComponent(key as String)
        if fileManager.fileExists(atPath: fileURL.path) {
            let size = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
            try? fileManager.removeItem(at: fileURL)
            diskCacheSize = max(0, diskCacheSize - size)
        }
    }

    // MARK: - Private

    private func cacheKey(for url: URL) -> String {
        // Use last 2 path components + host for readability, fallback to hash
        let full = url.absoluteString
        let sanitized = full
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "?", with: "_")
            .replacingOccurrences(of: "=", with: "_")
            .replacingOccurrences(of: "&", with: "_")
        // Short keys are used verbatim for readability.
        if sanitized.utf8.count <= 200 { return sanitized }
        // Filenames over 255 bytes fail on some filesystems, so long keys must
        // be truncated — but two distinct URLs can share the same 200-char
        // prefix (e.g. CDN/signed image URLs that differ only in a trailing
        // query param). Append a stable hash of the full URL so truncated keys
        // stay unique instead of colliding onto one cache file.
        return String(sanitized.prefix(160)) + "_" + stableHash(full)
    }

    /// Deterministic, launch-stable hash (FNV-1a, 64-bit). Unlike
    /// `String.hashValue` — which is seeded per process — this survives app
    /// restarts, so disk-cache filenames remain valid across launches.
    private func stableHash(_ s: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325   // FNV-1a offset basis
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3     // FNV-1a prime
        }
        return String(hash, radix: 16)
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
    @State private var loadFailed = false
    @State private var retryCount = 0

    /// Images smaller than this (e.g. 1×1 tracking pixels) are rejected.
    private static let minImageDimension: CGFloat = 4

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
            } else if !didAttempt {
                Rectangle()
                    .fill(.quaternary)
                    .task { await load() }
            } else {
                Rectangle()
                    .fill(Color(.systemGray6))
                    .overlay {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .onChange(of: url?.absoluteString ?? "") { _, _ in
            // Reset state when URL changes so reused views reload (#48)
            loadedImage = nil
            didAttempt = false
            loadFailed = false
            retryCount = 0
        }
        .onAppear {
            // Retry failed loads when card scrolls back into view
            if loadFailed && retryCount < 3 {
                loadFailed = false
                didAttempt = false
                retryCount += 1
            }
        }
    }

    private func load() async {
        guard let url else {
            didAttempt = true; loadFailed = true; onResult?(false)
            return
        }
        // Tier 1 + 2: memory + disk (disk I/O off MainActor via diskImage)
        if let cached = await ImageCache.shared.diskImage(for: url) {
            guard isValidImage(cached) else {
                ImageCache.shared.evict(url: url)
                didAttempt = true; loadFailed = true; onResult?(false)
                return
            }
            loadedImage = cached; onResult?(true)
            return
        }
        // Tier 3: network with URLCache + retry
        for attempt in 0..<2 {
            do {
                let (data, _) = try await Self.session.data(from: url)
                if let uiImage = UIImage(data: data), isValidImage(uiImage) {
                    ImageCache.shared.setImage(uiImage, for: url)
                    loadedImage = uiImage
                    onResult?(true)
                    return
                }
                // Invalid image data — don't retry
                break
            } catch {
                if attempt == 0 {
                    try? await Task.sleep(for: .milliseconds(500))
                    continue
                }
            }
        }
        didAttempt = true
        loadFailed = true
        onResult?(false)
    }

    /// Reject tracking pixels and other near-invisible images.
    private func isValidImage(_ image: UIImage) -> Bool {
        image.size.width >= Self.minImageDimension
        && image.size.height >= Self.minImageDimension
    }
}
