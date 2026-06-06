import AppKit
import SwiftUI

final class LauncherPanel: NSPanel {
    private var globalMonitor: Any?
    private var isTransitioning = false

    // Transparent margin around the card, giving the custom shadow room to render
    private let margin: CGFloat = 36
    private let cornerRadius: CGFloat = 28

    init() {
        let hosting = NSHostingView(
            rootView: LauncherView().environmentObject(AppStore.shared)
        )
        let cardSize = hosting.fittingSize
        let winSize = NSSize(width: cardSize.width + margin * 2,
                             height: cardSize.height + margin * 2)

        super.init(
            contentRect: NSRect(origin: .zero, size: winSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovable = false
        hasShadow = false  // system shadow ignores the layer mask → use a custom one

        let container = NSView(frame: NSRect(origin: .zero, size: winSize))
        container.wantsLayer = true
        contentView = container

        let cardFrame = NSRect(x: margin, y: margin,
                               width: cardSize.width, height: cardSize.height)

        hosting.frame = CGRect(origin: .zero, size: cardSize)
        hosting.autoresizingMask = [.width, .height]

        // Native Liquid Glass on macOS 26+, frosted-glass fallback below.
        let background = Self.makeGlassBackground(
            frame: CGRect(origin: .zero, size: cardSize),
            cornerRadius: cornerRadius, content: hosting
        )

        // Clip the glass to its own bounds so its built-in drop shadow (which
        // bleeds a few px outside the card) is cut off — the panel sits flush
        // with no visible halo on any background.
        let clip = NSView(frame: cardFrame)
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.addSubview(background)
        container.addSubview(clip)
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

    func toggle() {
        guard !isTransitioning else { return }
        isVisible ? hide() : show()
    }

    func show() {
        guard let screen = NSScreen.main else { return }
        let sx = screen.visibleFrame.midX - frame.width / 2
        let sy = screen.visibleFrame.midY - frame.height / 2
        setFrameOrigin(NSPoint(x: sx, y: sy))

        alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)

        isTransitioning = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            self?.isTransitioning = false
        })

        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.hide()
        }
    }

    func hide() {
        guard isVisible, !isTransitioning else { return }
        removeGlobalMonitor()

        isTransitioning = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.09
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            self?.isTransitioning = false
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
