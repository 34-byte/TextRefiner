import Cocoa
import Sparkle

/// Wraps Sparkle's SPUStandardUpdaterController for in-app auto-updates.
/// Handles both automatic background checks and manual "Check for Updates..." from the menu.
final class UpdateManager {

    private let updaterController: SPUStandardUpdaterController?

    init() {
        // Skip Sparkle in dev builds where SUFeedURL is not configured
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String != nil else {
            updaterController = nil
            return
        }

        // startingUpdater: true begins automatic background update checks on launch
        // The standard user driver shows Sparkle's built-in update dialogs (NSAlert-based),
        // which work correctly for LSUIElement (menu bar) apps — no main window needed.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Whether Sparkle is available (release builds with SUFeedURL configured).
    var isAvailable: Bool {
        updaterController != nil
    }

    /// Triggered by the "Check for Updates..." menu item.
    /// In dev builds (no Sparkle), shows a friendly message instead of silently failing.
    func checkForUpdates() {
        guard let updaterController else {
            // Dev build — no appcast configured, explain to the user
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Updates Not Available"
            alert.informativeText = "Auto-updates are only available in release builds. You're running a development build."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        // Bring app to front so Sparkle's dialogs are visible
        // (important for LSUIElement apps with no Dock icon)
        NSApp.activate(ignoringOtherApps: true)
        updaterController.checkForUpdates(nil)
    }

    /// Whether the updater is currently able to check for updates.
    /// Use this to enable/disable the menu item.
    var canCheckForUpdates: Bool {
        updaterController?.updater.canCheckForUpdates ?? false
    }
}
