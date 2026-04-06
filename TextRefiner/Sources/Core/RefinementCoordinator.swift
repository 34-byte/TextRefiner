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

    /// Guards against double-trigger if user presses ⌘⇧R while already processing.
    private var isProcessing = false

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

        Task { @MainActor in
            onProcessingStarted?()

            do {
                // Step 1: Simulate Cmd+C, read selected text from pasteboard.
                // Must run on main thread (pasteboard + CGEvent posting).
                guard let selectedText = await AccessibilityService.simulateCopyAndRead(),
                      !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw RefinementError.noTextSelected
                }

                // Step 2: Stream from local model on a BACKGROUND thread.
                // This prevents the model loading / inference from blocking the main
                // thread and freezing the entire Mac (especially on shared-memory M1).
                let fullResponse = try await Task.detached { [inferenceService] in
                    var accumulated = ""
                    let stream = inferenceService.streamRewrite(text: selectedText)

                    for try await token in stream {
                        accumulated += token
                    }

                    guard !accumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw RefinementError.emptyResponse
                    }

                    // Post-process: strip any prompt artifacts (leaked delimiters,
                    // closing anchor, preamble, wrapping quotes) before pasting.
                    return inferenceService.cleanResponse(accumulated)
                }.value

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

            } catch {
                onError?(error)
            }

            isProcessing = false
        }
    }
}

enum RefinementError: Error, LocalizedError {
    case noTextSelected
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .noTextSelected: return "No text selected. Highlight text and try again."
        case .emptyResponse:  return "Model returned an empty response."
        }
    }
}
