import Cocoa
import SwiftUI

/// Manages the one-time onboarding window shown on first launch.
/// Three pages: (1) Welcome — intro + feature overview, (2) Setup — Hardware check + Accessibility + Model download, (3) Tutorial — how-it-works + before/after.
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    /// True once onReadyForTrial returned true — meaning the CGEvent tap is live.
    /// Used by windowWillClose to decide whether to record completion or just poll.
    private var setupCompleted = false

    /// Guards against double-firing the completion callback. Set to true by the
    /// "Get Started" path (orderOut) so windowWillClose doesn't fire it a second time.
    private var completionFired = false

    /// Called when onboarding completes successfully — both checks passed.
    var onComplete: (() -> Void)?

    /// Called when the user clicks "Next" on the setup page (page 2).
    /// Tries to register the real CGEvent tap and returns true if it succeeded.
    /// The page transition to the tutorial is blocked until this returns true —
    /// so the user can never reach the tutorial without a working hotkey.
    var onReadyForTrial: (() -> Bool)?

    /// Called when the user closes the setup window with the red-X button before
    /// completing setup (i.e., before the hotkey was successfully registered).
    /// AppDelegate uses this to start background polling so the app can self-heal
    /// if the user later grants Accessibility permission via System Settings.
    var onDismissedEarly: (() -> Void)?

    func show() {
        // Capture callbacks NOW (before the window exists) so the closures below
        // don't need to go through [weak self] to reach them. This is critical:
        // if AppDelegate replaces onboardingController (e.g. onPermissionDenied
        // fires mid-tutorial and calls showOnboarding() again), the old
        // OnboardingWindowController is deallocated. With [weak self], that makes
        // self nil and the "Get Started" button silently does nothing —
        // window stays open, callback never fires.
        let capturedOnComplete = self.onComplete
        let capturedOnReadyForTrial: (() -> Bool)? = self.onReadyForTrial

        let w = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0,
                width: DesignTokens.Size.Window.onboarding.width,
                height: DesignTokens.Size.Window.onboarding.height
            ),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        // Capture w weakly to avoid a retain cycle: the closure is stored in the
        // SwiftUI view tree which lives inside w's contentViewController.
        // The window is kept alive by NSApp while it's on screen, so weak w
        // is valid for the entire time the user can click "Get Started".
        let onboardingView = OnboardingContainerView(
            onComplete: { [weak self, weak w] in
                // Mark completion before orderOut so windowWillClose (if it fires)
                // sees completionFired = true and skips its own callback.
                self?.completionFired = true
                w?.orderOut(nil)          // closes window even if self is nil
                capturedOnComplete?()     // fires callback even if self is nil
            },
            onReadyForTrial: { [weak self] in
                let result = capturedOnReadyForTrial?() ?? false
                // Record that the tap was successfully registered so windowWillClose
                // knows to call onComplete (not onDismissedEarly) if the user X-closes
                // while on the tutorial page.
                if result { self?.setupCompleted = true }
                return result
            }
        )

        w.title = "Welcome to TextRefiner"
        w.contentViewController = NSHostingController(rootView: onboardingView)
        w.delegate = self  // Intercept the red-X close button via windowWillClose
        w.center()
        w.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)

        self.window = w
    }

    /// Brings an already-showing onboarding window to the front.
    /// Called by AppDelegate when showOnboarding() is triggered while onboarding
    /// is already in progress — prevents two windows from opening simultaneously.
    func bringToFront() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSWindowDelegate

    /// Fires when the user closes the window via the red-X button (not via orderOut).
    /// Determines whether to record completion or kick off background recovery.
    func windowWillClose(_ notification: Notification) {
        guard !completionFired else { return }
        completionFired = true

        if setupCompleted {
            // User closed on the tutorial page — the hotkey is already registered.
            // Record onboarding as complete so the next launch doesn't restart setup.
            onComplete?()
        } else {
            // User closed on the welcome or setup page — the hotkey was never registered.
            // Tell AppDelegate to start polling so the app self-heals if the user
            // grants Accessibility permission later through System Settings.
            onDismissedEarly?()
        }
    }
}

