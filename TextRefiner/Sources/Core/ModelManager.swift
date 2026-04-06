import Foundation

/// Single-model constants for the embedded MLX inference engine.
/// TextRefiner ships with one model — no user selection needed.
final class ModelManager {
    static let shared = ModelManager()

    /// Hugging Face model ID used by LocalInferenceService.
    static let modelID = "mlx-community/Llama-3.2-3B-Instruct-4bit"

    /// Human-friendly name for display in UI.
    static let displayName = "Llama 3.2 (3B)"

    /// Approximate download size for user-facing messages.
    static let modelSize = "~1.8 GB"

    /// Read-only — always returns the single supported model.
    /// Keeps call sites in RefinementCoordinator and HistoryWindowController unchanged.
    var selectedModelID: String { Self.modelID }

    private init() {}
}
