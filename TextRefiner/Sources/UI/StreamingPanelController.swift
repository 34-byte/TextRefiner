import Cocoa

/// A minimal floating indicator — like macOS's native volume/brightness HUD
/// but smaller and more subtle.
///
/// States:
///   1. Spinner      — while model is processing
///   2. Checkmark    — green ✓ after text is pasted (confirmation, 1s)
///   3. Error        — red ✕ + message + 5s countdown bar (input too long, etc.)
///   4. Dismissed    — auto-cleans up
///
/// Uses NSPanel with .nonactivatingPanel so it floats WITHOUT stealing focus.
final class StreamingPanelController {
    private var panel: NSPanel?
    private var spinner: NSProgressIndicator?
    private var checkmarkView: NSImageView?
    private var errorDismissWork: DispatchWorkItem?

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

    // MARK: - Input Limit Error State

    /// Replaces the spinner panel with a 200×80 error HUD:
    ///   • Red ✕ icon
    ///   • "character limit is 10k" label
    ///   • Timer bar animating left→right over 5 seconds
    /// Auto-dismisses after 5s and calls `onDismiss` so the caller can clean up.
    func showInputLimitError(onDismiss: @escaping () -> Void) {
        // Tear down the spinner panel first
        panel?.orderOut(nil)
        panel = nil
        spinner = nil
        checkmarkView = nil

        let width: CGFloat = 200
        let height: CGFloat = 80
        let padding: CGFloat = 16

        // Build error panel
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
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

        // Frosted-glass background
        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14
        bg.layer?.masksToBounds = true
        p.contentView?.addSubview(bg)

        // Red ✕ icon
        let xView = NSImageView()
        let xCfg = NSImage.SymbolConfiguration(pointSize: 22, weight: .medium)
        xView.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Error")?
            .withSymbolConfiguration(xCfg)
        xView.contentTintColor = .systemRed
        let iconSize: CGFloat = 26
        xView.frame = NSRect(x: (width - iconSize) / 2, y: 48, width: iconSize, height: iconSize)
        xView.imageScaling = .scaleProportionallyUpOrDown
        bg.addSubview(xView)

        // "character limit is 10k" label
        let label = NSTextField(labelWithString: "character limit is 10k")
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.black
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.alignment = .center
        label.sizeToFit()
        label.frame = NSRect(
            x: (width - label.frame.width) / 2,
            y: 28,
            width: label.frame.width,
            height: label.frame.height
        )
        bg.addSubview(label)

        // Progress bar track (grey background)
        let barWidth = width - padding * 2
        let barTrack = NSView(frame: NSRect(x: padding, y: 10, width: barWidth, height: 5))
        barTrack.wantsLayer = true
        barTrack.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        barTrack.layer?.cornerRadius = 2.5
        bg.addSubview(barTrack)

        // Progress bar fill (starts at zero width, animates to full)
        let barFill = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: 5))
        barFill.wantsLayer = true
        barFill.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.8).cgColor
        barFill.layer?.cornerRadius = 2.5
        barTrack.addSubview(barFill)

        // Position panel: centered horizontally, slightly above vertical center
        if let screen = NSScreen.main {
            let x = (screen.frame.width - width) / 2
            let y = (screen.frame.height - height) / 2 + 80
            p.setFrameOrigin(NSPoint(x: x, y: y))
        }

        p.orderFrontRegardless()
        self.panel = p

        // Animate bar from 0 → full width over 5 seconds
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 5.0
            ctx.timingFunction = CAMediaTimingFunction(name: .linear)
            barFill.animator().frame = NSRect(x: 0, y: 0, width: barWidth, height: 5)
        }

        // Auto-dismiss after 5 seconds
        let work = DispatchWorkItem { [weak self] in
            self?.dismiss()
            onDismiss()
        }
        errorDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: work)
    }

    // MARK: - Dismiss

    /// Hides and releases the panel. Also cancels any pending error auto-dismiss.
    func dismiss() {
        errorDismissWork?.cancel()
        errorDismissWork = nil
        panel?.orderOut(nil)
        panel = nil
        spinner = nil
        checkmarkView = nil
    }
}
