import Cocoa

/// Displays the last 10 refinements in a scrollable list.
/// Clicking an entry copies its refined text to the clipboard.
final class HistoryWindowController {

    private var window: NSWindow?

    // MARK: - Show / Bring to Front

    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            rebuildContent()
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.title = "Refinement History"
        w.center()
        w.minSize = NSSize(width: 400, height: 250)
        w.isReleasedWhenClosed = false

        self.window = w
        rebuildContent()

        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Build UI

    private func rebuildContent() {
        guard let window = window else { return }

        let entries = RefinementHistory.shared.allEntries

        // Outer vertical stack: history entries + bottom bar
        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.spacing = 0
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        // --- Scrollable area with entry cards ---
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let clipView = NSClipView()
        clipView.drawsBackground = false
        scrollView.contentView = clipView

        let entryStack = NSStackView()
        entryStack.orientation = .vertical
        entryStack.spacing = 1
        entryStack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        entryStack.translatesAutoresizingMaskIntoConstraints = false

        if entries.isEmpty {
            let emptyLabel = NSTextField(labelWithString: "No refinements yet.")
            emptyLabel.font = .systemFont(ofSize: 13)
            emptyLabel.textColor = .secondaryLabelColor
            emptyLabel.alignment = .center
            entryStack.addArrangedSubview(emptyLabel)
        } else {
            for entry in entries {
                let card = makeEntryView(entry)
                entryStack.addArrangedSubview(card)
            }
        }

        // Document view needs a flipped container so content starts at the top
        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(entryStack)

        NSLayoutConstraint.activate([
            entryStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            entryStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            entryStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            // Let entryStack determine the document height
            entryStack.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor),
        ])

        scrollView.documentView = documentView

        // Pin documentView width to scrollView's clip view so it doesn't scroll horizontally
        NSLayoutConstraint.activate([
            documentView.widthAnchor.constraint(equalTo: clipView.widthAnchor),
        ])

        rootStack.addArrangedSubview(scrollView)

        // --- Bottom bar: Clear History button ---
        let bottomBar = NSStackView()
        bottomBar.orientation = .horizontal
        bottomBar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bottomBar.addArrangedSubview(spacer)

        let clearButton = NSButton(title: "Clear History", target: nil, action: #selector(clearHistory))
        clearButton.target = self
        clearButton.bezelStyle = .rounded
        clearButton.isEnabled = !entries.isEmpty
        bottomBar.addArrangedSubview(clearButton)

        rootStack.addArrangedSubview(bottomBar)

        // Constrain scroll to fill available space, bottom bar is fixed height
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        bottomBar.setContentHuggingPriority(.required, for: .vertical)

        window.contentView = rootStack
    }

    // MARK: - Entry Card

    private func makeEntryView(_ entry: RefinementHistory.Entry) -> NSView {
        let card = NSBox()
        card.boxType = .custom
        card.cornerRadius = 6
        card.borderWidth = 0.5
        card.borderColor = .separatorColor
        card.fillColor = .controlBackgroundColor
        card.contentViewMargins = NSSize(width: 10, height: 8)
        card.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Header: timestamp + model
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let headerText = "\(formatter.string(from: entry.timestamp))  [\(entry.modelUsed)]"
        let headerLabel = NSTextField(labelWithString: headerText)
        headerLabel.font = .systemFont(ofSize: 11, weight: .medium)
        headerLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(headerLabel)

        // Original text (truncated)
        let originalPreview = truncate(entry.originalText, maxLength: 120)
        let origLabel = NSTextField(wrappingLabelWithString: "Original: \(originalPreview)")
        origLabel.font = .systemFont(ofSize: 12)
        origLabel.textColor = .labelColor
        origLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(origLabel)

        // Refined text (truncated)
        let refinedPreview = truncate(entry.refinedText, maxLength: 120)
        let refinedLabel = NSTextField(wrappingLabelWithString: "Refined: \(refinedPreview)")
        refinedLabel.font = .systemFont(ofSize: 12, weight: .medium)
        refinedLabel.textColor = .labelColor
        refinedLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(refinedLabel)

        // "Click to copy" hint
        let hintLabel = NSTextField(labelWithString: "Click to copy refined text")
        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(hintLabel)

        card.contentView = stack

        // Click gesture to copy refined text
        let click = NSClickGestureRecognizer(target: self, action: #selector(entryClicked(_:)))
        card.addGestureRecognizer(click)

        // Stash the refined text so we can retrieve it in the click handler
        objc_setAssociatedObject(card, &AssociatedKeys.refinedText, entry.refinedText, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        return card
    }

    // MARK: - Actions

    @objc private func entryClicked(_ gesture: NSClickGestureRecognizer) {
        guard let card = gesture.view,
              let text = objc_getAssociatedObject(card, &AssociatedKeys.refinedText) as? String else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        // Brief visual feedback: flash the card background
        if let box = card as? NSBox {
            let original = box.fillColor
            box.fillColor = .selectedContentBackgroundColor
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                box.fillColor = original
            }
        }
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear Refinement History?"
        alert.informativeText = "This will permanently delete all saved refinement history."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            RefinementHistory.shared.clearAll()
            rebuildContent()
        }
    }

    // MARK: - Helpers

    private func truncate(_ text: String, maxLength: Int) -> String {
        let cleaned = text.replacingOccurrences(of: "\n", with: " ")
        if cleaned.count <= maxLength { return cleaned }
        return String(cleaned.prefix(maxLength)) + "..."
    }
}

// MARK: - Associated Object Key

private enum AssociatedKeys {
    static var refinedText = 0
}

// MARK: - Flipped NSView (so scroll content starts at top)

private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
