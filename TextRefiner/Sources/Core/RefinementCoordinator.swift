import Cocoa

/// Orchestrates the entire refinement flow:
/// 1. Check Accessibility permission (fast-fail before anything starts)
/// 2. Simulate Cmd+C to capture selected text
/// 3. Send to local MLX model for rewriting (OFF main thread — prevents system freeze)
/// 4. Paste refined text immediately when ready
/// 5. Show green checkmark for 1s as visual confirmation, then dismiss
///
/// All other components are stateless services this coordinator calls into.
final class RefinementCoordinator {
    let inferenceService = LocalInferenceService()

    // MARK: - Callbacks (set by AppDelegate to wire UI)

    /// Fired when processing begins — show spinner panel.
    var onProcessingStarted: (() -> Void)?

    /// Fired when model returns the full rewritten text and we're about to paste.
    /// Use this to show the success checkmark before the 1s hold.
    var onRefinementComplete: (() -> Void)?

    /// Fired after paste is done — dismiss panel, hide menu bar spinner.
    var onProcessingFinished: (() -> Void)?

    /// Fired when Accessibility permission is missing. No spinner is shown.
    var onPermissionDenied: (() -> Void)?

    /// Fired on any other error (model not loaded, empty response, etc.)
    var onError: ((Error) -> Void)?

    /// Maximum input length in characters (~2,000 words).
    /// Inputs beyond this exceed the model's useful context window.
    /// Referenced by TypingMonitor to hide the ready pill above this limit.
    static let maxInputCharacters = 10_000

    /// Fired when the user cancels a refinement in progress (Escape key).
    /// Dismiss spinner/panel, no text replacement.
    var onRefinementCancelled: (() -> Void)?

    /// Guards against double-trigger if user presses ⌘⇧R while already processing.
    private var isProcessing = false

    /// Stored reference to the active refinement task so it can be cancelled.
    private var refinementTask: Task<Void, Never>?

    // MARK: - Cancel

    /// Cancels the in-progress refinement immediately. No text is pasted.
    /// Called when the user presses Escape during processing.
    func cancelRefinement() {
        guard isProcessing else { return }
        refinementTask?.cancel()
        refinementTask = nil
        isProcessing = false
        onRefinementCancelled?()
    }

    // MARK: - Main Flow

    func startRefinement() {
        // Guard 1: Don't start if already processing
        guard !isProcessing else { return }

        // Guard 2: Fail fast — no spinner, no inference call if permission is missing.
        guard AccessibilityService.isTrusted() else {
            onPermissionDenied?()
            return
        }

        isProcessing = true

        refinementTask = Task { @MainActor in
            onProcessingStarted?()

            do {
                // Step 1: Simulate Cmd+C, read selected text from pasteboard.
                // Must run on main thread (pasteboard + CGEvent posting).
                guard let selectedText = await AccessibilityService.simulateCopyAndRead(),
                      !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw RefinementError.noTextSelected
                }

                try Task.checkCancellation()

                guard selectedText.count <= Self.maxInputCharacters else {
                    throw RefinementError.inputTooLong(selectedText.count)
                }

                // Step 2: Stream from local model on a BACKGROUND thread.
                // This prevents the model loading / inference from blocking the main
                // thread and freezing the entire Mac (especially on shared-memory M1).
                let fullResponse = try await Task.detached { [inferenceService] in
                    var accumulated = ""
                    let stream = inferenceService.streamRewrite(text: selectedText)

                    for try await token in stream {
                        try Task.checkCancellation()
                        accumulated += token
                    }

                    guard !accumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw RefinementError.emptyResponse
                    }

                    // Post-process: strip any prompt artifacts (leaked delimiters,
                    // closing anchor, preamble, wrapping quotes) before pasting.
                    return inferenceService.cleanResponse(accumulated)
                }.value

                try Task.checkCancellation()

                // Record to history (lightweight — just appends + writes JSON)
                RefinementHistory.shared.add(
                    originalText: selectedText,
                    refinedText: fullResponse,
                    modelUsed: ModelManager.shared.selectedModelID
                )

                // Back on main thread — Step 3: Paste immediately
                AccessibilityService.pasteText(fullResponse)

                // Let the paste event settle before showing confirmation
                try await Task.sleep(nanoseconds: 200_000_000) // 200ms

                // Step 4: Show green checkmark — visual confirmation the paste worked
                onRefinementComplete?()

                // Hold checkmark for 1 second so the user registers it
                try await Task.sleep(nanoseconds: 1_000_000_000)

                // Step 5: Dismiss everything
                onProcessingFinished?()

            } catch is CancellationError {
                // User pressed Escape — cancelRefinement() already handled UI cleanup.
                // Nothing to do here; just exit silently.
            } catch {
                onError?(error)
            }

            refinementTask = nil
            isProcessing = false
        }
    }
}

enum RefinementError: Error, LocalizedError {
    case noTextSelected
    case emptyResponse
    case inputTooLong(Int)

    var errorDescription: String? {
        switch self {
        case .noTextSelected:         return "No text selected. Highlight text and try again."
        case .emptyResponse:          return "Model returned an empty response."
        case .inputTooLong(let count): return "Selected text is too long (\(count) characters). Please select 10,000 characters or fewer and try again."
        }
    }
}
