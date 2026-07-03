import SwiftUI

/// In-memory image cache — instant loads, no disk I/O.
/// Prefetcher warms this cache; CachedAsyncImage reads from it.
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 50 * 1024 * 1024  // 50 MB
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url.absoluteString as NSString)
    }

    func setImage(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url.absoluteString as NSString)
    }
}

/// Image view that checks memory cache first, loads async if missing.
/// Calls `onResult(true)` on success, `onResult(false)` on failure.
struct CachedAsyncImage: View {
    let url: URL?
    var onResult: ((Bool) -> Void)?

    @State private var loadedImage: UIImage?
    @State private var didAttempt = false

    var body: some View {
        Group {
            if let image = loadedImage {
                Image(uiImage: image)
                    .resizable()
            } else if didAttempt {
                Color.clear
            } else {
                Color.clear
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
        if let cached = ImageCache.shared.image(for: url) {
            loadedImage = cached
            onResult?(true)
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
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
