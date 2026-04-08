import CryptoKit
import Foundation
import Hub
import MLX
import MLXLLM
import MLXLMCommon
import MLXRandom // Part of the MLX package

/// Runs LLM inference locally using Apple MLX on Apple Silicon.
/// Replaces OllamaService — no external process needed.
///
/// Model and prompt are read at call time so changes in Settings take effect
/// on the next refinement without restarting.
final class LocalInferenceService: @unchecked Sendable {

    /// The single model used by TextRefiner.
    /// Pinned to a specific commit so the downloaded files are immutable — any substitution
    /// or tampering is caught by verifyConfigIntegrity() before inference runs.
    static let modelConfiguration = ModelConfiguration(
        id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
        revision: "7f0dc925e0d0afb0322d96f9255cfddf2ba5636e"
    )

    /// SHA-256 of config.json at the pinned revision (captured 2026-04-08).
    private static let configIntegrityHash = "c546925585e48f43890d9dc5150df4fec73dd3780d92961c5ace451934cc4cd6"

    /// Where model files are cached on disk.
    /// ~/Library/Application Support/TextRefiner/models/
    private static var modelCacheURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("TextRefiner").appendingPathComponent("models")
    }

    /// The loaded model container — nil until loadModel() is called.
    private var modelContainer: ModelContainer?

    /// Reads the active prompt from PromptStorage at call time.
    private var promptTemplate: String {
        PromptStorage.shared.activePrompt
    }

    // MARK: - Model Management

    /// Checks whether model weights exist on disk.
    func isModelDownloaded() -> Bool {
        let hub = HubApi(downloadBase: Self.modelCacheURL)
        let modelDir = Self.modelConfiguration.modelDirectory(hub: hub)
        let fm = FileManager.default
        guard fm.fileExists(atPath: modelDir.path) else { return false }
        let contents = (try? fm.contentsOfDirectory(atPath: modelDir.path)) ?? []
        return contents.contains { $0.hasSuffix(".safetensors") }
    }

    /// Verifies that config.json in the local model directory matches the pinned SHA-256.
    /// Throws `integrityCheckFailed` and deletes the model directory if the hash doesn't match,
    /// forcing a clean re-download on the next launch.
    func verifyConfigIntegrity() throws {
        let hub = HubApi(downloadBase: Self.modelCacheURL)
        let modelDir = Self.modelConfiguration.modelDirectory(hub: hub)
        let configURL = modelDir.appendingPathComponent("config.json")

        guard let data = try? Data(contentsOf: configURL) else {
            // config.json missing — model is incomplete; let the download path handle it
            return
        }

        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()

        guard hex == Self.configIntegrityHash else {
            // Hash mismatch — delete the model directory to force a clean re-download
            try? FileManager.default.removeItem(at: Self.modelCacheURL)
            throw InferenceError.integrityCheckFailed
        }
    }

    /// Downloads the model from Hugging Face with progress reporting.
    func downloadModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        let hub = HubApi(downloadBase: Self.modelCacheURL)

        _ = try await MLXLMCommon.downloadModel(
            hub: hub,
            configuration: Self.modelConfiguration
        ) { p in
            progress(p.fractionCompleted)
        }
    }

    /// Loads the model into memory. Must be called before inference.
    func loadModel() async throws {
        guard modelContainer == nil else { return }

        Memory.cacheLimit = 20 * 1024 * 1024

        let hub = HubApi(downloadBase: Self.modelCacheURL)
        let container = try await LLMModelFactory.shared.loadContainer(
            hub: hub,
            configuration: Self.modelConfiguration
        ) { _ in }

        self.modelContainer = container
    }

    /// Removes the model files from disk and unloads from memory.
    func deleteModel() throws {
        modelContainer = nil
        let fm = FileManager.default
        if fm.fileExists(atPath: Self.modelCacheURL.path) {
            try fm.removeItem(at: Self.modelCacheURL)
        }
    }

    // MARK: - Streaming Rewrite

    /// Sends text to the local model and streams back rewritten tokens.
    /// Uses the active prompt from PromptStorage at call time.
    /// Returns an AsyncThrowingStream that yields individual text chunks as they arrive.
    func streamRewrite(text: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    // Ensure model is loaded
                    if self.modelContainer == nil {
                        guard self.isModelDownloaded() else {
                            throw InferenceError.modelNotDownloaded
                        }
                        try await self.loadModel()
                    }

                    guard let container = self.modelContainer else {
                        throw InferenceError.modelLoadFailed("Model container is nil after loading.")
                    }

                    // Strip delimiter strings from clipboard content before injection —
                    // prevents crafted clipboard text from breaking the prompt structure
                    // or echoing delimiters into the output (prompt injection hardening).
                    let sanitizedText = text
                        .replacingOccurrences(of: "[TEXT_START]", with: "")
                        .replacingOccurrences(of: "[TEXT_END]", with: "")
                        .replacingOccurrences(of: "{{USER_TEXT}}", with: "")

                    // Inject user text into the template
                    let fullPrompt = self.promptTemplate.replacingOccurrences(of: "{{USER_TEXT}}", with: sanitizedText)

                    // Build chat messages — the tokenizer applies the model's chat template
                    let userInput = UserInput(
                        chat: [.user(fullPrompt)]
                    )

                    // Seed random generator for varied output
                    MLXRandom.seed(UInt64(Date.timeIntervalSinceReferenceDate * 1000))

                    let lmInput = try await container.prepare(input: userInput)
                    let parameters = GenerateParameters(maxTokens: 2048, temperature: 0.7)
                    let stream = try await container.generate(input: lmInput, parameters: parameters)

                    for await generation in stream {
                        if let chunk = generation.chunk, !chunk.isEmpty {
                            continuation.yield(chunk)
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Response Post-Processing

    /// Strips prompt artifacts that small models may leak in their output.
    /// Called after full response accumulation (not per-token) to avoid mid-word false positives.
    func cleanResponse(_ raw: String) -> String {
        var result = raw

        // Strip leaked closing anchors (most common artifact)
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("Rewritten text:") {
            result = String(trimmed.dropFirst("Rewritten text:".count))
        }
        let trimmed2 = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed2.hasPrefix("Refined text:") {
            result = String(trimmed2.dropFirst("Refined text:".count))
        }

        // Strip preamble phrases (small models sometimes add these despite instructions)
        let preambles = ["Here is the rewritten text:", "Here's the rewritten text:",
                         "Here is the refined text:", "Here's the refined text:",
                         "Sure,", "Sure!", "Certainly,", "Certainly!",
                         "Here is the rewritten version:", "Here's the rewritten version:",
                         "Here is the refined version:", "Here's the refined version:"]
        for preamble in preambles {
            let check = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if check.hasPrefix(preamble) {
                result = String(check.dropFirst(preamble.count))
            }
        }

        // Strip leaked delimiters
        result = result.replacingOccurrences(of: "[TEXT_START]", with: "")
        result = result.replacingOccurrences(of: "[TEXT_END]", with: "")

        // Trim whitespace
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove wrapping quotes (model sometimes wraps output in quotes)
        if result.count >= 2,
           result.hasPrefix("\"") && result.hasSuffix("\"") {
            result = String(result.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return result
    }
}

enum InferenceError: Error, LocalizedError {
    case modelNotDownloaded
    case modelLoadFailed(String)
    case generationFailed(String)
    case integrityCheckFailed

    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded: return "AI model not downloaded. Please restart TextRefiner to download it."
        case .modelLoadFailed(let msg): return "Failed to load AI model: \(msg)"
        case .generationFailed(let msg): return "Text generation failed: \(msg)"
        case .integrityCheckFailed: return "AI model integrity check failed. The model files have been removed and will be re-downloaded on next launch."
        }
    }
}
