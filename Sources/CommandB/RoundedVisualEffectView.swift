import AppKit

final class RoundedVisualEffectView: NSVisualEffectView {
    var cornerRadius: CGFloat = 20 {
        didSet { updateMask() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        updateMask()
    }

    override func layout() {
        super.layout()
        updateMask()
    }

    private func updateMask() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let mask = CAShapeLayer()
        mask.path = CGPath(
            roundedRect: bounds,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        layer?.mask = mask
    }
}
