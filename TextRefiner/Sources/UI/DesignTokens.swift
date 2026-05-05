import Cocoa

// MARK: - Color Tokens
//
// All component code references these semantic tokens only.
// Primitive values are private backing constants defined per-property.
// Token path → Swift mapping: color/surface/hud → NSColor.surfaceHud (via material),
// color/text/primary → NSColor.textPrimary, etc.

extension NSColor {

    // MARK: Surfaces (semantic backgrounds)

    static var surfaceWindow: NSColor  { .windowBackgroundColor }
    static var surfaceControl: NSColor { .controlBackgroundColor }
    static var surfaceCode: NSColor    { .textBackgroundColor }
    static var surfaceRowEven: NSColor { .controlBackgroundColor }
    static var surfaceRowOdd: NSColor  {
        NSColor.controlBackgroundColor.blended(withFraction: 0.03, of: NSColor.labelColor)
            ?? NSColor.controlBackgroundColor
    }

    // MARK: Text

    static var textPrimary: NSColor   { .labelColor }
    static var textSecondary: NSColor { .secondaryLabelColor }
    static var textTertiary: NSColor  { .tertiaryLabelColor }
    static var textOnAccent: NSColor  { .white }
    static var textOnHud: NSColor     { .black }

    // MARK: Feedback (state colors)

    static var feedbackSuccess: NSColor { .systemGreen }
    static var feedbackError: NSColor   { .systemRed }
    static var feedbackWarning: NSColor { .systemOrange }
    static var feedbackPending: NSColor { .systemOrange }

    // MARK: Interactive

    static var interactiveAccent: NSColor              { .controlAccentColor }
    static var interactiveAccentMuted: NSColor         { .controlAccentColor.withAlphaComponent(0.08) }
    static var interactiveAccentBorder: NSColor        { .controlAccentColor.withAlphaComponent(0.25) }
    static var interactiveAccentHover: NSColor         { .controlAccentColor.withAlphaComponent(0.12) }
    static var interactiveAccentStepConnector: NSColor { .controlAccentColor.withAlphaComponent(0.30) }

    // MARK: Border / Separator

    static var borderSeparator: NSColor     { .separatorColor }
    static var borderSeparatorMuted: NSColor { NSColor.separatorColor.withAlphaComponent(0.5) }
    static var borderSuccess: NSColor       { NSColor.systemGreen.withAlphaComponent(0.4) }

    // MARK: HUD component tokens

    static var hudProgressTrack: NSColor { NSColor.white.withAlphaComponent(0.2) }
    static var hudProgressFill: NSColor  { NSColor.systemRed.withAlphaComponent(0.8) }
}

// MARK: - Font Tokens
//
// All sizes in points. All tokens map to SF System font.
// Token path → Swift mapping: typography/body/regular → NSFont.bodyRegular, etc.
// Note: design: .rounded must be applied at the SwiftUI callsite via Font.system().
// The displayHotkey token carries size + weight only.

extension NSFont {
    static var displayTitle: NSFont    { .systemFont(ofSize: 28, weight: .bold) }
    static var displayHotkey: NSFont   { .systemFont(ofSize: 26, weight: .bold) }
    static var headlineSection: NSFont { .systemFont(ofSize: 13, weight: .semibold) }
    static var headlineCard: NSFont    { .systemFont(ofSize: 13, weight: .bold) }
    static var bodyRegular: NSFont     { .systemFont(ofSize: 13) }
    static var bodyMedium: NSFont      { .systemFont(ofSize: 13, weight: .medium) }
    static var bodySemibold: NSFont    { .systemFont(ofSize: 13, weight: .semibold) }
    static var labelRegular: NSFont    { .systemFont(ofSize: 12) }
    static var labelMedium: NSFont     { .systemFont(ofSize: 12, weight: .medium) }
    static var labelSemibold: NSFont   { .systemFont(ofSize: 12, weight: .semibold) }
    static var captionRegular: NSFont  { .systemFont(ofSize: 11) }
    static var captionMedium: NSFont   { .systemFont(ofSize: 11, weight: .medium) }
    static var captionBold: NSFont     { .systemFont(ofSize: 11, weight: .bold) }
    /// Eyebrow style: 11pt semibold. Apply .tracking(1.2) and .textCase(.uppercase) at callsite.
    static var captionEyebrow: NSFont  { .systemFont(ofSize: 11, weight: .semibold) }
    static var codeRegular: NSFont     { .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) }
    static var menuBarSparkle: NSFont  { .systemFont(ofSize: 8, weight: .medium) }
    static var menuBarLetter: NSFont   { .systemFont(ofSize: 14, weight: .bold) }
}

