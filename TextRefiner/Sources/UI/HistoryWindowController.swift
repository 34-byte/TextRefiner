import Cocoa

/// Displays the last 10 refinements in a clean, scannable list.
/// Each row shows the refined text prominently with original as context.
/// Click any row to copy the refined text — a brief "Copied" label confirms.
final class HistoryWindowController {

    private var window: NSWindow?

    /// Transient "Copied!" label shown after copying — dismissed automatically.
    private var copiedLabel: NSTextField?

    // MARK: - Show / Bring to Front

    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            rebuildContent()
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.title = "History"
        w.center()
        w.minSize = NSSize(width: 420, height: 280)
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

        // Root container
        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.spacing = 0
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        if entries.isEmpty {
            // --- Empty State ---
            let emptyContainer = NSView()
            emptyContainer.translatesAutoresizingMaskIntoConstraints = false

            let emptyStack = NSStackView()
            emptyStack.orientation = .vertical
            emptyStack.alignment = .centerX
            emptyStack.spacing = 8
            emptyStack.translatesAutoresizingMaskIntoConstraints = false

            // Icon
            let iconView = NSImageView()
            let iconConfig = NSImage.SymbolConfiguration(pointSize: 32, weight: .light)
            iconView.image = NSImage(systemSymbolName: "text.badge.checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(iconConfig)
            iconView.contentTintColor = .tertiaryLabelColor
            emptyStack.addArrangedSubview(iconView)

            // Title
            let titleLabel = NSTextField(labelWithString: "No Refinements Yet")
            titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
            titleLabel.textColor = .secondaryLabelColor
            titleLabel.alignment = .center
            emptyStack.addArrangedSubview(titleLabel)

            // Subtitle
            let hotkey = HotkeyConfiguration.shared.displayString
            let subtitleLabel = NSTextField(labelWithString: "Select text and press \(hotkey) to refine it.\nYour last 10 refinements will appear here.")
            subtitleLabel.font = .systemFont(ofSize: 12)
            subtitleLabel.textColor = .tertiaryLabelColor
            subtitleLabel.alignment = .center
            subtitleLabel.maximumNumberOfLines = 2
            emptyStack.addArrangedSubview(subtitleLabel)

            emptyContainer.addSubview(emptyStack)
            NSLayoutConstraint.activate([
                emptyStack.centerXAnchor.constraint(equalTo: emptyContainer.centerXAnchor),
                emptyStack.centerYAnchor.constraint(equalTo: emptyContainer.centerYAnchor),
            ])

            rootStack.addArrangedSubview(emptyContainer)
            emptyContainer.setContentHuggingPriority(.defaultLow, for: .vertical)
        } else {
            // --- Entry List ---
            let scrollView = NSScrollView()
            scrollView.hasVerticalScroller = true
            scrollView.drawsBackground = false
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            scrollView.translatesAutoresizingMaskIntoConstraints = false

            let clipView = NSClipView()
            clipView.drawsBackground = false
            scrollView.contentView = clipView

            let entryStack = NSStackView()
            entryStack.orientation = .vertical
            entryStack.spacing = 0
            entryStack.translatesAutoresizingMaskIntoConstraints = false

            for (index, entry) in entries.enumerated() {
                let row = makeRowView(entry, isEven: index % 2 == 0)
                entryStack.addArrangedSubview(row)

                // Full-width constraint for each row
                row.widthAnchor.constraint(equalTo: entryStack.widthAnchor).isActive = true
            }

            let documentView = FlippedView()
            documentView.translatesAutoresizingMaskIntoConstraints = false
            documentView.addSubview(entryStack)

            NSLayoutConstraint.activate([
                entryStack.topAnchor.constraint(equalTo: documentView.topAnchor),
                entryStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
                entryStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
                entryStack.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor),
            ])

            scrollView.documentView = documentView
            NSLayoutConstraint.activate([
                documentView.widthAnchor.constraint(equalTo: clipView.widthAnchor),
            ])

            rootStack.addArrangedSubview(scrollView)
            scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        }

        // --- Bottom bar ---
        let bottomBar = makeBottomBar(hasEntries: !entries.isEmpty)
        rootStack.addArrangedSubview(bottomBar)
        bottomBar.setContentHuggingPriority(.required, for: .vertical)

