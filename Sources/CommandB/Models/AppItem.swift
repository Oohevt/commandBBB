import AppKit

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

    // Three-tier icon cache: memory → on-disk PNG → (first time only) the
    // real app bundle. Reading another app's bundle via NSWorkspace triggers
    // a sandboxd App-Management (SystemPolicyAppBundles) TCC preflight, which
    // re-prompts on every launch under ad-hoc signing. By caching the icon to
    // our own Caches dir once, later launches never touch foreign bundles.
    var icon: NSImage {
        let key = id.uuidString as NSString
        if let mem = Self.memCache.object(forKey: key) { return mem }

        let url = Self.cacheDir.appendingPathComponent("\(id).png")
        if let disk = NSImage(contentsOf: url) {
            let img = Self.downsample(disk, toPx: 256)
            Self.memCache.setObject(img, forKey: key)
            return img
        }

        // First encounter only — read the bundle icon and persist it full-res.
        let raw = NSWorkspace.shared.icon(forFile: path)
        Self.writePNG(raw, to: url)
        let img = Self.downsample(raw, toPx: 256)
        Self.memCache.setObject(img, forKey: key)
        return img
    }

    // The view redraws the icon at its exact frame size on every hover tick;
    // resampling from the 1024px original each time would burn CPU. Hold a
    // 256px (2x of the 81pt max magnified size, with headroom) copy in memory
    // so per-frame draws stay cheap and still oversample the target.
    private static func downsample(_ source: NSImage, toPx px: Int) -> NSImage {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return source }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()

        let out = NSImage(size: NSSize(width: px, height: px))
        out.addRepresentation(rep)
        return out
    }

    private static let memCache = NSCache<NSString, NSImage>()

    // Cached PNGs are keyed by item UUID; remove/replace must purge them or
    // they accumulate forever.
    static func purgeIconCache(for id: UUID) {
        memCache.removeObject(forKey: id.uuidString as NSString)
        try? FileManager.default.removeItem(
            at: cacheDir.appendingPathComponent("\(id).png")
        )
    }

    static let cacheDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.oohevt.commandb/icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func writePNG(_ image: NSImage, to url: URL) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

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