// MARK: - Design Tokens

enum DesignTokens {

    // MARK: Spacing
    //
    // Based on a 4pt base unit. Scale uses t-shirt size names.
    // Named sub-enums capture component-specific roles.

    enum Spacing {
        // Scale
        static let xxs: CGFloat = 2
        static let xs: CGFloat  = 4
        static let sm: CGFloat  = 6
        static let md: CGFloat  = 8
        static let lg: CGFloat  = 10
        static let xl: CGFloat  = 12
        static let x2l: CGFloat = 16
        static let x3l: CGFloat = 20
        static let x4l: CGFloat = 24
        static let x5l: CGFloat = 28
        static let x6l: CGFloat = 30

        // Component-specific roles
        enum HUD {
            static let padding: CGFloat = 16
        }
        enum Pill {
            static let horizontal: CGFloat = 20
            static let gap: CGFloat        = 4
            static let screenEdge: CGFloat = 4
        }
        enum Window {
            static let padding: CGFloat    = 20
            static let horizontal: CGFloat = 20
        }
        enum Onboarding {
            static let padding: CGFloat     = 30
            static let cardPadding: CGFloat = 16
            static let horizontal: CGFloat  = 28
            static let top: CGFloat         = 24
        }
        enum Row {
            static let vertical: CGFloat   = 10
            static let horizontal: CGFloat = 16
        }
        enum Bar {
            static let vertical: CGFloat   = 8
            static let horizontal: CGFloat = 16
        }
    }

    // MARK: Radius

    enum Radius {
        static let hud: CGFloat           = 14
        static let pill: CGFloat          = 6
        static let card: CGFloat          = 14
        static let inset: CGFloat         = 8
        static let codeBlock: CGFloat     = 6
        static let progressBar: CGFloat   = 2.5
        static let hotkeyDisplay: CGFloat = 10
        static let toast: CGFloat         = 12
        static let popover: CGFloat       = 6
    }

    // MARK: Size

    enum Size {
        enum HUD {
            static let spinnerPanel: CGFloat      = 56
            static let errorPanelWidth: CGFloat   = 200
            static let errorPanelHeight: CGFloat  = 80
            static let spinnerSize: CGFloat       = 20
            static let iconSize: CGFloat          = 32
            static let errorIconSize: CGFloat     = 26
            static let progressBarHeight: CGFloat = 5
            static let offsetAboveCenter: CGFloat = 80
        }
        enum Pill {
            static let height: CGFloat   = 24
            static let minWidth: CGFloat = 50
        }
        enum MenuBar {
            static let iconSize: CGFloat = 18
        }
        enum Onboarding {
            static let stepCircle: CGFloat    = 24
            static let stepIconWidth: CGFloat = 14
        }
        enum Window {
            static let settings    = NSSize(width: 420, height: 377)
            static let settingsDev = NSSize(width: 420, height: 477)
            static let onboarding  = NSSize(width: 520, height: 620)
            static let history     = NSSize(width: 520, height: 440)
            static let historyMin  = NSSize(width: 420, height: 280)
            static let prompt      = NSSize(width: 600, height: 550)
            static let promptMin   = NSSize(width: 500, height: 450)
        }
    }

    // MARK: Animation

    enum Animation {
        static let fadeIn: TimeInterval         = 0.18
        static let fadeOut: TimeInterval        = 0.12
        static let pageTransition: TimeInterval = 0.3
        static let flashIn: TimeInterval        = 0.15
        static let flashOut: TimeInterval       = 0.3
        static let toastIn: TimeInterval        = 0.15
        static let toastOut: TimeInterval       = 0.3
        static let toastHold: TimeInterval      = 1.2
        static let errorHUD: TimeInterval       = 5.0
        static let relaunchDelay: TimeInterval  = 1.0
        static let savedHold: TimeInterval      = 2.0
        static let hudExpand: TimeInterval      = 0.15
        static let hudCollapse: TimeInterval    = 0.22
        static let successHold: TimeInterval    = 1.5
        static let bounceDelay: TimeInterval    = 0.0
        static let bounceSpeed: Double          = 2.0
    }
}
