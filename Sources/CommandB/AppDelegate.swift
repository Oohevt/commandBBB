import AppKit
import ApplicationServices
import os

private let hotkeyLog = Logger(subsystem: "com.oohevt.commandb", category: "hotkey")

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: LauncherPanel?
    private var statusItem: NSStatusItem?
    private var monitors: [Any] = []
    private var permissionTimer: Timer?

    // Double-tap ⌘ detection. A "clean tap" is ⌘ down → up with no other key
    // or modifier involved; two clean taps within the window toggle the panel.
    private var cmdIsDown = false
    private var tapDirty = false
    private var lastCleanTapAt: TimeInterval = 0
    private let doubleTapWindow: TimeInterval = 0.35

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = LauncherPanel()
        setupMenuBar()
        startMonitoringWhenTrusted()
        // NOTE: do NOT touch SMAppService on launch. Reading its status /
        // registering triggers a sandboxd App-Management (SystemPolicyAppBundles)
        // TCC preflight, which — under ad-hoc signing — re-prompts on every
        // launch. Launch-at-login is now opt-in via Settings only.

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hideLauncher),
            name: .hideLauncher,
            object: nil
        )
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(
            systemSymbolName: "square.grid.2x2.fill",
            accessibilityDescription: "CommandB"
        )

        let menu = NSMenu()
        menu.addItem(NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        ))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit CommandB",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        statusItem?.menu = menu
    }

    // MARK: - Accessibility permission

    // Global NSEvent monitors silently receive nothing until the app is
    // AX-trusted, so prompt once and poll until the user flips the switch.
    private func startMonitoringWhenTrusted() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        hotkeyLog.log("AX trusted at launch: \(trusted)")
        if trusted {
            installMonitors()
            return
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, AXIsProcessTrusted() else { return }
            self.permissionTimer?.invalidate()
            self.permissionTimer = nil
            hotkeyLog.log("AX granted after poll, installing monitors")
            self.installMonitors()
        }
    }

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        // Global monitors never see our own events, so local ones are needed
        // for double-tap-to-hide while the panel is the key window.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] e in
            self?.handleFlagsChanged(e)
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] _ in
            self?.handleKeyDown()
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] e in
            self?.handleFlagsChanged(e)
            return e
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            self?.handleKeyDown()
            return e
        }) { monitors.append(m) }
        hotkeyLog.log("monitors installed: \(self.monitors.count)")
    }

    // MARK: - Double-tap ⌘ state machine

    // Only real modifier keys matter; .capsLock/.numericPad/.function would
    // otherwise keep `flags` non-empty and mark every tap dirty.
    private static let modMask: NSEvent.ModifierFlags = [.command, .shift, .control, .option]

    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(Self.modMask)
        let now = ProcessInfo.processInfo.systemUptime

        if flags.contains(.command) {
            if !cmdIsDown {
                cmdIsDown = true
                tapDirty = (flags != .command)
            } else if flags != .command {
                tapDirty = true
            }
        } else if cmdIsDown {
            cmdIsDown = false
            defer { tapDirty = false }
            guard !tapDirty, flags.isEmpty else {
                lastCleanTapAt = 0
                return
            }
            if now - lastCleanTapAt <= doubleTapWindow {
                lastCleanTapAt = 0
                hotkeyLog.log("double-tap ⌘ -> toggle")
                panel?.toggle()   // monitor handlers already run on the main thread
            } else {
                hotkeyLog.log("clean tap")
                lastCleanTapAt = now
            }
        }
    }

    private func handleKeyDown() {
        // Fast path: nothing pending, so the vast majority of keystrokes exit here.
        guard cmdIsDown || lastCleanTapAt != 0 else { return }
        if cmdIsDown { tapDirty = true }
        lastCleanTapAt = 0
    }

    @objc private func hideLauncher() {
        panel?.hide()
    }

    @objc private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
