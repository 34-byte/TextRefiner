import Cocoa

/// Stores the user's chosen hotkey (keyCode + modifier flags) in UserDefaults.
/// Provides validation, display formatting, and known-conflict warnings.
///
/// Default: ⌘⇧R (keyCode 15). Validation requires at least one modifier key
/// (⌘, ⌃, ⌥, ⇧) plus one non-modifier key — bare letter keys are rejected.
final class HotkeyConfiguration {
    static let shared = HotkeyConfiguration()

    // MARK: - Defaults

    static let defaultKeyCode: UInt16 = 15  // 'r'
    static let defaultModifierFlags: CGEventFlags = [.maskCommand, .maskShift]

    // MARK: - UserDefaults Keys

    private let keyCodeKey = "com.textrefiner.hotkeyKeyCode"
    private let modifierFlagsKey = "com.textrefiner.hotkeyModifierFlags"

    // MARK: - Current Hotkey

    var keyCode: UInt16 {
        guard UserDefaults.standard.object(forKey: keyCodeKey) != nil else {
            return Self.defaultKeyCode
        }
        return UInt16(UserDefaults.standard.integer(forKey: keyCodeKey))
    }

    var modifierFlags: CGEventFlags {
        guard UserDefaults.standard.object(forKey: modifierFlagsKey) != nil else {
            return Self.defaultModifierFlags
        }
        return CGEventFlags(rawValue: UInt64(UserDefaults.standard.integer(forKey: modifierFlagsKey)))
    }

    /// Formatted display string for the current hotkey (e.g. "⌘⇧R").
    var displayString: String {
        Self.formatHotkey(keyCode: keyCode, modifierFlags: modifierFlags)
    }

    // MARK: - Save / Reset

    func save(keyCode: UInt16, modifierFlags: CGEventFlags) {
        UserDefaults.standard.set(Int(keyCode), forKey: keyCodeKey)
        UserDefaults.standard.set(Int(modifierFlags.rawValue), forKey: modifierFlagsKey)
    }

    func resetToDefault() {
        UserDefaults.standard.removeObject(forKey: keyCodeKey)
        UserDefaults.standard.removeObject(forKey: modifierFlagsKey)
    }

    var isDefault: Bool {
        keyCode == Self.defaultKeyCode && modifierFlags == Self.defaultModifierFlags
    }

    // MARK: - Validation

    /// Returns true if the modifier flags contain at least one of ⌘, ⌃, ⌥, ⇧.
    static func hasRequiredModifier(_ flags: CGEventFlags) -> Bool {
        return flags.contains(.maskCommand) ||
               flags.contains(.maskControl) ||
               flags.contains(.maskAlternate) ||
               flags.contains(.maskShift)
    }

    /// Returns a warning string if the hotkey conflicts with a known system or app shortcut.
    /// Returns nil if no conflict is detected. This is advisory, not a hard block.
    static func conflictWarning(keyCode: UInt16, modifierFlags: CGEventFlags) -> String? {
        let isCmd = modifierFlags.contains(.maskCommand)
        let isShift = modifierFlags.contains(.maskShift)
        let isCtrl = modifierFlags.contains(.maskControl)
        let isAlt = modifierFlags.contains(.maskAlternate)

        // ⌘Q — Quit (system-wide)
        if keyCode == 12 && isCmd && !isShift && !isCtrl && !isAlt {
            return "⌘Q is the system Quit shortcut. This will prevent quitting apps."
        }

        // ⌘W — Close window
        if keyCode == 13 && isCmd && !isShift && !isCtrl && !isAlt {
            return "⌘W is the system Close Window shortcut."
        }

        // ⌘C / ⌘V / ⌘X / ⌘Z / ⌘A — common edit shortcuts
        let editKeys: Set<UInt16> = [8, 9, 7, 6, 0]  // c, v, x, z, a
        if editKeys.contains(keyCode) && isCmd && !isShift && !isCtrl && !isAlt {
            return "This conflicts with a standard editing shortcut (⌘C/V/X/Z/A)."
        }

        // ⌘Tab — app switcher
        if keyCode == 48 && isCmd && !isShift && !isCtrl && !isAlt {
            return "⌘Tab is the system app switcher."
        }

        // ⌘Space — Spotlight
        if keyCode == 49 && isCmd && !isShift && !isCtrl && !isAlt {
            return "⌘Space is the Spotlight shortcut."
        }

        return nil
    }

    // MARK: - Display Formatting

    /// Formats a keyCode + modifiers into a human-readable string like "⌘⇧R".
    static func formatHotkey(keyCode: UInt16, modifierFlags: CGEventFlags) -> String {
        var parts = ""

        if modifierFlags.contains(.maskControl)   { parts += "⌃" }
        if modifierFlags.contains(.maskAlternate)  { parts += "⌥" }
        if modifierFlags.contains(.maskShift)      { parts += "⇧" }
        if modifierFlags.contains(.maskCommand)    { parts += "⌘" }

        parts += keyCodeToString(keyCode)
        return parts
    }

    /// Maps a virtual keyCode to its display character.
    /// Covers alphanumeric keys and common special keys.
    static func keyCodeToString(_ keyCode: UInt16) -> String {
        switch keyCode {
        case 0:  return "A"
        case 1:  return "S"
        case 2:  return "D"
        case 3:  return "F"
        case 4:  return "H"
        case 5:  return "G"
        case 6:  return "Z"
        case 7:  return "X"
        case 8:  return "C"
        case 9:  return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 24: return "="
        case 25: return "9"
        case 26: return "7"
        case 27: return "-"
        case 28: return "8"
        case 29: return "0"
        case 30: return "]"
        case 31: return "O"
        case 32: return "U"
        case 33: return "["
        case 34: return "I"
        case 35: return "P"
        case 36: return "↩"
        case 37: return "L"
        case 38: return "J"
        case 39: return "'"
        case 40: return "K"
        case 41: return ";"
        case 42: return "\\"
        case 43: return ","
        case 44: return "/"
        case 45: return "N"
        case 46: return "M"
        case 47: return "."
        case 48: return "⇥"
        case 49: return "␣"
        case 50: return "`"
        case 51: return "⌫"
        case 53: return "⎋"
        // Function keys
        case 96:  return "F5"
        case 97:  return "F6"
        case 98:  return "F7"
        case 99:  return "F3"
        case 100: return "F8"
        case 101: return "F9"
        case 103: return "F11"
        case 105: return "F13"
        case 107: return "F14"
        case 109: return "F10"
        case 111: return "F12"
        case 113: return "F15"
        case 118: return "F4"
        case 120: return "F2"
        case 122: return "F1"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return "Key\(keyCode)"
        }
    }

    // MARK: - Init

    private init() {}
}
