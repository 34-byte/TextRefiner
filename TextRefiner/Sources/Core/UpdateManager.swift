import Cocoa
import Sparkle

/// Wraps Sparkle's SPUStandardUpdaterController for in-app auto-updates.
/// Handles both automatic background checks and manual "Check for Updates..." from the menu.
///
/// Also tracks whether a valid update has been found and manages the per-version
/// dismiss/snooze counters for the update notification banner.
final class UpdateManager: NSObject, SPUUpdaterDelegate {

    private var updaterController: SPUStandardUpdaterController?

    // MARK: - Update State

    /// Set to true when Sparkle detects a valid update. Reset to false when the user
    /// initiates "Update now" or the counter is cleared. Not persisted — determined
    /// fresh each session via Sparkle's background check.
    private(set) var hasPendingUpdate = false

    /// Fired on the main thread the moment Sparkle detects an available update.
    /// AppDelegate uses this to show the "Update available →" menu item.
    var onUpdateDetected: (() -> Void)?

    // MARK: - Per-Version Dismiss Counter

    private static let dismissCountKey   = "com.textrefiner.updateDismissCount"
    private static let dismissVersionKey = "com.textrefiner.updateDismissVersion"
    private static let snoozeCountKey    = "com.textrefiner.updateSnoozeCount"

    /// How many times the user has tapped "Later" for the current version.
    private(set) var dismissCount: Int

    /// How many more successful refinements before the banner appears again (snooze).
    private(set) var snoozeRefinementsRemaining: Int

    /// The version string the dismiss counter is associated with (nil if never dismissed).
    private(set) var dismissedVersion: String?

    // MARK: - Init

    override init() {
        // Load persisted counter state before super.init() so all stored properties
        // are initialised — Swift requires this before delegating to super.
        let defaults = UserDefaults.standard
        dismissCount               = defaults.integer(forKey: Self.dismissCountKey)
        snoozeRefinementsRemaining = defaults.integer(forKey: Self.snoozeCountKey)
        dismissedVersion           = defaults.string(forKey: Self.dismissVersionKey)

        super.init()

        // Skip Sparkle in dev builds where SUFeedURL is not configured.
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String != nil else {
            return
        }

        // startingUpdater: false — allows `self` to be fully initialised before
        // Sparkle can fire any delegate callbacks. We call startUpdater() below,
        // after `self` is safe to use as a delegate.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        updaterController?.startUpdater()
    }

    // MARK: - SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        hasPendingUpdate = true
        onUpdateDetected?()
    }

    // MARK: - Banner Logic

    /// Returns true if the automatic banner is permanently suppressed for the current
    /// app version — i.e. the user has clicked "Later" at least twice on this version.
    var isBannerSuppressed: Bool {
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard dismissedVersion == currentVersion else { return false }
        return dismissCount >= 2
    }

    /// Returns true if the update banner should appear after a successful refinement.
    var shouldShowBanner: Bool {
        hasPendingUpdate && !isBannerSuppressed && snoozeRefinementsRemaining == 0
    }

    /// Called after each successful refinement when an update is pending but snoozed.
    /// Decrements the snooze counter (clamped at 0).
    func decrementSnooze() {
        guard snoozeRefinementsRemaining > 0 else { return }
        snoozeRefinementsRemaining = max(0, snoozeRefinementsRemaining - 1)
        UserDefaults.standard.set(snoozeRefinementsRemaining, forKey: Self.snoozeCountKey)
    }

    /// Called when the user taps "Later".
    /// Increments the per-version dismiss counter and starts a 10-refinement snooze.
    func recordLater(currentVersion: String) {
        // Normalise to the current version — a version change resets the counter.
        if dismissedVersion != currentVersion {
            dismissCount = 0
            dismissedVersion = currentVersion
        }
        dismissCount += 1
        snoozeRefinementsRemaining = 10
        let defaults = UserDefaults.standard
        defaults.set(dismissCount,               forKey: Self.dismissCountKey)
        defaults.set(dismissedVersion,           forKey: Self.dismissVersionKey)
        defaults.set(snoozeRefinementsRemaining, forKey: Self.snoozeCountKey)
    }

    /// Called when the user taps "Update now". Resets all banner state.
    func recordUpdateNow() {
        hasPendingUpdate               = false
        dismissCount                   = 0
        snoozeRefinementsRemaining     = 0
        dismissedVersion               = nil
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.dismissCountKey)
        defaults.removeObject(forKey: Self.dismissVersionKey)
        defaults.removeObject(forKey: Self.snoozeCountKey)
    }

    // MARK: - Dev Helper

    /// For dev builds only — simulates a pending update to exercise the banner flow
    /// without a live Sparkle appcast. Resets all dismiss/snooze counters so the
    /// banner always shows regardless of previous test sessions. Fires `onUpdateDetected`
    /// so the menu item appears exactly as it would in a real update scenario.
    func simulateUpdateAvailable() {
        // Reset all counters so stale UserDefaults from previous test runs
        // cannot silently suppress the banner (isBannerSuppressed checks UserDefaults).
        dismissCount = 0
        snoozeRefinementsRemaining = 0
        dismissedVersion = nil
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.dismissCountKey)
        defaults.removeObject(forKey: Self.dismissVersionKey)
        defaults.removeObject(forKey: Self.snoozeCountKey)

        hasPendingUpdate = true
        onUpdateDetected?()
    }

    // MARK: - Public API

    /// Whether Sparkle is available (release builds with SUFeedURL configured).
    var isAvailable: Bool {
        updaterController != nil
    }

    /// Triggered by the "Check for Updates..." menu item.
    /// In dev builds (no Sparkle), shows a friendly message instead of silently failing.
    func checkForUpdates() {
        guard let updaterController else {
            // Dev build — no appcast configured
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
