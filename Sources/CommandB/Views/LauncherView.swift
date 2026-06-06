import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LauncherView: View {
    @EnvironmentObject private var store: AppStore

    // Cursor x within the row (.local space) drives Dock-style magnification.
    @State private var hoverX: CGFloat? = nil
    // Index currently being dragged for reorder.
    @State private var dragging: Int? = nil

    private let slotW: CGFloat = 76
    private let spacing: CGFloat = 8
    private let hPad: CGFloat = 22

    private func centerX(_ i: Int) -> CGFloat {
        hPad + CGFloat(i) * (slotW + spacing) + slotW / 2
    }

    // Gaussian falloff: hovered icon biggest, neighbours taper off.
    private func scaleFor(_ i: Int) -> CGFloat {
        guard let hx = hoverX else { return 1 }
        let d = centerX(i) - hx
        let sigma = (slotW + spacing) * 0.7
        return 1 + 0.5 * exp(-(d * d) / (2 * sigma * sigma))
    }

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<8, id: \.self) { index in
                if index < store.apps.count {
                    AppSlotButton(
                        item: store.apps[index],
                        index: index,
                        scale: scaleFor(index),
                        dragging: $dragging
                    )
                } else {
                    EmptySlotButton()
                }
            }
        }
        .padding(.horizontal, hPad)
        .padding(.vertical, 18)
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let p): hoverX = p.x
            case .ended: hoverX = nil
            }
        }
        .animation(.easeOut(duration: 0.10), value: hoverX)
    }
}

// MARK: - Filled slot

struct AppSlotButton: View {
    let item: AppItem
    let index: Int
    let scale: CGFloat
    @Binding var dragging: Int?

    var body: some View {
        Button {
            AppStore.shared.launch(item)
        } label: {
            Image(nsImage: item.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 13))
                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                .scaleEffect(scale, anchor: .center)
                .overlay(alignment: .topTrailing) {
                    if item.unread {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 12, height: 12)
                            .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                            .offset(x: 4, y: -4)
                    }
                }
        }
        .buttonStyle(.plain)
        .frame(width: 76, height: 76)
        .onDrag {
            dragging = index
            return NSItemProvider(object: String(index) as NSString)
        }
        .onDrop(of: [UTType.text], delegate: SlotDropDelegate(toIndex: index, dragging: $dragging))
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

// MARK: - Empty slot (icon-only "+")

struct EmptySlotButton: View {
    @State private var isHovered = false

    var body: some View {
        Button {
            pickAndAdd()
        } label: {
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

// MARK: - Drag-to-reorder

struct SlotDropDelegate: DropDelegate {
    let toIndex: Int
    @Binding var dragging: Int?

    func dropEntered(info: DropInfo) {
        guard let from = dragging, from != toIndex else { return }
        AppStore.shared.move(from: from, to: toIndex)
        dragging = toIndex   // dragged item now lives at this slot
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
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