// MARK: - Container (manages page transitions)

struct OnboardingContainerView: View {
    let onComplete: () -> Void
    let onReadyForTrial: () -> Bool
    @State private var currentPage: OnboardingPage = .welcome

    enum OnboardingPage {
        case welcome
        case setup
        case tutorial
    }

    var body: some View {
        Group {
            switch currentPage {
            case .welcome:
                OnboardingWelcomeView(onNext: {
                    withAnimation(.easeInOut(duration: DesignTokens.Animation.pageTransition)) {
                        currentPage = .setup
                    }
                })
            case .setup:
                // onNext returns true only if the real CGEvent tap was created.
                // If false the view stays on page 2 and shows a tap-failed error.
                OnboardingSetupView(onNext: {
                    let tapOK = onReadyForTrial()
                    if tapOK {
                        withAnimation(.easeInOut(duration: DesignTokens.Animation.pageTransition)) {
                            currentPage = .tutorial
                        }
                    }
                    return tapOK
                })
            case .tutorial:
                OnboardingTutorialView(onComplete: onComplete)
            }
        }
        .frame(width: DesignTokens.Size.Window.onboarding.width, height: DesignTokens.Size.Window.onboarding.height)
    }
}

// MARK: - Page 1: Welcome (intro + feature overview)

struct OnboardingWelcomeView: View {
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                // App title — centered
                HStack(spacing: 10) {
                    Text("✦")
                        .font(.system(size: 28))
                    Text("TextRefiner")
                        .font(.largeTitle.bold())
                }
                .frame(maxWidth: .infinity, alignment: .center)

                // Tagline card — green background
                Text("Write fast. Refine it. Get polished text in seconds.\n— Nothing ever leaves your Mac.")
                    .font(.system(size: 15, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 28)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                            .fill(Color.green.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                            .stroke(Color.green.opacity(0.25), lineWidth: 0.5)
                    )

                Divider()

                Text("What it does")
                    .font(Font(NSFont.captionEyebrow))
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))

                VStack(spacing: 12) {
                    WelcomeFeatureRow(
                        icon: "keyboard",
                        title: "Stop rewriting the same sentence",
                        description: "Highlight anything, press the shortcut, and it comes back clean — right where you're typing."
                    )
                    WelcomeFeatureRow(
                        icon: "sparkles",
                        title: "Sound like yourself, but sharper",
                        description: "Your ideas stay yours. The rough edges get smoothed out — without sounding like a robot wrote it."
                    )
                    WelcomeFeatureRow(
                        icon: "lock.fill",
                        title: "Write freely — nothing leaves your Mac",
                        description: "No account, no cloud, nothing shared. Your words are processed entirely on your device."
                    )
                }

                Divider()

                Text("Good to know")
                    .font(Font(NSFont.captionEyebrow))
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))

                HStack(spacing: 8) {
                    Text("English only")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color.orange.opacity(0.9))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.orange.opacity(0.12))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.orange.opacity(0.25), lineWidth: 0.5)
                        )
                    Text("Works best in English — other languages may not refine correctly.")
                        .font(Font(NSFont.labelRegular))
                        .foregroundColor(Color(nsColor: .secondaryLabelColor))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(DesignTokens.Spacing.Onboarding.padding)

            Spacer(minLength: 8)

            VStack(spacing: 0) {
                Divider()
                HStack {
                    OnboardingPageDots(activePage: 1)
                    Spacer()
                    Button("Continue") {
                        onNext()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
            }
        }
    }
}

// MARK: - Welcome Feature Row

private struct WelcomeFeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.accentColor.opacity(0.15))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(Color.accentColor.opacity(0.3), lineWidth: 0.5)
                    )
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(.accentColor)
                    .frame(width: 20, height: 20)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Font(NSFont.headlineSection))
                Text(description)
                    .font(Font(NSFont.labelRegular))
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
    }
}

// MARK: - Page 2: Setup (Hardware check + Accessibility + Model download)

