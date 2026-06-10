import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LauncherView: View {
    @EnvironmentObject private var store: AppStore
    @State private var hoverX: CGFloat? = nil
    @State private var draggingID: UUID? = nil

    private let slotW: CGFloat = 76
    private let spacing: CGFloat = 8
    private let hPad: CGFloat = 22
    private let vPad: CGFloat = 18
    private var step: CGFloat { slotW + spacing }

    // Animation duration for neighbour reorder. Must be deterministic (not
    // spring) so we know exactly when the animation is done before revealing
    // the dragged icon. Spring(response: 0.28) takes ~300ms to settle; a
    // timed curve lets us schedule the reveal precisely.
    fileprivate static let reorderDuration: TimeInterval = 0.18

    private func centerX(_ i: Int) -> CGFloat {
        hPad + CGFloat(i) * step + slotW / 2
    }

    private func scaleFor(_ i: Int) -> CGFloat {
        if draggingID != nil { return 1 }
        guard let hx = hoverX else { return 1 }
        let d = centerX(i) - hx
        let sigma = step * 0.7
        return 1 + 0.5 * exp(-(d * d) / (2 * sigma * sigma))
    }

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(Array(store.apps.enumerated()), id: \.element.id) { index, item in
                let s = scaleFor(index)
                AppSlotButton(item: item, index: index, scale: s, draggingID: $draggingID)
            }
            ForEach(store.apps.count..<8, id: \.self) { _ in
                EmptySlotButton()
            }
        }
        .padding(.horizontal, hPad)
        .padding(.vertical, vPad)
        // Neighbour reorder: easeOut with a fixed duration so the reveal
        // delay below can guarantee the animation has finished.
        .animation(.easeOut(duration: Self.reorderDuration), value: store.apps.map(\.id))
        .animation(.easeOut(duration: 0.10), value: hoverX)
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let p): hoverX = p.x
            case .ended: hoverX = nil
            }
        }
        // Reset drag state whenever the panel hides (Esc / outside click /
        // keyboard shortcut). Without this, a cancelled drag leaves the
        // dragged slot permanently invisible.
        .onReceive(NotificationCenter.default.publisher(for: .hideLauncher)) { _ in
            draggingID = nil
        }
    }

}

// MARK: - Filled slot

struct AppSlotButton: View {
    let item: AppItem
    let index: Int
    let scale: CGFloat
    @Binding var draggingID: UUID?

    var body: some View {
        let side = 54 * scale
        Button {
            AppStore.shared.launch(item)
        } label: {
            Image(nsImage: item.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 13 * scale))
                .shadow(color: .black.opacity(0.18), radius: 4 * scale, y: 2 * scale)
                .overlay(alignment: .topTrailing) {
                    if item.unread {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 12 * scale, height: 12 * scale)
                            .overlay(Circle().strokeBorder(.white, lineWidth: 1.5 * scale))
                            .offset(x: 4 * scale, y: -4 * scale)
                    }
                }
        }
        .buttonStyle(.plain)
        .frame(width: 76, height: 76)
        .opacity(draggingID == item.id ? 0 : 1)
        .onDrag {
            draggingID = item.id
            return NSItemProvider(object: item.id.uuidString as NSString)
        } preview: {
            Image(nsImage: item.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 13))
                .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
        }
        .onDrop(of: [UTType.text],
                delegate: SlotDropDelegate(toIndex: index, draggingID: $draggingID))
        .contextMenu {
            Button(item.unread ? "标记为已读" : "标记为未读") {
                AppStore.shared.setUnread(!item.unread, at: index)
            }
            Divider()
            Button("替换应用…") { pickAndReplace(at: index) }
            Button("从应用栏移除", role: .destructive) { AppStore.shared.remove(at: index) }
        }
    }
}

// MARK: - Drag-to-reorder

struct SlotDropDelegate: DropDelegate {
    let toIndex: Int
    @Binding var draggingID: UUID?

    func dropEntered(info: DropInfo) {
        guard let id = draggingID,
              let from = AppStore.shared.apps.firstIndex(where: { $0.id == id }),
              from != toIndex else { return }
        AppStore.shared.swapSlots(from, toIndex)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        AppStore.shared.save()
        // Delay = reorder animation duration + preview fade buffer.
        // If we reveal immediately or too early:
        //   (a) animation mid-flight → icon appears at ghost position
        //   (b) system preview still visible → two icons overlap
        let delay = LauncherView.reorderDuration + 0.08
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            withAnimation(.easeIn(duration: 0.08)) { draggingID = nil }
        }
        return true
    }
}

// MARK: - Empty slot

struct EmptySlotButton: View {
    @State private var isHovered = false

    var body: some View {
        Button { pickAndAdd() } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(
                        Color.secondary.opacity(isHovered ? 0.45 : 0.2),
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])
                    )
                    .frame(width: 54, height: 54)
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(.tertiary)
            }
            .scaleEffect(isHovered ? 1.08 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.spring(response: 0.18, dampingFraction: 0.65), value: isHovered)
        .frame(width: 76, height: 76)
    }
}

// MARK: - Pickers

private func pickAndReplace(at index: Int) {
    NotificationCenter.default.post(name: .hideLauncher, object: nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        guard let url = runAppPicker(prompt: "替换") else { return }
        let name = url.deletingPathExtension().lastPathComponent
        AppStore.shared.replace(at: index, with: AppItem(id: UUID(), name: name, path: url.path))
    }
}

private func pickAndAdd() {
    NotificationCenter.default.post(name: .hideLauncher, object: nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        guard let url = runAppPicker(prompt: "添加") else { return }
        let name = url.deletingPathExtension().lastPathComponent
        AppStore.shared.add(AppItem(id: UUID(), name: name, path: url.path))
    }
}
