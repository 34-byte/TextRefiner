import Cocoa

/// A floating pill anchored above the focused text field.
/// Serves as both the ready indicator and the processing/success/error HUD.
///
/// States:
///   - hidden:     nothing visible
///   - ready:      `[ ⇧⌘R ]` — compact hotkey pill
///   - processing: 56×56 square HUD with animated spinner (text hidden)
///   - success:    56×56 square HUD with green checkmark
///   - error:      56×56 square HUD with red X + message, 5s auto-dismiss
///
/// NSPanel with .nonactivatingPanel — never steals keyboard focus.
final class ReadyIndicatorController {

    // MARK: - State

    private enum PillState {
        case hidden, ready, processing, success, error, updateBanner
    }

    private var state: PillState = .hidden

    // MARK: - Views

    private var panel: NSPanel?
    private var bgView: NSVisualEffectView?
    private var hotkeyLabel: NSTextField?
    private var symbolView: NSImageView?
    private var errorLabel: NSTextField?
    private var errorDismissWork: DispatchWorkItem?

    // MARK: - Banner Views & Callbacks (updateBanner state)

    private var bannerMessageLabel: NSTextField?
    private var bannerUpdateButton: NSButton?
    private var bannerSeparatorLabel: NSTextField?
    private var bannerLaterButton: NSButton?
    private var onUpdateAction: (() -> Void)?
    private var onLaterAction: (() -> Void)?

    /// Stored when the pill is created so collapse restores the correct width.
    private var normalPillWidth: CGFloat = 0
    /// Most recent field frame — used to position the pill when startProcessing fires
    /// before the pill was ever visible (e.g. fewer than 40 chars typed).
    private var lastFieldFrame: CGRect?
    /// Last AX field frame seen by the display link — used for delta tracking only.
    /// Separate from lastFieldFrame so cursor-based initial placement isn't overwritten
    /// by the absolute field position during the first display link tick.
    private var lastTrackedFieldFrame: CGRect?

    // MARK: - Update Banner

    /// Morphs the ready pill into a wider banner containing the update message
    /// and "Update now" / "Later" action buttons.
    ///
    /// Only valid when `state == .ready`. The banner is cursor-anchored — it appears
    /// exactly where the pill is, expanding rightward.
    func showUpdateBanner(onUpdate: @escaping () -> Void, onLater: @escaping () -> Void) {
        guard state == .ready, let p = panel, let bg = bgView else { return }

        onUpdateAction = onUpdate
        onLaterAction  = onLater
        stopAppSwitchObserver()
        state = .updateBanner

        // --- Measure content for dynamic banner width ---
        let font   = NSFont.captionMedium   // 11pt medium — fits in 24pt pill height
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let msgText    = "Excitinggg new update is here!"
        let updateText = "Update now"
        let laterText  = "Later"
        let msgW  = ceil((msgText    as NSString).size(withAttributes: attrs).width)
        let updW  = ceil((updateText as NSString).size(withAttributes: attrs).width)
        let latW  = ceil((laterText  as NSString).size(withAttributes: attrs).width)
        let sepW: CGFloat  = ceil(("  |  " as NSString).size(withAttributes: attrs).width)
        let leftPad: CGFloat  = 12
        let rightPad: CGFloat = 12
        let gap: CGFloat      = 10   // between message and buttons
        let btnGap: CGFloat   = 0    // separator already has built-in spacing
        let bannerW = leftPad + msgW + gap + updW + sepW + btnGap + latW + rightPad

        // --- Message label with red dotted underline on "Excitinggg" ---
        let msgAttr = NSMutableAttributedString(string: msgText, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ])
        // "Excitinggg" is 10 characters — dotted red underline simulates spell-check squiggle
        let squigRange = NSRange(location: 0, length: 10)
        msgAttr.addAttributes([
            .underlineStyle: (NSUnderlineStyle.single.rawValue |
                              NSUnderlineStyle.patternDot.rawValue) as Int,
            .underlineColor: NSColor.systemRed
        ], range: squigRange)

        let labelH    = ceil(font.pointSize + 3)
        let labelY    = (pillHeight - labelH) / 2
        let msgLabel  = NSTextField(labelWithString: "")
        msgLabel.attributedStringValue = msgAttr
        msgLabel.frame     = NSRect(x: leftPad, y: labelY, width: msgW, height: labelH)
        msgLabel.alphaValue = 0
        bg.addSubview(msgLabel)
        bannerMessageLabel = msgLabel

        // --- "Update now" button ---
        var x = leftPad + msgW + gap
        let btnH: CGFloat = 16
        let btnY = (pillHeight - btnH) / 2

