import Cocoa

/// Monitors text input across all apps using the Accessibility API.
/// When the user types enough text (>= ~7 words), notifies the caller
/// to show the TextRefiner ready indicator. Hides when text drops below
/// threshold, focus moves, or the hotkey fires.
///
/// Requires Accessibility permission (same TCC entry as the hotkey tap).
final class TypingMonitor {

    // MARK: - Configuration

    /// ~7 words x ~5.5 chars/word = 38 chars. Round up to 40.
    private static let characterThreshold = 40

    /// Known browser bundle IDs. When the frontmost app is a browser, the ready pill
    /// is suppressed — AX cannot distinguish reading from editing inside web content.
    /// A browser extension is the future path for proper browser support.
    private static let browserBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.apple.Safari",
        "org.mozilla.firefox",
        "company.thebrowser.Browser",   // Arc
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi"
    ]

    /// Known terminal emulator bundle IDs. The pill is suppressed for terminals —
    /// text typed here is shell input, not refineable prose.
    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",        // iTerm2
        "io.alacritty.Alacritty",       // Alacritty
        "com.github.wez.wezterm",       // WezTerm
        "net.kovidgoyal.kitty",         // Kitty
        "com.hyper.app"                 // Hyper
    ]

    /// UserDefaults key — defaults to true (enabled).
    static let enabledKey = "com.textrefiner.showTypingIndicator"

    // MARK: - Callbacks (always called on main thread)

    /// Fired when text crosses the threshold. Provides the focused text
    /// field's frame in Cocoa screen coordinates (bottom-left origin).
    var onShouldShow: ((CGRect) -> Void)?

    /// Fired when text drops below threshold, focus moves, or stop() is called.
    var onShouldHide: (() -> Void)?

    /// Fired when the frontmost app changes. Used to clear stale cached
    /// position data so the HUD doesn't anchor to the previous app's field.
    var onAppSwitched: (() -> Void)?

    // MARK: - State

    private var appObserver: AXObserver?
    private var observedAppElement: AXUIElement?
    private var elementObserver: AXObserver?
    private var observedElement: AXUIElement?
    private var isIndicatorVisible = false
    /// Character count recorded the moment we attached to the current element.
    /// Used in change-detection mode to avoid showing the pill for pre-existing
    /// text in Electron apps (see placeholderAttributeAvailable).
    private var attachCharacterCount: Int?
    /// True when the focused element exposes kAXPlaceholderValueAttribute.
    /// Native Mac apps expose it; Electron apps typically do not.
    /// When false, change-detection mode is active: the pill only shows after
    /// the user types (count differs from attachCharacterCount).
    private var placeholderAttributeAvailable = false
    /// Set to true the first time the character count diverges from attachCharacterCount.
    /// Once true, the change-detection gate is bypassed for the rest of this element
    /// session — so deleting back to the baseline count does not re-hide the pill.
    private var hasDetectedChange = false
    /// Set to true by restoreIndicatorVisibility() after a refinement completes.
    /// Applies to all apps (native and Electron): pill stays hidden until the user
    /// makes a new edit (count diverges from the post-refinement baseline).
    private var requiresNewEditAfterRefinement = false
    /// The most recent focused text field frame (Cocoa screen coordinates).
    /// Updated every time a focused element is checked, regardless of char count.
    /// Used by AppDelegate to position the pill for processing/error states
    /// even when the pill was not already visible.
    private(set) var lastKnownFrame: CGRect?
    /// The AX element currently being observed for value changes.
    /// Exposed so callers can perform high-frequency position reads during processing.
    private(set) var trackedElement: AXUIElement?
    /// True when the frontmost app is a known browser. Used by AppDelegate to
    /// anchor the HUD to the mouse cursor instead of a text-field frame.
    private(set) var isBrowserFrontmost = false

    /// Returns true if the given running application is a known browser.
    /// Reads bundle ID synchronously at call time — use this instead of
    /// `isBrowserFrontmost` when you need the live answer (e.g. at hotkey time,
    /// before the workspace notification has necessarily fired).
    static func isBrowserApp(_ app: NSRunningApplication?) -> Bool {
        guard let bundleID = app?.bundleIdentifier else { return false }
        return browserBundleIDs.contains(bundleID)
    }
    private var workspaceToken: NSObjectProtocol?
    /// Fallback polling timer — fires every 500ms when an element is observed.
    /// Catches character-count changes in apps (Chrome, Electron) whose renderer
    /// processes don't reliably fire kAXValueChangedNotification to the system.
    private var pollTimer: DispatchSourceTimer?

    // MARK: - Lifecycle

    func start() {
        // Teardown any existing observers first — start() can be called multiple
        // times (e.g. startListening() from both launch and accessibility-poll).
        // Without this, setupWorkspaceObserver() leaks the previous observer
        // token, causing duplicate firings on every app switch.
        stop()

        #if DEBUG
        print("[TypingMonitor] start() called")
        #endif
        setupWorkspaceObserver()
        attachToFrontmostApp()
        guard !isBrowserFrontmost else { return }
        attachToFocusedElement()
        #if DEBUG
        print("[TypingMonitor] start() complete — callbacks set? show=\(onShouldShow != nil) hide=\(onShouldHide != nil)")
        #endif
    }

    func stop() {
        teardownElementObserver()
        teardownAppObserver()
        if let token = workspaceToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            workspaceToken = nil
        }
        emitHide()
    }

    /// Called externally (e.g. when the hotkey fires) to immediately hide.
    func forceHide() {
        emitHide()
    }

    /// Called when the refinement animation collapses back to pill shape.
    /// Hides the pill immediately and re-arms the gate so it only reappears after
    /// the user makes a new edit. Applies to all apps (native and Electron).
    func restoreIndicatorVisibility() {
        guard let element = observedElement, !isBrowserFrontmost else { return }
        // The pill is visually present at this point (animation just finished).
        // Set the flag so emitHide() fires the callback, then clear it.
        isIndicatorVisible = true
        emitHide()
        // Snapshot the current count as the new baseline. The pill will only
        // reappear after the user changes the content from this point.
        attachCharacterCount = readCharacterCount(element)
        hasDetectedChange = false
        requiresNewEditAfterRefinement = true
    }

    // MARK: - Workspace Observer (app activation)

    /// Listens for app activation changes via NSWorkspace (reliable, no PID issues).
    /// When the frontmost app changes, re-attach the per-app AXObserver for focus
    /// changes within that app, then check the newly focused element.
    private func setupWorkspaceObserver() {
        workspaceToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleAppActivated(notification)
        }
    }

    private func handleAppActivated(_ notification: Notification) {
        let appName = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.localizedName ?? "?"
        #if DEBUG
        print("[TypingMonitor] App activated: \(appName)")
        #endif
        emitHide()
        onAppSwitched?()
        teardownElementObserver()
        attachToFrontmostApp()
        guard !isBrowserFrontmost else { return }
        attachToFocusedElement()
    }

    // MARK: - Per-app Focus Observer

    /// Creates an AXObserver on the frontmost app's PID to watch for
    /// kAXFocusedUIElementChangedNotification within that app.
    private func attachToFrontmostApp() {
        teardownAppObserver()

        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            #if DEBUG
            print("[TypingMonitor] attachToFrontmostApp: no frontmost app")
            #endif
            return
        }
        let pid = frontApp.processIdentifier
        let name = frontApp.localizedName ?? "?"

        // Don't observe our own app
        if pid == ProcessInfo.processInfo.processIdentifier {
            #if DEBUG
            print("[TypingMonitor] attachToFrontmostApp: skipping own app (\(name))")
            #endif
            return
        }

        // Browsers expose only a single AXWebArea to macOS — no per-element focus.
        // Suppress the pill entirely for browser contexts.
        // A browser extension is the future path for proper browser support.
        if let bundleID = frontApp.bundleIdentifier,
           Self.browserBundleIDs.contains(bundleID) {
            isBrowserFrontmost = true
            #if DEBUG
            print("[TypingMonitor] attachToFrontmostApp: skipping browser (\(name))")
            #endif
            return
        }
        isBrowserFrontmost = false

        // Terminals expose shell input as text areas — not refineable prose.
        // Suppress the pill entirely.
        if let bundleID = frontApp.bundleIdentifier,
           Self.terminalBundleIDs.contains(bundleID) {
            #if DEBUG
            print("[TypingMonitor] attachToFrontmostApp: skipping terminal (\(name))")
            #endif
            return
        }

        // User-excluded apps from Settings — same suppression as terminals.
        // The hotkey still works; only the pill is hidden.
        if let bundleID = frontApp.bundleIdentifier,
           ExcludedAppsStorage.shared.contains(bundleID) {
            #if DEBUG
            print("[TypingMonitor] attachToFrontmostApp: skipping user-excluded app (\(name))")
            #endif
            return
        }

        let appElement = AXUIElementCreateApplication(pid)

        var obs: AXObserver?
        guard AXObserverCreate(pid, Self.axCallback, &obs) == .success,
              let observer = obs else {
            #if DEBUG
            print("[TypingMonitor] attachToFrontmostApp: AXObserverCreate failed for \(name)")
            #endif
            return
        }

        let ptr = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(
            observer,
            appElement,
            kAXFocusedUIElementChangedNotification as CFString,
            ptr
        )

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        appObserver = observer
        observedAppElement = appElement
        #if DEBUG
        print("[TypingMonitor] attachToFrontmostApp: watching \(name) (pid \(pid))")
        #endif
    }

    private func teardownAppObserver() {
        if let obs = appObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        appObserver = nil
        observedAppElement = nil
    }

    // MARK: - Per-element Value Observer

    private func attachToFocusedElement() {
        teardownElementObserver()

        let sysEl = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let axErr = AXUIElementCopyAttributeValue(sysEl, kAXFocusedUIElementAttribute as CFString, &focused)
        guard axErr == .success else {
            #if DEBUG
            print("[TypingMonitor] attachToFocusedElement: no focused element (AXError \(axErr.rawValue))")
            #endif
            return
        }
        guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            #if DEBUG
            print("[TypingMonitor] attachToFocusedElement: focused value is not an AXUIElement")
            #endif
            return
        }

        let element = focused as! AXUIElement

        // Log the role so we can see what element we're looking at
        var roleVal: CFTypeRef?
        let role = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleVal) == .success
            ? (roleVal as? String ?? "?") : "error"
        #if DEBUG
        print("[TypingMonitor] attachToFocusedElement: role=\(role)")
        #endif

        guard isTextInputElement(element) else {
            #if DEBUG
            print("[TypingMonitor] attachToFocusedElement: not a text input (role=\(role)), skipping")
            #endif
            return
        }

        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else {
            #if DEBUG
            print("[TypingMonitor] attachToFocusedElement: AXUIElementGetPid failed")
            #endif
            return
        }

        var obs: AXObserver?
        guard AXObserverCreate(pid, Self.axCallback, &obs) == .success,
              let observer = obs else {
            #if DEBUG
            print("[TypingMonitor] attachToFocusedElement: AXObserverCreate failed")
            #endif
            return
        }

        let ptr = Unmanaged.passUnretained(self).toOpaque()
        // Primary: AppKit text fields fire this on every character
        AXObserverAddNotification(observer, element, kAXValueChangedNotification as CFString, ptr)
        // Fallback: some apps fire this more reliably (e.g. cursor-movement-based tracking)
        AXObserverAddNotification(observer, element, kAXSelectedTextChangedNotification as CFString, ptr)

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        elementObserver = observer
        observedElement = element
        trackedElement = element
        #if DEBUG
        print("[TypingMonitor] attachToFocusedElement: observing element (pid \(pid))")
        #endif

        // Record the character count at attach time and whether the element exposes
        // kAXPlaceholderValueAttribute. These drive the change-detection gate in
        // checkAndNotify for Electron apps that store placeholder text as the real
        // AX value without exposing a placeholder attribute.
        let countAtAttach = readCharacterCount(element)
        attachCharacterCount = countAtAttach
        var placeholderProbe: CFTypeRef?
        placeholderAttributeAvailable = AXUIElementCopyAttributeValue(
            element, kAXPlaceholderValueAttribute as CFString, &placeholderProbe
        ) == .success
        #if DEBUG
        print("[TypingMonitor] attachToFocusedElement: placeholderAttr=\(placeholderAttributeAvailable) countAtAttach=\(countAtAttach)")
        #endif

        // Electron apps fire focus notifications late — sometimes after the user has
        // already typed past the threshold. When that happens, countAtAttach equals
        // the current count and the change-detection gate (count != baseline) never
        // opens. Fix: if we're in Electron mode and already above threshold on attach,
        // open the gate immediately — the content is clearly refineable.
        // Placeholder text in Electron apps is typically short (< 40 chars), so this
        // won't falsely trigger on placeholder text.
        if !placeholderAttributeAvailable && countAtAttach >= Self.characterThreshold {
            hasDetectedChange = true
        }

        // Check immediately in case we focused into an already-long field
        checkAndNotify(element: element)

        // Start the polling fallback for apps whose renderer processes don't fire
        // kAXValueChangedNotification reliably (Chrome, Safari web content, Electron).
        // The AX notification path stays as the fast lane; the timer catches the rest.
        startPollTimer(for: element)
    }

    private func teardownElementObserver() {
        stopPollTimer()
        if let obs = elementObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        elementObserver = nil
        observedElement = nil
        trackedElement = nil
        attachCharacterCount = nil
        placeholderAttributeAvailable = false
        hasDetectedChange = false
        requiresNewEditAfterRefinement = false
        lastKnownFrame = nil
    }

    // MARK: - Polling Fallback

    private func startPollTimer(for element: AXUIElement) {
        stopPollTimer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // 500ms interval — responsive enough for UX, cheap enough for battery.
        timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self, let el = self.observedElement else { return }
            self.checkAndNotify(element: el)
        }
        timer.resume()
        pollTimer = timer
    }

    private func stopPollTimer() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    // MARK: - Event Handlers (called by C callback on main thread)

    fileprivate func handleFocusChanged() {
        emitHide()
        attachToFocusedElement()
    }

    fileprivate func handleValueChanged(element: AXUIElement) {
        checkAndNotify(element: element)
    }

    private func checkAndNotify(element: AXUIElement) {
        let count = readCharacterCount(element)
        #if DEBUG
        print("[TypingMonitor] checkAndNotify: count=\(count) threshold=\(Self.characterThreshold) visible=\(isIndicatorVisible)")
        #endif

        // Always track the field frame for positioning — even below threshold.
        // AppDelegate uses lastKnownFrame to position the pill for processing/error
        // states when the pill was not already visible.
        let frame = readFieldFrame(element)
        if let frame { lastKnownFrame = frame }

        if count >= Self.characterThreshold {
            // Post-refinement gate — applies to all apps (native and Electron).
            // After a refinement, the pill is hidden and only reappears once the
            // user makes a new edit (count diverges from the post-refinement baseline).
            if requiresNewEditAfterRefinement, let baseline = attachCharacterCount {
                if count != baseline {
                    requiresNewEditAfterRefinement = false
                    hasDetectedChange = true  // also open the Electron gate
                } else {
                    #if DEBUG
                    print("[TypingMonitor] checkAndNotify: post-refinement gate blocked (count==baseline=\(baseline))")
                    #endif
                    emitHide()
                    return
                }
            }

            // Change-detection gate for Electron apps: if the element does not expose
            // kAXPlaceholderValueAttribute, only show the pill after the user has
            // actually typed (count diverged from the baseline recorded on attach).
            // This prevents placeholder text stored as the real AX value from
            // triggering the pill in apps like Slack, Claude Code, and Notion.
            if !placeholderAttributeAvailable, let baseline = attachCharacterCount {
                // Once the count has ever diverged from baseline, lock the gate open
                // permanently for this element session. This prevents deleting back
                // to the attach count from incorrectly re-hiding the pill.
                if count != baseline { hasDetectedChange = true }
                if !hasDetectedChange {
                    #if DEBUG
                    print("[TypingMonitor] checkAndNotify: change-detection gate blocked (count==baseline=\(baseline), placeholderAttr=false)")
                    #endif
                    emitHide()
                    return
                }
            }

            if let frame {
                #if DEBUG
                print("[TypingMonitor] onShouldShow firing (frame=\(frame)) — callback nil? \(onShouldShow == nil)")
                #endif
                isIndicatorVisible = true
                onShouldShow?(frame)
            } else {
                #if DEBUG
                print("[TypingMonitor] readFieldFrame returned nil — indicator cannot be positioned")
                #endif
            }
        } else {
            emitHide()
        }
    }

    private func emitHide() {
        guard isIndicatorVisible else { return }
        isIndicatorVisible = false
        onShouldHide?()
    }

    // MARK: - AX Attribute Reads

    private func readCharacterCount(_ element: AXUIElement) -> Int {
        // Read the actual value string first — needed for both counting and
        // placeholder comparison regardless of which path we take.
        var strValue: CFTypeRef?
        let actualString: String? = AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &strValue
        ) == .success ? (strValue as? String) : nil

        // If the element exposes a placeholder value and the current value matches
        // it exactly, the field is empty (showing placeholder, not user content).
        // This prevents custom rich-text editors (Notion, Slate, etc.) that store
        // placeholder text as real content from triggering the indicator.
        if let actual = actualString, !actual.isEmpty {
            var placeholderRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                element, kAXPlaceholderValueAttribute as CFString, &placeholderRef
            ) == .success, let placeholder = placeholderRef as? String,
               !placeholder.isEmpty, actual == placeholder {
                #if DEBUG
                print("[TypingMonitor] readCharacterCount: value == placeholder, returning 0")
                #endif
                return 0
            }
        }

        // Primary: kAXNumberOfCharactersAttribute (fast, avoids reading full text)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            kAXNumberOfCharactersAttribute as CFString,
            &value
        ) == .success, let num = value as? NSNumber {
            return num.intValue
        }

        // Fallback: use the value string we already read above.
        // Many apps (browsers, Electron) don't expose kAXNumberOfCharactersAttribute.
        return actualString?.count ?? 0
    }

    private func readFieldFrame(_ element: AXUIElement) -> CGRect? {
        // Read position (AXPosition -> CGPoint)
        var posValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &posValue
        ) == .success,
              let posAX = posValue,
              CFGetTypeID(posAX) == AXValueGetTypeID() else { return nil }

        var point = CGPoint.zero
        guard AXValueGetValue(posAX as! AXValue, .cgPoint, &point) else { return nil }

        // Read size (AXSize -> CGSize)
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &sizeValue
        ) == .success,
              let sizeAX = sizeValue,
              CFGetTypeID(sizeAX) == AXValueGetTypeID() else { return nil }

        var size = CGSize.zero
        guard AXValueGetValue(sizeAX as! AXValue, .cgSize, &size) else { return nil }

        // AX coordinates: origin is top-left of screen, Y increases downward.
        // Cocoa coordinates: origin is bottom-left of screen, Y increases upward.
        let screenH = NSScreen.main?.frame.height ?? 0
        return CGRect(
            x: point.x,
            y: screenH - point.y - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// Returns true for elements that accept text input.
    /// Checks the AX role first (fast path), then falls back to checking
    /// whether the element has a settable value attribute (covers browsers,
    /// Electron apps, and other non-standard text inputs).
    private func isTextInputElement(_ element: AXUIElement) -> Bool {
        var roleVal: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &roleVal
        ) == .success, let role = roleVal as? String {
            // Fast path: known text input roles
            if role == kAXTextFieldRole as String ||
               role == kAXTextAreaRole as String ||
               role == "AXComboBox" ||
               role == "AXSearchField" {
                return true
            }
        }

        // Fallback: if the element supports a settable value, treat it as text input.
        // This covers Electron apps, custom text controls, etc.
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success {
            return settable.boolValue
        }

        return false
    }

    // MARK: - C Callback

    // Cannot capture Swift values. Uses the userInfo pointer to reach self.
    private static let axCallback: AXObserverCallback = { _, element, notification, userInfo in
        guard let userInfo else { return }
        let monitor = Unmanaged<TypingMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        let notif = notification as String

        if notif == kAXFocusedUIElementChangedNotification as String {
            monitor.handleFocusChanged()
        } else if notif == kAXValueChangedNotification as String ||
                  notif == kAXSelectedTextChangedNotification as String {
            monitor.handleValueChanged(element: element)
        }
    }
}
