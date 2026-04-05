import Cocoa
import Sparkle

/// Wraps Sparkle's SPUStandardUpdaterController for in-app auto-updates.
/// Handles both automatic background checks and manual "Check for Updates..." from the menu.
final class UpdateManager {

    private let updaterController: SPUStandardUpdaterController

    init() {
        // startingUpdater: true begins automatic background update checks on launch
        // The standard user driver shows Sparkle's built-in update dialogs (NSAlert-based),
        // which work correctly for LSUIElement (menu bar) apps — no main window needed.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Triggered by the "Check for Updates..." menu item.
    func checkForUpdates() {
        // Bring app to front so Sparkle's dialogs are visible
        // (important for LSUIElement apps with no Dock icon)
        NSApp.activate(ignoringOtherApps: true)
        updaterController.checkForUpdates(nil)
    }

    /// Whether the updater is currently able to check for updates.
    /// Use this to enable/disable the menu item.
    var canCheckForUpdates: Bool {
        updaterController.updater.canCheckForUpdates
    }
}
