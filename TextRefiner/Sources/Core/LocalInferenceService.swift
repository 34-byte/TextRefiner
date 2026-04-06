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
    static let modelConfiguration = LLMRegistry.llama3_2_3B_4bit

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

                    // Inject user text into the template
                    let fullPrompt = self.promptTemplate.replacingOccurrences(of: "{{USER_TEXT}}", with: text)

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

    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded: return "AI model not downloaded. Please restart TextRefiner to download it."
        case .modelLoadFailed(let msg): return "Failed to load AI model: \(msg)"
        case .generationFailed(let msg): return "Text generation failed: \(msg)"
        }
    }
}
