import AppKit

struct ModifierDoubleTap {
    private var trackedFlag: NSEvent.ModifierFlags?
    private var tapDirty = false
    private var lastTap: (flag: NSEvent.ModifierFlags, time: TimeInterval)?
    private static let flags: [NSEvent.ModifierFlags] = [.command, .shift, .control, .option]
    private static let mask: NSEvent.ModifierFlags = [.command, .shift, .control, .option]

    mutating func handle(flags: NSEvent.ModifierFlags, selected: Set<ActivationModifier>, at time: TimeInterval) -> Bool {
        let activeFlags = selected.compactMap(\.flag)
        guard !activeFlags.isEmpty else { return false }
        // Caps Lock, Fn and device-specific bits do not dirty a clean modifier tap.
        let flags = flags.intersection(Self.mask)
        let present = Self.flags.filter { flags.contains($0) }

        if present.isEmpty {
            guard let releasedFlag = trackedFlag else { return false }
            defer { trackedFlag = nil; tapDirty = false }
            guard !tapDirty else {
                lastTap = nil
                return false
            }
            if let lastTap, lastTap.flag == releasedFlag, time - lastTap.time <= 0.35 {
                self.lastTap = nil
                return true
            }
            lastTap = (releasedFlag, time)
            return false
        }
        if let trackedFlag {
            if flags != trackedFlag { tapDirty = true }
            return false
        }
        if present.count == 1, activeFlags.contains(present[0]) {
            trackedFlag = present[0]
            tapDirty = false
            return false
        }
        lastTap = nil
        return false
    }

    mutating func keyDown() {
        if trackedFlag != nil { tapDirty = true }
        lastTap = nil
    }

    mutating func reset() {
        self = ModifierDoubleTap()
    }
}

enum ActivationModifier: String, CaseIterable, Identifiable {
    case command
    case option
    case control
    case shift
    case rightClick

    var id: String { rawValue }

    // Legacy single-choice key, kept only to migrate older installs.
    static let legacyStorageKey = "com.oohevt.commandb.activationModifier"
    static let selectionKey = "com.oohevt.commandb.activationModifiers"

    static let defaultSelection: Set<ActivationModifier> = [.option]

    static func loadSelection() -> Set<ActivationModifier> {
        let defaults = UserDefaults.standard
        if let raws = defaults.stringArray(forKey: selectionKey) {
            return Set(raws.compactMap(ActivationModifier.init(rawValue:)))
        }
        if let raw = defaults.string(forKey: legacyStorageKey),
           let single = ActivationModifier(rawValue: raw) {
            return [single]
        }
        return defaultSelection
    }

    static func saveSelection(_ selection: Set<ActivationModifier>) {
        UserDefaults.standard.set(selection.map(\.rawValue).sorted(), forKey: selectionKey)
    }

    // nil for mouse triggers — they never take part in the flagsChanged machine.
    var flag: NSEvent.ModifierFlags? {
        switch self {
        case .command: return .command
        case .option: return .option
        case .control: return .control
        case .shift: return .shift
        case .rightClick: return nil
        }
    }

    var symbol: String {
        switch self {
        case .command: return "⌘"
        case .option: return "⌥"
        case .control: return "⌃"
        case .shift: return "⇧"
        case .rightClick: return "🖱"
        }
    }

    var menuTitle: String {
        switch self {
        case .command: return "Double-tap ⌘"
        case .option: return "Double-tap ⌥"
        case .control: return "Double-tap ⌃"
        case .shift: return "Double-tap ⇧"
        case .rightClick: return "Double Right-Click"
        }
    }

    var instructionText: String {
        switch self {
        case .rightClick:
            return "Double right-click to open the launcher"
        default:
            return "Double-tap \(symbol) to open the launcher"
        }
    }
}
