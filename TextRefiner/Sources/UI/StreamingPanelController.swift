import Cocoa

/// A minimal floating indicator — like macOS's native volume/brightness HUD
/// but smaller and more subtle.
///
/// States:
///   1. Spinner  — while Ollama is processing
///   2. Checkmark — green ✓ after text is pasted (confirmation, 1s)
///   3. Dismissed — auto-cleans up
///
/// Uses NSPanel with .nonactivatingPanel so it floats WITHOUT stealing focus.
final class StreamingPanelController {
    private var panel: NSPanel?
    private var spinner: NSProgressIndicator?
    private var checkmarkView: NSImageView?

    // MARK: - Show

    /// Shows the panel with a spinner. Call this when the hotkey fires.
    func show() {
        let size: CGFloat = 56

        // Non-activating panel — won't steal keyboard focus
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden

        // Frosted-glass background — matches native macOS HUD style
        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14
        bg.layer?.masksToBounds = true
        p.contentView?.addSubview(bg)

        // Spinner — small, centered
        let sp = NSProgressIndicator()
        sp.style = .spinning
        sp.controlSize = .regular  // 20×20pt — fits the compact panel
        sp.sizeToFit()
        let spX = (size - sp.frame.width) / 2
        let spY = (size - sp.frame.height) / 2
        sp.frame = NSRect(x: spX, y: spY, width: sp.frame.width, height: sp.frame.height)
        sp.startAnimation(nil)
        bg.addSubview(sp)

        // Checkmark — compact SF Symbol, hidden until paste completes
        let iv = NSImageView()
        let cfg = NSImage.SymbolConfiguration(pointSize: 28, weight: .medium)
        iv.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Done")?
            .withSymbolConfiguration(cfg)
        iv.contentTintColor = .systemGreen
        let iconSize: CGFloat = 32
        let iconOffset = (size - iconSize) / 2
        iv.frame = NSRect(x: iconOffset, y: iconOffset, width: iconSize, height: iconSize)
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.isHidden = true
        bg.addSubview(iv)

        // Position: centered on screen, slightly above vertical center
        if let screen = NSScreen.main {
            let x = (screen.frame.width - size) / 2
            let y = (screen.frame.height - size) / 2 + 80
            p.setFrameOrigin(NSPoint(x: x, y: y))
        }

        p.orderFrontRegardless()

        self.panel = p
        self.spinner = sp
        self.checkmarkView = iv
    }

    // MARK: - Checkmark Transition

    /// Swaps the spinner for a green checkmark.
    /// Call this after the text has been pasted — visual confirmation of success.
    func showCheckmark() {
        spinner?.stopAnimation(nil)
        spinner?.isHidden = true
        checkmarkView?.isHidden = false
    }

    // MARK: - Dismiss

    /// Hides and releases the panel.
    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        spinner = nil
        checkmarkView = nil
    }
}
