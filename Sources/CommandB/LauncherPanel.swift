import AppKit
import SwiftUI
import Combine

final class LauncherPanel: NSPanel {
    private var globalMonitor: Any?
    private var isTransitioning = false
    private var wantsVisible = false

    // Transparent margin around the card, giving the custom shadow room to render.
    static let margin: CGFloat = 36

    private let cornerRadius: CGFloat = 28
    private var cardFrame: NSRect
    private let cardBackground: NSView
    private let cardContent: NSView
    private var countCancellable: AnyCancellable?

    init() {
        let hosting = NSHostingView(
            rootView: LauncherView().environmentObject(AppStore.shared)
        )
        let cardSize = hosting.fittingSize
        let m = Self.margin
        let winSize = NSSize(width: cardSize.width + m * 2,
                             height: cardSize.height + m * 2)
        let cardFrame = NSRect(x: m, y: m,
                               width: cardSize.width, height: cardSize.height)

        hosting.frame = CGRect(origin: .zero, size: cardSize)
        hosting.autoresizingMask = [.width, .height]

        // Native Liquid Glass on macOS 26+, frosted-glass fallback below.
        // The glass view self-clips via its own cornerRadius + layer mask;
        // a separate clip NSView created a rectangular boundary that fought
        // the glass rendering and left a visible purple border artefact.
        let background = Self.makeGlassBackground(
            frame: cardFrame,
            cornerRadius: cornerRadius, content: hosting
        )
        let container = NSView(frame: NSRect(origin: .zero, size: winSize))
        container.wantsLayer = true
        container.addSubview(background)

        self.cardFrame = cardFrame
        self.cardBackground = background
        self.cardContent = hosting

        super.init(
            contentRect: NSRect(origin: .zero, size: winSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        // Above desktop-island overlays (Vibe Island et al. hover around
        // level 27), below system popup menus (101).
        level = NSWindow.Level(rawValue: 28)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovable = false
        hasShadow = false  // system shadow ignores the layer mask → use a custom one
        contentView = container

        // Removing a slot from the context menu mutates the store while the
        // panel is on screen; everything else (pickers, Settings) hides the
        // panel first and is picked up by the relayout in show().
        countCancellable = AppStore.shared.$apps
            .map(\.count)
            .removeDuplicates()
            .dropFirst()
            .debounce(for: .seconds(0.25), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isVisible, !self.isTransitioning else { return }
                self.relayout(animated: true)
            }
    }

    /// Re-measures the SwiftUI card and resizes window + glass card to match.
    /// The window margin is symmetric, so recentering on the current midpoint
    /// keeps the card visually pinned while its width changes.
    private func relayout(animated: Bool) {
        let cardSize = cardContent.fittingSize
        guard cardSize != cardFrame.size else { return }
        let m = Self.margin
        cardFrame = NSRect(x: m, y: m, width: cardSize.width, height: cardSize.height)
        let winSize = NSSize(width: cardSize.width + m * 2, height: cardSize.height + m * 2)
        let winFrame = NSRect(x: frame.midX - winSize.width / 2,
                              y: frame.midY - winSize.height / 2,
                              width: winSize.width, height: winSize.height)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().setFrame(winFrame, display: true)
                cardBackground.animator().frame = cardFrame
            }
        } else {
            setFrame(winFrame, display: true)
            cardBackground.frame = cardFrame
        }
    }

    /// Returns an NSGlassEffectView (real Liquid Glass — refracts the desktop
    /// behind the panel) when available, otherwise the rounded VFX fallback.
    private static func makeGlassBackground(
        frame: NSRect, cornerRadius: CGFloat, content: NSView
    ) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.frame = frame
            glass.cornerRadius = cornerRadius
            glass.style = .clear   // see-through refractive glass (vs milky .regular)
            glass.contentView = content
            // Zero out any layer border the view hierarchy may inherit —
            // prevents the purple/accent-colour outline visible in dark mode.
            glass.wantsLayer = true
            glass.layer?.borderWidth = 0
            glass.layer?.masksToBounds = true
            return glass
        } else {
            let vfx = RoundedVisualEffectView()
            vfx.frame = frame
            vfx.cornerRadius = cornerRadius
            content.frame = vfx.bounds
            vfx.addSubview(content)
            return vfx
        }
    }

    func toggle(onMouseScreen: Bool = false) {
        wantsVisible ? hide() : show(onMouseScreen: onMouseScreen)
    }

    func show(onMouseScreen: Bool = false) {
        wantsVisible = true
        guard !isTransitioning, !isVisible else { return }
        relayout(animated: false)
        // Keyboard activation follows keyboard focus; a right-click should
        // summon the panel wherever the pointer is — the two differ when a
        // second display is attached.
        let screen = onMouseScreen
            ? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            : NSScreen.main
        guard let screen else { return }
        let sx = screen.visibleFrame.midX - frame.width / 2
        let sy = screen.visibleFrame.midY - frame.height / 2
        setFrameOrigin(NSPoint(x: sx, y: sy))

        alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)

        isTransitioning = true
        // Gentle pop: the card settles the last 2% of its size while fading in.
        cardBackground.frame = cardFrame.insetBy(dx: cardFrame.width * 0.01,
                                                 dy: cardFrame.height * 0.01)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
            cardBackground.animator().frame = cardFrame
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.cardBackground.frame = self.cardFrame
            self.isTransitioning = false
            if !self.wantsVisible { self.hide() }
        })

        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.hide()
        }
    }

    func hide() {
        wantsVisible = false
        guard isVisible, !isTransitioning else { return }
        isTransitioning = true
        removeGlobalMonitor()
        NotificationCenter.default.post(name: .launcherDidHide, object: nil)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.09
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.orderOut(nil)
            self.isTransitioning = false
            if self.wantsVisible { self.show() }
        })
    }

    private func removeGlobalMonitor() {
        if let m = globalMonitor {
            NSEvent.removeMonitor(m)
            globalMonitor = nil
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { hide() } // Esc
    }

    override var canBecomeKey: Bool { true }
}
