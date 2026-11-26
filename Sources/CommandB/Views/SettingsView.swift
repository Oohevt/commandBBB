import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    // Cached once on appear — SMAppService.mainApp.status is a launchd IPC
    // call and must not run on every body evaluation.
    @State private var loginStatus: SMAppService.Status = .notRegistered
    @State private var loginError: String?
    @State private var showMenuBarIcon = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            appList
            Divider()
            footer
        }
        .frame(width: 420, height: 440)
    }

    private var header: some View {
        HStack {
            Text("CommandB Launcher")
                .font(.headline)
            Spacer()
            Text("\(store.apps.count) / \(AppStore.maxSlots)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var appList: some View {
        List {
            // Use enumerated + element.id so reorder/remove don't corrupt indices
            ForEach(Array(store.apps.enumerated()), id: \.element.id) { index, item in
                AppRowView(
                    item: item,
                    onReplace: { replaceApp(at: index) },
                    onRemove:  { store.remove(at: index) }
                )
            }
            .onMove { from, to in
                store.apps.move(fromOffsets: from, toOffset: to)
                store.save()
            }

            addButton
        }
        .listStyle(.inset)
    }

    private var addButton: some View {
        Button {
            addApp()
        } label: {
            Label("Add App…", systemImage: "plus.circle.fill")
                .foregroundStyle(store.canAdd ? .blue : .secondary)
        }
        .buttonStyle(.plain)
        .help(store.canAdd ? "Add app" : "App slots are full")
        .padding(.vertical, 4)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(spacing: 0) {
                ForEach(ActivationModifier.allCases) { modifier in
                    Toggle(isOn: store.binding(for: modifier)) {
                        Text(modifier.menuTitle)
                            .font(.system(size: 13))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                }
            }

            Divider()
            Toggle(isOn: Binding(
                get: { loginStatus == .enabled },
                set: setLaunchAtLogin
            )) {
                Text("Launch at Login")
                    .font(.system(size: 13))
            }
            .toggleStyle(.switch)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .onAppear {
                loginStatus = SMAppService.mainApp.status
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                let current = SMAppService.mainApp.status
                if current != loginStatus { loginError = nil }
                loginStatus = current
            }
            if let message = loginError ?? loginStatus.commandBMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)
            }
            if loginStatus == .requiresApproval {
                Button("打开系统登录项设置") {
                    SMAppService.openSystemSettingsLoginItems()
                }
                .padding(.bottom, 8)
            }

            Divider()
            Toggle(isOn: $showMenuBarIcon) {
                Text("Show Menu Bar Icon")
                    .font(.system(size: 13))
            }
            .toggleStyle(.switch)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .onAppear {
                showMenuBarIcon = store.showMenuBarIcon
            }
            .onChange(of: showMenuBarIcon) { visible in
                store.showMenuBarIcon = visible
                NotificationCenter.default.post(name: .menuBarIconVisibilityChanged, object: nil)
            }

            Divider()
            Text("Drag rows to reorder  •  \(store.activationInstruction)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
        }
    }

    private func addApp() {
        addPickedApp(prompt: "Add")
    }

    private func setLaunchAtLogin(_ enable: Bool) {
        loginError = nil
        let service = SMAppService.mainApp
        do {
            if enable {
                if service.status != .enabled && service.status != .requiresApproval {
                    try service.register()
                }
            } else {
                try service.unregister()
            }
        } catch {
            loginError = "开机启动设置失败：\(error.localizedDescription)"
        }
        loginStatus = service.status
    }

    private func replaceApp(at index: Int) {
        guard let url = runAppPicker(prompt: "Replace") else { return }
        let name = url.deletingPathExtension().lastPathComponent
        store.replace(at: index, with: AppItem(id: UUID(), name: name, path: url.path))
    }
}

extension SMAppService.Status {
    var commandBMessage: String? {
        switch self {
        case .enabled, .notRegistered: return nil
        case .requiresApproval: return "等待系统批准，开机启动尚未生效。"
        case .notFound: return "开机启动不可用，请确认应用已正确安装。"
        @unknown default: return "无法确认开机启动状态。"
        }
    }
}

struct AppRowView: View {
    let item: AppItem
    let onReplace: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: item.icon)
                .resizable()
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 13, weight: .medium))
                Text(item.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button(action: onReplace) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .help("Replace app")

            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red.opacity(0.75))
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
        .padding(.vertical, 3)
    }
}

// Shared picker helper
@MainActor
func addPickedApp(prompt: String) {
    guard AppStore.shared.canAdd else {
        NotificationCenter.default.post(name: .appSlotsFull, object: nil)
        return
    }
    guard let url = runAppPicker(prompt: prompt) else { return }
    let name = url.deletingPathExtension().lastPathComponent
    AppStore.shared.add(AppItem(id: UUID(), name: name, path: url.path))
}

@MainActor
func runAppPicker(prompt: String) -> URL? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [UTType.application]
    panel.allowsMultipleSelection = false
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.prompt = prompt
    NSApp.activate(ignoringOtherApps: true)
    return panel.runModal() == .OK ? panel.url : nil
}
