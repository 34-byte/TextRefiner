import Cocoa

/// Registers a global hotkey (⌘⇧R) using a CGEvent tap.
/// CGEvent tap is used instead of NSEvent.addGlobalMonitorForEvents because
/// it can intercept AND consume the event, preventing it from reaching the frontmost app.
final class HotkeyManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Called on the main thread when ⌘⇧R is pressed.
    var onHotkeyPressed: (() -> Void)?

    /// True if the event tap is currently installed AND enabled by macOS.
    /// Checks the real enabled state — not just whether the tap object exists.
    /// A tap can exist (non-nil) but be temporarily disabled by macOS under load;
    /// reenableTap() handles that case. This property reflects live capability.
    var isRunning: Bool {
        guard let tap = eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    /// Installs the global event tap. Must be called after Accessibility permission is granted.
    /// Calls stop() first so it is safe to call multiple times without leaking taps.
    /// Returns true if the tap was successfully created.
    @discardableResult
    func start() -> Bool {
        stop() // Always clean up any previous tap — prevents double-tap leaks when
               // startListening() is called more than once (e.g. from the accessibility
               // poll timer firing after onReadyForTrial already registered a tap).

        let eventMask = (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap, // .defaultTap = can suppress events
            eventsOfInterest: CGEventMask(eventMask),
            callback: hotkeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("[TextRefiner] Failed to create event tap — Accessibility permission missing?")
            return false
        }

        self.eventTap = tap
        self.runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        // Use CFRunLoopGetMain() — not CFRunLoopGetCurrent(). These happen to be the
        // same thread today, but CFRunLoopGetCurrent() is contextual and would silently
        // register into a background thread's loop if ever called from a Task.detached.
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Removes the event tap and cleans up.
    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            // Fully invalidate the Mach port — disable alone doesn't close the channel.
            // A keypress already in-flight when stop() is called could otherwise still
            // arrive at the callback after eventTap is set to nil.
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            // Match the run loop used in start() — must be the main run loop.
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    /// Re-enables the tap if macOS disabled it (timeout/user input protection).
    fileprivate func reenableTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }
}

/// C function pointer callback — required by CGEvent.tapCreate.
/// Runs on a Mach port thread; dispatches to main immediately.
private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passRetained(event) }

    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()

    // macOS can disable the tap under load — re-enable it.
    // Dispatch to main: reenableTap() reads/writes eventTap, which is also
    // written by stop()/start() on the main thread. Dispatching eliminates the
    // data race between this Mach port callback thread and the main thread.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        DispatchQueue.main.async { manager.reenableTap() }
        return Unmanaged.passRetained(event)
    }

    guard type == .keyDown else { return Unmanaged.passRetained(event) }

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags

    // Read the configured hotkey (defaults to ⌘⇧R / keyCode 15)
    let config = HotkeyConfiguration.shared
    let targetKeyCode = Int64(config.keyCode)
    let targetModifiers = config.modifierFlags

    let matchesKey = keyCode == targetKeyCode
    let matchesModifiers =
        flags.contains(.maskCommand) == targetModifiers.contains(.maskCommand) &&
        flags.contains(.maskShift) == targetModifiers.contains(.maskShift) &&
        flags.contains(.maskControl) == targetModifiers.contains(.maskControl) &&
        flags.contains(.maskAlternate) == targetModifiers.contains(.maskAlternate)

    if matchesKey && matchesModifiers {
        DispatchQueue.main.async {
            manager.onHotkeyPressed?()
        }
        return nil // Consume the event — don't pass to frontmost app
    }

    return Unmanaged.passRetained(event) // Pass through all other events
}
