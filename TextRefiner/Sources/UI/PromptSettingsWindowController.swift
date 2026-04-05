import Cocoa
import SwiftUI

/// Manages the Prompt Settings window.
/// Follows the same pattern as OnboardingWindowController:
/// NSWindow + NSHostingController hosting a SwiftUI view.
final class PromptSettingsWindowController {
    private var window: NSWindow?

    func show() {
        // If window already exists, just bring it to front
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = PromptSettingsView()

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 550),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "Prompt Settings"
        w.contentViewController = NSHostingController(rootView: settingsView)
        w.contentMinSize = NSSize(width: 500, height: 450)
        w.center()
        w.makeKeyAndOrderFront(nil)

        // Bring our app to the front
        NSApp.activate(ignoringOtherApps: true)

        self.window = w
    }
}

// MARK: - SwiftUI Prompt Settings View

struct PromptSettingsView: View {
    @State private var editingPrompt: String = ""
    @State private var history: [PromptStorage.PromptHistoryEntry] = []
    @State private var validationError: String? = nil
    @State private var showSavedConfirmation = false
    @State private var showInfoPopover = false

    /// True when the editor text contains the required {{USER_TEXT}} placeholder.
    private var isValid: Bool {
        editingPrompt.contains("{{USER_TEXT}}")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header with info button
            HStack(spacing: 8) {
                Text("Active Prompt")
                    .font(.headline)

                Button(action: { showInfoPopover.toggle() }) {
                    Image(systemName: "info.circle")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showInfoPopover, arrowEdge: .trailing) {
                    promptInfoPopover
                }

                Spacer()
            }

            // Text editor for the prompt
            TextEditor(text: $editingPrompt)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 180)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .onChange(of: editingPrompt) {
                    // Clear stale validation errors as user types
                    validationError = nil
                    showSavedConfirmation = false
                }

            // Validation hints and status
            HStack {
                Text("Must contain {{USER_TEXT}} placeholder")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if let error = validationError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .transition(.opacity)
                }
                if showSavedConfirmation {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Saved!")
                            .foregroundColor(.green)
                    }
                    .font(.caption)
                    .transition(.opacity)
                }
            }

            // Action buttons
            HStack {
                Button("Reset to Default") {
                    resetToDefault()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Save") {
                    savePrompt()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid || editingPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Divider()

            // History section
            Text("Prompt History")
                .font(.headline)

            if history.isEmpty {
                Text("No saved prompts yet. Save a prompt to start building history.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(history) { entry in
                            PromptHistoryRow(entry: entry) {
                                revertToEntry(entry)
                            }
                        }
                    }
                }
                .frame(maxHeight: 180)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 500, minHeight: 450)
        .onAppear {
            loadState()
        }
    }

    // MARK: - Info Popover

    private var promptInfoPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Prompt Best Practices")
                .font(.headline)

            Text("Example prompt structure:")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text("""
            [Describe the task in 1-2 sentences]

            Rules:
            - Output ONLY the refined text, nothing else.
            - [Add your specific rules here]

            [TEXT_START]
            {{USER_TEXT}}
            [TEXT_END]

            Refined text:
            """)
            .font(.system(.caption, design: .monospaced))
            .padding(10)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(6)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Label("Keep instructions short — smaller models follow shorter prompts better", systemImage: "lightbulb")
                Label("Always include {{USER_TEXT}} — this is where your selected text gets inserted", systemImage: "text.cursor")
                Label("The [TEXT_START]/[TEXT_END] delimiters help the model treat your text as data", systemImage: "shield")
                Label("End with \"Refined text:\" to prime the model to output immediately", systemImage: "arrow.right.circle")
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(16)
        .frame(width: 380)
    }

    // MARK: - Actions

    private func loadState() {
        editingPrompt = PromptStorage.shared.activePrompt
        history = PromptStorage.shared.history
    }

    private func savePrompt() {
        do {
            try PromptStorage.shared.saveCurrentPrompt(editingPrompt)
            history = PromptStorage.shared.history
            validationError = nil
            showSavedConfirmation = true

            // Auto-dismiss "Saved!" after 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                showSavedConfirmation = false
            }
        } catch {
            validationError = error.localizedDescription
        }
    }

    private func resetToDefault() {
        PromptStorage.shared.resetToDefault()
        editingPrompt = PromptStorage.shared.activePrompt
        history = PromptStorage.shared.history
        validationError = nil
        showSavedConfirmation = false
    }

    private func revertToEntry(_ entry: PromptStorage.PromptHistoryEntry) {
        PromptStorage.shared.revertToHistoryEntry(entry)
        editingPrompt = PromptStorage.shared.activePrompt
        // Don't refresh history — revert doesn't create a new entry
        validationError = nil
        showSavedConfirmation = false
    }
}

// MARK: - History Row

struct PromptHistoryRow: View {
    let entry: PromptStorage.PromptHistoryEntry
    let onRevert: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.savedAt, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(String(entry.prompt.prefix(100)) + (entry.prompt.count > 100 ? "..." : ""))
                    .font(.caption)
                    .foregroundColor(.primary)
                    .lineLimit(2)
            }

            Spacer()

            Button("Revert") {
                onRevert()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }
}
