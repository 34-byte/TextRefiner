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

    private var hotkeyButton: NSButton?
    private var warningLabel: NSTextField?
    private var resetButton: NSButton?
    private var launchOnLoginCheckbox: NSButton?
    private var indicatorCheckbox: NSButton?
    private var rebuildButton: NSButton?
    private var buildStatusLabel: NSTextField?
    private var buildSpinner: NSProgressIndicator?
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
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let isDevBuild = Bundle.main.bundleIdentifier == "com.textrefiner.app.dev"
        // +22pt vs previous heights to accommodate the new typing indicator row
        let windowHeight: CGFloat = isDevBuild ? 412 : 377

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
        sectionLabel.frame = NSRect(x: 20, y: 340, width: 380, height: 20)
        contentView.addSubview(sectionLabel)

        let descLabel = makeLabel("Click the field below, then press your desired shortcut.")
        descLabel.frame = NSRect(x: 20, y: 315, width: 380, height: 20)
        descLabel.textColor = .secondaryLabelColor
        contentView.addSubview(descLabel)

        let btn = NSButton(frame: NSRect(x: 20, y: 278, width: 200, height: 28))
        btn.bezelStyle = .roundRect
        btn.title = HotkeyConfiguration.shared.displayString
        btn.target = self
        btn.action = #selector(hotkeyButtonClicked)
        contentView.addSubview(btn)
        self.hotkeyButton = btn

        let reset = NSButton(frame: NSRect(x: 228, y: 278, width: 120, height: 28))
        reset.bezelStyle = .roundRect
        reset.title = "Reset to Default"
        reset.target = self
        reset.action = #selector(resetToDefault)
        contentView.addSubview(reset)
        self.resetButton = reset

        let warning = makeLabel("")
        warning.frame = NSRect(x: 20, y: 245, width: 380, height: 30)
        warning.textColor = .systemOrange
        warning.lineBreakMode = .byWordWrapping
        warning.maximumNumberOfLines = 2
        contentView.addSubview(warning)
        self.warningLabel = warning

        updateWarningLabel()

        // --- Separator (Hotkey / General) ---

        let separator1 = NSBox(frame: NSRect(x: 20, y: 225, width: 380, height: 1))
        separator1.boxType = .separator
        contentView.addSubview(separator1)

        // --- General Section ---

        let generalLabel = makeLabel("General", bold: true)
        generalLabel.frame = NSRect(x: 20, y: 195, width: 380, height: 20)
        contentView.addSubview(generalLabel)

        let loginCheckbox = NSButton(checkboxWithTitle: "Launch TextRefiner on login", target: self, action: #selector(toggleLaunchOnLogin))
        loginCheckbox.frame = NSRect(x: 20, y: 170, width: 380, height: 18)
        loginCheckbox.state = Self.isLaunchOnLoginEnabled ? .on : .off
        contentView.addSubview(loginCheckbox)
        self.launchOnLoginCheckbox = loginCheckbox

        let indCheckbox = NSButton(checkboxWithTitle: "Show typing indicator", target: self, action: #selector(toggleIndicator))
        indCheckbox.frame = NSRect(x: 20, y: 148, width: 380, height: 18)
        indCheckbox.state = Self.isIndicatorEnabled ? .on : .off
        contentView.addSubview(indCheckbox)
        self.indicatorCheckbox = indCheckbox

        let tutorialBtn = NSButton(frame: NSRect(x: 20, y: 113, width: 170, height: 28))
        tutorialBtn.bezelStyle = .roundRect
        tutorialBtn.title = "Replay Tutorial..."
        tutorialBtn.target = self
        tutorialBtn.action = #selector(replayTutorial)
        contentView.addSubview(tutorialBtn)

        // --- Developer Section (dev builds only) ---
        if isDevBuild {
            let separator = NSBox(frame: NSRect(x: 20, y: 112, width: 380, height: 1))
            separator.boxType = .separator
            contentView.addSubview(separator)

            let devLabel = makeLabel("Developer", bold: true)
            devLabel.frame = NSRect(x: 20, y: 82, width: 380, height: 20)
            contentView.addSubview(devLabel)

            let rebuildBtn = NSButton(frame: NSRect(x: 20, y: 45, width: 170, height: 28))
            rebuildBtn.bezelStyle = .roundRect
            rebuildBtn.title = "Rebuild & Relaunch"
            rebuildBtn.target = self
            rebuildBtn.action = #selector(rebuildAndRelaunch)
            contentView.addSubview(rebuildBtn)
            self.rebuildButton = rebuildBtn

            let spinner = NSProgressIndicator(frame: NSRect(x: 198, y: 49, width: 20, height: 20))
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isHidden = true
            contentView.addSubview(spinner)
            self.buildSpinner = spinner

            let statusLabel = makeLabel("")
            statusLabel.frame = NSRect(x: 20, y: 15, width: 380, height: 20)
            statusLabel.textColor = .secondaryLabelColor
            contentView.addSubview(statusLabel)
            self.buildStatusLabel = statusLabel
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
