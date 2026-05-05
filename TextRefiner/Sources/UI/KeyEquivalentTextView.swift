import Cocoa

// MARK: - Key Equivalent Text View

/// NSTextView subclass that explicitly handles Cmd+C/V/A/X/Z key equivalents.
/// Inside an NSHostingController, the SwiftUI hosting view can intercept key events
/// before they reach embedded AppKit views. This subclass overrides `performKeyEquivalent`
/// to ensure standard editing shortcuts always reach the text view.
///
/// Used by NativeTextView (Onboarding) and PromptTextEditor (Prompt Settings).
final class KeyEquivalentTextView: NSTextView {

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }

        switch event.charactersIgnoringModifiers {
        case "c":
            if selectedRange().length > 0 {
                copy(nil)
                return true
            }
            return false
        case "v":
            paste(nil)
            return true
        case "a":
            selectAll(nil)
            return true
        case "x":
            if selectedRange().length > 0 {
                cut(nil)
                return true
            }
            return false
        case "z":
            if event.modifierFlags.contains(.shift) {
                undoManager?.redo()
            } else {
                undoManager?.undo()
            }
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        return super.becomeFirstResponder()
    }
}
