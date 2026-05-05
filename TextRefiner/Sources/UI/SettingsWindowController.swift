import Cocoa
import ServiceManagement

/// Settings window with a hotkey capture control.
/// Accessible via menu bar → "Settings...".
///
/// The hotkey field enters recording mode on click — the user presses their
/// desired key combo, which is validated (requires modifier + non-modifier)
/// and saved to UserDefaults. The CGEvent tap is re-registered live.
final class SettingsWindowController {
    private var window: NSWindow?

    /// Called after the hotkey is saved — AppDelegate uses this to restart the event tap.
    var onHotkeyChanged: (() -> Void)?

    /// Called when the user clicks "Replay Tutorial" — AppDelegate shows onboarding.
    var onReplayTutorial: (() -> Void)?

    /// Called when the typing indicator toggle changes. AppDelegate starts/stops TypingMonitor.
    var onTypingIndicatorToggled: ((Bool) -> Void)?

    /// Called when the "Show in Dock" toggle changes. AppDelegate updates the activation policy.
    var onDockIconToggled: ((Bool) -> Void)?

    /// Called when the refinement sound toggle changes.
    var onSoundToggled: ((Bool) -> Void)?

    /// Called when the dev-only "Simulate Update Available" button is tapped.
    /// AppDelegate uses this to exercise the update banner flow without a live Sparkle appcast.
    var onSimulateUpdate: (() -> Void)?

    /// Called when the user adds or removes an excluded app. AppDelegate restarts
    /// TypingMonitor so the change takes effect immediately for the frontmost app.
    var onExcludedAppsChanged: (() -> Void)?

    private var hotkeyButton: NSButton?
    private var warningLabel: NSTextField?
    private var resetButton: NSButton?
    private var launchOnLoginCheckbox: NSButton?
    private var indicatorCheckbox: NSButton?
    private var dockCheckbox: NSButton?
    private var soundCheckbox: NSButton?
    private var rebuildButton: NSButton?
    private var buildStatusLabel: NSTextField?
    private var buildSpinner: NSProgressIndicator?
    private var simulateButton: NSButton?
    private var simulateStatusLabel: NSTextField?
    private var excludedAppsTable: NSTableView?
    private var excludedAppsRemoveButton: NSButton?
    private var excludedAppsDataSource: ExcludedAppsTableSource?
    private var isRecording = false
    private var isBuilding = false
    private var eventMonitor: Any?
    private var windowDelegate: WindowDelegate?

    // Pending values while recording
    private var pendingKeyCode: UInt16?
    private var pendingModifiers: CGEventFlags?

