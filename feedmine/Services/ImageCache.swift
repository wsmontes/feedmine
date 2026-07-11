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

        // Warm memory cache off the main actor — disk I/O + decode must not
        // compete with first render. Only the final setObject hops to MainActor.
        Task.detached(priority: .utility) { [weak self] in
            await self?.warmMemoryCache()
        }
    }

    // MARK: - Downsampling

    /// Target max pixel dimension for cached images. At 800px we cover
    /// 2× Retina on all iPhones for card-width display (~390 pt × 2 = 780 px).
    /// Full-res originals (often 3000×2000+) would waste 10-50× more memory.
    nonisolated static let downsampleMaxDimension: CGFloat = 800

    /// Decode image data at the target pixel dimension using ImageIO.
    /// Thread-safe — can be called from any queue, including Task.detached.
    /// Returns nil if the data is not a decodable image.
    nonisolated static func downsample(data: Data, to maxDimension: CGFloat = downsampleMaxDimension) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Public

    /// Raw image data from disk cache — safe to call from any queue.
    /// UIImage can be created from Data without MainActor.
    nonisolated func cachedImageData(for url: URL) -> Data? {
        let key = cacheKey(for: url)
        let fileURL = diskCacheURL.appendingPathComponent(key)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try? Data(contentsOf: fileURL)
    }

    /// Nonisolated static check — used by the ImagePrefetcher actor to avoid
    /// a MainActor hop per URL. Replicates the disk-cache path lookup without
    /// touching `shared` (which is @MainActor-isolated).
    nonisolated static func hasCachedImageData(for url: URL) -> Bool {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let diskURL = caches.appendingPathComponent("ImageCache", isDirectory: true)
        let key = cacheKeyForURL(url)
        let fileURL = diskURL.appendingPathComponent(key)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Duplicated key logic — kept private, nonisolated, and static so
    /// `hasCachedImageData` doesn't need a `shared` instance.
    private nonisolated static func cacheKeyForURL(_ url: URL) -> String {
        let full = url.absoluteString
        let sanitized = full
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "?", with: "_")
            .replacingOccurrences(of: "=", with: "_")
            .replacingOccurrences(of: "&", with: "_")
        if sanitized.utf8.count <= 200 { return sanitized }
        return String(sanitized.prefix(160)) + "_" + Self.stableHash(full)
    }

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

    /// Store a pre-decoded image (legacy path — stores at whatever resolution
    /// the caller provides). Prefer `setImage(data:for:)` to get automatic
    /// downsampling.
    func setImage(_ image: UIImage, for url: URL) {
        let key = cacheKey(for: url)
        let cost = Int(image.size.width * image.size.height * 4)
        memoryCache.setObject(image, forKey: key as NSString, cost: cost)

        let fileURL = diskCacheURL.appendingPathComponent(key)
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            guard let data = image.jpegData(compressionQuality: 0.85) else { return }
            do {
                try data.write(to: fileURL, options: .atomic)
                await self.didWriteToDisk(bytes: data.count)
            } catch { /* disk full */ }
        }
    }

    /// Store raw image data with automatic downsampling before both memory
    /// AND disk cache. Returns the downsampled UIImage so callers can use
    /// it directly instead of decoding again.
    @discardableResult
    func setImage(data: Data, for url: URL, maxDimension: CGFloat = downsampleMaxDimension) -> UIImage? {
        let key = cacheKey(for: url)

        guard let downsampled = Self.downsample(data: data, to: maxDimension) else { return nil }
        let cost = Int(downsampled.size.width * downsampled.size.height * 4)
        memoryCache.setObject(downsampled, forKey: key as NSString, cost: cost)

        // Write downsampled JPEG to disk — NOT original data
        let fileURL = diskCacheURL.appendingPathComponent(key)
        Task.detached(priority: .background) { [weak self] in
            guard let self,
                  let jpeg = downsampled.jpegData(compressionQuality: 0.85) else { return }
            do {
                try jpeg.write(to: fileURL, options: .atomic)
                await self.didWriteToDisk(bytes: jpeg.count)
            } catch { /* disk full */ }
        }
        return downsampled
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

    private nonisolated func cacheKey(for url: URL) -> String {
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
        return String(sanitized.prefix(160)) + "_" + Self.stableHash(full)
    }

    /// Deterministic, launch-stable hash (FNV-1a, 64-bit). Unlike
    /// `String.hashValue` — which is seeded per process — this survives app
    /// restarts, so disk-cache filenames remain valid across launches.
    private nonisolated static func stableHash(_ s: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325   // FNV-1a offset basis
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3     // FNV-1a prime
        }
        return String(hash, radix: 16)
    }

    /// Warm memory cache: list & read disk files off the main actor, then
    /// hop to MainActor only for the NSCache insertions. Previously the
    /// entire loop (50 disk reads + UIImage decodes) ran on MainActor.
    private func warmMemoryCache() async {
        // Phase 1 — background: list files, read data, downsample
        let preloaded: [(key: String, image: UIImage, byteCount: Int)] = await Task.detached {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: self.diskCacheURL, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: .skipsHiddenFiles
            ) else { return [] }

            let sorted = files.sorted { url1, url2 in
                let d1 = (try? url1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let d2 = (try? url2.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return d1 > d2
            }

            var result: [(key: String, image: UIImage, byteCount: Int)] = []
            result.reserveCapacity(50)
            for fileURL in sorted {
                guard result.count < 50,
                      let data = try? Data(contentsOf: fileURL),
                      let img = Self.downsample(data: data) else { continue }
                result.append((fileURL.lastPathComponent, img, data.count))
            }
            return result
        }.value

        // Phase 2 — MainActor: insert into NSCache (fast, just pointer assignments)
        var totalSize = 0
        for entry in preloaded {
            let cost = Int(entry.image.size.width * entry.image.size.height * 4)
            memoryCache.setObject(entry.image, forKey: entry.key as NSString, cost: cost)
            totalSize += entry.byteCount
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
                // Validate via metadata only — no full-res pixel decode on
                // MainActor. The old `UIImage(data:)` decoded 3000×2000 px
                // synchronously, which caused scroll stutter on device.
                guard Self.isValidImageData(data) else { break }
                if let downsampled = ImageCache.shared.setImage(data: data, for: url) {
                    loadedImage = downsampled
                    onResult?(true)
                    return
                }
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

    /// Metadata-only validation — reads image dimensions from the header
    /// without decoding pixels. Safe to call on MainActor during scroll.
    private nonisolated static func isValidImageData(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width  = props[kCGImagePropertyPixelWidth]  as? CGFloat,
              let height = props[kCGImagePropertyPixelHeight] as? CGFloat else { return false }
        return width >= minImageDimension && height >= minImageDimension
    }
}
