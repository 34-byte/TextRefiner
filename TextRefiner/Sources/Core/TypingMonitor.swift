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

    /// UserDefaults key — defaults to true (enabled).
    static let enabledKey = "com.textrefiner.showTypingIndicator"

    // MARK: - Callbacks (always called on main thread)

    /// Fired when text crosses the threshold. Provides the focused text
    /// field's frame in Cocoa screen coordinates (bottom-left origin).
    var onShouldShow: ((CGRect) -> Void)?

    /// Fired when text drops below threshold, focus moves, or stop() is called.
    var onShouldHide: (() -> Void)?

    // MARK: - State

    private var appObserver: AXObserver?
    private var observedAppElement: AXUIElement?
    private var elementObserver: AXObserver?
    private var observedElement: AXUIElement?
    private var isIndicatorVisible = false
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

        print("[TypingMonitor] start() called")
        setupWorkspaceObserver()
        attachToFrontmostApp()
        attachToFocusedElement()
        print("[TypingMonitor] start() complete — callbacks set? show=\(onShouldShow != nil) hide=\(onShouldHide != nil)")
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
        print("[TypingMonitor] App activated: \(appName)")
        emitHide()
        attachToFrontmostApp()
        attachToFocusedElement()
    }

    // MARK: - Per-app Focus Observer

    /// Creates an AXObserver on the frontmost app's PID to watch for
    /// kAXFocusedUIElementChangedNotification within that app.
    private func attachToFrontmostApp() {
        teardownAppObserver()

        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            print("[TypingMonitor] attachToFrontmostApp: no frontmost app")
            return
        }
        let pid = frontApp.processIdentifier
        let name = frontApp.localizedName ?? "?"

        // Don't observe our own app
        if pid == ProcessInfo.processInfo.processIdentifier {
            print("[TypingMonitor] attachToFrontmostApp: skipping own app (\(name))")
            return
        }

        let appElement = AXUIElementCreateApplication(pid)

        var obs: AXObserver?
        guard AXObserverCreate(pid, Self.axCallback, &obs) == .success,
              let observer = obs else {
            print("[TypingMonitor] attachToFrontmostApp: AXObserverCreate failed for \(name)")
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
        print("[TypingMonitor] attachToFrontmostApp: watching \(name) (pid \(pid))")
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
            print("[TypingMonitor] attachToFocusedElement: no focused element (AXError \(axErr.rawValue))")
            return
        }
        guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            print("[TypingMonitor] attachToFocusedElement: focused value is not an AXUIElement")
            return
        }

        let element = focused as! AXUIElement

        // Log the role so we can see what element we're looking at
        var roleVal: CFTypeRef?
        let role = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleVal) == .success
            ? (roleVal as? String ?? "?") : "error"
        print("[TypingMonitor] attachToFocusedElement: role=\(role)")

        guard isTextInputElement(element) else {
            print("[TypingMonitor] attachToFocusedElement: not a text input (role=\(role)), skipping")
            return
        }

        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else {
            print("[TypingMonitor] attachToFocusedElement: AXUIElementGetPid failed")
            return
        }

        var obs: AXObserver?
        guard AXObserverCreate(pid, Self.axCallback, &obs) == .success,
              let observer = obs else {
            print("[TypingMonitor] attachToFocusedElement: AXObserverCreate failed")
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
        print("[TypingMonitor] attachToFocusedElement: observing element (pid \(pid))")

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
        print("[TypingMonitor] checkAndNotify: count=\(count) threshold=\(Self.characterThreshold) visible=\(isIndicatorVisible)")

        if count >= Self.characterThreshold {
            // Only re-emit if we need to move the indicator (field may have scrolled)
            if let frame = readFieldFrame(element) {
                print("[TypingMonitor] onShouldShow firing (frame=\(frame)) — callback nil? \(onShouldShow == nil)")
                isIndicatorVisible = true
                onShouldShow?(frame)
            } else {
                print("[TypingMonitor] readFieldFrame returned nil — indicator cannot be positioned")
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
                print("[TypingMonitor] readCharacterCount: value == placeholder, returning 0")
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
               role == "AXSearchField" ||
               role == "AXWebArea" {
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
