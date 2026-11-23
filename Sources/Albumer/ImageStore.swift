import AppKit
import Observation

@MainActor @Observable
final class ImageStore {
    static let shared = ImageStore()
    @ObservationIgnored private let cache = NSCache<NSString, NSImage>()
    @ObservationIgnored private var pending: [String: Task<NSImage?, Never>] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let session = URLSession(configuration: .ephemeral)

    private init() { cache.totalCostLimit = 64 * 1024 * 1024; cache.countLimit = 100 }
    func cachedImage(for album: Album) -> NSImage? {
        guard let url = album.artwork else { return nil }
        return cachedImage(at: url)
    }
    func cachedImage(at url: URL) -> NSImage? {
        return cache.object(forKey: url.absoluteString as NSString)
    }
    func image(for album: Album) async -> NSImage? {
        guard let url = album.artwork else { return nil }
        return await image(at: url)
    }
    func image(at url: URL) async -> NSImage? {
        let key = url.absoluteString
        if let image = cache.object(forKey: key as NSString) { return image }
        if let pending = pending[key] { return await pending.value }
        let generation = generation
        let task = Task<NSImage?, Never> {
            if url.scheme == "albumer-preview", let source = url.host,
               let url = Bundle.main.url(forResource: source, withExtension: "jpg", subdirectory: "Fixtures") {
                return NSImage(contentsOf: url)
            }
            guard url.scheme == "https" else { return nil }
            if let data = await LocalStore.shared.artwork(url), let image = NSImage(data: data) { return image }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                let (data, response) = try await session.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 8 * 1024 * 1024,
                      let image = NSImage(data: data) else { return nil }
                await LocalStore.shared.saveArtwork(data, url: url)
                return image
            } catch { return nil }
        }
        pending[key] = task
        let image = await task.value
        guard generation == self.generation else { return nil }
        pending[key] = nil
        if let image {
            cache.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.size.height * 4))
        }
        return image
    }
    func clear() {
        generation += 1
        pending.values.forEach { $0.cancel() }; pending.removeAll()
        cache.removeAllObjects()
    }
}

@MainActor
final class DockArtworkController {
    static let shared = DockArtworkController(
        originalIcon: { NSImage(named: NSImage.applicationIconName) ?? NSApp?.applicationIconImage },
        isAvailable: { NSApp != nil },
        cachedImage: { ImageStore.shared.cachedImage(at: $0) },
        loadImage: { await ImageStore.shared.image(at: $0) },
        applyImage: { NSApp?.applicationIconImage = $0 }
    )

    private let originalIcon: @MainActor () -> NSImage?
    private let isAvailable: @MainActor () -> Bool
    private let cachedImage: @MainActor (URL) -> NSImage?
    private let loadImage: @MainActor (URL) async -> NSImage?
    private let applyImage: @MainActor (NSImage?) -> Void
    private var original: NSImage?
    private var capturedOriginal = false
    private var task: Task<Void, Never>?
    private var requestedURL: URL?
    private var displayedURL: URL?

    init(originalIcon: @escaping @MainActor () -> NSImage?,
         isAvailable: @escaping @MainActor () -> Bool = { true },
         cachedImage: @escaping @MainActor (URL) -> NSImage? = { _ in nil },
         loadImage: @escaping @MainActor (URL) async -> NSImage?,
         applyImage: @escaping @MainActor (NSImage?) -> Void) {
        self.originalIcon = originalIcon
        self.isAvailable = isAvailable
        self.cachedImage = cachedImage
        self.loadImage = loadImage
        self.applyImage = applyImage
    }

    func update(_ artworkURL: URL?) {
        guard isAvailable() else { return }
        if !capturedOriginal { original = originalIcon(); capturedOriginal = true }
        let changed = requestedURL != artworkURL
        if changed {
            task?.cancel(); task = nil
            requestedURL = artworkURL
            displayedURL = nil
        }
        guard let artworkURL else { applyImage(original); return }
        guard displayedURL != artworkURL, task == nil else { return }
        if let image = cachedImage(artworkURL) {
            displayedURL = artworkURL
            applyImage(image)
            return
        }
        // A different album must not leave an unrelated cover visible while its image loads.
        if changed { applyImage(original) }
        task = Task {
            let image = await loadImage(artworkURL)
            guard !Task.isCancelled, requestedURL == artworkURL else { return }
            task = nil
            // Failed loads remain eligible for the next playback refresh instead of getting stuck.
            if let image {
                displayedURL = artworkURL
                applyImage(image)
            }
        }
    }
}
