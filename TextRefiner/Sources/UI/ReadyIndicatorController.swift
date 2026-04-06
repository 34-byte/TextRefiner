import Cocoa

/// A small floating pill that appears at the top-left of the focused text field
/// when the user has typed ~7+ words, reminding them that TextRefiner is ready.
///
/// Uses the same NSPanel pattern as StreamingPanelController:
/// .nonactivatingPanel so it never steals keyboard focus from the app the
/// user is typing in.
final class ReadyIndicatorController {

    private var panel: NSPanel?
    private var hotkeyLabel: NSTextField?

    // MARK: - Show

    /// Shows (or repositions) the pill near the top-left of `fieldFrame`.
    /// `fieldFrame` is in Cocoa screen coordinates (bottom-left origin).
    /// Safe to call repeatedly — fades in only on the first call.
    func show(near fieldFrame: CGRect) {
        let isNew = panel == nil
        let p = panel ?? makePanel()
        self.panel = p

        positionPanel(p, relativeTo: fieldFrame)

        if isNew {
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                p.animator().alphaValue = 1
            }
        }
        // If already visible, just update position (no fade — avoids flicker)
    }

    /// Fades out and hides the panel. Safe to call when already hidden.
    func hide() {
        guard let p = panel else { return }
        self.panel = nil
        self.hotkeyLabel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            p.animator().alphaValue = 0
        }, completionHandler: {
            p.orderOut(nil)
        })
    }

    /// Updates the displayed hotkey string. Call after the user changes the hotkey.
    func updateHotkey() {
        hotkeyLabel?.stringValue = HotkeyConfiguration.shared.displayString
        resizePanelToFitLabel()
    }

    // MARK: - Panel Construction

    private func makePanel() -> NSPanel {
        let pillH: CGFloat = 24
        let pillW = preferredWidth()

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: pillW, height: pillH),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden

        // Frosted glass background
        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: pillW, height: pillH))
        bg.material = .popover
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 6
        bg.layer?.masksToBounds = true
        p.contentView?.addSubview(bg)

        // Hotkey label
        let label = NSTextField(labelWithString: HotkeyConfiguration.shared.displayString)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 0, width: pillW, height: pillH)
        bg.addSubview(label)

        hotkeyLabel = label
        return p
    }

    // MARK: - Positioning

    private func positionPanel(_ panel: NSPanel, relativeTo fieldFrame: CGRect) {
        let pillW = panel.frame.width
        let pillH = panel.frame.height
        let gap: CGFloat = 4

        // Always float ABOVE the field — never inside it.
        // Placing the pill inside the text area causes it to overlap the user's text
        // as the content grows (the text starts at top-left and fills toward the pill).
        var x = fieldFrame.minX
        var y = fieldFrame.maxY + gap

        // Find the screen that actually contains the field for correct clamping.
        // NSScreen.main may not be the screen the field is on in multi-monitor setups.
        let midPoint = CGPoint(x: fieldFrame.midX, y: fieldFrame.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(midPoint) }) ?? NSScreen.main

        if let safe = screen?.visibleFrame {
            // If "above" would clip off-screen (field near the top of the display),
            // fall back to just below the field instead.
            if y + pillH > safe.maxY {
                y = fieldFrame.minY - pillH - gap
            }
            x = max(safe.minX + 4, min(x, safe.maxX - pillW - 4))
            y = max(safe.minY + 4, min(y, safe.maxY - pillH - 4))
        }

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Sizing Helpers

    private func preferredWidth() -> CGFloat {
        let text = HotkeyConfiguration.shared.displayString
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let textWidth = (text as NSString).size(withAttributes: attrs).width
        return max(textWidth + 20, 50)
    }

    private func resizePanelToFitLabel() {
        guard let p = panel, let label = hotkeyLabel else { return }
        let newW = preferredWidth()
        label.stringValue = HotkeyConfiguration.shared.displayString
        label.frame = NSRect(x: 0, y: 0, width: newW, height: p.frame.height)
        // Resize pill
        var f = p.frame
        f.size.width = newW
        p.setFrame(f, display: true)
        // Also resize the visual effect view (first subview)
        if let bg = p.contentView?.subviews.first {
            bg.frame = NSRect(x: 0, y: 0, width: newW, height: p.frame.height)
        }
    }
}
