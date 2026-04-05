import Cocoa

/// Registers a global hotkey (⌘⇧R) using a CGEvent tap.
/// CGEvent tap is used instead of NSEvent.addGlobalMonitorForEvents because
/// it can intercept AND consume the event, preventing it from reaching the frontmost app.
final class HotkeyManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Called on the main thread when ⌘⇧R is pressed.
    var onHotkeyPressed: (() -> Void)?

    /// Installs the global event tap. Must be called after Accessibility permission is granted.
    /// Returns true if the tap was successfully created.
    @discardableResult
    func start() -> Bool {
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
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Removes the event tap and cleans up.
    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
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

    // macOS can disable the tap under load — re-enable it
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        manager.reenableTap()
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
