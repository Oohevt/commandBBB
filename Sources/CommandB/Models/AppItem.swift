import AppKit
import ImageIO

struct AppItem: Codable, Identifiable {
    let id: UUID
    var name: String
    var path: String
    var unread: Bool

    init(id: UUID, name: String, path: String, unread: Bool = false) {
        self.id = id
        self.name = name
        self.path = path
        self.unread = unread
    }

    enum CodingKeys: String, CodingKey { case id, name, path, unread }

    // Custom decode so old saved data (without `unread`) still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        unread = try c.decodeIfPresent(Bool.self, forKey: .unread) ?? false
    }

    // Rendering only reads memory. Cache misses are prepared asynchronously;
    // the view never reads a bundle, decodes a PNG, or writes to disk.
    @MainActor var icon: NSImage {
        let key = id.uuidString as NSString
        if let image = Self.memCache.object(forKey: key) { return image }
        Self.prepareIcon(self)
        return Self.placeholder
    }

    @MainActor private static let placeholder = NSImage(
        systemSymbolName: "app.dashed", accessibilityDescription: "Loading app icon"
    ) ?? NSImage(size: NSSize(width: 256, height: 256))
    @MainActor private static let memCache = NSCache<NSString, NSImage>()
    @MainActor private static var pendingLoads: [UUID: UUID] = [:]
    private static let iconQueue = DispatchQueue(
        label: "com.oohevt.commandb.icons", qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )

    @MainActor private static func prepareIcon(_ item: AppItem) {
        guard pendingLoads[item.id] == nil else { return }
        let generation = UUID()
        pendingLoads[item.id] = generation
        let url = cacheDir.appendingPathComponent("\(item.id).png")
        Task { @MainActor in
            defer {
                if pendingLoads[item.id] == generation { pendingLoads[item.id] = nil }
            }
            var bitmap: CGImage? = await withCheckedContinuation { continuation in
                iconQueue.async {
                    continuation.resume(returning: readThumbnail(at: url))
                }
            }
            // A removed/replaced item must not resurrect its cache on completion.
            guard pendingLoads[item.id] == generation else { return }
            if bitmap == nil {
                // Keep AppKit bundle access on the main actor. Rasterize only
                // the requested size, never the original multi-resolution TIFF.
                bitmap = rasterizedIcon(forFile: item.path)
                if let image = bitmap {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        iconQueue.async {
                            writeThumbnail(image, to: url)
                            continuation.resume()
                        }
                    }
                }
            }
            guard pendingLoads[item.id] == generation else { return }
            let image = bitmap.map {
                NSImage(cgImage: $0, size: NSSize(width: 256, height: 256))
            } ?? placeholder
            memCache.setObject(image, forKey: item.id.uuidString as NSString)
            NotificationCenter.default.post(name: .appIconDidLoad, object: item.id)
        }
    }

    private static func readThumbnail(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { return nil }

        // Migrate old 1024px caches once, without touching foreign app bundles.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        if max(width, height) > 256 { writeThumbnail(image, to: url) }
        return image
    }

    @MainActor private static func rasterizedIcon(forFile path: String) -> CGImage? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        NSWorkspace.shared.icon(forFile: path).draw(
            in: NSRect(x: 0, y: 0, width: 256, height: 256)
        )
        return rep.cgImage
    }

    private static func writeThumbnail(_ image: CGImage, to url: URL) {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, "public.png" as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? (data as Data).write(to: url, options: .atomic)
    }

    @MainActor static func purgeIconCache(for id: UUID) {
        memCache.removeObject(forKey: id.uuidString as NSString)
        pendingLoads[id] = nil
        let url = cacheDir.appendingPathComponent("\(id).png")
        // Deletion follows any in-flight disk write on the same serial queue.
        iconQueue.async { try? FileManager.default.removeItem(at: url) }
    }

    static let cacheDir: URL = {
        #if COMMAND_B_TESTING
        if let path = ProcessInfo.processInfo.environment["COMMAND_B_TEST_CACHE_DIR"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.oohevt.commandb/icons", isDirectory: true)
    }()

    static let defaults: [AppItem] = {
        let candidates: [(String, String)] = [
            ("Safari",   "/Applications/Safari.app"),
            ("Finder",   "/System/Library/CoreServices/Finder.app"),
            ("Terminal", "/System/Applications/Utilities/Terminal.app"),
            ("Notes",    "/System/Applications/Notes.app"),
        ]
        return candidates.compactMap { name, path in
            FileManager.default.fileExists(atPath: path)
                ? AppItem(id: UUID(), name: name, path: path)
                : nil
        }
    }()
}
