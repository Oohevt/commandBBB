import AppKit
import ApplicationServices
import SwiftUI
import os

private let hotkeyLog = Logger(subsystem: "com.oohevt.commandb", category: "hotkey")

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: LauncherPanel?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var monitors: [Any] = []
    private var permissionTimer: Timer?
    private var activationModifiers = ActivationModifier.loadSelection()

    // Double-tap modifier detection. A "clean tap" is a selected modifier down → up with no other key
    // or modifier involved; two clean taps within the window toggle the panel.
    private var modifierIsDown = false
    private var tapDirty = false
    private var trackedFlag: NSEvent.ModifierFlags?   // which selected modifier the current tap belongs to
    private var lastCleanTapAt: TimeInterval = 0
    private let doubleTapWindow: TimeInterval = 0.35

    // Double right-click detection reuses the same toggle, timed by the
    // user's own system double-click setting.
    private var lastRightClickAt: TimeInterval = 0
    private var doubleClickWindow: TimeInterval { NSEvent.doubleClickInterval }

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = LauncherPanel()
        setupMenuBar()
        statusItem?.isVisible = AppStore.shared.showMenuBarIcon
        startMonitoringWhenTrusted()
        // NOTE: do NOT touch SMAppService on launch. Reading its status /
        // registering triggers a sandboxd App-Management (SystemPolicyAppBundles)
        // TCC preflight, which — under ad-hoc signing — re-prompts on every
        // launch. Launch-at-login is now opt-in via Settings only.

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hideLauncher),
            name: .requestHideLauncher,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(activationHotkeyChanged),
            name: .activationHotkeyChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showSlotsFullAlert),
            name: .appSlotsFull,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSettings),
            name: .requestOpenSettings,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuBarIconVisibilityChanged),
            name: .menuBarIconVisibilityChanged,
            object: nil
        )

        // CommandB 是 LSUIElement，手动打开也拿不到前台激活信号，
        // 用「控制台会话年龄」区分：登录后 120 秒内的首次启动是登录项
        // 开机自启，不弹设置窗；用户主动打开照旧出设置页（在运行时走 reopen）。
        let age = Self.consoleSessionAge()
        let loginLaunch = age.map { $0 < Self.loginLaunchWindow } ?? true
        Self.logLaunch(sessionAge: age, suppressed: loginLaunch)
        if !loginLaunch { openSettings() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 应用常驻时「搜索/图标打开」是 reopen，同样要出设置页
        openSettings()
        return true
    }

    /// 登录后这个秒数内的首次启动视为登录项开机自启。
    private static let loginLaunchWindow: TimeInterval = 120

    private static func consoleSessionAge() -> TimeInterval? {
        setutxent()
        defer { endutxent() }
        var start: TimeInterval?
        while let e = getutxent()?.pointee {
            guard e.ut_type == Int32(USER_PROCESS) else { continue }
            let line = withUnsafeBytes(of: e.ut_line) {
                String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            if line == "console" {
                start = TimeInterval(e.ut_tv.tv_sec) + TimeInterval(e.ut_tv.tv_usec) / 1e6
            }
        }
        return start.map { Date().timeIntervalSince1970 - $0 }
    }

    private static func logLaunch(sessionAge: TimeInterval?, suppressed: Bool) {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CommandB")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("launch.log")
        let age = sessionAge.map { String(format: "%.0f", $0) } ?? "unknown"
        let line = "\(Date()) sessionAge=\(age)s suppressed=\(suppressed)\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: file)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(
            systemSymbolName: "square.grid.2x2.fill",
            accessibilityDescription: "CommandB"
        )

        let menu = NSMenu()
        let addItem = NSMenuItem(
            title: "Add App…",
            action: #selector(addApp),
            keyEquivalent: "a"
        )
        addItem.target = self
        menu.addItem(addItem)

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
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
        // Only the monitors some active trigger needs go in: global monitors
        // wake this process on every matching event system-wide, so idle
        // trigger types must not tax unrelated input. Global monitors never
        // see our own events, so local ones are still needed for input on
        // our own windows.
        if activationModifiers.contains(.rightClick) {
            // The local variant covers right-clicks on our own panel/settings.
            if let m = NSEvent.addGlobalMonitorForEvents(matching: .rightMouseDown, handler: { [weak self] _ in
                self?.handleRightMouseDown()
            }) { monitors.append(m) }
            if let m = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown, handler: { [weak self] e in
                self?.handleRightMouseDown()
                return e
            }) { monitors.append(m) }
        }
        if activationModifiers.contains(where: { $0.flag != nil }) {
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
        }
        hotkeyLog.log("monitors installed: \(self.monitors.count) for \(self.activationModifiers.map(\.rawValue).sorted().joined(separator: ","), privacy: .public)")
    }

    private func teardownMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    // MARK: - Double-tap modifier state machine

    // Only real modifier keys matter; .capsLock/.numericPad/.function would
    // otherwise keep `flags` non-empty and mark every tap dirty.
    private static let modMask: NSEvent.ModifierFlags = [.command, .shift, .control, .option]
    private static let modMaskFlags: [NSEvent.ModifierFlags] = [.command, .shift, .control, .option]

    private func handleFlagsChanged(_ event: NSEvent) {
        // No modifier triggers selected — mouse-only mode, taps are inert.
        let activeFlags = activationModifiers.compactMap(\.flag)
        guard !activeFlags.isEmpty else { return }
        let flags = event.modifierFlags.intersection(Self.modMask)
        let present = Self.modMaskFlags.filter { flags.contains($0) }
        let now = ProcessInfo.processInfo.systemUptime

        if present.isEmpty {
            guard modifierIsDown else { return }
            // the tracked modifier was released — judge the tap
            modifierIsDown = false
            defer { trackedFlag = nil; tapDirty = false }
            guard !tapDirty else {
                lastCleanTapAt = 0
                return
            }
            if now - lastCleanTapAt <= doubleTapWindow {
                lastCleanTapAt = 0
                let symbol = activationModifiers.first { $0.flag == trackedFlag }?.symbol ?? "?"
                hotkeyLog.log("double-tap \(symbol, privacy: .public) -> toggle")
                panel?.toggle()   // monitor handlers already run on the main thread
            } else {
                hotkeyLog.log("clean tap")
                lastCleanTapAt = now
            }
        } else if modifierIsDown {
            // any deviation from the exact tracked modifier dirties the tap
            if trackedFlag == nil || flags != trackedFlag { tapDirty = true }
        } else if present.count == 1, activeFlags.contains(present[0]) {
            modifierIsDown = true
            trackedFlag = present[0]
            tapDirty = false
        } else {
            // untracked combo (e.g. ⌘⌥) — must never bridge two clean taps
            lastCleanTapAt = 0
        }
    }

    private func handleKeyDown() {
        // Fast path: nothing pending, so the vast majority of keystrokes exit here.
        guard modifierIsDown || lastCleanTapAt != 0 else { return }
        if modifierIsDown { tapDirty = true }
        lastCleanTapAt = 0
    }

    private func handleRightMouseDown() {
        guard activationModifiers.contains(.rightClick) else { return }
        // While the panel is up, one right-click anywhere outside already
        // hides it (LauncherPanel's own monitor); counting taps here would
        // make the second click re-open it.
        if panel?.isVisible == true {
            lastRightClickAt = 0
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastRightClickAt <= doubleClickWindow {
            lastRightClickAt = 0
            // A Finder/Dock context menu being up right now is exactly the
            // desktop conflict — press two only closes that menu. Sample
            // twice: the menu press one opened may be swapped for press
            // two's own menu mid-flight, but it is present on one side.
            if DesktopMenu.isOpen() {
                hotkeyLog.log("right-click with Finder/Dock menu open, ignoring")
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self else { return }
                    if DesktopMenu.isOpen() {
                        hotkeyLog.log("right-click with Finder/Dock menu open (delayed sample), ignoring")
                    } else {
                        hotkeyLog.log("double right-click -> toggle")
                        self.panel?.toggle(onMouseScreen: true)
                    }
                }
            }
        } else {
            // This press may itself be closing a stale desktop/Dock menu;
            // a tap that lands on a menu must never start a new chain.
            if DesktopMenu.isOpen() {
                hotkeyLog.log("right-click lands on open Finder/Dock menu, not arming")
            } else {
                hotkeyLog.log("right-click armed")
                lastRightClickAt = now
            }
        }
    }
    @objc private func activationHotkeyChanged() {
        activationModifiers = ActivationModifier.loadSelection()
        modifierIsDown = false
        trackedFlag = nil
        tapDirty = false
        lastCleanTapAt = 0
        lastRightClickAt = 0
        teardownMonitors()
        installMonitors()
    }

    @objc @MainActor private func menuBarIconVisibilityChanged() {
        statusItem?.isVisible = AppStore.shared.showMenuBarIcon
    }

    @objc private func hideLauncher() {
        panel?.hide()
    }

    @objc private func addApp() {
        Task { @MainActor in
            addPickedApp(prompt: "Add")
        }
    }

    @objc private func showSlotsFullAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "App slots are full"
        alert.informativeText = "Remove or replace an app before adding another one."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc @MainActor private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView().environmentObject(AppStore.shared)
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "CommandB Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 420, height: 440))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