        window.contentView = rootStack
    }

    // MARK: - Row View

    private func makeRowView(_ entry: RefinementHistory.Entry, isEven: Bool) -> NSView {
        let container = HistoryRowView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = isEven
            ? NSColor.controlBackgroundColor.cgColor
            : NSColor.controlBackgroundColor.blended(withFraction: 0.03, of: .labelColor)?.cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)

        // Row 1: Relative time + model badge
        let headerStack = NSStackView()
        headerStack.orientation = .horizontal
        headerStack.spacing = 6
        headerStack.alignment = .centerY

        let timeLabel = NSTextField(labelWithString: relativeTime(from: entry.timestamp))
        timeLabel.font = .systemFont(ofSize: 11)
        timeLabel.textColor = .tertiaryLabelColor
        headerStack.addArrangedSubview(timeLabel)

        let dot = NSTextField(labelWithString: "\u{00B7}")
        dot.font = .systemFont(ofSize: 11, weight: .bold)
        dot.textColor = .tertiaryLabelColor
        headerStack.addArrangedSubview(dot)

        // Model name — extract display name from ID
        let modelDisplay = (entry.modelUsed == ModelManager.modelID) ? ModelManager.displayName : entry.modelUsed
        let modelLabel = NSTextField(labelWithString: modelDisplay)
        modelLabel.font = .systemFont(ofSize: 11)
        modelLabel.textColor = .tertiaryLabelColor
        headerStack.addArrangedSubview(modelLabel)

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerStack.addArrangedSubview(headerSpacer)

        // Copy icon hint (subtle, right-aligned)
        let copyHint = NSImageView()
        copyHint.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
        copyHint.contentTintColor = .tertiaryLabelColor
        copyHint.toolTip = "Click to copy refined text"
        headerStack.addArrangedSubview(copyHint)

        stack.addArrangedSubview(headerStack)
        headerStack.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true

        // Row 2: Refined text (primary — what the user wants to copy)
        let refinedText = truncate(entry.refinedText, maxLength: 160)
        let refinedLabel = NSTextField(wrappingLabelWithString: refinedText)
        refinedLabel.font = .systemFont(ofSize: 13)
        refinedLabel.textColor = .labelColor
        refinedLabel.maximumNumberOfLines = 3
        refinedLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(refinedLabel)

        // Row 3: Original text (secondary context — what was submitted)
        let originalText = truncate(entry.originalText, maxLength: 100)
        let originalLabel = NSTextField(wrappingLabelWithString: originalText)
        originalLabel.font = .systemFont(ofSize: 11)
        originalLabel.textColor = .secondaryLabelColor
        originalLabel.maximumNumberOfLines = 2
        originalLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(originalLabel)

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Thin separator at the bottom
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(separator)
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Click to copy
        let click = NSClickGestureRecognizer(target: self, action: #selector(entryClicked(_:)))
        container.addGestureRecognizer(click)
        objc_setAssociatedObject(container, &AssociatedKeys.refinedText, entry.refinedText, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        return container
    }

    // MARK: - Bottom Bar

    private func makeBottomBar(hasEntries: Bool) -> NSView {
        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        bar.spacing = 8

        // Entry count label (left side)
        if hasEntries {
            let count = RefinementHistory.shared.allEntries.count
            let countText = count == 1 ? "1 refinement" : "\(count) refinements"
            let countLabel = NSTextField(labelWithString: countText)
            countLabel.font = .systemFont(ofSize: 11)
            countLabel.textColor = .tertiaryLabelColor
            bar.addArrangedSubview(countLabel)
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bar.addArrangedSubview(spacer)

        if hasEntries {
            let clearButton = NSButton(title: "Clear All", target: self, action: #selector(clearHistory))
            clearButton.bezelStyle = .rounded
            clearButton.controlSize = .small
            bar.addArrangedSubview(clearButton)
        }

        // Top border for the bar
        bar.wantsLayer = true
        let topBorder = CALayer()
        topBorder.backgroundColor = NSColor.separatorColor.cgColor
        topBorder.frame = CGRect(x: 0, y: bar.bounds.height, width: 2000, height: 1)
        topBorder.autoresizingMask = [.layerWidthSizable, .layerMinYMargin]
        bar.layer?.addSublayer(topBorder)

        return bar
    }

    // MARK: - Actions

    @objc private func entryClicked(_ gesture: NSClickGestureRecognizer) {
        guard let row = gesture.view,
              let text = objc_getAssociatedObject(row, &AssociatedKeys.refinedText) as? String else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        // Highlight the row briefly
        if let rowView = row as? HistoryRowView {
            let originalBg = rowView.layer?.backgroundColor
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                rowView.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
            } completionHandler: {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.3
                    rowView.layer?.backgroundColor = originalBg
                }
            }
        }

        // Show "Copied!" feedback near the bottom of the window
        showCopiedFeedback()
    }

    /// Shows a brief "Copied!" label at the bottom of the window that auto-dismisses.
    private func showCopiedFeedback() {
        // Remove existing label if still visible
        copiedLabel?.removeFromSuperview()

        guard let contentView = window?.contentView else { return }

        let label = NSTextField(labelWithString: "Copied to clipboard")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.backgroundColor = NSColor.controlAccentColor
        label.isBordered = false
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        label.layer?.cornerRadius = 10
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        // Wrap in a container for padding
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        pill.layer?.cornerRadius = 12
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.alphaValue = 0

        pill.addSubview(label)
        contentView.addSubview(pill)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -6),

            pill.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            pill.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -48),
        ])

        self.copiedLabel = label

        // Fade in
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            pill.animator().alphaValue = 1
        }

        // Fade out after 1.2s
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                pill.animator().alphaValue = 0
            }, completionHandler: {
                pill.removeFromSuperview()
                if self?.copiedLabel === label {
                    self?.copiedLabel = nil
                }
            })
        }
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear All History?"
        alert.informativeText = "This will permanently remove all \(RefinementHistory.shared.allEntries.count) refinement records. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear All")
        alert.addButton(withTitle: "Keep")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            RefinementHistory.shared.clearAll()
            rebuildContent()
        }
    }

    // MARK: - Helpers

    private func truncate(_ text: String, maxLength: Int) -> String {
        let cleaned = text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if cleaned.count <= maxLength { return cleaned }
        return String(cleaned.prefix(maxLength)) + "..."
    }

    /// Formats a date as relative time: "just now", "2 min ago", "3 hours ago", "yesterday", or a date.
    private func relativeTime(from date: Date) -> String {
        let now = Date()
        let interval = now.timeIntervalSince(date)

        if interval < 60 {
            return "just now"
        } else if interval < 3600 {
            let mins = Int(interval / 60)
            return "\(mins) min ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        } else if interval < 172800 {
            return "yesterday"
        } else if interval < 604800 {
            let days = Int(interval / 86400)
            return "\(days) days ago"
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: date)
        }
    }
}

// MARK: - Associated Object Key

private enum AssociatedKeys {
    static var refinedText = 0
}

// MARK: - Flipped NSView (scroll content starts at top)

private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Custom row view with cursor change

private class HistoryRowView: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
