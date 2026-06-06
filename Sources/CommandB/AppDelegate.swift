import AppKit
import Carbon.HIToolbox

// Module-level callback storage — required because C function pointers can't capture context
fileprivate var _hotKeyAction: (() -> Void)?

// C-compatible handler passed to Carbon
fileprivate func hotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    _hotKeyAction?()
    return noErr
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: LauncherPanel?
    private var statusItem: NSStatusItem?
    private var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = LauncherPanel()
        setupMenuBar()
        setupHotKey()
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

    private func setupHotKey() {
        _hotKeyAction = { [weak self] in
            DispatchQueue.main.async { self?.panel?.toggle() }
        }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyHandler,
            1,
            &eventSpec,
            nil,
            nil
        )

        let hotKeyID = EventHotKeyID(signature: 0x434D4442, id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_B),
            UInt32(cmdKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    @objc private func hideLauncher() {
        panel?.hide()
    }

    @objc private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
