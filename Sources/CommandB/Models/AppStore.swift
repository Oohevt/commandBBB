import Foundation
import AppKit

@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore()

    @Published var apps: [AppItem] = []

    private let storageKey = "com.oohevt.commandb.apps"

    private init() {
        load()
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

    func save() {
        if let data = try? JSONEncoder().encode(apps) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    func add(_ item: AppItem) {
        guard apps.count < 8 else { return }
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

    // No save() here: dropEntered calls this once per slot crossed during a
    // drag — persisting is the drop's job (see SlotDropDelegate.performDrop).
    func move(from: Int, to: Int) {
        guard apps.indices.contains(from), from != to else { return }
        let item = apps.remove(at: from)
        let target = from < to ? to - 1 : to
        apps.insert(item, at: max(0, min(target, apps.count)))
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
        NotificationCenter.default.post(name: .hideLauncher, object: nil)
    }

    func openSettings() {
        NotificationCenter.default.post(name: .hideLauncher, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

extension Notification.Name {
    static let hideLauncher = Notification.Name("com.oohevt.commandb.hideLauncher")
}