        let updBtn = NSButton(title: updateText, target: self, action: #selector(updateButtonTapped))
        updBtn.bezelStyle  = .inline
        updBtn.isBordered  = false
        updBtn.font        = font
        updBtn.contentTintColor = .textSecondary
        updBtn.frame       = NSRect(x: x, y: btnY, width: updW, height: btnH)
        updBtn.alphaValue  = 0
        bg.addSubview(updBtn)
        bannerUpdateButton = updBtn

        x += updW

        // --- " | " separator ---
        let sepLabel = NSTextField(labelWithString: "  |  ")
        sepLabel.font      = font
        sepLabel.textColor = .textTertiary
        sepLabel.frame     = NSRect(x: x, y: labelY, width: sepW, height: labelH)
        sepLabel.alphaValue = 0
        bg.addSubview(sepLabel)
        bannerSeparatorLabel = sepLabel

        x += sepW + btnGap

        // --- "Later" button ---
        let latBtn = NSButton(title: laterText, target: self, action: #selector(laterButtonTapped))
        latBtn.bezelStyle  = .inline
        latBtn.isBordered  = false
        latBtn.font        = font
        latBtn.contentTintColor = .textSecondary
        latBtn.frame       = NSRect(x: x, y: btnY, width: latW, height: btnH)
        latBtn.alphaValue  = 0
        bg.addSubview(latBtn)
        bannerLaterButton = latBtn

        // --- Animate pill expanding to banner width ---
        let currentFrame = p.frame
        let newPanelFrame = NSRect(x: currentFrame.minX, y: currentFrame.minY,
                                   width: bannerW, height: pillHeight)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration        = 0.5
            ctx.timingFunction  = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            hotkeyLabel?.animator().alphaValue = 0
            p.animator().setFrame(newPanelFrame, display: true)
            bg.animator().frame = NSRect(x: 0, y: 0, width: bannerW, height: pillHeight)
        }, completionHandler: { [weak self] in
            guard let self else { return }
            // Hide label (keep alpha=1 for when pill collapses back)
            self.hotkeyLabel?.isHidden = true
            self.hotkeyLabel?.alphaValue = 1

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = DesignTokens.Animation.fadeIn
                self.bannerMessageLabel?.animator().alphaValue  = 1
                self.bannerUpdateButton?.animator().alphaValue  = 1
                self.bannerSeparatorLabel?.animator().alphaValue = 1
                self.bannerLaterButton?.animator().alphaValue   = 1
            }
            self.startAppSwitchObserver()
        })
    }

    @objc private func updateButtonTapped() {
        dismissUpdateBanner { [weak self] in self?.onUpdateAction?() }
    }

    @objc private func laterButtonTapped() {
        dismissUpdateBanner { [weak self] in self?.onLaterAction?() }
    }

    /// Animated dismissal: banner content fades out, panel contracts back to pill width,
    /// hotkey label is restored, then `completion` fires.
    private func dismissUpdateBanner(then completion: (() -> Void)? = nil) {
        guard let p = panel, let bg = bgView else {
            completion?()
            return
        }
        stopAppSwitchObserver()

        // Phase 1 — fade out banner content
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = DesignTokens.Animation.fadeOut
            bannerMessageLabel?.animator().alphaValue  = 0
            bannerUpdateButton?.animator().alphaValue  = 0
            bannerSeparatorLabel?.animator().alphaValue = 0
            bannerLaterButton?.animator().alphaValue   = 0
        }

        // Cancel any in-flight layer animations before contracting
        bg.layer?.removeAllAnimations()

        let pillW = normalPillWidth > 0 ? normalPillWidth : preferredWidth()
        let newFrame = NSRect(x: p.frame.minX, y: p.frame.minY,
                              width: pillW, height: pillHeight)

        // Phase 2 — contract frame back to pill width
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration       = DesignTokens.Animation.hudCollapse
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            p.animator().setFrame(newFrame, display: true)
            bg.animator().frame = NSRect(x: 0, y: 0, width: pillW, height: pillHeight)
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.bannerMessageLabel?.removeFromSuperview()
            self.bannerUpdateButton?.removeFromSuperview()
            self.bannerSeparatorLabel?.removeFromSuperview()
            self.bannerLaterButton?.removeFromSuperview()
            self.bannerMessageLabel  = nil
            self.bannerUpdateButton  = nil
            self.bannerSeparatorLabel = nil
            self.bannerLaterButton   = nil
            self.onUpdateAction = nil
            self.onLaterAction  = nil
            self.hotkeyLabel?.isHidden = false
            self.hotkeyLabel?.frame    = self.centeredLabelFrame(width: pillW)
            self.state = .ready
            self.startAppSwitchObserver()
            completion?()
        })
    }

    /// Synchronous, no-animation teardown of the update banner.
    /// Called when a new refinement starts or an app switch fires while the banner
    /// is still showing. Snaps the panel back to pill width immediately — no fade.
    /// Caller is responsible for setting `state` after this returns.
    private func clearUpdateBannerImmediately() {
        guard let p = panel, let bg = bgView else { return }

        // Cancel all in-flight layer animations (corner radius, etc.)
        bg.layer?.removeAllAnimations()

        // Non-animated frame snap — overrides any in-flight NSAnimationContext animation
        let pillW = normalPillWidth > 0 ? normalPillWidth : preferredWidth()
        p.setFrame(NSRect(x: p.frame.minX, y: p.frame.minY,
                          width: pillW, height: pillHeight), display: false)
        bg.frame = NSRect(x: 0, y: 0, width: pillW, height: pillHeight)

        // Remove banner subviews immediately
        bannerMessageLabel?.removeFromSuperview()
        bannerUpdateButton?.removeFromSuperview()
        bannerSeparatorLabel?.removeFromSuperview()
        bannerLaterButton?.removeFromSuperview()
        bannerMessageLabel  = nil
        bannerUpdateButton  = nil
        bannerSeparatorLabel = nil
        bannerLaterButton   = nil
        onUpdateAction = nil
        onLaterAction  = nil

        // Restore hotkey label
        hotkeyLabel?.isHidden  = false
        hotkeyLabel?.alphaValue = 1
        hotkeyLabel?.frame     = centeredLabelFrame(width: pillW)

        // Transition to .ready so callers (softHide, startProcessing) see a clean state.
        // Callers that want a different terminal state must set it themselves after this.
        state = .ready
    }

    // MARK: - Position Tracking
    //
    // Two-layer architecture:
    //   1. Background thread polls AX position at ~8ms and writes to a cached frame.
    //   2. CADisplayLink fires on main thread at vsync cadence, reads the cache,
    //      and calls setFrameOrigin — no AX IPC on main, no GCD dispatch hop.
    //
    // The display link starts only AFTER the expand animation completes, so
    // setFrameOrigin never conflicts with an in-flight NSAnimationContext animation.

    private var displayLink: CADisplayLink?
    private var lastDisplayLinkTimestamp: CFTimeInterval = 0
    private let axCacheLock = NSLock()
    private var cachedFieldFrame: CGRect?
    private var isAXPollingActive = false
    private var positionTrackedElement: AXUIElement?

    /// Workspace notification token registered while the pill is in `.ready` state.
    /// When any app becomes frontmost, the pill hides immediately — regardless of
    /// whether TypingMonitor's `isIndicatorVisible` flag is accurate. This is the
    /// safety net that keeps the pill from floating above unrelated app windows.
    private var appSwitchToken: NSObjectProtocol?

    // MARK: - Convenience

    private var hudSize: CGFloat    { DesignTokens.Size.HUD.spinnerPanel }
    private var pillHeight: CGFloat { DesignTokens.Size.Pill.height }

    // MARK: - Init

    init() {
        let p = makePanel()
        p.alphaValue = 0
        panel = p
    }

    // MARK: - State Query

    /// True when the pill is in the ready state and visible to the user.
    /// Used by AppDelegate to gate the 1.5s update banner delay — if the pill
    /// was hidden by an app switch or TypingMonitor during that window, skip the banner.
    var isPillVisible: Bool { state == .ready }

    // MARK: - Show (Ready State)

    /// Shows (or repositions) the pill near the top-left of `fieldFrame`.
    /// `fieldFrame` is in Cocoa screen coordinates (bottom-left origin).
    /// Safe to call repeatedly — fades in only on the first call.
    /// During processing/success/error: updates `lastFieldFrame` only.
    /// The display link handles the actual repositioning during those states.
    func show(near fieldFrame: CGRect) {
        // During active HUD or banner states, only cache the frame.
        // The display link (HUD) or banner layout (updateBanner) handles positioning.
        if state == .processing || state == .success || state == .error || state == .updateBanner {
            lastFieldFrame = fieldFrame
            return
        }

        lastFieldFrame = fieldFrame

        switch state {
        case .hidden:
            let p: NSPanel
            if let existing = panel {
                p = existing
            } else {
                let newPanel = makePanel()
                panel = newPanel
                p = newPanel
            }
            state = .ready
            positionPanel(p, relativeTo: fieldFrame)
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = DesignTokens.Animation.fadeIn
                p.animator().alphaValue = 1
            }
            startAppSwitchObserver()
        case .ready:
            panel.map { positionPanel($0, relativeTo: fieldFrame) }
        case .processing, .success, .error, .updateBanner:
            break  // handled above
        }
    }

    /// Fades out and hides the panel. No-op during processing/success/error.
    func hide() {
        guard state == .ready else { return }
        softHide()
    }

    /// Clears cached field position data. Call on app switch so the next
    /// startProcessing/showError doesn't anchor to a stale position from
    /// the previous app.
    func clearCachedFrame() {
        lastFieldFrame = nil
        lastTrackedFieldFrame = nil
    }

    /// Updates the displayed hotkey string. Call after the user changes the hotkey.
    func updateHotkey() {
        hotkeyLabel?.stringValue = HotkeyConfiguration.shared.displayString
        if state == .ready {
            resizePanelToFitLabel()
        }
    }

    // MARK: - Processing State

    /// Morphs the pill into the HUD square and shows the spinner.
    /// If the pill is not currently visible, creates it at `fieldFrame`
    /// (or `lastFieldFrame` as fallback) before morphing.
    /// Pass `trackedElement` to enable vsync-locked position tracking.
    func startProcessing(near fieldFrame: CGRect?, trackedElement: AXUIElement?) {
        // The HUD must stay visible regardless of app switching during processing.
        // Stop the app-switch observer — it's only for the idle pill state.
        stopAppSwitchObserver()
        // If the update banner is showing when the hotkey fires, clear it immediately
        // before expanding to the HUD. No dismiss animation — the hotkey takes priority.
        if state == .updateBanner {
            clearUpdateBannerImmediately()
        }
        errorDismissWork?.cancel()
        errorDismissWork = nil

        // Initial placement: anchor to the mouse cursor, not the field frame.
        // Field frames for large content areas (browsers, code editors) span the
        // entire viewport — using fieldFrame.maxY would place the HUD in the app
        // chrome (browser tab bar, title bar) rather than near the selection.
        // The cursor is always near the user's focus point when the hotkey fires.
        //
        // Height = hudSize so positionPanel computes:
        //   y = cursor.y + hudSize + gap  (~60px above cursor)
        // This clears a typical line of text before the HUD's bottom edge appears.
        // Seed lastFieldFrame — used to create the panel if it doesn't exist yet.
        // Uses the same field frame the pill uses, so the HUD appears at the same
        // position as the pill (or where the pill would have been).
        // If no field frame is available at all (e.g. app switch cleared the cache
        // and the hotkey fires before TypingMonitor re-attaches), fall back to the
        // mouse cursor position. NSEvent.mouseLocation is in Cocoa screen coordinates
        // (bottom-left origin) — the same space positionPanel expects.
        if let frame = fieldFrame ?? lastFieldFrame {
            lastFieldFrame = frame
        } else {
            let cursor = NSEvent.mouseLocation
            lastFieldFrame = CGRect(x: cursor.x - hudSize / 2,
                                    y: cursor.y,
                                    width: hudSize,
                                    height: 1)
        }

        if let p = panel {
            // Panel already exists (pre-warmed or previously shown).
            // If it was soft-hidden, reposition and bring it front before expanding.
            if state == .hidden, let frame = lastFieldFrame {
                positionPanel(p, relativeTo: frame)
            }
            p.alphaValue = 1
            p.orderFrontRegardless()
        } else {
            guard let frame = lastFieldFrame else { return }
            let p = makePanel()
            panel = p
            positionPanel(p, relativeTo: frame)
            p.alphaValue = 1
            p.orderFrontRegardless()
        }

        state = .processing
        expandToHUD(
            symbol: "arrow.triangle.2.circlepath",
            tintColor: .textSecondary,
            spinning: true,
            errorText: nil,
            onComplete: { [weak self] in
                // Start tracking AFTER the expand animation finishes.
                // Starting earlier would cause setFrameOrigin to conflict with
                // the in-flight NSAnimationContext, snapping the panel mid-animation.
                self?.startPositionTracking(trackedElement, fieldFrame: fieldFrame)
            }
        )
    }

    // MARK: - Success State

    /// Swaps the spinner for a green checkmark. No-op unless currently processing.
    func showCheckmark() {
        guard state == .processing,
              let iv = symbolView,
              let img = NSImage(systemSymbolName: "checkmark.circle.fill",
                                accessibilityDescription: "Done") else { return }
        state = .success
        iv.removeAllSymbolEffects()
        iv.contentTintColor = .feedbackSuccess
        iv.setSymbolImage(img, contentTransition: .replace.magic(fallback: .replace))
    }

    // MARK: - Finish (Return to Ready)

    /// Called when the pill returns to ready state after processing/success/error.
    /// TypingMonitor uses this to resync its visibility flag — without it,
    /// forceHide() during processing leaves isIndicatorVisible=false permanently,
    /// so app-switch hide is a no-op and the pill stays on top of the new window.
    var onDidReturnToReady: (() -> Void)?

    /// Morphs the HUD square back to the small pill and returns to ready state.
    /// After this, TypingMonitor's next onShouldShow/onShouldHide determines visibility.
    func finishProcessing(then completion: (() -> Void)? = nil) {
        guard state == .processing || state == .success || state == .error else { return }
        errorDismissWork?.cancel()
        errorDismissWork = nil
        stopPositionTracking()
        collapseFromHUD(animated: true) { [weak self] in
            self?.state = .ready
            self?.startAppSwitchObserver()
            self?.onDidReturnToReady?()
            completion?()
        }
    }

    // MARK: - Error State

    /// Morphs the pill into the HUD square with a red X and error message.
    /// Auto-dismisses after 5 seconds.
    func showError(near fieldFrame: CGRect?, trackedElement: AXUIElement? = nil,
                   message: String = "char limit 10k", onDismiss: @escaping () -> Void) {
        errorDismissWork?.cancel()
        errorDismissWork = nil

        // Same field-frame seeding as startProcessing — HUD appears where the pill is.
        if let frame = fieldFrame ?? lastFieldFrame {
            lastFieldFrame = frame
        }

        if panel == nil {
            guard let frame = lastFieldFrame else {
                onDismiss()
                return
            }
            let p = makePanel()
            panel = p
            positionPanel(p, relativeTo: frame)
            p.alphaValue = 1
            p.orderFrontRegardless()
        }

        // Clear banner if it was showing when the error fires (e.g. error arrives
        // mid-animation or from a previous processing cycle).
        if state == .updateBanner {
            clearUpdateBannerImmediately()
        }

        state = .error
        expandToHUD(
            symbol: "xmark.circle.fill",
            tintColor: .feedbackError,
            spinning: false,
            errorText: message,
            onComplete: { [weak self] in
                self?.startPositionTracking(trackedElement, fieldFrame: fieldFrame)
            }
        )

        let work = DispatchWorkItem { [weak self] in
            self?.stopPositionTracking()
            self?.collapseFromHUD(animated: true) { [weak self] in
                self?.state = .ready
                self?.startAppSwitchObserver()
                onDismiss()
            }
        }
        errorDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + DesignTokens.Animation.errorHUD, execute: work)
    }

    // MARK: - Panel Construction

    private func makePanel() -> NSPanel {
        let w = preferredWidth()
        normalPillWidth = w
        let h = pillHeight

        let p = ReadyIndicatorPanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
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

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        bg.material = .popover
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = DesignTokens.Radius.pill
        bg.layer?.masksToBounds = true
        p.contentView?.addSubview(bg)
        bgView = bg

        let label = NSTextField(labelWithString: HotkeyConfiguration.shared.displayString)
        label.font = .labelMedium
        label.textColor = .textSecondary
        label.alignment = .center
        label.frame = centeredLabelFrame(width: w)
        bg.addSubview(label)
        hotkeyLabel = label

        return p
    }

    // MARK: - Expand / Collapse

    /// Grows the pill into a 56×56 square centered on the pill's current center.
    /// Calls `onComplete` after the animation finishes — used to start position
    /// tracking only once the panel is fully settled (no active NSAnimationContext).
    private func expandToHUD(symbol: String, tintColor: NSColor, spinning: Bool,
                              errorText: String?, onComplete: (() -> Void)? = nil) {
        guard let p = panel, let bg = bgView else { return }

        // Clean up any existing symbol icon before adding a new one.
        // Handles the processing→error transition where expandToHUD is called twice:
        // first from startProcessing (spinner), then from showError (xmark). Without
        // this, the old spinner stays in the view hierarchy, still rotating underneath.
        symbolView?.removeAllSymbolEffects()
        symbolView?.removeFromSuperview()
        symbolView = nil
        errorLabel?.removeFromSuperview()
        errorLabel = nil

        normalPillWidth = preferredWidth()

        let pillOrigin = p.frame.origin
        let pillCenterX = pillOrigin.x + normalPillWidth / 2
        let pillCenterY = pillOrigin.y + pillHeight / 2

        hotkeyLabel?.isHidden = true

        let hasText = errorText != nil
        let iconSize: CGFloat = 22
        let iconCenterY: CGFloat = hasText ? hudSize / 2 + 6 : hudSize / 2
        let iconFrame = NSRect(
            x: (hudSize - iconSize) / 2,
            y: iconCenterY - iconSize / 2,
            width: iconSize,
            height: iconSize
        )

        let iv = NSImageView(frame: iconFrame)
        iv.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        iv.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        iv.contentTintColor = tintColor
        iv.imageAlignment = .alignCenter
        iv.imageScaling = .scaleNone
        iv.alphaValue = 0
        bg.addSubview(iv)
        symbolView = iv

        if spinning {
            iv.addSymbolEffect(.rotate, options: .repeating.speed(DesignTokens.Animation.bounceSpeed))
        }

        if let text = errorText {
            let lbl = NSTextField(labelWithString: text)
            lbl.font = .systemFont(ofSize: 10, weight: .medium)
            lbl.textColor = tintColor
            lbl.alignment = .center
            lbl.frame = NSRect(x: 0, y: 6, width: hudSize, height: 13)
            lbl.alphaValue = 0
            bg.addSubview(lbl)
            errorLabel = lbl
        }

        // Animate corner radius: pill → HUD
        let radiusAnim = CABasicAnimation(keyPath: "cornerRadius")
        radiusAnim.fromValue = DesignTokens.Radius.pill
        radiusAnim.toValue = DesignTokens.Radius.hud
        radiusAnim.duration = DesignTokens.Animation.hudExpand
        radiusAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        radiusAnim.fillMode = .forwards
        radiusAnim.isRemovedOnCompletion = false
        bg.layer?.add(radiusAnim, forKey: "cornerRadius")
        bg.layer?.cornerRadius = DesignTokens.Radius.hud

        // Anchor HUD bottom to pill bottom — HUD grows upward, never into the text below.
        let newOrigin = CGPoint(x: pillCenterX - hudSize / 2, y: pillOrigin.y)
        let newPanelFrame = NSRect(origin: newOrigin, size: CGSize(width: hudSize, height: hudSize))

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = DesignTokens.Animation.hudExpand
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            p.animator().setFrame(newPanelFrame, display: true)
            bg.animator().frame = NSRect(x: 0, y: 0, width: hudSize, height: hudSize)
            iv.animator().alphaValue = 1
            errorLabel?.animator().alphaValue = 1
        }, completionHandler: {
            onComplete?()
        })
    }

    /// Shrinks the HUD square back to the small pill, centered on the HUD's current center.
    /// `completion` fires after the animation finishes — callers use this to defer state
    /// transitions so nothing can interrupt the in-flight animation.
    private func collapseFromHUD(animated: Bool, completion: (() -> Void)? = nil) {
        guard let p = panel, let bg = bgView else { return }

        let pillW = normalPillWidth > 0 ? normalPillWidth : preferredWidth()
        let hudOrigin = p.frame.origin
        // Collapse back to pill bottom — reverse of the bottom-anchored expand.
        let newOrigin = CGPoint(
            x: hudOrigin.x + hudSize / 2 - pillW / 2,
            y: hudOrigin.y
        )
        let newFrame = NSRect(origin: newOrigin, size: CGSize(width: pillW, height: pillHeight))

        if animated {
            symbolView?.removeAllSymbolEffects()

            // Phase 1 — icon fades out in the first ~40% of the collapse duration.
            // This lets the eye release the content before tracking the shape change,
            // which reads as "morph" rather than "disappear".
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = DesignTokens.Animation.hudCollapse * 0.4
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                symbolView?.animator().alphaValue = 0
                errorLabel?.animator().alphaValue = 0
            }

            // Phase 2 — frame collapses with ease-in-out over the full duration.
            // Corner radius animation shares the same timing to stay in sync with the frame.
            let radiusAnim = CABasicAnimation(keyPath: "cornerRadius")
            radiusAnim.fromValue = DesignTokens.Radius.hud
            radiusAnim.toValue = DesignTokens.Radius.pill
            radiusAnim.duration = DesignTokens.Animation.hudCollapse
            radiusAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            radiusAnim.fillMode = .forwards
            radiusAnim.isRemovedOnCompletion = false
            bg.layer?.add(radiusAnim, forKey: "cornerRadius")
            bg.layer?.cornerRadius = DesignTokens.Radius.pill

            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = DesignTokens.Animation.hudCollapse
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                p.animator().setFrame(newFrame, display: true)
                bg.animator().frame = NSRect(x: 0, y: 0, width: pillW, height: pillHeight)
            }, completionHandler: { [weak self] in
                guard let self else { return }
                self.symbolView?.removeFromSuperview()
                self.symbolView = nil
                self.errorLabel?.removeFromSuperview()
                self.errorLabel = nil
                self.hotkeyLabel?.isHidden = false
                self.hotkeyLabel?.frame = self.centeredLabelFrame(width: pillW)
                completion?()
            })
        } else {
            symbolView?.removeAllSymbolEffects()
            symbolView?.removeFromSuperview()
            symbolView = nil
            errorLabel?.removeFromSuperview()
            errorLabel = nil
            p.setFrame(newFrame, display: true)
            bg.frame = NSRect(x: 0, y: 0, width: pillW, height: pillHeight)
            bg.layer?.cornerRadius = DesignTokens.Radius.pill
            hotkeyLabel?.isHidden = false
            hotkeyLabel?.frame = centeredLabelFrame(width: pillW)
        }
    }

    // MARK: - App Switch Observer

    /// Registers a one-shot workspace observer that hides the pill the moment any
    /// other app becomes frontmost. This is the safety net for cases where
    /// TypingMonitor's `isIndicatorVisible` flag is stale (e.g. after hotkey fires
    /// and `forceHide()` clears the flag). Only active while state == `.ready`.
    private func startAppSwitchObserver() {
        stopAppSwitchObserver()
        appSwitchToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self,
                  self.state == .ready || self.state == .updateBanner else { return }
            self.softHide()
        }
    }

    private func stopAppSwitchObserver() {
        if let token = appSwitchToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            appSwitchToken = nil
        }
    }

    // MARK: - Teardown

    private func teardown() {
        guard let p = panel else { return }

        stopAppSwitchObserver()
        errorDismissWork?.cancel()
        errorDismissWork = nil
        stopPositionTracking()

        let capturedPanel = p
        panel = nil
        bgView = nil
        hotkeyLabel = nil
        symbolView?.removeAllSymbolEffects()
        symbolView = nil
        errorLabel = nil
        // Banner properties — nil closures to break any retain cycles
        bannerMessageLabel = nil
        bannerUpdateButton = nil
        bannerSeparatorLabel = nil
        bannerLaterButton = nil
        onUpdateAction = nil
        onLaterAction = nil
        state = .hidden

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = DesignTokens.Animation.fadeOut
            capturedPanel.animator().alphaValue = 0
        }, completionHandler: {
            capturedPanel.orderOut(nil)
        })
    }

    /// Fades the panel out without destroying it. Keeps the panel, bgView,
    /// hotkeyLabel, symbolView, and errorLabel alive so the next `show()` reuses
    /// the existing hierarchy — no cold-start stutter.
    /// If called while the update banner is showing (e.g. app switch during banner),
    /// clears the banner immediately so the pill is restored before fading out.
    private func softHide() {
        guard let p = panel else { return }
        // Clear banner subviews synchronously before fading — banner buttons must not
        // remain in the view hierarchy after the panel fades and is reused.
        if state == .updateBanner {
            clearUpdateBannerImmediately()
        }
        stopAppSwitchObserver()
        errorDismissWork?.cancel()
        errorDismissWork = nil
        stopPositionTracking()
        state = .hidden

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = DesignTokens.Animation.fadeOut
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Only order out if still hidden — startProcessing() may have reclaimed
            // this panel during the fade and changed state to .processing.
            guard self?.state == .hidden else { return }
            p.orderOut(nil)
        })
    }

    // MARK: - Position Tracking

    /// Starts vsync-locked position tracking for the HUD.
    ///
    /// Architecture:
    /// - A background thread reads the AX element position every ~8ms and caches it.
    ///   AX IPC takes 0.5–10ms depending on the target app; isolating it prevents
    ///   the main thread from blocking during a display link callback.
    /// - A CADisplayLink on the main thread reads the cached frame at vsync cadence
    ///   and applies any delta to the HUD's current position — sub-millisecond work,
    ///   phase-aligned with the display.
    ///
    /// Delta tracking (not absolute repositioning): the HUD moves by the same amount
    /// the field moved. This means initial placement (cursor-based) is preserved, and
    /// window dragging during processing is handled correctly regardless of field size.
    ///
    /// Must be called AFTER any in-flight NSAnimationContext animation on the panel
    /// (i.e. from the expandToHUD completion handler), because setFrameOrigin cancels
    /// active NSAnimationContext animations.
    private func startPositionTracking(_ element: AXUIElement?, fieldFrame: CGRect?) {
        stopPositionTracking()
        guard let element, let panel else { return }
        positionTrackedElement = element

        // Seed the AX cache and delta-tracking baseline with the actual field frame
        // (not the cursor anchor). The display link uses this to compute deltas when
        // the field moves (e.g. user drags the window during processing).
        if let frame = fieldFrame {
            axCacheLock.lock()
            cachedFieldFrame = frame
            axCacheLock.unlock()
            lastTrackedFieldFrame = frame
        }

        // Background AX poll
        isAXPollingActive = true
        // Cache screen height on the main thread — NSScreen.main is not thread-safe.
        // The background poll calls axFieldFrame every ~8ms; reading NSScreen there
        // would be a data race. A slightly stale height (e.g. monitor unplug mid-poll)
        // causes at most a few pixels of position error, which is acceptable.
        let screenHeight = NSScreen.main?.frame.height ?? 0
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self else { return }
            while self.isAXPollingActive, let el = self.positionTrackedElement {
                if let frame = Self.axFieldFrame(from: el, screenHeight: screenHeight) {
                    self.axCacheLock.lock()
                    self.cachedFieldFrame = frame
                    self.axCacheLock.unlock()
                }
                Thread.sleep(forTimeInterval: 0.008)
            }
        }

        // Vsync-aligned display link on main thread
        let link = panel.displayLink(target: self, selector: #selector(displayLinkTick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastDisplayLinkTimestamp = 0
    }

    private func stopPositionTracking() {
        isAXPollingActive = false
        positionTrackedElement = nil
        displayLink?.invalidate()
        displayLink = nil
        axCacheLock.lock()
        cachedFieldFrame = nil
        axCacheLock.unlock()
        lastTrackedFieldFrame = nil
    }

    @objc private func displayLinkTick(_ link: CADisplayLink) {
        // Read cached frame — no AX IPC, sub-microsecond
        axCacheLock.lock()
        let frame = cachedFieldFrame
        axCacheLock.unlock()

        guard let fieldFrame = frame, let p = panel else { return }

        // Delta tracking: compute how much the field has moved and apply the same
        // delta to the HUD. This preserves the cursor-based initial placement and
        // correctly follows window drags regardless of field size.
        guard let lastFrame = lastTrackedFieldFrame else {
            lastTrackedFieldFrame = fieldFrame
            return
        }

        let dx = fieldFrame.minX - lastFrame.minX
        let dy = fieldFrame.minY - lastFrame.minY

        if abs(dx) < 0.5 && abs(dy) < 0.5 { return }

        lastTrackedFieldFrame = fieldFrame
        let origin = p.frame.origin
        p.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
    }

    /// Reads an AX element's frame in Cocoa screen coordinates (bottom-left origin).
    /// `screenHeight` must be read on the main thread before calling from a background
    /// thread — NSScreen.main is not thread-safe.
    private static func axFieldFrame(from element: AXUIElement, screenHeight: CGFloat) -> CGRect? {
        var posValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXPositionAttribute as CFString, &posValue
        ) == .success,
              let posAX = posValue,
              CFGetTypeID(posAX) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(posAX as! AXValue, .cgPoint, &point) else { return nil }

        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSizeAttribute as CFString, &sizeValue
        ) == .success,
              let sizeAX = sizeValue,
              CFGetTypeID(sizeAX) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(sizeAX as! AXValue, .cgSize, &size) else { return nil }

        return CGRect(x: point.x, y: screenHeight - point.y - size.height,
                      width: size.width, height: size.height)
    }

    // MARK: - Positioning

    private func positionPanel(_ panel: NSPanel, relativeTo fieldFrame: CGRect) {
        let panelW = panel.frame.width
        let panelH = panel.frame.height
        let gap = DesignTokens.Spacing.Pill.gap

        var x = fieldFrame.minX
        var y = fieldFrame.maxY + gap

        let midPoint = CGPoint(x: fieldFrame.midX, y: fieldFrame.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(midPoint) }) ?? NSScreen.main

        if let safe = screen?.visibleFrame {
            if y + panelH > safe.maxY {
                y = fieldFrame.minY - panelH - gap
            }
            let edge = DesignTokens.Spacing.Pill.screenEdge
            x = max(safe.minX + edge, min(x, safe.maxX - panelW - edge))
            y = max(safe.minY + edge, min(y, safe.maxY - panelH - edge))
        }

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Sizing

    /// The current pill width in points. Used by AppDelegate to build a cursor-centered
    /// anchor rect so the HUD expands centered on the cursor, not left-aligned to it.
    var pillWidth: CGFloat { preferredWidth() }

    /// Returns a frame that vertically centers the hotkey label within the pill.
    /// NSTextField does not auto-center text vertically, so we compute the
    /// natural line height from the font and offset y accordingly.
    private func centeredLabelFrame(width: CGFloat) -> NSRect {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.labelMedium]
        let lineH = ceil(("M" as NSString).size(withAttributes: attrs).height)
        return NSRect(x: 0, y: (pillHeight - lineH) / 2, width: width, height: lineH)
    }

    private func preferredWidth() -> CGFloat {
        let text = HotkeyConfiguration.shared.displayString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.labelMedium]
        let textWidth = (text as NSString).size(withAttributes: attrs).width
        return max(textWidth + DesignTokens.Spacing.Pill.horizontal, DesignTokens.Size.Pill.minWidth)
    }

    private func resizePanelToFitLabel() {
        guard let p = panel, let label = hotkeyLabel, let bg = bgView else { return }
        let newW = preferredWidth()
        normalPillWidth = newW
        label.stringValue = HotkeyConfiguration.shared.displayString
        label.frame = centeredLabelFrame(width: newW)
        var f = p.frame
        f.size.width = newW
        p.setFrame(f, display: true)
        bg.frame = NSRect(x: 0, y: 0, width: newW, height: p.frame.height)
    }
}

// MARK: - ReadyIndicatorPanel

/// NSPanel subclass that can temporarily become the key window.
///
/// Standard `.nonactivatingPanel` windows cannot become key, which prevents
/// NSButton target-action from firing inside them. Overriding `canBecomeKey`
/// allows button clicks to work without activating the app or stealing keyboard
/// focus from the user's active window. The panel is still `.nonactivatingPanel`
/// — the app is never brought to the foreground.
private final class ReadyIndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
