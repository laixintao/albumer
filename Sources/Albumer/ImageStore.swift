import AppKit
import SwiftUI
import CoreImage

@MainActor @Observable
final class ImageStore {
    static let shared = ImageStore()
    @ObservationIgnored private let cache = NSCache<NSString, NSImage>()
    @ObservationIgnored private var pending: [String: Task<NSImage?, Never>] = [:]
    @ObservationIgnored private var colors: [String: Color] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let session = URLSession(configuration: .ephemeral)

    private init() { cache.totalCostLimit = 64 * 1024 * 1024; cache.countLimit = 100 }
    func image(for album: Album) async -> NSImage? {
        let key = album.artwork?.absoluteString ?? album.id
        if let image = cache.object(forKey: key as NSString) { return image }
        if let pending = pending[key] { return await pending.value }
        let generation = generation
        let task = Task<NSImage?, Never> {
            if album.artwork?.scheme == "albumer-preview", let source = album.artwork?.host,
               let url = Bundle.main.url(forResource: source, withExtension: "jpg", subdirectory: "Fixtures") {
                return NSImage(contentsOf: url)
            }
            guard let url = album.artwork, url.scheme == "https" else { return nil }
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
    func color(for album: Album) async -> Color? {
        if let color = colors[album.id] { return color }
        let generation = generation
        guard let image = await image(for: album), let data = image.tiffRepresentation,
              let bytes = await ArtworkPalette.shared.average(data), generation == self.generation else { return nil }
        let base = NSColor(srgbRed: Double(bytes[0]) / 255, green: Double(bytes[1]) / 255, blue: Double(bytes[2]) / 255, alpha: 1)
        let color = Color(nsColor: NSColor(hue: base.hueComponent, saturation: min(0.5, max(0.15, base.saturationComponent)), brightness: max(0.5, base.brightnessComponent), alpha: 1))
        colors[album.id] = color
        return color
    }
    func clear() {
        generation += 1
        pending.values.forEach { $0.cancel() }; pending.removeAll()
        cache.removeAllObjects(); colors.removeAll()
    }
}

@MainActor
final class DockArtworkController {
    static let shared = DockArtworkController()
    private var original: NSImage?
    private var task: Task<Void, Never>?
    private var key: String?

    func update(_ album: Album?) {
        guard NSApp != nil else { return }
        if original == nil { original = NSImage(named: NSImage.applicationIconName) ?? NSApp.applicationIconImage }
        let nextKey = album.map { $0.id + ($0.artwork?.absoluteString ?? "") }
        guard key != nextKey else { return }
        key = nextKey; task?.cancel()
        guard let album else { NSApp.applicationIconImage = original; return }
        // Never leave the previous album's cover visible while the next loads.
        NSApp.applicationIconImage = original
        task = Task {
            let image = await ImageStore.shared.image(for: album)
            guard !Task.isCancelled, key == nextKey else { return }
            NSApp.applicationIconImage = image ?? original
        }
    }
}

private actor ArtworkPalette {
    static let shared = ArtworkPalette()
    private let context = CIContext(options: [.cacheIntermediates: false])
    func average(_ data: Data) -> [UInt8]? {
        guard let ci = CIImage(data: data), let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: ci.extent), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return bytes
    }
}