    func show() {
        if let existing = window {
            // Refresh controls to reflect current state
            launchOnLoginCheckbox?.state = Self.isLaunchOnLoginEnabled ? .on : .off
            indicatorCheckbox?.state = Self.isIndicatorEnabled ? .on : .off
            dockCheckbox?.state = Self.isShowDockEnabled ? .on : .off
            soundCheckbox?.state = Self.isSoundEnabled ? .on : .off
            excludedAppsTable?.reloadData()
            updateExcludedAppsRemoveButtonState()
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let isDevBuild = Bundle.main.bundleIdentifier == "com.textrefiner.app.dev"
        // Dev builds add an extra developer section below the privacy note.
        // The 176pt difference accommodates: separator + label + rebuild button +
        // spinner + status label + simulate button + margins.
        let windowHeight: CGFloat = isDevBuild ? 787 : 611
        // All shared content is positioned from the top using this offset.
        // Dev builds have a taller window, so content shifts up by the extra height.
        let topBase: CGFloat = windowHeight - 37   // y of first element from window top

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: windowHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "Settings"
        w.center()
        w.isReleasedWhenClosed = false
        let delegate = WindowDelegate(onClose: { [weak self] in
            self?.stopRecording()
            self?.window = nil
            self?.windowDelegate = nil
        })
        self.windowDelegate = delegate
        w.delegate = delegate

        let contentView = NSView(frame: w.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]
        w.contentView = contentView

        // --- Hotkey Section ---

        let sectionLabel = makeLabel("Hotkey", bold: true)
        sectionLabel.frame = NSRect(x: 20, y: topBase, width: 380, height: 20)
        contentView.addSubview(sectionLabel)

        let descLabel = makeLabel("Click the field below, then press your desired shortcut.")
        descLabel.frame = NSRect(x: 20, y: topBase - 25, width: 380, height: 20)
        descLabel.textColor = .secondaryLabelColor
        contentView.addSubview(descLabel)

        let btn = NSButton(frame: NSRect(x: 20, y: topBase - 62, width: 200, height: 28))
        btn.bezelStyle = .roundRect
        btn.title = HotkeyConfiguration.shared.displayString
        btn.target = self
        btn.action = #selector(hotkeyButtonClicked)
        contentView.addSubview(btn)
        self.hotkeyButton = btn

        let reset = NSButton(frame: NSRect(x: 228, y: topBase - 62, width: 120, height: 28))
        reset.bezelStyle = .roundRect
        reset.title = "Reset to Default"
        reset.target = self
        reset.action = #selector(resetToDefault)
        contentView.addSubview(reset)
        self.resetButton = reset

        let warning = makeLabel("")
        warning.frame = NSRect(x: 20, y: topBase - 95, width: 380, height: 30)
        warning.textColor = .systemOrange
        warning.lineBreakMode = .byWordWrapping
        warning.maximumNumberOfLines = 2
        contentView.addSubview(warning)
        self.warningLabel = warning

        updateWarningLabel()

        // --- Separator (Hotkey / General) ---

        let separator1 = NSBox(frame: NSRect(x: 20, y: topBase - 115, width: 380, height: 1))
        separator1.boxType = .separator
        contentView.addSubview(separator1)

        // --- General Section ---

        let generalLabel = makeLabel("General", bold: true)
        generalLabel.frame = NSRect(x: 20, y: topBase - 145, width: 380, height: 20)
        contentView.addSubview(generalLabel)

        let loginCheckbox = NSButton(checkboxWithTitle: "Launch TextRefiner on login", target: self, action: #selector(toggleLaunchOnLogin))
        loginCheckbox.frame = NSRect(x: 20, y: topBase - 170, width: 380, height: 18)
        loginCheckbox.state = Self.isLaunchOnLoginEnabled ? .on : .off
        contentView.addSubview(loginCheckbox)
        self.launchOnLoginCheckbox = loginCheckbox

        let indCheckbox = NSButton(checkboxWithTitle: "Show typing indicator", target: self, action: #selector(toggleIndicator))
        indCheckbox.frame = NSRect(x: 20, y: topBase - 192, width: 380, height: 18)
        indCheckbox.state = Self.isIndicatorEnabled ? .on : .off
        contentView.addSubview(indCheckbox)
        self.indicatorCheckbox = indCheckbox

        let dockCB = NSButton(checkboxWithTitle: "Show in Dock", target: self, action: #selector(toggleDockIcon))
        dockCB.frame = NSRect(x: 20, y: topBase - 214, width: 380, height: 18)
        dockCB.state = Self.isShowDockEnabled ? .on : .off
        contentView.addSubview(dockCB)
        self.dockCheckbox = dockCB

        let sndCheckbox = NSButton(checkboxWithTitle: "Play sound on refinement", target: self, action: #selector(toggleSound))
        sndCheckbox.frame = NSRect(x: 20, y: topBase - 236, width: 380, height: 18)
        sndCheckbox.state = Self.isSoundEnabled ? .on : .off
        contentView.addSubview(sndCheckbox)
        self.soundCheckbox = sndCheckbox

        let tutorialBtn = NSButton(frame: NSRect(x: 20, y: topBase - 271, width: 170, height: 28))
        tutorialBtn.bezelStyle = .roundRect
        tutorialBtn.title = "Replay Tutorial..."
        tutorialBtn.target = self
        tutorialBtn.action = #selector(replayTutorial)
        contentView.addSubview(tutorialBtn)

        // --- Excluded Apps Section ---

        let separatorExcluded = NSBox(frame: NSRect(x: 20, y: topBase - 291, width: 380, height: 1))
        separatorExcluded.boxType = .separator
        contentView.addSubview(separatorExcluded)

        let excludedLabel = makeLabel("Excluded Apps", bold: true)
        excludedLabel.frame = NSRect(x: 20, y: topBase - 318, width: 380, height: 20)
        contentView.addSubview(excludedLabel)

        let excludedDesc = makeLabel("Pill won't appear in these apps.")
        excludedDesc.frame = NSRect(x: 20, y: topBase - 340, width: 380, height: 18)
        excludedDesc.textColor = .secondaryLabelColor
        contentView.addSubview(excludedDesc)

        let scrollView = NSScrollView(frame: NSRect(x: 20, y: topBase - 425, width: 380, height: 80))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder
        scrollView.autohidesScrollers = true

        let table = NSTableView(frame: scrollView.bounds)
        table.headerView = nil
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.rowHeight = 18

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("excludedApp"))
        column.title = "App"
        column.width = 360
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        let dataSource = ExcludedAppsTableSource(onSelectionChanged: { [weak self] in
            self?.updateExcludedAppsRemoveButtonState()
        })
        table.dataSource = dataSource
        table.delegate = dataSource
        excludedAppsDataSource = dataSource

        scrollView.documentView = table
        contentView.addSubview(scrollView)
        excludedAppsTable = table

        let addExcludedBtn = NSButton(frame: NSRect(x: 20, y: topBase - 461, width: 110, height: 28))
        addExcludedBtn.bezelStyle = .roundRect
        addExcludedBtn.title = "Add App..."
        addExcludedBtn.target = self
        addExcludedBtn.action = #selector(addExcludedApp)
        contentView.addSubview(addExcludedBtn)

        let removeExcludedBtn = NSButton(frame: NSRect(x: 138, y: topBase - 461, width: 110, height: 28))
        removeExcludedBtn.bezelStyle = .roundRect
        removeExcludedBtn.title = "Remove"
        removeExcludedBtn.target = self
        removeExcludedBtn.action = #selector(removeExcludedApp)
        removeExcludedBtn.isEnabled = false
        contentView.addSubview(removeExcludedBtn)
        excludedAppsRemoveButton = removeExcludedBtn

        // --- Privacy Note ---

        let separatorPrivacy = NSBox(frame: NSRect(x: 20, y: topBase - 481, width: 380, height: 1))
        separatorPrivacy.boxType = .separator
        contentView.addSubview(separatorPrivacy)

        let lockIcon = NSImageView(frame: NSRect(x: 20, y: topBase - 506, width: 16, height: 16))
        lockIcon.image = NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: "Privacy")
        lockIcon.contentTintColor = .systemGreen
        contentView.addSubview(lockIcon)

        let privacyLabel = makeLabel("100% private — all processing happens on your Mac.")
        privacyLabel.frame = NSRect(x: 42, y: topBase - 506, width: 358, height: 16)
        privacyLabel.textColor = .tertiaryLabelColor
        contentView.addSubview(privacyLabel)

        // --- Developer Section (dev builds only) ---
        if isDevBuild {
            let separatorDev = NSBox(frame: NSRect(x: 20, y: topBase - 526, width: 380, height: 1))
            separatorDev.boxType = .separator
            contentView.addSubview(separatorDev)

            let devLabel = makeLabel("Developer", bold: true)
            devLabel.frame = NSRect(x: 20, y: topBase - 552, width: 380, height: 20)
            contentView.addSubview(devLabel)

            let rebuildBtn = NSButton(frame: NSRect(x: 20, y: topBase - 589, width: 170, height: 28))
            rebuildBtn.bezelStyle = .roundRect
            rebuildBtn.title = "Rebuild & Relaunch"
            rebuildBtn.target = self
            rebuildBtn.action = #selector(rebuildAndRelaunch)
            contentView.addSubview(rebuildBtn)
            self.rebuildButton = rebuildBtn

            let spinner = NSProgressIndicator(frame: NSRect(x: 198, y: topBase - 585, width: 20, height: 20))
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isHidden = true
            contentView.addSubview(spinner)
            self.buildSpinner = spinner

            let statusLabel = makeLabel("")
            statusLabel.frame = NSRect(x: 20, y: topBase - 619, width: 380, height: 20)
            statusLabel.textColor = .secondaryLabelColor
            contentView.addSubview(statusLabel)
            self.buildStatusLabel = statusLabel

            let simulateBtn = NSButton(frame: NSRect(x: 20, y: topBase - 657, width: 210, height: 28))
            simulateBtn.bezelStyle = .roundRect
            simulateBtn.title = "Simulate Update Available"
            simulateBtn.target = self
            simulateBtn.action = #selector(simulateUpdateAvailable)
            contentView.addSubview(simulateBtn)
            self.simulateButton = simulateBtn

            let simStatus = makeLabel("")
            simStatus.frame = NSRect(x: 20, y: topBase - 687, width: 380, height: 20)
            simStatus.textColor = .systemGreen
            contentView.addSubview(simStatus)
            self.simulateStatusLabel = simStatus
        }

        self.window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Hotkey Recording

    @objc private func hotkeyButtonClicked() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        pendingKeyCode = nil
        pendingModifiers = nil
        hotkeyButton?.title = "Press shortcut..."
        warningLabel?.stringValue = ""

        // Monitor key events while the Settings window is key
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }

            if event.type == .keyDown {
                self.handleKeyDown(event)
                return nil // consume the event
            }

            return event
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        // If no valid combo was captured, restore current display
        if pendingKeyCode == nil {
            hotkeyButton?.title = HotkeyConfiguration.shared.displayString
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        let keyCode = UInt16(event.keyCode)

        // Escape cancels recording
        if keyCode == 53 {
            stopRecording()
            return
        }

        // Build CGEventFlags from NSEvent modifierFlags
        var cgFlags = CGEventFlags()
        if event.modifierFlags.contains(.command)  { cgFlags.insert(.maskCommand) }
        if event.modifierFlags.contains(.shift)    { cgFlags.insert(.maskShift) }
        if event.modifierFlags.contains(.control)  { cgFlags.insert(.maskControl) }
        if event.modifierFlags.contains(.option)   { cgFlags.insert(.maskAlternate) }

        // Validate: must have at least one modifier
        guard HotkeyConfiguration.hasRequiredModifier(cgFlags) else {
            warningLabel?.stringValue = "Shortcut must include at least one modifier key (⌘, ⌃, ⌥, or ⇧)."
            return
        }

        pendingKeyCode = keyCode
        pendingModifiers = cgFlags

        // Update display
        let display = HotkeyConfiguration.formatHotkey(keyCode: keyCode, modifierFlags: cgFlags)
        hotkeyButton?.title = display

        // Stop recording
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        isRecording = false

        // Save and notify
        HotkeyConfiguration.shared.save(keyCode: keyCode, modifierFlags: cgFlags)
        updateWarningLabel()
        onHotkeyChanged?()
    }

    @objc private func resetToDefault() {
        stopRecording()
        HotkeyConfiguration.shared.resetToDefault()
        hotkeyButton?.title = HotkeyConfiguration.shared.displayString
        updateWarningLabel()
        onHotkeyChanged?()
    }

    private func updateWarningLabel() {
        let config = HotkeyConfiguration.shared
        if let warning = HotkeyConfiguration.conflictWarning(keyCode: config.keyCode, modifierFlags: config.modifierFlags) {
            warningLabel?.stringValue = warning
        } else {
            warningLabel?.stringValue = ""
        }
    }

    // MARK: - Replay Tutorial

    @objc private func replayTutorial() {
        window?.close()
        onReplayTutorial?()
    }

    // MARK: - Typing Indicator

    private static var isIndicatorEnabled: Bool {
        // Default to true when the key hasn't been written yet
        guard UserDefaults.standard.object(forKey: TypingMonitor.enabledKey) != nil else { return true }
        return UserDefaults.standard.bool(forKey: TypingMonitor.enabledKey)
    }

    @objc private func toggleIndicator() {
        let enabled = indicatorCheckbox?.state == .on
        UserDefaults.standard.set(enabled, forKey: TypingMonitor.enabledKey)
        onTypingIndicatorToggled?(enabled)
    }

    // MARK: - Dock Icon

    private static var isShowDockEnabled: Bool {
        // Default to true when the key hasn't been written yet
        guard UserDefaults.standard.object(forKey: "com.textrefiner.showDockIcon") != nil else { return true }
        return UserDefaults.standard.bool(forKey: "com.textrefiner.showDockIcon")
    }

    @objc private func toggleDockIcon() {
        let enabled = dockCheckbox?.state == .on
        UserDefaults.standard.set(enabled, forKey: "com.textrefiner.showDockIcon")
        onDockIconToggled?(enabled)
    }

    // MARK: - Refinement Sound

    static let soundEnabledKey = "com.textrefiner.soundEnabled"

    static var isSoundEnabled: Bool {
        // Default to true when the key hasn't been written yet
        guard UserDefaults.standard.object(forKey: soundEnabledKey) != nil else { return true }
        return UserDefaults.standard.bool(forKey: soundEnabledKey)
    }

    @objc private func toggleSound() {
        let enabled = soundCheckbox?.state == .on
        UserDefaults.standard.set(enabled, forKey: Self.soundEnabledKey)
        onSoundToggled?(enabled)
    }

    // MARK: - Launch on Login

    private static var isLaunchOnLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLaunchOnLogin() {
        do {
            if Self.isLaunchOnLoginEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            // Show brief error and revert checkbox state
            let alert = NSAlert()
            alert.messageText = "Could not update login item"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
        // Sync checkbox with actual state regardless of success/failure
        launchOnLoginCheckbox?.state = Self.isLaunchOnLoginEnabled ? .on : .off
    }

    // MARK: - Rebuild & Relaunch

    @objc private func rebuildAndRelaunch() {
        guard !isBuilding else { return }
        isBuilding = true
        rebuildButton?.isEnabled = false
        buildSpinner?.isHidden = false
        buildSpinner?.startAnimation(nil)
        buildStatusLabel?.textColor = .secondaryLabelColor
        buildStatusLabel?.stringValue = "Building..."

        // Derive build.sh path from the running app bundle
        // Bundle: TextRefiner/TextRefiner.app/Contents/MacOS/TextRefiner
        // build.sh: TextRefiner/build.sh
        let bundlePath = Bundle.main.bundlePath
        let appDir = (bundlePath as NSString).deletingLastPathComponent
        let buildScript = (appDir as NSString).appendingPathComponent("build.sh")

        Task.detached { [weak self] in
            let weakSelf = self
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [buildScript]
            process.currentDirectoryURL = URL(fileURLWithPath: appDir)

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()

                let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outputData, encoding: .utf8) ?? ""

                await MainActor.run {
                    weakSelf?.buildSpinner?.stopAnimation(nil)
                    weakSelf?.buildSpinner?.isHidden = true
                    weakSelf?.isBuilding = false

                    if process.terminationStatus == 0 {
                        weakSelf?.buildStatusLabel?.textColor = .systemGreen
                        weakSelf?.buildStatusLabel?.stringValue = "Build succeeded. Relaunching..."

                        // Launch the new app and quit this instance
                        let appBundleURL = URL(fileURLWithPath: appDir)
                            .appendingPathComponent("TextRefiner.app")

                        // Quit first, then launch the new app after a short delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            let relaunch = Process()
                            relaunch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                            relaunch.arguments = [appBundleURL.path]
                            try? relaunch.run()
                        }

                        // Quit the current app
                        NSApp.terminate(nil)
                    } else {
                        weakSelf?.buildStatusLabel?.textColor = .systemRed
                        // Show last meaningful line of build output
                        let lastLine = output.components(separatedBy: .newlines)
                            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                            .last ?? "Unknown error"
                        weakSelf?.buildStatusLabel?.stringValue = "Build failed: \(lastLine)"
                        weakSelf?.rebuildButton?.isEnabled = true
                    }
                }
            } catch {
                await MainActor.run {
                    weakSelf?.buildSpinner?.stopAnimation(nil)
                    weakSelf?.buildSpinner?.isHidden = true
                    weakSelf?.isBuilding = false
                    weakSelf?.buildStatusLabel?.textColor = .systemRed
                    weakSelf?.buildStatusLabel?.stringValue = "Failed to run build.sh: \(error.localizedDescription)"
                    weakSelf?.rebuildButton?.isEnabled = true
                }
            }
        }
    }

    // MARK: - Simulate Update (dev builds only)

    @objc private func simulateUpdateAvailable() {
        onSimulateUpdate?()
        simulateButton?.isEnabled = false
        simulateStatusLabel?.stringValue = "✓ Ready — now refine some text to see the banner"
        // Re-enable after 8s so it can be triggered again in the same session
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.simulateButton?.isEnabled = true
            self?.simulateStatusLabel?.stringValue = ""
        }
    }

