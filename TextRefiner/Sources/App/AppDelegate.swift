import Cocoa
import Sparkle

/// The central hub that wires all components together.
/// Manages the menu bar icon, spinner states, and coordinates between
/// onboarding, hotkey detection, and the refinement flow.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

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

    /// Timer that polls for Accessibility permission after an update resets TCC.
    private var accessibilityPollTimer: Timer?

    /// Kept as a reference so we can update model checkmarks and download status dynamically.
    private var modelSubmenu: NSMenu?

    /// Cached set of downloaded model IDs — updated each time the Model submenu opens.
    private var downloadedModels: Set<String> = []

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        wireCoordinator()

        // Request notification permission early
        NotificationManager.requestPermission()

        // Show onboarding only when needed:
        // - First ever launch (flag not yet set), OR
        // - Accessibility permission was revoked since last launch
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "com.textrefiner.onboardingCompleted")
        let accessibilityGranted = AccessibilityService.isTrusted()

        if !hasCompletedOnboarding {
            // First launch — full onboarding
            showOnboarding()
        } else if !accessibilityGranted {
            // Completed onboarding before but permission lost (likely after an update)
            showAccessibilityRegrantPrompt()
        } else {
            startListening()
        }

        // Pre-warm Ollama connection in background
        Task { await coordinator.ollamaService.prewarm() }
    }

    // MARK: - Menu Bar Setup

    /// Creates the menu bar icon (sparkle + A as template image) and dropdown menu.
    /// Menu structure: Model > [submenu], Prompt Settings..., separator, About, Quit.
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = createMenuBarIcon()
            button.image?.isTemplate = true // Respects dark/light mode automatically
        }

        let menu = NSMenu()

        // Model submenu
        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.delegate = self  // We implement menuWillOpen to refresh download status
        modelItem.submenu = submenu
        self.modelSubmenu = submenu
        menu.addItem(modelItem)

        // Prompt Settings
        menu.addItem(NSMenuItem(title: "Prompt Settings...", action: #selector(showPromptSettings), keyEquivalent: ""))

        // History
        menu.addItem(NSMenuItem(title: "History...", action: #selector(showHistory), keyEquivalent: ""))

        // Settings (hotkey configuration, etc.)
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ","))

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

    // MARK: - NSMenuDelegate (Model Submenu)

    /// Called just before the model submenu opens — refreshes download status.
    func menuWillOpen(_ menu: NSMenu) {
        guard menu == modelSubmenu else { return }
        rebuildModelSubmenu(with: downloadedModels)

        // Async-refresh downloaded models (fast localhost call).
        // Updates the menu in-place if the result differs from cached state.
        Task {
            let freshDownloaded = await ModelManager.shared.fetchDownloadedModels()
            if freshDownloaded != self.downloadedModels {
                self.downloadedModels = freshDownloaded
                await MainActor.run {
                    self.rebuildModelSubmenu(with: freshDownloaded)
                }
            }
        }
    }

    /// Rebuilds the Model submenu items based on current download/selection state.
    private func rebuildModelSubmenu(with downloaded: Set<String>) {
        guard let submenu = modelSubmenu else { return }
        submenu.removeAllItems()

        let selectedID = ModelManager.shared.selectedModelID

        // Add a model item for each recommended model
        for model in ModelManager.recommendedModels {
            let isDownloaded = downloaded.contains(model.id)
            let isSelected = model.id == selectedID

            // Build title: "Llama 3.2 (3B) — ~2.0 GB" + optional tags
            var title = "\(model.displayName) — \(model.size)"
            if model.isDefault {
                title += "  ★ Recommended"
            }
            if !isDownloaded {
                title += "  (Not Downloaded)"
            }

            let item = NSMenuItem(title: title, action: #selector(selectModel(_:)), keyEquivalent: "")
            item.representedObject = model.id
            item.target = self
            item.state = isSelected ? .on : .off

            // Grey out undownloaded models (still clickable — triggers download prompt)
            if !isDownloaded {
                item.attributedTitle = NSAttributedString(
                    string: title,
                    attributes: [.foregroundColor: NSColor.secondaryLabelColor]
                )
            }

            submenu.addItem(item)
        }

        // Separator + Manage Models section (only if there are downloaded models to manage)
        let deletableModels = downloaded.filter { $0 != selectedID }
        if !deletableModels.isEmpty {
            submenu.addItem(NSMenuItem.separator())

            let headerItem = NSMenuItem(title: "Manage Downloaded Models", action: nil, keyEquivalent: "")
            headerItem.isEnabled = false
            submenu.addItem(headerItem)

            for modelID in deletableModels.sorted() {
                let model = ModelManager.recommendedModels.first { $0.id == modelID }
                let displayName = model?.displayName ?? modelID
                let size = model?.size ?? ""
                let deleteItem = NSMenuItem(
                    title: "Remove \(displayName) (\(size))",
                    action: #selector(deleteModel(_:)),
                    keyEquivalent: ""
                )
                deleteItem.representedObject = modelID
                deleteItem.target = self
                submenu.addItem(deleteItem)
            }
        }
    }

    // MARK: - Model Actions

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let modelID = sender.representedObject as? String else { return }

        // If already selected, do nothing
        if modelID == ModelManager.shared.selectedModelID { return }

        // Check if the model is downloaded
        if downloadedModels.contains(modelID) {
            // Downloaded — select it immediately
            ModelManager.shared.selectedModelID = modelID
        } else {
            // Not downloaded — ask user to confirm download
            let model = ModelManager.recommendedModels.first { $0.id == modelID }
            let displayName = model?.displayName ?? modelID
            let size = model?.size ?? "unknown size"

            let alert = NSAlert()
            alert.messageText = "Download \(displayName)?"
            alert.informativeText = "This model is not downloaded yet. It will download \(size) to your Mac. Are you sure you want to proceed?"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                downloadAndSelectModel(modelID: modelID)
            }
        }
    }

    /// Downloads a model in the background, then selects it.
    private func downloadAndSelectModel(modelID: String) {
        let model = ModelManager.recommendedModels.first { $0.id == modelID }
        let displayName = model?.displayName ?? modelID

        Task {
            do {
                try await coordinator.ollamaService.pullModel(name: modelID) { status in
                    print("[TextRefiner] Pull progress for \(displayName): \(status)")
                }

                // Download complete — select the model
                ModelManager.shared.selectedModelID = modelID
                downloadedModels.insert(modelID)

                await MainActor.run {
                    let doneAlert = NSAlert()
                    doneAlert.messageText = "\(displayName) Ready"
                    doneAlert.informativeText = "\(displayName) has been downloaded and is now your active model."
                    doneAlert.alertStyle = .informational
                    doneAlert.addButton(withTitle: "OK")
                    NSApp.activate(ignoringOtherApps: true)
                    doneAlert.runModal()
                }
            } catch {
                await MainActor.run {
                    let errorAlert = NSAlert()
                    errorAlert.messageText = "Download Failed"
                    errorAlert.informativeText = "Could not download \(displayName): \(error.localizedDescription)"
                    errorAlert.alertStyle = .warning
                    errorAlert.addButton(withTitle: "OK")
                    NSApp.activate(ignoringOtherApps: true)
                    errorAlert.runModal()
                }
            }
        }
    }

    @objc private func deleteModel(_ sender: NSMenuItem) {
        guard let modelID = sender.representedObject as? String else { return }

        // Safety: never delete the currently selected model
        guard modelID != ModelManager.shared.selectedModelID else { return }

        let model = ModelManager.recommendedModels.first { $0.id == modelID }
        let displayName = model?.displayName ?? modelID
        let size = model?.size ?? ""

        let alert = NSAlert()
        alert.messageText = "Remove \(displayName)?"
        alert.informativeText = "This will delete the model from your Mac and free \(size) of storage. You can re-download it later."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            Task {
                do {
                    try await coordinator.ollamaService.deleteModel(name: modelID)
                    downloadedModels.remove(modelID)
                    print("[TextRefiner] Deleted model: \(modelID)")
                } catch {
                    await MainActor.run {
                        let errorAlert = NSAlert()
                        errorAlert.messageText = "Delete Failed"
                        errorAlert.informativeText = "Could not remove \(displayName): \(error.localizedDescription)"
                        errorAlert.alertStyle = .warning
                        errorAlert.addButton(withTitle: "OK")
                        NSApp.activate(ignoringOtherApps: true)
                        errorAlert.runModal()
                    }
                }
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
                // Re-register the CGEvent tap with the new hotkey — no restart required
                self?.hotkeyManager.stop()
                self?.hotkeyManager.start()
                let display = HotkeyConfiguration.shared.displayString
                print("[TextRefiner] Hotkey changed to \(display)")
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

        // Hotkey fired, processing begins — show spinner in menu bar + floating panel
        coordinator.onProcessingStarted = { [weak self] in
            self?.showSpinner()
            let panel = StreamingPanelController()
            panel.show()
            self?.streamingPanel = panel
        }

        // Ollama done, text ready to paste — swap spinner for green checkmark
        coordinator.onRefinementComplete = { [weak self] in
            self?.streamingPanel?.showCheckmark()
        }

        // Paste complete — dismiss everything
        coordinator.onProcessingFinished = { [weak self] in
            self?.streamingPanel?.dismiss()
            self?.streamingPanel = nil
            self?.hideSpinner()
        }

        // Error (Ollama down, no text selected, etc.) — show alert, always clean up
        coordinator.onError = { [weak self] error in
            self?.streamingPanel?.dismiss()
            self?.streamingPanel = nil
            self?.hideSpinner()
            self?.showErrorAlert(error)
        }
    }

    // MARK: - Hotkey + Onboarding

    /// Starts listening for the configured hotkey globally.
    private func startListening() {
        hotkeyManager.onHotkeyPressed = { [weak self] in
            self?.coordinator.startRefinement()
        }
        hotkeyManager.start()
        print("[TextRefiner] Listening for \(HotkeyConfiguration.shared.displayString)...")
    }

    /// Shows the onboarding window, then starts listening when complete.
    private func showOnboarding() {
        let controller = OnboardingWindowController()
        controller.onComplete = { [weak self] in
            // Mark onboarding as completed so we don't show it again on next launch
            UserDefaults.standard.set(true, forKey: "com.textrefiner.onboardingCompleted")

            // Start listening immediately — no dependency on controller cleanup order
            self?.startListening()
            // Defer the controller nil-out by one runloop tick so any pending
            // SwiftUI/AppKit layout work finishes before the hosting controller deallocates
            DispatchQueue.main.async {
                self?.onboardingController = nil
            }
        }
        controller.show()
        self.onboardingController = controller
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
            // Stop the existing (now-broken) event tap before re-onboarding
            hotkeyManager.stop()
            showOnboarding()
        }
    }

    /// Shown when refinement fails (Ollama down, empty response, etc.)
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

    // MARK: - Post-Update Accessibility Re-grant

    /// After an update, the binary hash changes (ad-hoc signing) and TCC invalidates
    /// the Accessibility grant. This shows a friendly prompt and polls until re-granted.
    private func showAccessibilityRegrantPrompt() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = """
        TextRefiner was just updated. macOS requires you to re-enable \
        Accessibility permission after an update.

        In System Settings → Privacy & Security → Accessibility:
        • If TextRefiner is listed, toggle it OFF then ON
        • If not listed, click + and add TextRefiner

        This window will close automatically once permission is granted.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            // Open Accessibility settings directly
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }

        // Start polling for permission regardless of button choice
        startAccessibilityPolling()
    }

    /// Polls for Accessibility permission every 1.5s. When granted, starts the hotkey listener.
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

    // MARK: - About

    @objc private func showAbout() {
        let modelName = ModelManager.shared.selectedModel?.displayName ?? ModelManager.shared.selectedModelID
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let alert = NSAlert()
        alert.messageText = "TextRefiner"
        let hotkey = HotkeyConfiguration.shared.displayString
        alert.informativeText = "Highlight text, press \(hotkey), get better writing.\nPowered by Ollama (local AI).\nActive model: \(modelName)\n\nVersion \(version)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
