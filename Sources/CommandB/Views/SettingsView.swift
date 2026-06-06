import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore

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
            Text("Command+B Launcher")
                .font(.headline)
            Spacer()
            Text("\(store.apps.count) / 8")
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

            if store.apps.count < 8 {
                addButton
            }
        }
        .listStyle(.inset)
    }

    private var addButton: some View {
        Button {
            addApp()
        } label: {
            Label("Add App…", systemImage: "plus.circle.fill")
                .foregroundStyle(.blue)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            Toggle(isOn: Binding(
                get: { SMAppService.mainApp.status == .enabled },
                set: { enable in
                    try? enable
                        ? SMAppService.mainApp.register()
                        : SMAppService.mainApp.unregister()
                }
            )) {
                Text("Launch at Login")
                    .font(.system(size: 13))
            }
            .toggleStyle(.switch)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()
            Text("Drag rows to reorder  •  Press ⌘B to open the launcher")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
        }
    }

    private func addApp() {
        guard let url = runAppPicker(prompt: "Add") else { return }
        let name = url.deletingPathExtension().lastPathComponent
        store.add(AppItem(id: UUID(), name: name, path: url.path))
    }

    private func replaceApp(at index: Int) {
        guard let url = runAppPicker(prompt: "Replace") else { return }
        let name = url.deletingPathExtension().lastPathComponent
        store.replace(at: index, with: AppItem(id: UUID(), name: name, path: url.path))
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
func runAppPicker(prompt: String) -> URL? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [UTType.application]
    panel.allowsMultipleSelection = false
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.prompt = prompt
    NSApp.activate(ignoringOtherApps: true)
    return panel.runModal() == .OK ? panel.url : nil
}
