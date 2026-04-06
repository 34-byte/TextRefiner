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
    private var streamingPanel: StreamingPanelController?
    private var promptSettingsController: PromptSettingsWindowController?
    private var historyController: HistoryWindowController?
    private var settingsController: SettingsWindowController?
    private let updateManager = UpdateManager()
    private let typingMonitor = TypingMonitor()
    private let readyIndicator = ReadyIndicatorController()

    /// Timer that polls for Accessibility permission after an update resets TCC.
    private var accessibilityPollTimer: Timer?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        wireCoordinator()

        // Request notification permission early
        NotificationManager.requestPermission()

        // Pre-load model in background so first refinement is fast.
        // This runs independently of quarantine/permission state.
        Task.detached { try? await self.coordinator.inferenceService.loadModel() }

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
            // First launch or app was updated — binary hash changed, so the old
            // TCC entry is stale (points to a different CDHash). Clear it so
            // "Grant Access" triggers a fresh system prompt for the current binary.
            if needsReOnboarding {
                Self.resetAccessibilityPermission()
            }
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

        menu.addItem(NSMenuItem.separator())

        // Delete AI Model
        menu.addItem(NSMenuItem(title: "Delete AI Model...", action: #selector(deleteLocalModel), keyEquivalent: ""))

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "About TextRefiner", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit TextRefiner", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    /// Creates the ✦A menu bar icon programmatically as a template image.
    /// Drawn at 18x18pt (36x36px @2x) — standard menu bar icon size.
    private func createMenuBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            // Draw the sparkle (✦) — small, on the left
            let sparkleFont = NSFont.systemFont(ofSize: 8, weight: .medium)
            let sparkleAttrs: [NSAttributedString.Key: Any] = [
                .font: sparkleFont,
                .foregroundColor: NSColor.black
            ]
            let sparkle = NSAttributedString(string: "✦", attributes: sparkleAttrs)
            sparkle.draw(at: NSPoint(x: 0, y: 3))

            // Draw the "A" — bold, on the right
            let aFont = NSFont.systemFont(ofSize: 14, weight: .bold)
            let aAttrs: [NSAttributedString.Key: Any] = [
                .font: aFont,
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
                // The return value MUST be checked: silently discarding it was stress test
                // bug S-01. If permission lapsed while the app was running and the tap
                // fails here, the user must be notified — not left with a broken hotkey
                // and a UI that shows the new shortcut as if everything worked.
                hotkeyManager.stop()
                if !hotkeyManager.start() {
                    showHotkeyPermissionAlert()
                }
                // Update the pill label to show the new hotkey
                readyIndicator.updateHotkey()
                let display = HotkeyConfiguration.shared.displayString
                print("[TextRefiner] Hotkey changed to \(display)")
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
            controller.onReplayTutorial = { [weak self] in
                self?.showOnboarding()
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

        // Hotkey fired, processing begins — hide ready indicator, show spinner + floating panel
        coordinator.onProcessingStarted = { [weak self] in
            self?.typingMonitor.forceHide()
            self?.readyIndicator.hide()
            self?.showSpinner()
            let panel = StreamingPanelController()
            panel.show()
            self?.streamingPanel = panel
        }

        // Model done, text ready to paste — swap spinner for green checkmark
        coordinator.onRefinementComplete = { [weak self] in
            self?.streamingPanel?.showCheckmark()
        }

        // Paste complete — dismiss everything
        coordinator.onProcessingFinished = { [weak self] in
            self?.streamingPanel?.dismiss()
            self?.streamingPanel = nil
            self?.hideSpinner()
        }

        // Error (model not loaded, no text selected, etc.) — show alert, always clean up
        coordinator.onError = { [weak self] error in
            self?.streamingPanel?.dismiss()
            self?.streamingPanel = nil
            self?.hideSpinner()
            self?.showErrorAlert(error)
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
            // Hide the ready indicator the moment the hotkey fires
            self?.typingMonitor.forceHide()
            self?.readyIndicator.hide()
            self?.coordinator.startRefinement()
        }

        let tapCreated = hotkeyManager.start()
        print("[TextRefiner] Hotkey tap created: \(tapCreated) — listening for \(HotkeyConfiguration.shared.displayString)")

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

    private func wireTypingMonitor() {
        typingMonitor.onShouldShow = { [weak self] fieldFrame in
            self?.readyIndicator.show(near: fieldFrame)
        }
        typingMonitor.onShouldHide = { [weak self] in
            self?.readyIndicator.hide()
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

    // MARK: - Updates

    @objc private func checkForUpdates() {
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
                print("[TextRefiner] Accessibility re-granted after update")
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
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        print("[TextRefiner] Reset Accessibility TCC for \(bundleID)")
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
        alert.informativeText = "Highlight text, press \(hotkey), get better writing.\nPowered by local AI.\nModel: \(ModelManager.displayName)\n\nVersion \(version)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