    // MARK: - Excluded Apps

    @objc private func addExcludedApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        panel.message = "Choose an app to exclude from the typing indicator."

        guard let parentWindow = window else { return }
        panel.beginSheetModal(for: parentWindow) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.handleExcludedAppSelection(url: url)
        }
    }

    private func handleExcludedAppSelection(url: URL) {
        guard let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier else {
            showExcludedAppsAlert(
                title: "Couldn't Read App",
                message: "macOS could not determine the bundle identifier for that app."
            )
            return
        }

        // Don't let the user exclude TextRefiner itself — would have no effect anyway
        // (TypingMonitor already skips its own PID), but this avoids a confusing entry.
        if bundleID == Bundle.main.bundleIdentifier {
            showExcludedAppsAlert(
                title: "Can't Exclude TextRefiner",
                message: "TextRefiner doesn't show its own typing indicator, so excluding itself has no effect."
            )
            return
        }

        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent

        ExcludedAppsStorage.shared.add(name: name, bundleID: bundleID)
        excludedAppsTable?.reloadData()
        updateExcludedAppsRemoveButtonState()
        onExcludedAppsChanged?()
    }

    @objc private func removeExcludedApp() {
        guard let table = excludedAppsTable else { return }
        let row = table.selectedRow
        guard row >= 0 else { return }
        let entries = ExcludedAppsStorage.shared.all()
        guard row < entries.count else { return }
        ExcludedAppsStorage.shared.remove(bundleID: entries[row].bundleID)
        table.reloadData()
        updateExcludedAppsRemoveButtonState()
        onExcludedAppsChanged?()
    }

    private func updateExcludedAppsRemoveButtonState() {
        excludedAppsRemoveButton?.isEnabled = (excludedAppsTable?.selectedRow ?? -1) >= 0
    }

    private func showExcludedAppsAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let parent = window {
            alert.beginSheetModal(for: parent, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Helpers

    private func makeLabel(_ text: String, bold: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        if bold {
            label.font = .systemFont(ofSize: 13, weight: .semibold)
        } else {
            label.font = .systemFont(ofSize: 12)
        }
        return label
    }
}

// MARK: - Window Delegate (cleanup on close)

private final class WindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}

// MARK: - Excluded Apps Table Source

/// Reads ExcludedAppsStorage on demand for each numberOfRows / view-for-row call.
/// No internal cache — the storage is the source of truth and changes always flow
/// through reloadData() in the controller.
private final class ExcludedAppsTableSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let onSelectionChanged: () -> Void

    init(onSelectionChanged: @escaping () -> Void) {
        self.onSelectionChanged = onSelectionChanged
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        ExcludedAppsStorage.shared.all().count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entries = ExcludedAppsStorage.shared.all()
        guard row < entries.count else { return nil }

        let identifier = NSUserInterfaceItemIdentifier("excludedAppCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let textField = NSTextField(labelWithString: "")
            textField.font = .systemFont(ofSize: 12)
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        cell.textField?.stringValue = entries[row].name
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelectionChanged()
    }
}
