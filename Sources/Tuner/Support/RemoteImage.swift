import ImageIO
import SwiftUI
import TunerCore

/// Remote artwork (posters, backdrops, logos), loaded through `ArtworkLoader`: shown at once when it's already in
/// memory (no placeholder flash when scrolling back), otherwise read from the disk cache or downloaded, scaled down
/// to the size it's drawn at off the main thread, and faded in.
struct RemoteImage<Placeholder: View>: View {
    let url: String?
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder

    @Environment(\.displayScale) private var displayScale
    @ViewState private var size: CGSize = .zero
    @ViewState private var loaded: ArtworkLoader.Loaded?

    init(url: String?, contentMode: ContentMode = .fill, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.contentMode = contentMode
        self.placeholder = placeholder
    }

    private var parsedURL: URL? {
        guard let url, let parsed = URL(string: url), parsed.scheme != nil else { return nil }
        return parsed
    }

    var body: some View {
        let parsed = parsedURL
        // Already decoded (any size): draw it in this very pass, then let the task fetch a sharper copy if needed.
        let image = loaded?.url == parsed ? loaded?.image : parsed.flatMap { ArtworkLoader.shared.cachedImage(for: $0) }
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                placeholder()
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .task(id: LoadKey(url: parsed, pixels: ArtworkLoader.bucket(for: size, scale: displayScale))) {
            await load(parsed)
        }
    }

    private func load(_ url: URL?) async {
        guard let url else {
            loaded = nil
            return
        }
        guard size.width > 0 || size.height > 0 else { return }
        let pixels = ArtworkLoader.bucket(for: size, scale: displayScale)
        let wasShowing = loaded?.url == url || ArtworkLoader.shared.cachedImage(for: url) != nil
        guard let image = await ArtworkLoader.shared.image(for: url, maxPixels: pixels), !Task.isCancelled else { return }
        if wasShowing {
            loaded = .init(url: url, image: image)
        } else {
            withAnimation(.easeOut(duration: 0.2)) { loaded = .init(url: url, image: image) }
        }
    }

    private struct LoadKey: Equatable {
        let url: URL?
        let pixels: Int
    }
}

/// Fetches, caches and downsamples artwork for `RemoteImage`.
///
/// Three levels: decoded images in memory (`NSCache`, keyed by URL and size bucket, evicted under memory
/// pressure), the original bytes on disk (`ImageDiskCache`, kept regardless of the server's caching headers), and
/// the network (one request per URL however many views ask for it at once). Decoding uses ImageIO's thumbnail path,
/// so a 2000-px poster drawn at 150 pt costs a ~450-px bitmap, not the full image.
final class ArtworkLoader: @unchecked Sendable {
    static let shared = ArtworkLoader()

    struct Loaded: Equatable {
        let url: URL
        let image: CGImage
        static func == (a: Loaded, b: Loaded) -> Bool { a.url == b.url && a.image === b.image }
    }

    private final class Entry {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let memory = NSCache<NSString, Entry>()
    /// Largest decoded size per URL, so a view of unknown size can show something straight away.
    private let largest = NSCache<NSString, Entry>()
    let disk: ImageDiskCache
    private let session: URLSession
    private let lock = NSLock()
    private var inFlight: [URL: Task<Data?, Never>] = [:]

    private init() {
        #if os(macOS)
        memory.totalCostLimit = 192 * 1024 * 1024
        #else
        memory.totalCostLimit = 96 * 1024 * 1024
        #endif
        largest.totalCostLimit = memory.totalCostLimit / 2
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "app.tuner", isDirectory: true)
            .appendingPathComponent("Artwork", isDirectory: true)
        disk = ImageDiskCache(directory: caches, limitBytes: 600 * 1024 * 1024)
        let config = URLSessionConfiguration.default
        config.urlCache = nil   // our disk cache keeps the bytes
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: config)
    }

    /// Pixel size buckets (longest side) so neighbouring sizes share one decoded copy.
    static func bucket(for size: CGSize, scale: CGFloat) -> Int {
        let pixels = max(size.width, size.height) * max(scale, 1)
        guard pixels > 0 else { return 0 }
        for bucket in [128, 256, 384, 512, 768, 1024, 1536, 2048] where CGFloat(bucket) >= pixels { return bucket }
        return 3072
    }

    /// The best decoded copy already in memory, if any (synchronous; for the first frame).
    func cachedImage(for url: URL) -> CGImage? {
        largest.object(forKey: url.absoluteString as NSString)?.image
    }

    /// The image scaled to fit `maxPixels` on its longest side (0: as large as the cached copy allows).
    func image(for url: URL, maxPixels: Int) async -> CGImage? {
        let key = "\(maxPixels)|\(url.absoluteString)" as NSString
        if let hit = memory.object(forKey: key) { return hit.image }
        guard let data = await bytes(for: url) else { return nil }
        let image = await Task.detached(priority: .userInitiated) { Self.decode(data, maxPixels: maxPixels) }.value
        guard let image else { return nil }
        let cost = image.bytesPerRow * image.height
        memory.setObject(Entry(image), forKey: key, cost: cost)
        let urlKey = url.absoluteString as NSString
        if (largest.object(forKey: urlKey)?.image.width ?? 0) < image.width {
            largest.setObject(Entry(image), forKey: urlKey, cost: cost)
        }
        return image
    }

    /// Clears memory and disk (Settings).
    func removeAll() async {
        memory.removeAllObjects()
        largest.removeAllObjects()
        await disk.removeAll()
    }

    // MARK: Bytes

    private func bytes(for url: URL) async -> Data? {
        if url.isFileURL {
            return await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
        }
        let task: Task<Data?, Never> = lock.withLock {
            if let running = inFlight[url] { return running }
            let task = Task<Data?, Never> { [disk, session] in
                if let cached = await disk.data(for: url) { return cached }
                guard let (data, response) = try? await session.data(from: url),
                      (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                      CGImageSourceCreateWithData(data as CFData, nil).map({ CGImageSourceGetCount($0) > 0 }) == true
                else { return nil }
                await disk.store(data, for: url)
                return data
            }
            inFlight[url] = task
            return task
        }
        let data = await task.value
        lock.withLock { if inFlight[url] == task { inFlight[url] = nil } }
        return data
    }

    // MARK: Decoding

    private static func decode(_ data: Data, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if maxPixels > 0 { options[kCGImageSourceThumbnailMaxPixelSize] = maxPixels }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

enum ImageCacheSetup {
    static func configure() {
        // Artwork has its own caches (ArtworkLoader); this one serves the rest (metadata, logos, trailers).
        URLCache.shared = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 256 * 1024 * 1024)
    }
}