struct OnboardingSetupView: View {
    /// Returns true if the hotkey tap was successfully created; false if it failed.
    /// The view stays on page 1 and shows an error when false.
    let onNext: () -> Bool

    @State private var accessibilityGranted = AccessibilityService.isTrusted()
    @State private var modelDownloaded = false
    @State private var isDownloading = false
    @State private var downloadProgress: Double = 0
    @State private var downloadError: String? = nil
    @State private var appManagementConfirmed = false
    /// Set to true if "Next" was clicked but the CGEvent tap creation failed.
    /// Shows an inline error so the user knows exactly what went wrong.
    @State private var tapFailed = false
    /// Guards against double-click: set to true when "Next" is first pressed,
    /// prevents a second press from calling startListening() again while the
    /// first is still in progress. Stays true on success (button becomes irrelevant).
    @State private var isProcessingNext = false

    private let hardwareOK = HardwareChecker.meetsRequirements
    private let incompatibilityReason = HardwareChecker.incompatibilityReason

    private var isReleaseBuild: Bool {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String != nil
    }

    private let accessibilityTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // App title
            HStack(spacing: 10) {
                Text("✦")
                    .font(.system(size: 28))
                Text("TextRefiner")
                    .font(.largeTitle.bold())
            }

            Text("Highlight text anywhere on your Mac, press **\(HotkeyConfiguration.shared.displayString)**, and get a clearer version instantly. Powered by a local AI model — nothing leaves your Mac.")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            Text("Refinement takes 2–5 seconds. You'll see a spinner while it works.")
                .font(.callout)
                .foregroundColor(.secondary)

