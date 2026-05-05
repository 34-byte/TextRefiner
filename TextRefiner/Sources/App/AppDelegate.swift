import AVFoundation
import Cocoa
import Sparkle

/// The central hub that wires all components together.
/// Manages the menu bar icon, spinner states, and coordinates between
/// onboarding, hotkey detection, and the refinement flow.
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Components

    private var statusItem: NSStatusItem!
    private var spinner: NSProgressIndicator?
    private let coordinator = RefinementCoordinator()
    private let hotkeyManager = HotkeyManager()
    private var onboardingController: OnboardingWindowController?
    private var promptSettingsController: PromptSettingsWindowController?
    private var historyController: HistoryWindowController?
    private var settingsController: SettingsWindowController?
    private let updateManager = UpdateManager()
    /// "Update available →" menu item. Hidden until Sparkle detects a valid update;
    /// stays visible until the user installs it (app restarts with new version).
    private var updateAvailableMenuItem: NSMenuItem?
    private let typingMonitor = TypingMonitor()
    private let readyIndicator = ReadyIndicatorController()
    /// Retains the active AVAudioPlayer instance for its full playback duration.
    private var audioPlayer: AVAudioPlayer?
    /// Cursor-based HUD anchor captured at hotkey time for browser contexts.
    /// Cleared and reset on each new refinement cycle.
    private var browserAnchorFrame: CGRect?

    /// Timer that polls for Accessibility permission after an update resets TCC.
    private var accessibilityPollTimer: Timer?

    // MARK: - Lifecycle

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if onboardingController != nil {
            onboardingController?.bringToFront()
        } else {
            statusItem.button?.performClick(nil)
        }
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyDockVisibility()
        setupMenuBar()
        wireCoordinator()

        // Request notification permission early
        NotificationManager.requestPermission()

        // Strip quarantine asynchronously — Sparkle updates and browser downloads
        // tag the binary with com.apple.quarantine, which blocks CGEvent tap creation
        // even when Accessibility is granted. Running this async prevents the main
        // thread from freezing at launch on slower machines or network volumes.
        // All permission-dependent setup happens in the completion handler, guaranteeing
        // quarantine is cleared before any CGEvent tap is attempted.
        Self.removeQuarantineFlag {
            self.completeLaunchSetup()
        }
    }

    /// Runs after quarantine removal completes. Contains all permission-dependent
    /// launch logic so nothing attempts a CGEvent tap before the flag is cleared.
    private func completeLaunchSetup() {
        // Dev fast-path: skip the onboarding wizard entirely.
        // TCC is reset on every build by build.sh, so just register the app in the
        // Accessibility list and start polling. The user only needs to toggle it ON
        // in System Settings — no wizard, no multi-step flow.
        if Bundle.main.bundleIdentifier == "com.textrefiner.app.dev" {
            AccessibilityService.requestPermission()
            if AccessibilityService.isTrusted() {
                _ = startListening()
            } else {
                startAccessibilityPolling()
            }
            return
        }

        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "com.textrefiner.onboardingCompleted")

        // Use a UUID fallback if CFBundleVersion is unreadable (packaging error,
        // stripped binary, etc.). "0" as a fallback was dangerous — if the previous
        // launch also returned nil and stored "0", the strings would match and the
        // post-update TCC reset would be silently skipped, leaving every user on
        // that build with a stale CDHash and a broken hotkey (stress test S-08).
        let currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "missing-\(UUID().uuidString)"
        let lastOnboardedBuild = UserDefaults.standard.string(forKey: "com.textrefiner.lastOnboardedBuild")
        let needsReOnboarding = hasCompletedOnboarding && lastOnboardedBuild != currentBuild

        if !hasCompletedOnboarding || needsReOnboarding {
            // Always reset on first launch or after an update. Both cases need a fresh
            // TCC entry tied to the current binary's CDHash:
            //
            // - Re-onboarding: the old entry points to the previous binary (stale CDHash).
            // - First launch: a stale entry can still exist from a prior install or
            //   dev-build test session (different bundle ID → different UserDefaults domain,
            //   but same release bundle ID in TCC). Without a reset, the toggle shows ON
            //   but authorises the wrong binary — isTrusted() fails and the user loops
            //   through toggle ON/OFF with no recovery path.
            //
            // tccutil reset is a no-op when no entry exists, so this is safe for
            // genuine first-time installs.
            Self.resetAccessibilityPermission()
            // Proactively register the app in the Accessibility list by calling
            // AXIsProcessTrustedWithOptions with kAXTrustedCheckOptionPrompt: true.
            // On macOS 14+, CGEvent.tapCreate() alone may not add the app to System
            // Settings > Accessibility. Without this call, the app can be completely
            // invisible in the Accessibility list — the user has no toggle to flip.
            // This must happen before showOnboarding() so the toggle exists by the
            // time the user navigates to System Settings.
            AccessibilityService.requestPermission()
            showOnboarding()
        } else {
            // Permission check first: if accessibility was lost since last onboarding
            // (user manually revoked it, or dev build reset TCC), we MUST show onboarding
            // again. Without it, nothing ever calls requestPermission() — which is the
            // only way to trigger the system prompt that adds the app to the Accessibility
            // list. Silent polling alone would loop forever because the app is invisible
            // in System Settings (stress test S-22).
            if !AccessibilityService.isTrusted() {
                // Proactively register the app in the Accessibility list before
                // showing onboarding — same reasoning as the first-launch path above.
                AccessibilityService.requestPermission()
                showOnboarding()
            } else if !startListening() {
                // Trusted but tap failed for a transient reason — poll to recover.
                startAccessibilityPolling()
            }
        }
    }

    // MARK: - Menu Bar Setup

    /// Creates the menu bar icon (sparkle + A as template image) and dropdown menu.
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = createMenuBarIcon()
            button.image?.isTemplate = true // Respects dark/light mode automatically
        }

        let menu = NSMenu()

        // Prompt Settings
        menu.addItem(NSMenuItem(title: "Prompt Settings...", action: #selector(showPromptSettings), keyEquivalent: ""))

        // History
        menu.addItem(NSMenuItem(title: "History...", action: #selector(showHistory), keyEquivalent: ""))

        // Settings (hotkey configuration, etc.)
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ","))

        // Rebuild & Relaunch — dev builds only
        if Bundle.main.bundleIdentifier == "com.textrefiner.app.dev" {
            let rebuildItem = NSMenuItem(title: "Rebuild & Relaunch", action: #selector(rebuildAndRelaunch), keyEquivalent: "")
            rebuildItem.image = NSImage(systemSymbolName: "hammer.fill", accessibilityDescription: nil)
            menu.addItem(rebuildItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Delete AI Model
        menu.addItem(NSMenuItem(title: "Delete AI Model...", action: #selector(deleteLocalModel), keyEquivalent: ""))

        menu.addItem(NSMenuItem.separator())

        // "Update available →" — hidden until Sparkle detects a valid update.
        // Always present as the permanent fallback after banner dismissals.
        let updateItem = NSMenuItem(title: "Update available →",
                                    action: #selector(installAvailableUpdate),
                                    keyEquivalent: "")
        updateItem.isHidden = true
        menu.addItem(updateItem)
        updateAvailableMenuItem = updateItem

        menu.addItem(NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "About TextRefiner", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit TextRefiner", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        // Show the update item the moment Sparkle detects an available update.
        updateManager.onUpdateDetected = { [weak self] in
            self?.updateAvailableMenuItem?.isHidden = false
        }
    }

    /// Creates the ✦A menu bar icon programmatically as a template image.
    /// Drawn at 18x18pt (36x36px @2x) — standard menu bar icon size.
    private func createMenuBarIcon() -> NSImage {
        let iconSize = DesignTokens.Size.MenuBar.iconSize
        let size = NSSize(width: iconSize, height: iconSize)
        let image = NSImage(size: size, flipped: false) { rect in
            // Draw the sparkle (✦) — small, on the left
            let sparkleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.menuBarSparkle,
                .foregroundColor: NSColor.black
            ]
            let sparkle = NSAttributedString(string: "✦", attributes: sparkleAttrs)
            sparkle.draw(at: NSPoint(x: 0, y: 3))

            // Draw the "A" — bold, on the right
            let aAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.menuBarLetter,
                .foregroundColor: NSColor.black
            ]
            let aStr = NSAttributedString(string: "A", attributes: aAttrs)
            aStr.draw(at: NSPoint(x: 7, y: 0))

            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Model Management

    @objc private func deleteLocalModel() {
        let alert = NSAlert()
        alert.messageText = "Delete AI Model?"
        alert.informativeText = "This will remove the \(ModelManager.displayName) model (\(ModelManager.modelSize)) from your Mac. You'll need to re-download it before TextRefiner can refine text again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            do {
                try coordinator.inferenceService.deleteModel()
                let doneAlert = NSAlert()
                doneAlert.messageText = "Model Deleted"
                doneAlert.informativeText = "The AI model has been removed. TextRefiner will need to re-download it on next use."
                doneAlert.alertStyle = .informational
                doneAlert.addButton(withTitle: "OK")
                doneAlert.runModal()
            } catch {
                let errorAlert = NSAlert()
                errorAlert.messageText = "Delete Failed"
                errorAlert.informativeText = "Could not remove the model: \(error.localizedDescription)"
                errorAlert.alertStyle = .warning
                errorAlert.addButton(withTitle: "OK")
                errorAlert.runModal()
            }
        }
    }

    // MARK: - Prompt Settings

    @objc private func showPromptSettings() {
        if promptSettingsController == nil {
            promptSettingsController = PromptSettingsWindowController()
        }
        promptSettingsController?.show()
    }

    // MARK: - History

    @objc private func showHistory() {
        if historyController == nil {
            historyController = HistoryWindowController()
        }
        historyController?.show()
    }

    // MARK: - Settings

    @objc private func showSettings() {
        if settingsController == nil {
            let controller = SettingsWindowController()
            controller.onHotkeyChanged = { [weak self] in
                guard let self else { return }
                // Re-register the CGEvent tap with the new hotkey — no restart required.
                // start() calls stop() internally, so no explicit stop() needed here.
                // The return value MUST be checked: silently discarding it was stress test
                // bug S-01. If permission lapsed while the app was running and the tap
                // fails here, the user must be notified — not left with a broken hotkey
                // and a UI that shows the new shortcut as if everything worked.
                if !hotkeyManager.start() {
                    showHotkeyPermissionAlert()
                }
                // Update the pill label to show the new hotkey
                readyIndicator.updateHotkey()
                let display = HotkeyConfiguration.shared.displayString
                #if DEBUG
                print("[TextRefiner] Hotkey changed to \(display)")
                #endif
            }
            controller.onTypingIndicatorToggled = { [weak self] isEnabled in
                guard let self else { return }
                if isEnabled {
                    self.wireTypingMonitor()
                    self.typingMonitor.start()
                } else {
                    self.typingMonitor.stop()
                    self.readyIndicator.hide()
                }
            }
            controller.onDockIconToggled = { isEnabled in
                NSApp.setActivationPolicy(isEnabled ? .regular : .accessory)
            }
            controller.onReplayTutorial = { [weak self] in
                self?.showOnboarding()
            }
            controller.onSimulateUpdate = { [weak self] in
                guard let self else { return }
                updateManager.simulateUpdateAvailable()
            }
            controller.onExcludedAppsChanged = { [weak self] in
                // Restart the typing monitor so the frontmost-app guard is re-evaluated
                // immediately. start() calls stop() internally — no explicit stop() needed.
                self?.typingMonitor.start()
            }
            settingsController = controller
        }
        settingsController?.show()
    }

    // MARK: - Spinner (Processing Feedback)

    /// Replaces the static menu bar icon with an animated spinner.
    private func showSpinner() {
        guard let button = statusItem.button else { return }
        button.image = nil
        let s = NSProgressIndicator()
        s.style = .spinning
        s.controlSize = .small
        s.sizeToFit()
        s.frame = CGRect(
            x: (button.bounds.width - s.bounds.width) / 2,
            y: (button.bounds.height - s.bounds.height) / 2,
            width: s.bounds.width,
            height: s.bounds.height
        )
        button.addSubview(s)
        s.startAnimation(nil)
        self.spinner = s
    }

    /// Restores the static menu bar icon and removes the spinner.
    private func hideSpinner() {
        spinner?.stopAnimation(nil)
        spinner?.removeFromSuperview()
        spinner = nil
        if let button = statusItem.button {
            button.image = createMenuBarIcon()
            button.image?.isTemplate = true
        }
    }

    // MARK: - Coordinator Wiring

    /// Connects the RefinementCoordinator's callbacks to UI actions.
    private func wireCoordinator() {

        // Permission was revoked — show alert before any processing begins
        coordinator.onPermissionDenied = { [weak self] in
            self?.showPermissionAlert()
        }

        // Hotkey fired, processing begins — expand pill with spinner.
        // Keep typingMonitor.forceHide() to sync its isIndicatorVisible flag.
        // Enable Escape key interception so the user can cancel.
        coordinator.onProcessingStarted = { [weak self] in
            self?.typingMonitor.forceHide()
            self?.showSpinner()
            // In browsers, anchor the HUD to the cursor position captured at hotkey time.
            // In native apps, use the focused text field frame as usual.
            //
            // Read the frontmost app synchronously here rather than relying on
            // typingMonitor.isBrowserFrontmost, which is updated by a workspace
            // notification that may not have fired yet when the user switches to a
            // browser and immediately presses the hotkey. Reading live guarantees
            // the correct branch is taken regardless of notification timing.
            let frontmostApp = NSWorkspace.shared.frontmostApplication
            if TypingMonitor.isBrowserApp(frontmostApp) {
                let cursor = NSEvent.mouseLocation
                let pillW = self?.readyIndicator.pillWidth ?? 60
                self?.browserAnchorFrame = CGRect(
                    x: cursor.x - pillW / 2,
                    y: cursor.y,
                    width: pillW,
                    height: 1
                )
                // Clear any lingering native-app panel before creating the browser HUD.
                // After a native refinement, finishProcessing() leaves panel != nil at state=.ready.
                // Without hide(), startProcessing reuses it at the old text field position.
                self?.readyIndicator.hide()
            } else {
                self?.browserAnchorFrame = nil
            }
            self?.readyIndicator.startProcessing(
                near: self?.browserAnchorFrame ?? self?.typingMonitor.lastKnownFrame,
                trackedElement: self?.typingMonitor.trackedElement
            )
            self?.hotkeyManager.onEscapePressed = { [weak self] in
                self?.coordinator.cancelRefinement()
            }
        }

        // Model done, text ready to paste — swap spinner for green checkmark
        coordinator.onRefinementComplete = { [weak self] in
            self?.readyIndicator.showCheckmark()
            self?.playSound(resource: "Success_Sound", extension: "mp3")
        }

        // Paste complete — collapse pill back to ready state, stop intercepting Escape.
        // Native apps: pill stays visible (TypingMonitor manages it from here).
        // Browser: pill was cursor-anchored with no TypingMonitor management, so hide it
        // after the collapse animation completes (browserAnchorFrame != nil = browser context).
        //
        // After collapse: decrement snooze counter (if update pending), then check whether
        // to show the update banner (1.5s delay, pill must still be visible).
        coordinator.onProcessingFinished = { [weak self] in
            guard let self else { return }
            hotkeyManager.onEscapePressed = nil
            let isBrowser = browserAnchorFrame != nil
            readyIndicator.finishProcessing { [weak self] in
                guard let self else { return }

                // Only successful refinements count toward the snooze countdown.
                if updateManager.hasPendingUpdate {
                    updateManager.decrementSnooze()
                }

                if updateManager.shouldShowBanner {
                    // Wait 1.5s so the user can absorb the refined text before the banner appears.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        guard let self else { return }
                        // Re-check: pill must still be visible after the delay.
                        // An app switch or hide() call during those 1.5s should cancel the banner.
                        guard readyIndicator.isPillVisible else {
                            if isBrowser { readyIndicator.hide() }
                            return
                        }
                        let version = Bundle.main.object(
                            forInfoDictionaryKey: "CFBundleShortVersionString"
                        ) as? String ?? ""
                        readyIndicator.showUpdateBanner(
                            onUpdate: { [weak self] in
                                guard let self else { return }
                                updateManager.recordUpdateNow()
                                updateAvailableMenuItem?.isHidden = true
                                updateManager.checkForUpdates()
                            },
                            onLater: { [weak self] in
                                guard let self else { return }
                                updateManager.recordLater(currentVersion: version)
                                if isBrowser { readyIndicator.hide() }
                            }
                        )
                    }
                } else if isBrowser {
                    readyIndicator.hide()
                }
            }
            hideSpinner()
        }

        // User cancelled with Escape — same browser/native split as onProcessingFinished.
        coordinator.onRefinementCancelled = { [weak self] in
            self?.hotkeyManager.onEscapePressed = nil
            if self?.browserAnchorFrame != nil {
                self?.readyIndicator.finishProcessing { [weak self] in
                    self?.readyIndicator.hide()
                }
            } else {
                self?.readyIndicator.finishProcessing()
            }
            self?.hideSpinner()
        }

        // Error — input too long shows error in the pill (auto-dismisses after 5s).
        // All other errors collapse the pill and show an NSAlert.
        coordinator.onError = { [weak self] error in
            self?.hotkeyManager.onEscapePressed = nil
            self?.playSound(resource: "Fail_sound", extension: "mov")
            if case RefinementError.inputTooLong = error {
                self?.hideSpinner()
                self?.readyIndicator.showError(near: self?.browserAnchorFrame ?? self?.typingMonitor.lastKnownFrame) {
                    self?.hotkeyManager.onEscapePressed = nil
                    self?.readyIndicator.hide()
                }
                self?.hotkeyManager.onEscapePressed = { [weak self] in
                    self?.hotkeyManager.onEscapePressed = nil
                    self?.readyIndicator.finishProcessing { [weak self] in
                        self?.readyIndicator.hide()
                    }
                }
            } else if case RefinementError.inferenceTimedOut = error {
                self?.hideSpinner()
                self?.readyIndicator.showError(near: self?.browserAnchorFrame ?? self?.typingMonitor.lastKnownFrame, message: "timed out") {
                    self?.hotkeyManager.onEscapePressed = nil
                    self?.readyIndicator.hide()
                }
                self?.hotkeyManager.onEscapePressed = { [weak self] in
                    self?.hotkeyManager.onEscapePressed = nil
                    self?.readyIndicator.finishProcessing { [weak self] in
                        self?.readyIndicator.hide()
                    }
                }
            } else if case RefinementError.noTextSelected = error {
                self?.hideSpinner()
                self?.readyIndicator.showError(near: self?.browserAnchorFrame ?? self?.typingMonitor.lastKnownFrame, message: "no text selected") {
                    self?.hotkeyManager.onEscapePressed = nil
                    self?.readyIndicator.hide()
                }
                self?.hotkeyManager.onEscapePressed = { [weak self] in
                    self?.hotkeyManager.onEscapePressed = nil
                    self?.readyIndicator.finishProcessing { [weak self] in
                        self?.readyIndicator.hide()
                    }
                }
            } else if case InferenceError.modelNotDownloaded = error {
                self?.readyIndicator.finishProcessing()
                self?.hideSpinner()
                self?.showModelDownloadPrompt()
            } else {
                self?.readyIndicator.finishProcessing()
                self?.hideSpinner()
                self?.showErrorAlert(error)
            }
        }
    }

    // MARK: - Hotkey + Onboarding

    /// Starts listening for the configured hotkey globally and activates the typing monitor.
    /// Returns true if the CGEvent tap was successfully created.
    ///
    /// **This method has no UI side effects on failure.** It returns false and the caller
    /// decides the appropriate response — silent polling, an inline error, or an alert.
    /// This is intentional: when the tap attempt triggers macOS's own system Accessibility
    /// prompt, showing our alert on top of it creates a confusing double-dialog
    /// (stress test S-21). Callers that want to show an alert do so explicitly.
    @discardableResult
    private func startListening() -> Bool {
        // Kill any existing poll timer first. If startListening() succeeds, the timer's
        // job is done. If it fails, the caller will restart polling if needed. Either way
        // the old timer must not keep firing in the background
        // (stress test S-02: poll timer racing with onReadyForTrial).
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = nil

        hotkeyManager.onHotkeyPressed = { [weak self] in
            self?.coordinator.startRefinement()
        }

        let tapCreated = hotkeyManager.start()
        #if DEBUG
        print("[TextRefiner] Hotkey tap created: \(tapCreated) — listening for \(HotkeyConfiguration.shared.displayString)")
        #endif

        if tapCreated {
            // Start the typing monitor only if the feature is enabled
            let isEnabled = UserDefaults.standard.object(forKey: TypingMonitor.enabledKey) == nil
                || UserDefaults.standard.bool(forKey: TypingMonitor.enabledKey)
            if isEnabled {
                wireTypingMonitor()
                typingMonitor.start()
            }
        }

        return tapCreated
    }

    private func applyDockVisibility() {
        let show = UserDefaults.standard.object(forKey: "com.textrefiner.showDockIcon") == nil
            || UserDefaults.standard.bool(forKey: "com.textrefiner.showDockIcon")
        NSApp.setActivationPolicy(show ? .regular : .accessory)
    }

    private func wireTypingMonitor() {
        typingMonitor.onShouldShow = { [weak self] fieldFrame in
            self?.readyIndicator.show(near: fieldFrame)
        }
        typingMonitor.onShouldHide = { [weak self] in
            self?.readyIndicator.hide()
        }
        typingMonitor.onAppSwitched = { [weak self] in
            self?.readyIndicator.clearCachedFrame()
        }
        // When the HUD collapses back to the pill after processing/cancel, the pill is
        // visually present but TypingMonitor.isIndicatorVisible is false (forceHide()
        // cleared it when the hotkey fired). Without this, the next app-switch emitHide()
        // is a no-op and the pill stays floating on top of the browser (Issue 3).
        readyIndicator.onDidReturnToReady = { [weak self] in
            self?.typingMonitor.restoreIndicatorVisibility()
        }
    }

    /// Shows the onboarding window, then starts listening when complete.
    private func showOnboarding() {
        // Guard against opening a second onboarding window while one is already showing.
        // Multiple code paths can trigger showOnboarding() — first launch, version change,
        // permission failure mid-session, and "Replay Tutorial" from Settings. Without
        // this guard, two windows could open simultaneously, both trying to register the
        // hotkey at the same time (stress test S-07).
        if let existing = onboardingController {
            existing.bringToFront()
            return
        }

        let controller = OnboardingWindowController()

        // onReadyForTrial is called when the user clicks "Next" on setup page 1.
        // It tries to register the actual CGEvent tap and returns success/failure so
        // the onboarding can gate the page transition on whether the hotkey ACTUALLY works.
        // This is the critical guardrail: the user cannot reach the tutorial page unless
        // the real tap was created successfully.
        controller.onReadyForTrial = { [weak self] in
            return self?.startListening() ?? false
        }

        controller.onComplete = { [weak self] in
            // Mark onboarding as completed and record this build number.
            // Use a UUID fallback — consistent with completeLaunchSetup() — so that
            // an unreadable version number always triggers re-onboarding next launch
            // rather than silently pinning to a "0" that never changes (stress test S-08).
            UserDefaults.standard.set(true, forKey: "com.textrefiner.onboardingCompleted")
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                ?? "missing-\(UUID().uuidString)"
            UserDefaults.standard.set(build, forKey: "com.textrefiner.lastOnboardedBuild")

            // Hotkey listener was already started when the tutorial page appeared
            // (via onReadyForTrial). Just clean up the onboarding controller.
            DispatchQueue.main.async {
                self?.onboardingController = nil
            }
        }

        // onDismissedEarly fires when the user closes the setup window via the red-X
        // button before completing setup (stress test S-06). The hotkey was never
        // registered. Start background polling so the app can self-heal if they later
        // grant Accessibility permission through System Settings.
        controller.onDismissedEarly = { [weak self] in
            DispatchQueue.main.async {
                self?.onboardingController = nil
            }
            self?.startAccessibilityPolling()
        }

        controller.show()
        self.onboardingController = controller
    }

    /// Shown when the hotkey tap cannot be created — Accessibility permission is missing
    /// or stale (common after ad-hoc binary updates). Gives clear, specific instructions.
    private func showHotkeyPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Hotkey Not Working — Permission Needed"
        alert.informativeText = """
            TextRefiner couldn't register the \(HotkeyConfiguration.shared.displayString) hotkey. \
            This happens after updates because macOS ties Accessibility permission to the specific \
            binary — the old permission no longer applies.

            Fix: Open System Settings → Privacy & Security → Accessibility, find TextRefiner, \
            toggle it OFF then back ON. Then click Retry.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Later")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn: // Open System Settings
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            // Start polling — when the user re-grants, startListening() fires automatically
            startAccessibilityPolling()

        case .alertSecondButtonReturn: // Retry
            // If retry still fails, fall through to silent background polling instead of
            // re-showing this alert. Re-alerting on failure creates an infinite modal stack
            // (each "Retry" that fails opens another copy of this dialog on top of the
            // previous one — stress test S-05).
            if !startListening() {
                startAccessibilityPolling()
            }

        default: // Later
            // The user said "later" but they expect the app to keep trying in the background.
            // Without polling, the hotkey stays broken for the entire session unless they
            // restart the app. Silent polling self-heals if they grant permission later
            // through System Settings (stress test S-04).
            startAccessibilityPolling()
        }
    }

    // MARK: - Alerts

    /// Shown when the user presses the hotkey but Accessibility permission is missing.
    /// Offers a single path: re-run onboarding to re-grant permission.
    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "TextRefiner Needs Permission"
        alert.informativeText = "Accessibility access was disabled. TextRefiner needs it to read and replace selected text in other apps."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Start Onboarding")
        alert.addButton(withTitle: "Cancel")

        // Bring app to front so the alert is visible
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            // Stop any running poll timer before entering onboarding — the timer calling
            // startListening() concurrently with onboarding's onReadyForTrial creates a
            // race where both try to register the tap at the same time (stress test S-10).
            accessibilityPollTimer?.invalidate()
            accessibilityPollTimer = nil
            // Stop the existing (now-broken) event tap before re-onboarding
            hotkeyManager.stop()
            showOnboarding()
        }
    }

    /// Shown when refinement fails (model error, empty response, etc.)
    private func showErrorAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "TextRefiner"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Shown when the AI model is missing — offers to download it immediately.
    private func showModelDownloadPrompt() {
        let alert = NSAlert()
        alert.messageText = "AI Model Not Found"
        alert.informativeText = "The AI model needs to be downloaded before TextRefiner can refine text. This is a one-time download (~\(ModelManager.modelSize))."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download Now")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        // Show a progress alert while downloading
        let progressAlert = NSAlert()
        progressAlert.messageText = "Downloading AI Model…"
        progressAlert.informativeText = "0%"
        progressAlert.alertStyle = .informational
        progressAlert.addButton(withTitle: "Cancel")

        // Add a progress indicator to the alert
        let progressBar = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 250, height: 20))
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressAlert.accessoryView = progressBar

        // Run the download in the background, updating the alert
        var downloadTask: Task<Void, Error>?

        downloadTask = Task {
            do {
                try await coordinator.inferenceService.downloadModel { progress in
                    DispatchQueue.main.async {
                        let pct = Int(progress * 100)
                        progressBar.doubleValue = Double(pct)
                        progressAlert.informativeText = "\(pct)%"
                    }
                }
                DispatchQueue.main.async {
                    // Dismiss the progress alert by clicking its button programmatically
                    NSApp.stopModal(withCode: .alertFirstButtonReturn)
                    let doneAlert = NSAlert()
                    doneAlert.messageText = "Download Complete"
                    doneAlert.informativeText = "The AI model is ready. Select some text and press your hotkey to refine."
                    doneAlert.alertStyle = .informational
                    doneAlert.addButton(withTitle: "OK")
                    doneAlert.runModal()
                }
            } catch {
                DispatchQueue.main.async {
                    NSApp.stopModal(withCode: .alertSecondButtonReturn)
                    let errorAlert = NSAlert()
                    errorAlert.messageText = "Download Failed"
                    errorAlert.informativeText = error.localizedDescription
                    errorAlert.alertStyle = .warning
                    errorAlert.addButton(withTitle: "OK")
                    errorAlert.runModal()
                }
            }
        }

        let modalResponse = progressAlert.runModal()
        if modalResponse == .alertFirstButtonReturn {
            // User clicked Cancel on the progress dialog
            downloadTask?.cancel()
        }
    }

    // MARK: - Updates

    @objc private func checkForUpdates() {
        updateManager.checkForUpdates()
    }

    /// Action for the "Update available →" menu item.
    /// Triggers Sparkle to present its standard download/install flow.
    @objc private func installAvailableUpdate() {
        updateManager.checkForUpdates()
    }

    /// Polls for Accessibility permission every 1.5s. When granted, re-registers the hotkey listener.
    private func startAccessibilityPolling() {
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            if AccessibilityService.isTrusted() {
                timer.invalidate()
                self?.accessibilityPollTimer = nil
                self?.startListening()
                #if DEBUG
                print("[TextRefiner] Accessibility re-granted after update")
                #endif
            }
        }
    }

    // MARK: - Permission Management

    /// Resets the Accessibility TCC entry for this app's bundle ID.
    /// With ad-hoc signing, every binary change produces a new CDHash. The old
    /// TCC entry becomes stale — the toggle appears ON in System Settings but
    /// doesn't match the current binary. Resetting forces a clean re-grant.
    private static func resetAccessibilityPermission() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleID]
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        #if DEBUG
        print("[TextRefiner] Reset Accessibility TCC for \(bundleID)")
        #endif
    }

    // MARK: - Quarantine Removal

    /// Removes the com.apple.quarantine extended attribute from the app bundle,
    /// then calls the completion handler on the main thread.
    ///
    /// This is critical for ad-hoc signed apps distributed outside the App Store:
    /// macOS blocks CGEvent tap creation for quarantined binaries, even when
    /// Accessibility permission is granted. Sparkle updates and browser downloads
    /// both set this flag. Must complete before any Accessibility / CGEvent checks.
    ///
    /// Runs on a background thread to avoid blocking the main thread at launch —
    /// on slow machines, network volumes, or large bundles, xattr -dr can take
    /// multiple seconds synchronously (stress test S-12).
    private static func removeQuarantineFlag(completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let bundlePath = Bundle.main.bundlePath
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            process.arguments = ["-dr", "com.apple.quarantine", bundlePath]
            process.environment = ["PATH": "/usr/bin:/bin"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            DispatchQueue.main.async { completion() }
        }
    }

    // MARK: - About

    @objc private func showAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let alert = NSAlert()
        alert.messageText = "TextRefiner"
        let hotkey = HotkeyConfiguration.shared.displayString
        alert.informativeText = "Highlight text, press \(hotkey), get better writing.\n100% private — your text never leaves your Mac.\nModel: \(ModelManager.displayName)\n\nVersion \(version)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Rebuild & Relaunch (dev builds only)

    @objc private func rebuildAndRelaunch() {
        let bundlePath = Bundle.main.bundlePath
        let appDir = (bundlePath as NSString).deletingLastPathComponent
        let buildScript = (appDir as NSString).appendingPathComponent("build.sh")

        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [buildScript]
            process.currentDirectoryURL = URL(fileURLWithPath: appDir)
            process.environment = [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/libexec",
                "HOME": ProcessInfo.processInfo.environment["HOME"] ?? "",
            ]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()

                let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outputData, encoding: .utf8) ?? ""

                await MainActor.run {
                    if process.terminationStatus == 0 {
                        let appBundleURL = URL(fileURLWithPath: appDir)
                            .appendingPathComponent("TextRefiner.app")
                        // Launch first, then terminate. The previous code used asyncAfter(1s)
                        // for the open call but called NSApp.terminate() immediately — terminate
                        // won the race and the new app never launched. open(2) forks immediately
                        // and returns, so it's safe to terminate right after.
                        let relaunch = Process()
                        relaunch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                        relaunch.arguments = ["-n", appBundleURL.path]
                        relaunch.environment = ["PATH": "/usr/bin:/bin"]
                        try? relaunch.run()
                        NSApp.terminate(nil)
                    } else {
                        let lastLine = output.components(separatedBy: .newlines)
                            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                            .last ?? "Unknown error"
                        let alert = NSAlert()
                        alert.messageText = "Build Failed"
                        alert.informativeText = lastLine
                        alert.alertStyle = .critical
                        alert.runModal()
                    }
                }
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Build Failed"
                    alert.informativeText = "Could not run build.sh: \(error.localizedDescription)"
                    alert.alertStyle = .critical
                    alert.runModal()
                }
            }
        }
    }

    // MARK: - Audio Feedback

    /// Plays a bundled sound file. Supports mp3, aiff, wav, caf, m4a, and mov.
    /// Retains the player in `audioPlayer` so ARC doesn't deallocate it mid-playback.
    /// Respects the user's sound toggle in Settings. Volume is set to 70% of max.
    private func playSound(resource: String, extension ext: String) {
        guard SettingsWindowController.isSoundEnabled else { return }
        guard let url = Bundle.main.url(forResource: resource, withExtension: ext) else { return }
        audioPlayer?.stop()
        audioPlayer = try? AVAudioPlayer(contentsOf: url)
        audioPlayer?.volume = 0.7
        audioPlayer?.play()
    }
}
