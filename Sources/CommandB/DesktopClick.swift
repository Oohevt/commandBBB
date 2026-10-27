import AppKit
import Darwin

// Right-clicks on the Finder desktop (or the Dock) are special: their context
// menu opens on the first press and a second press only closes it, so a
// double-right-click trigger must never fire there.
//
// Detecting "this click would land on the desktop" statically is a losing
// game — invisible all-Spaces overlays, click-through desktop islands and
// other-Space windows all poison both the CGWindowList z-order and the AX
// hit-test. So we watch the actual conflict signal instead: whether a Finder
// or Dock context menu is open right now.
enum DesktopMenu {
    // kCGPopUpMenuWindowLevel; the C macro isn't exposed to Swift.
    private static let popUpMenuLevel = 101

    static func isOpen() -> Bool {
        let systemApps = Set(
            [("com.apple.finder" as String), "com.apple.dock"].compactMap { bundleID in
                NSWorkspace.shared.runningApplications
                    .first { $0.bundleIdentifier == bundleID }?.processIdentifier
            }
        )
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] else { return false }
        for window in list {
            guard let layer = window[kCGWindowLayer as String] as? Int,
                  layer == popUpMenuLevel,
                  let owner = window[kCGWindowOwnerPID as String] as? Int else { continue }
            if systemApps.contains(pid_t(owner)) { return true }
            // On current macOS the menu itself is drawn by a per-app XPC
            // helper ("DockHelper.xpc" etc.) re-parented to launchd, so its
            // PID matches nothing — match the helper's embedded app instead.
            if let path = executablePath(of: pid_t(owner)),
               path.contains("/Finder.app/") || path.contains("/Dock.app/") {
                return true
            }
        }
        return false
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)   // PROC_PIDPATHINFO_MAXSIZE
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}
