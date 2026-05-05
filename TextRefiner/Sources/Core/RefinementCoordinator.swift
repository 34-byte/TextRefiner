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

    /// Maximum time (in nanoseconds) for inference to complete before auto-cancelling.
    /// 60 seconds is generous for the 3B model on M1; if it hasn't finished by then,
    /// something is stuck and the user shouldn't wait indefinitely.
    static let inferenceTimeoutNanoseconds: UInt64 = 60_000_000_000

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
                // Races inference against a 60s timeout — if inference stalls, the user
                // sees a "timed out" HUD instead of waiting forever.
                let inferenceTask = Task.detached { [inferenceService] in
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
                }

                let fullResponse: String
                do {
                    fullResponse = try await withThrowingTaskGroup(of: String.self) { group in
                        group.addTask {
                            try await inferenceTask.value
                        }
                        group.addTask {
                            try await Task.sleep(nanoseconds: Self.inferenceTimeoutNanoseconds)
                            throw RefinementError.inferenceTimedOut
                        }
                        // First task to finish wins — if inference completes, we get the
                        // result; if timeout fires first, it throws inferenceTimedOut.
                        let result = try await group.next()!
                        group.cancelAll()
                        return result
                    }
                } catch {
                    // Explicitly cancel the detached inference task so MLX stops
                    // generating tokens in the background. Critical: the detached task
                    // lives outside structured concurrency — group.cancelAll() won't
                    // reach it.
                    inferenceTask.cancel()
                    throw error
                }

                try Task.checkCancellation()

                // Record to history (lightweight — just appends + writes JSON)
                RefinementHistory.shared.add(
                    originalText: selectedText,
                    refinedText: fullResponse,
                    modelUsed: ModelManager.shared.selectedModelID
                )

                // Back on main thread — Step 3: Paste immediately.
                // If paste simulation fails, the refined text is still on the clipboard —
                // show a friendly message telling the user to paste manually.
                do {
                    try await AccessibilityService.pasteText(fullResponse)
                } catch {
                    throw RefinementError.pasteSimulationFailed
                }

                // Step 4: Brief pause to let the target app process the Cmd+V CGEvent before
                // showing the checkmark. pasteText() posts the event and returns immediately
                // (fire-and-forget); the target app renders the text change 10–100ms later.
                // 60ms covers native AppKit apps (~5–30ms) and most Electron apps (~40–80ms).
                try await Task.sleep(nanoseconds: 60_000_000)

                // Show green checkmark + play sound — visual confirmation the paste worked
                onRefinementComplete?()

                // Hold checkmark for 1 second so the user registers it
                try await Task.sleep(nanoseconds: UInt64(DesignTokens.Animation.successHold * 1_000_000_000))

                // Step 5: Dismiss everything
                onProcessingFinished?()

            } catch is CancellationError {
                // User pressed Escape — cancelRefinement() already handled UI cleanup.
                // Nothing to do here; just exit silently.
            } catch {
                onError?(error)
            }

            // Release the model from memory — no reason to hold 1.8 GB while idle.
            // Next refinement will reload from cache (~2-5s).
            Task.detached { [inferenceService] in
                // Short delay so the model isn't unloaded while the checkmark is still showing
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                inferenceService.unloadModel()
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
    case inferenceTimedOut
    case pasteSimulationFailed

    var errorDescription: String? {
        switch self {
        case .noTextSelected:         return "No text selected. Highlight text and try again."
        case .emptyResponse:          return "Model returned an empty response."
        case .inputTooLong(let count): return "Selected text is too long (\(count) characters). Please select 10,000 characters or fewer and try again."
        case .inferenceTimedOut:      return "Refinement timed out. Try selecting shorter text."
        case .pasteSimulationFailed:  return "Done! Press CMD + V to paste the new text"
        }
    }
}