            // Privacy badge — visual callout reinforcing the on-device promise
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.green)
                Text("100% private — your text is processed on-device and never leaves your Mac.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DesignTokens.Spacing.lg)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.inset)
                    .fill(Color.green.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.inset)
                    .stroke(Color.green.opacity(0.15), lineWidth: 0.5)
            )

            Divider()

            if !hardwareOK {
                // MARK: Hardware Incompatibility Gate
                HStack(spacing: 12) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.red)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Incompatible Hardware")
                            .font(.headline)
                        Text(incompatibilityReason ?? "This Mac does not meet the minimum requirements.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer()

                HStack {
                    Spacer()
                    Button("Quit") {
                        NSApp.terminate(nil)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            } else {
                // MARK: Accessibility Permission
                HStack(spacing: 12) {
                    Image(systemName: accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .font(.title2)
                        .foregroundColor(accessibilityGranted ? .green : .orange)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accessibility Permission")
                            .font(.headline)
                        if accessibilityGranted {
                            Text("Permission granted.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Required to read and replace selected text in other apps.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer()

                    if !accessibilityGranted {
                        HStack(spacing: 6) {
                            Button("Grant Access") {
                                AccessibilityService.requestPermission()
                            }
                            .buttonStyle(.bordered)

                            Button("Check") {
                                accessibilityGranted = AccessibilityService.isTrusted()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                // MARK: AI Model Download
                HStack(spacing: 12) {
                    Group {
                        if isDownloading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: modelDownloaded ? "checkmark.circle.fill" : "arrow.down.circle")
                                .font(.title2)
                                .foregroundColor(modelDownloaded ? .green : .orange)
                        }
                    }
                    .frame(width: 24)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("AI Model")
                            .font(.headline)

                        if modelDownloaded {
                            Text("\(ModelManager.displayName) ready.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else if isDownloading {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Downloading \(ModelManager.displayName) (\(ModelManager.modelSize))...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                ProgressView(value: downloadProgress)
                                    .progressViewStyle(.linear)
                                Text("\(Int(downloadProgress * 100))%")
                                    .font(.caption2)
                                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                            }
                        } else if let error = downloadError {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(error)
                                    .font(.caption)
                                    .foregroundColor(.red)
                                Button("Retry Download") {
                                    downloadModel()
                                }
                                .buttonStyle(.bordered)
                                .font(.caption)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(ModelManager.displayName) (\(ModelManager.modelSize)) will be downloaded.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Button("Download Model") {
                                    downloadModel()
                                }
                                .buttonStyle(.bordered)
                                .font(.caption)
                            }
                        }
                    }

                    Spacer()
                }

                // MARK: App Management (release builds only)
                if isReleaseBuild {
                    HStack(spacing: 12) {
                        Image(systemName: appManagementConfirmed ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .font(.title2)
                            .foregroundColor(appManagementConfirmed ? .green : .orange)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto-Updates")
                                .font(.headline)
                            if appManagementConfirmed {
                                Text("App Management enabled. Updates will install automatically.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("Allow TextRefiner to update itself. In System Settings, enable TextRefiner under Privacy & Security > App Management.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        Spacer()

                        if !appManagementConfirmed {
                            HStack(spacing: 6) {
                                Button("Open Settings") {
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppManagement") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                .buttonStyle(.bordered)

                                Button("Done") {
                                    appManagementConfirmed = true
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }

                Spacer()

                // MARK: Tap-failed error (shown if hotkey registration fails after "Next")
                if tapFailed {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Hotkey registration failed")
                                .font(.caption).bold()
                                .foregroundColor(.red)
                            Text("Go to System Settings → Privacy & Security → Accessibility, toggle TextRefiner OFF then back ON, then click Next again.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(DesignTokens.Spacing.lg)
                    .background(Color.red.opacity(0.08))
                    .cornerRadius(DesignTokens.Radius.inset)
                }

                // MARK: Next Button
                HStack {
                    OnboardingPageDots(activePage: 2)
                    Spacer()
                    Button("Next") {
                        // Guard against double-click: a second press while the first
                        // is still in progress would call startListening() twice —
                        // the second call tears down the tap the first one just built.
                        guard !isProcessingNext else { return }
                        isProcessingNext = true
                        tapFailed = false
                        let ok = onNext()
                        if !ok {
                            // Tap failed — show inline error and re-enable the button
                            // so the user can fix the permission and try again.
                            tapFailed = true
                            isProcessingNext = false
                        }
                        // On success, currentPage advances to .tutorial and this view
                        // is torn down. isProcessingNext stays true — intentional, as
                        // the button is about to disappear anyway.
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!accessibilityGranted || !modelDownloaded || isProcessingNext || (isReleaseBuild && !appManagementConfirmed))
                }
            }
        }
        .padding(DesignTokens.Spacing.Onboarding.padding)
        .task {
            guard hardwareOK else { return }
            // Check if model is already downloaded
            let service = LocalInferenceService()
            if service.isModelDownloaded() {
                modelDownloaded = true
            } else {
                downloadModel()
            }
        }
        .onReceive(accessibilityTimer) { _ in
            if !accessibilityGranted {
                accessibilityGranted = AccessibilityService.isTrusted()
            }
        }
    }

    // MARK: - Model Download

    private func downloadModel() {
        guard !isDownloading else { return }
        isDownloading = true
        downloadError = nil
        downloadProgress = 0

        Task {
            do {
                let service = LocalInferenceService()
                try await service.downloadModel { progress in
                    Task { @MainActor in
                        downloadProgress = progress
                    }
                }
                modelDownloaded = true
            } catch {
                downloadError = "Download failed: \(error.localizedDescription)"
            }
            isDownloading = false
        }
    }
}

// MARK: - Page 3: Tutorial (How It Works + interactive trial)

struct OnboardingTutorialView: View {
    let onComplete: () -> Void
    private let hotkey = HotkeyConfiguration.shared.displayString

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 20) {
                // Hero hotkey section
                VStack(spacing: 6) {
                    Text("Your Shortcut")
                        .font(Font(NSFont.captionEyebrow))
                        .textCase(.uppercase)
                        .tracking(1.2)
                        .foregroundColor(Color(nsColor: .secondaryLabelColor))

                    Text(hotkey)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: DesignTokens.Radius.hotkeyDisplay)
                                .fill(Color.accentColor.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignTokens.Radius.hotkeyDisplay)
                                .stroke(Color.accentColor.opacity(0.25), lineWidth: 1.5)
                        )

                    Text("You can change this anytime in Settings")
                        .font(Font(NSFont.captionRegular))
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                }

                // Combined How It Works + Trial — single card
                HowItWorksFlow(hotkey: hotkey)
            }
            .padding(.horizontal, DesignTokens.Spacing.Onboarding.horizontal)
            .padding(.top, DesignTokens.Spacing.Onboarding.top)

            Spacer(minLength: 8)

            // Pinned Get Started button
            VStack(spacing: 0) {
                Divider()
                HStack {
                    OnboardingPageDots(activePage: 3)
                    Spacer()
                    Button("Get Started") {
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
            }
        }
    }
}

// MARK: - How It Works + Interactive Trial (single card)

private struct HowItWorksFlow: View {
    let hotkey: String

    @State private var trialText = "hey, i wanted to let you know that the meeting has been moved to wendsday. pls make sure your availble and bring the updated reportt. also, dont forget to cc sarah on the email you send about the buget changes."
    @State private var isRefining = false
    @State private var hasRefined = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header
            Text("How It Works")
                .font(Font(NSFont.headlineCard))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundColor(Color(nsColor: .secondaryLabelColor))
                .padding(.bottom, 14)

            // Steps — compact, no example text boxes
            StepRow(number: 1, label: "Find text you want to improve", icon: "text.cursor")
            StepConnector()
            StepRow(number: 2, label: "Select it and press \(hotkey)", icon: "selection.pin.in.out")
            StepConnector()
            StepRow(number: 3, label: "Text is refined in-place", icon: "sparkles")

            // Divider between steps and trial
            Divider()
                .padding(.vertical, 14)

            // Trial header
            Text("Give it a try")
                .font(Font(NSFont.headlineSection))
                .padding(.bottom, 8)

            // Hint text
            Text("Select the text below and press **\(hotkey)**, or click Refine.")
                .font(Font(NSFont.captionRegular))
                .foregroundColor(Color(nsColor: .secondaryLabelColor))
                .padding(.bottom, 4)

            // Editable text area — native NSTextView for full editing support
            // (Cmd-A, mouse selection, Cmd-C/V, and CGEvent hotkey simulation all work)
            NativeTextView(text: $trialText, hasRefined: hasRefined)
                .frame(height: 80)

            // Refine button — calls local model directly (no hotkey simulation needed)
            Button(action: { refineTrial() }) {
                HStack(spacing: 6) {
                    if isRefining {
                        ProgressView()
                            .controlSize(.small)
                    } else if hasRefined {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    Text(isRefining ? "Refining..." : (hasRefined ? "Refined!" : "Refine"))
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(hasRefined ? .green : .accentColor)
            .disabled(isRefining || trialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .padding(.top, 10)
        }
        .padding(DesignTokens.Spacing.Onboarding.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                .fill(Color(nsColor: .surfaceControl))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                .stroke(Color(nsColor: .borderSeparatorMuted), lineWidth: 0.5)
        )
    }

    /// Sends the trial text directly to the local model and replaces it with the refined version.
    /// No hotkey/Cmd+C simulation — calls LocalInferenceService directly for reliability.
    private func refineTrial() {
        guard !isRefining else { return }
        isRefining = true
        let textToRefine = trialText

        Task {
            let service = LocalInferenceService()
            do {
                let result = try await Task.detached {
                    var accumulated = ""
                    let stream = service.streamRewrite(text: textToRefine)
                    for try await token in stream {
                        accumulated += token
                    }
                    return service.cleanResponse(accumulated)
                }.value

                if !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    trialText = result
                    hasRefined = true
                }
            } catch {
                // Model was verified working on page 2 — silent recovery
            }
            isRefining = false
        }
    }
}

// MARK: - Native NSTextView Wrapper

/// Wraps a real NSTextView (KeyEquivalentTextView subclass) inside NSScrollView so the
/// "Give it a try" text area behaves like a fully native macOS text field:
/// Cmd-A (select all), mouse selection, Cmd-C/V, and — critically — responds
/// to CGEvent-posted Cmd+C from the hotkey flow.
///
/// SwiftUI's TextEditor, when hosted in NSHostingController, intercepts key events
/// and breaks standard editing shortcuts. KeyEquivalentTextView overrides
/// performKeyEquivalent to reclaim those events.
private struct NativeTextView: NSViewRepresentable {
    @Binding var text: String
    var hasRefined: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = KeyEquivalentTextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindPanel = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        textView.font = .labelRegular
        textView.textColor = .textPrimary
        textView.backgroundColor = .surfaceCode
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 8, height: 8)

        // Allow the text view to wrap text and resize with the scroll view
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0, // will be set by widthTracksTextView
            height: CGFloat.greatestFiniteMagnitude
        )

        textView.string = text

        // Style the scroll view with rounded corners and border
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = DesignTokens.Radius.inset
        scrollView.layer?.masksToBounds = true
        scrollView.layer?.borderWidth = 0.5
        scrollView.layer?.borderColor = NSColor.borderSeparator.cgColor

        scrollView.documentView = textView
        context.coordinator.textView = textView

        // Make the text view first responder once it has a window.
        // This is deferred because at makeNSView time the view is not yet
        // in a window hierarchy. Without this, the user must click into
        // the text view before CGEvent-posted Cmd+C can reach it.
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? KeyEquivalentTextView else { return }

        // Only update text if it changed from outside (e.g., after refinement)
        if textView.string != text {
            // Suppress delegate callback to avoid a binding feedback loop:
            // SwiftUI sets text -> updateNSView -> textView.string = text -> textDidChange -> binding update
            context.coordinator.isUpdatingFromSwiftUI = true
            textView.string = text
            context.coordinator.isUpdatingFromSwiftUI = false

            // Don't restore old selection — the text content changed (e.g., after
            // refinement), so the old selection range is meaningless and may be out of bounds.
            // Place the cursor at the end so the user can see the full result.
            let endPos = (text as NSString).length
            textView.setSelectedRange(NSRange(location: endPos, length: 0))
        }

        // Update border color based on refinement state
        if hasRefined {
            scrollView.layer?.borderWidth = 1.5
            scrollView.layer?.borderColor = NSColor.borderSuccess.cgColor
        } else {
            scrollView.layer?.borderWidth = 0.5
            scrollView.layer?.borderColor = NSColor.borderSeparator.cgColor
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeTextView
        weak var textView: KeyEquivalentTextView?

        /// Guard flag to prevent binding feedback loops during programmatic text updates.
        var isUpdatingFromSwiftUI = false

        init(_ parent: NativeTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdatingFromSwiftUI else { return }
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

// MARK: - Step Row (number + icon + label)

private struct StepRow: View {
    let number: Int
    let label: String
    let icon: String

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.lg) {
            ZStack {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: DesignTokens.Size.Onboarding.stepCircle, height: DesignTokens.Size.Onboarding.stepCircle)
                Text("\(number)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }

            Image(systemName: icon)
                .font(Font(NSFont.labelSemibold))
                .foregroundColor(.accentColor)
                .frame(width: DesignTokens.Size.Onboarding.stepIconWidth)

            Text(label)
                .font(Font(NSFont.headlineSection))
        }
    }
}

// MARK: - Step Connector (vertical dashed line)

private struct StepConnector: View {
    var body: some View {
        HStack {
            DashedLine()
                .stroke(Color(nsColor: .interactiveAccentStepConnector), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                .frame(width: 1.5, height: 16)
                .padding(.leading, 11)
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

private struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

// MARK: - Page Dots

private struct OnboardingPageDots: View {
    let activePage: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(1...3, id: \.self) { page in
                if page == activePage {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 16, height: 5)
                } else {
                    Circle()
                        .fill(Color(nsColor: .tertiaryLabelColor))
                        .frame(width: 5, height: 5)
                }
            }
        }
    }
}
