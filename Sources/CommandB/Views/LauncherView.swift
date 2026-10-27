import SwiftUI
import AppKit

struct LauncherView: View {
    @EnvironmentObject private var store: AppStore
    @State private var hoverX: CGFloat? = nil
    @State private var draggingID: UUID? = nil
    @State private var dragLocation: CGPoint? = nil
    @State private var dragIsLifted = false

    private let slotW: CGFloat = 76
    private let spacing: CGFloat = 8
    private let hPad: CGFloat = 22
    private let vPad: CGFloat = 18
    private var step: CGFloat { slotW + spacing }

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
                AppSlotButton(
                    item: item,
                    index: index,
                    scale: s,
                    draggingID: $draggingID,
                    dragLocation: $dragLocation,
                    onDragChanged: handleDragChanged,
                    onDragEnded: handleDragEnded
                )
            }
            if store.apps.isEmpty {
                EmptySlotButton()
            }
        }
        .padding(.horizontal, hPad)
        .padding(.vertical, vPad)
        .coordinateSpace(name: "launcher")
        .animation(.easeOut(duration: Self.reorderDuration), value: store.apps.map(\.id))
        .animation(.easeOut(duration: 0.10), value: hoverX)
        .overlay(alignment: .topLeading) {
            if let draggingID,
               let dragLocation,
               let item = store.apps.first(where: { $0.id == draggingID }) {
                DraggedAppIcon(item: item, isLifted: dragIsLifted)
                    .position(dragLocation)
                    .allowsHitTesting(false)
            }
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let p): hoverX = p.x
            case .ended: hoverX = nil
            }
        }
        // Reset drag state whenever the panel hides (Esc / outside click /
        // keyboard shortcut). Without this, a cancelled drag leaves the
        // dragged slot permanently invisible.
        .onReceive(NotificationCenter.default.publisher(for: .launcherDidHide)) { _ in
            draggingID = nil
            dragLocation = nil
            dragIsLifted = false
        }
    }

    private func handleDragChanged(id: UUID, location: CGPoint) {
        if draggingID == nil {
            draggingID = id
            dragLocation = location
            withAnimation(.spring(response: 0.18, dampingFraction: 0.74)) {
                dragIsLifted = true
            }
            return
        }
        dragLocation = location

        guard let from = store.apps.firstIndex(where: { $0.id == id }) else { return }
        let rawIndex = Int(((location.x - hPad) / step).rounded())
        let to = min(max(rawIndex, 0), max(store.apps.count - 1, 0))
        guard from != to else { return }
        store.swapSlots(from, to)
    }

    private func handleDragEnded() {
        let endedID = draggingID
        store.save()
        withAnimation(.spring(response: 0.14, dampingFraction: 0.82)) {
            dragIsLifted = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard draggingID == endedID else { return }
            draggingID = nil
            dragLocation = nil
        }
    }
}

// MARK: - Filled slot

struct AppSlotButton: View {
    let item: AppItem
    let index: Int
    let scale: CGFloat
    @Binding var draggingID: UUID?
    @Binding var dragLocation: CGPoint?
    let onDragChanged: (UUID, CGPoint) -> Void
    let onDragEnded: () -> Void

    var body: some View {
        let side = 54 * scale
        AppIconView(
            item: item,
            side: side,
            cornerRadius: 13 * scale,
            shadowScale: scale,
            shadowOpacity: 0.18
        )
        .frame(width: 76, height: 76)
        .opacity(draggingID == item.id ? 0 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            guard draggingID == nil, dragLocation == nil else { return }
            AppStore.shared.launch(item)
        }
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named("launcher"))
                .onChanged { value in
                    onDragChanged(item.id, value.location)
                }
                .onEnded { _ in
                    onDragEnded()
                }
        )
        .contextMenu {
            Button(item.unread ? "标记为已读" : "标记为未读") {
                AppStore.shared.setUnread(!item.unread, at: index)
            }
            Divider()
            Button("添加应用…") { pickAndAdd() }
                .disabled(!AppStore.shared.canAdd)
            Button("替换应用…") { pickAndReplace(at: index) }
            Button("从应用栏移除", role: .destructive) { AppStore.shared.remove(at: index) }
            Divider()
            Button("设置…") { AppStore.shared.openSettings() }
        }
    }
}

private struct AppIconView: View {
    let item: AppItem
    let side: CGFloat
    let cornerRadius: CGFloat
    let shadowScale: CGFloat
    let shadowOpacity: Double

    var body: some View {
        Image(nsImage: item.icon)
            .resizable()
            .interpolation(.high)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .shadow(color: .black.opacity(shadowOpacity), radius: 4 * shadowScale, y: 2 * shadowScale)
            .overlay(alignment: .topTrailing) {
                if item.unread {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 12 * shadowScale, height: 12 * shadowScale)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 1.5 * shadowScale))
                        .offset(x: 4 * shadowScale, y: -4 * shadowScale)
                }
            }
    }
}

private struct DraggedAppIcon: View {
    let item: AppItem
    let isLifted: Bool

    var body: some View {
        AppIconView(item: item, side: 54, cornerRadius: 13, shadowScale: 1, shadowOpacity: 0)
            .scaleEffect(isLifted ? 1.14 : 0.94)
            .opacity(isLifted ? 0.98 : 0.72)
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
        // Settings lifeline when the menu bar icon is hidden and no app slots exist yet.
        .contextMenu {
            Button("设置…") { AppStore.shared.openSettings() }
        }
    }
}

// MARK: - Pickers

private func pickAndReplace(at index: Int) {
    NotificationCenter.default.post(name: .requestHideLauncher, object: nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        guard let url = runAppPicker(prompt: "替换") else { return }
        let name = url.deletingPathExtension().lastPathComponent
        AppStore.shared.replace(at: index, with: AppItem(id: UUID(), name: name, path: url.path))
    }
}

private func pickAndAdd() {
    NotificationCenter.default.post(name: .requestHideLauncher, object: nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        addPickedApp(prompt: "添加")
    }
}
