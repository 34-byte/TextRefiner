import Cocoa
import ApplicationServices

/// Handles Accessibility permission checks and keyboard event simulation (Cmd+C / Cmd+V).
/// This is the highest-risk component — the entire app depends on paste simulation working
/// in third-party apps like Slack, Chrome, Notes, and Mail.
enum AccessibilityService {

    // MARK: - Permission

    /// Returns true if the app actually has working Accessibility permission.
    ///
    /// `AXIsProcessTrusted()` is known to be unreliable on macOS Ventura+ — it can return
    /// false even when the toggle is ON in System Settings (especially after rebuilds).
    ///
    /// The reliable approach: try to create a CGEvent tap. If it succeeds, we genuinely
    /// have permission to post keyboard events. This tests the actual capability, not
    /// a database entry.
    static func isTrusted() -> Bool {
        // Method 1: Try creating a real event tap — this is the ground truth.
        // If we can create a defaultTap (which can modify/suppress events),
        // we definitely have Accessibility permission.
        let testCallback: CGEventTapCallBack = { _, _, event, _ in
            return Unmanaged.passRetained(event)
        }

        let testTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: testCallback,
            userInfo: nil
        )

        if let tap = testTap {
            // We have permission — clean up the test tap immediately
            CFMachPortInvalidate(tap)
            return true
        }

        // Method 2: Tap creation failed — treat as not trusted.
        // AXIsProcessTrusted() is explicitly documented as unreliable on macOS Ventura+;
        // using it here as a fallback would give a false answer with false confidence.
        // If the tap cannot be created, permission is not working regardless of what
        // the system database says.
        return false
    }

    /// Prompts the user to grant Accessibility permission via System Settings.
    /// The system dialog appears only once; subsequent calls open System Settings directly.
    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Copy Simulation

    /// Simulates Cmd+C and waits for the pasteboard to update.
    /// Polls `NSPasteboard.general.changeCount` for up to 500ms to detect when
    /// the target app has actually processed the copy command.
    /// Returns the copied text, or nil if no text was selected / copy failed.
    static func simulateCopyAndRead() async -> String? {
        let previousCount = NSPasteboard.general.changeCount

        // If CGEvent creation fails, treat as "no text selected" — the user sees
        // a clear error either way. Logging helps diagnose if this ever happens.
        do {
            try simulateKeyCombo(keyCode: 0x08, flags: .maskCommand) // 0x08 = 'c'
        } catch {
            #if DEBUG
            print("[TextRefiner] Copy simulation failed: \(error)")
            #endif
            return nil
        }

        // Poll pasteboard — target app needs time to process the event
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms per poll
            if NSPasteboard.general.changeCount != previousCount {
                return NSPasteboard.general.string(forType: .string)
            }
        }

        return nil // Copy failed or no text was selected
    }

    // MARK: - Paste Simulation

    /// Writes text to the pasteboard and simulates Cmd+V to paste it
    /// into the currently focused app.
    /// Throws if the keystroke simulation fails — the refined text is still
    /// on the clipboard so the user can paste manually.
    static func pasteText(_ text: String) async throws {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        try simulateKeyCombo(keyCode: 0x09, flags: .maskCommand) // 0x09 = 'v'
    }

    // MARK: - Key Simulation

    /// Posts a keyboard event with the given virtual key code and modifier flags.
    /// Uses CGEvent to simulate the keypress at the HID level.
    /// Throws `KeySimulationError.eventCreationFailed` if CGEvent creation fails.
    private static func simulateKeyCombo(keyCode: CGKeyCode, flags: CGEventFlags) throws {
        let source = CGEventSource(stateID: .hidSystemState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw KeySimulationError.eventCreationFailed
        }

        keyDown.flags = flags
        keyUp.flags = flags

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    enum KeySimulationError: Error, LocalizedError {
        case eventCreationFailed

        var errorDescription: String? {
            switch self {
            case .eventCreationFailed:
                return "Could not simulate keyboard event. Accessibility permission may have been revoked."
            }
        }
    }
}
