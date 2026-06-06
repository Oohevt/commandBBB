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
            Self.memCache.setObject(disk, forKey: key)
            return disk
        }

        // First encounter only — read the bundle icon and persist it.
        let img = NSWorkspace.shared.icon(forFile: path)
        img.size = NSSize(width: 256, height: 256)
        Self.writePNG(img, to: url)
        Self.memCache.setObject(img, forKey: key)
        return img
    }

    private static let memCache = NSCache<NSString, NSImage>()

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
