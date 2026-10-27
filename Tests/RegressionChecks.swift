import AppKit
import Combine
import ImageIO

@main
struct RegressionChecks {
    @MainActor static var results: [[String: Any]] = []

    @MainActor static func record(_ name: String, _ passed: Bool, _ detail: String = "") {
        results.append(["name": name, "passed": passed, "detail": detail])
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            let reportURL = URL(fileURLWithPath: CommandLine.arguments[1])
            guard Bundle.main.bundleIdentifier == "com.oohevt.commandb.regression" else {
                fatalError("Tests require their own bundle and preferences domain")
            }
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("CommandBChecks-\(UUID())", isDirectory: true)
            try! FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            setenv("COMMAND_B_TEST_CACHE_DIR", scratch.appendingPathComponent("icons").path, 1)
            UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)

            await checkPersistence()
            await checkIcons(scratch: scratch)
            await checkPanel()
            await checkPanelSizing()
            await checkActivationTrigger()

            UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
            try? FileManager.default.removeItem(at: scratch)
            let data = try! JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            try! data.write(to: reportURL, options: .atomic)
            NSApp.terminate(nil)
        }
        app.run()
    }

    @MainActor static func checkPersistence() async {
        let store = AppStore.shared
        var stale = 0
        let start = ProcessInfo.processInfo.systemUptime
        for revision in 0..<100 {
            store.apps = (0..<8).map {
                AppItem(id: UUID(), name: "revision-\(revision)-\($0)", path: "/tmp/test-\($0).app")
            }
            store.save()
            let data = UserDefaults.standard.data(forKey: "com.oohevt.commandb.apps")
            let saved = data.flatMap { try? JSONDecoder().decode([AppItem].self, from: $0) }
            if saved?.last?.name != "revision-\(revision)-7" { stale += 1 }
        }
        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
        record("Ordered save is available before returning", stale == 0,
               "stale=\(stale)/100; eight-item save+read mean=\(elapsed / 100) ms")
        let expected = try! JSONEncoder().encode(store.apps)
        try? await Task.sleep(nanoseconds: 200_000_000)
        let saved = UserDefaults.standard.data(forKey: "com.oohevt.commandb.apps")
        let decoded = saved.flatMap { try? JSONDecoder().decode([AppItem].self, from: $0) }
        let reference = try! JSONDecoder().decode([AppItem].self, from: expected)
        record("Latest revision survives delayed work", decoded?.map(\.name) == reference.map(\.name))
        store.apps = []
    }

    @MainActor static func checkIcons(scratch: URL) async {
        var ready: Set<UUID> = []
        let subscription = NotificationCenter.default.publisher(for: Notification.Name("com.oohevt.commandb.appIconDidLoad"))
            .sink { if let id = $0.object as? UUID { ready.insert(id) } }
        var storeUpdates = 0
        let storeSubscription = AppStore.shared.objectWillChange.sink { storeUpdates += 1 }
        let item = AppItem(id: UUID(), name: "fixture", path: scratch.appendingPathComponent("unused.app").path)
        let url = AppItem.cacheDir.appendingPathComponent("\(item.id).png")
        try! FileManager.default.createDirectory(at: AppItem.cacheDir, withIntermediateDirectories: true)
        writeFixture(to: url)
        let start = ProcessInfo.processInfo.systemUptime
        _ = item.icon
        let lookupMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
        record("Icon lookup defers file decoding", !ready.contains(item.id) && dimensions(url) == 1024,
               "lookup=\(lookupMS) ms")
        await waitUntil { ready.contains(item.id) }
        record("Legacy cache loads and migrates to 256 pixels", ready.contains(item.id) && dimensions(url) == 256)
        record("Icon completion refreshes the store", storeUpdates > 0)
        record("Warm icon reuses the same memory object", item.icon === item.icon)

        let cancelled = AppItem(id: UUID(), name: "cancelled", path: item.path)
        let cancelledURL = AppItem.cacheDir.appendingPathComponent("\(cancelled.id).png")
        writeFixture(to: cancelledURL)
        _ = cancelled.icon
        AppItem.purgeIconCache(for: cancelled.id)
        try? await Task.sleep(nanoseconds: 400_000_000)
        record("Purge cancels pending icon publication and persistence",
               !ready.contains(cancelled.id) && !FileManager.default.fileExists(atPath: cancelledURL.path))

        let textFile = scratch.appendingPathComponent("fixture.txt")
        try! "fixture".write(to: textFile, atomically: true, encoding: .utf8)
        let newItem = AppItem(id: UUID(), name: "new", path: textFile.path)
        _ = newItem.icon
        await waitUntil { ready.contains(newItem.id) }
        let newURL = AppItem.cacheDir.appendingPathComponent("\(newItem.id).png")
        record("First-use icon writes only 256 pixels", ready.contains(newItem.id) && dimensions(newURL) == 256)
        withExtendedLifetime((subscription, storeSubscription)) {}
    }

    @MainActor static func checkPanel() async {
        AppStore.shared.apps = []
        let panel = LauncherPanel()
        panel.show()
        panel.hide()
        try? await Task.sleep(nanoseconds: 450_000_000)
        record("Hide during fade-in is honored", !panel.isVisible)

        panel.show()
        panel.hide()
        panel.show()
        try? await Task.sleep(nanoseconds: 450_000_000)
        record("Latest show wins during fade-in", panel.isVisible && panel.alphaValue > 0.99)

        panel.hide()
        panel.show()
        try? await Task.sleep(nanoseconds: 450_000_000)
        record("Show during fade-out is honored", panel.isVisible && panel.alphaValue > 0.99)

        panel.hide()
        try? await Task.sleep(nanoseconds: 200_000_000)
        panel.toggle()
        panel.toggle()
        try? await Task.sleep(nanoseconds: 450_000_000)
        record("Two rapid toggles restore hidden state", !panel.isVisible)

        for _ in 0..<5 {
            panel.show()
            panel.hide()
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        record("Repeated interrupted transitions settle hidden", !panel.isVisible)
        panel.hide()
    }

    @MainActor static func checkPanelSizing() async {
        // Deliberate copies of the layout constants — cross-checks the product code.
        let slot: CGFloat = 76, gap: CGFloat = 8, hPad: CGFloat = 22, vPad: CGFloat = 18, margin: CGFloat = 36
        func expectedWidth(_ n: Int) -> CGFloat {
            let slots = CGFloat(max(n, 1))
            return 2 * margin + 2 * hPad + slots * slot + (slots - 1) * gap
        }
        let expectedHeight = 2 * margin + slot + 2 * vPad
        let store = AppStore.shared
        store.apps = []
        let panel = LauncherPanel()

        panel.show()
        try? await Task.sleep(nanoseconds: 300_000_000)
        record("Empty bar collapses to a single add slot",
               abs(panel.frame.width - expectedWidth(0)) < 1, "width=\(panel.frame.width)")
        record("Bar height stays constant", abs(panel.frame.height - expectedHeight) < 1,
               "height=\(panel.frame.height)")
        panel.hide()
        try? await Task.sleep(nanoseconds: 300_000_000)

        store.apps = (0..<3).map {
            AppItem(id: UUID(), name: "sizing-\($0)", path: "/tmp/test-\($0).app")
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        panel.show()
        try? await Task.sleep(nanoseconds: 300_000_000)
        record("Bar width follows app count (3)",
               abs(panel.frame.width - expectedWidth(3)) < 1,
               "width=\(panel.frame.width) expected=\(expectedWidth(3))")
        panel.hide()
        try? await Task.sleep(nanoseconds: 300_000_000)

        store.apps = (0..<8).map {
            AppItem(id: UUID(), name: "sizing-\($0)", path: "/tmp/test-\($0).app")
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        record("canAdd is false at max slots", !store.canAdd)
        panel.show()
        try? await Task.sleep(nanoseconds: 300_000_000)
        record("Bar width follows app count (8)",
               abs(panel.frame.width - expectedWidth(8)) < 1,
               "width=\(panel.frame.width) expected=\(expectedWidth(8))")

        // Remove while visible: debounce 0.25s + shrink animation 0.18s.
        let midXBefore = panel.frame.midX
        store.remove(at: 0)
        try? await Task.sleep(nanoseconds: 700_000_000)
        record("Visible remove shrinks the bar live",
               abs(panel.frame.width - expectedWidth(7)) < 1,
               "width=\(panel.frame.width) expected=\(expectedWidth(7))")
        record("Live shrink keeps the card centered", abs(panel.frame.midX - midXBefore) < 1,
               "midX delta=\(panel.frame.midX - midXBefore)")
        panel.hide()
        store.apps = []
    }

    @MainActor static func checkActivationTrigger() async {
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
        let store = AppStore.shared
        record("Default activation is double-Option", store.activationModifiers == [.option])

        let rawCases = ActivationModifier.allCases.map(\.rawValue)
        record("Right-click trigger is selectable", rawCases.contains("rightClick"))
        record("Mouse trigger opts out of the modifier state machine",
               ActivationModifier.rightClick.flag == nil)
        record("Modifier triggers keep a flag", ActivationModifier.option.flag == .option)

        // Legacy single-choice installs migrate losslessly.
        UserDefaults.standard.set("rightClick", forKey: ActivationModifier.legacyStorageKey)
        UserDefaults.standard.removeObject(forKey: ActivationModifier.selectionKey)
        record("Legacy single-trigger choice migrates",
               ActivationModifier.loadSelection() == [.rightClick])

        store.activationModifiers = [.option, .rightClick]
        record("Multi-trigger selection persists immediately",
               Set(UserDefaults.standard.stringArray(forKey: ActivationModifier.selectionKey) ?? [])
                   == ["option", "rightClick"])
        store.activationModifiers = [.option]

        record("Desktop menu probe runs cleanly with no menu open", !DesktopMenu.isOpen())
        record("Executable path lookup resolves own process",
               DesktopMenu.executablePath(of: ProcessInfo.processInfo.processIdentifier)?
                   .contains("CommandBChecks") == true)
    }

    @MainActor static func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<500 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    static func writeFixture(to url: URL) {
        let context = CGContext(data: nil, width: 1024, height: 1024,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 0.7))
        context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
    }

    static func dimensions(_ url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return 0 }
        return properties[kCGImagePropertyPixelWidth] as? Int ?? 0
    }
}
