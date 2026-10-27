import Foundation
import AppKit
import Combine
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore()
    static let maxSlots = 8

    @Published var apps: [AppItem] = []
    @Published var activationModifiers: Set<ActivationModifier> = ActivationModifier.defaultSelection {
        didSet {
            guard activationModifiers != oldValue else { return }
            ActivationModifier.saveSelection(activationModifiers)
            NotificationCenter.default.post(name: .activationHotkeyChanged, object: nil)
        }
    }

    // Turn a trigger on/off from Settings; the last remaining trigger cannot
    // be disabled so the launcher always stays reachable.
    func binding(for modifier: ActivationModifier) -> Binding<Bool> {
        Binding(
            get: { self.activationModifiers.contains(modifier) },
            set: { active in
                if active {
                    self.activationModifiers.insert(modifier)
                } else if self.activationModifiers.count > 1 {
                    self.activationModifiers.remove(modifier)
                }
            }
        )
    }

    var activationInstruction: String {
        let active = ActivationModifier.allCases.filter { activationModifiers.contains($0) }
        guard !active.isEmpty else { return "no activation shortcut" }
        return active.map(\.instructionText).joined(separator: " • ")
    }

    private var iconUpdates: AnyCancellable?

    private let storageKey = "com.oohevt.commandb.apps"
    private let showMenuBarIconKey = "com.oohevt.commandb.showMenuBarIcon"

    // Absent key means visible — the menu bar icon is the historic default.
    var showMenuBarIcon: Bool {
        get { UserDefaults.standard.object(forKey: showMenuBarIconKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: showMenuBarIconKey) }
    }

    var canAdd: Bool {
        apps.count < Self.maxSlots
    }

    private init() {
        load()
        loadActivationModifier()
        iconUpdates = NotificationCenter.default.publisher(for: .appIconDidLoad)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let items = try? JSONDecoder().decode([AppItem].self, from: data) {
            apps = items
        } else {
            apps = AppItem.defaults
            save()
        }
    }

    private func loadActivationModifier() {
        activationModifiers = ActivationModifier.loadSelection()
    }

    func save() {
        // At most eight small records: encode and commit in call order.
        // Independent detached tasks can let an older snapshot overwrite a new one.
        guard let data = try? JSONEncoder().encode(apps) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    func add(_ item: AppItem) {
        guard canAdd else { return }
        apps.append(item)
        save()
    }

    func remove(at index: Int) {
        guard index < apps.count else { return }
        AppItem.purgeIconCache(for: apps[index].id)
        apps.remove(at: index)
        save()
    }

    func replace(at index: Int, with item: AppItem) {
        guard index < apps.count else { return }
        AppItem.purgeIconCache(for: apps[index].id)
        apps[index] = item
        save()
    }

    // No save() here: called once per slot crossed during a drag —
    // persisting is the drag-end's job (LauncherView.reorderGesture.onEnded).
    func swapSlots(_ a: Int, _ b: Int) {
        guard apps.indices.contains(a), apps.indices.contains(b), a != b else { return }
        apps.swapAt(a, b)
    }

    func setUnread(_ value: Bool, at index: Int) {
        guard apps.indices.contains(index) else { return }
        apps[index].unread = value
        save()
    }

    func launch(_ item: AppItem) {
        if let i = apps.firstIndex(where: { $0.id == item.id }), apps[i].unread {
            apps[i].unread = false   // opening clears the unread dot
            save()
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
        NotificationCenter.default.post(name: .requestHideLauncher, object: nil)
    }

    func openSettings() {
        NotificationCenter.default.post(name: .requestHideLauncher, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            NotificationCenter.default.post(name: .requestOpenSettings, object: nil)
        }
    }
}

extension Notification.Name {
    static let appIconDidLoad = Notification.Name("com.oohevt.commandb.appIconDidLoad")
    static let requestHideLauncher = Notification.Name("com.oohevt.commandb.requestHideLauncher")
    static let requestOpenSettings = Notification.Name("com.oohevt.commandb.requestOpenSettings")
    static let launcherDidHide = Notification.Name("com.oohevt.commandb.launcherDidHide")
    static let activationHotkeyChanged = Notification.Name("com.oohevt.commandb.activationHotkeyChanged")
    static let menuBarIconVisibilityChanged = Notification.Name("com.oohevt.commandb.menuBarIconVisibilityChanged")
    static let appSlotsFull = Notification.Name("com.oohevt.commandb.appSlotsFull")
}
