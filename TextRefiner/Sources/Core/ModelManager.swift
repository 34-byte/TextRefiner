import Foundation

/// Manages model selection and the curated list of recommended Ollama models.
/// Persists the selected model ID in UserDefaults.
final class ModelManager {
    static let shared = ModelManager()

    // MARK: - Model Definition

    struct RecommendedModel {
        let id: String          // Ollama model tag, e.g. "llama3.2:3b"
        let displayName: String // Human-friendly name, e.g. "Llama 3.2 (3B)"
        let size: String        // Approximate download size, e.g. "~2.0 GB"
        let isDefault: Bool     // Whether this is the recommended default
    }

    // MARK: - Curated Model List

    /// Models ordered by size — smallest to largest.
    /// The default (recommended) model is llama3.2:3b — good balance of speed and quality.
    static let recommendedModels: [RecommendedModel] = [
        RecommendedModel(id: "llama3.2:1b",  displayName: "Llama 3.2 (1B)",  size: "~1.3 GB", isDefault: false),
        RecommendedModel(id: "llama3.2:3b",  displayName: "Llama 3.2 (3B)",  size: "~2.0 GB", isDefault: true),
        RecommendedModel(id: "qwen2.5:3b",   displayName: "Qwen 2.5 (3B)",   size: "~1.9 GB", isDefault: false),
        RecommendedModel(id: "phi4-mini",     displayName: "Phi-4 Mini",       size: "~2.5 GB", isDefault: false),
        RecommendedModel(id: "gemma3:4b",     displayName: "Gemma 3 (4B)",     size: "~3.3 GB", isDefault: false),
        RecommendedModel(id: "llama3.1:8b",   displayName: "Llama 3.1 (8B)",   size: "~4.7 GB", isDefault: false),
        RecommendedModel(id: "mistral:7b",    displayName: "Mistral (7B)",     size: "~4.1 GB", isDefault: false),
        RecommendedModel(id: "gpt-oss:20b",   displayName: "GPT-OSS (20B)",    size: "~13 GB",  isDefault: false),
    ]

    /// The default model ID — used when no selection has been made yet.
    static let defaultModelID = "llama3.2:3b"

    // MARK: - Selected Model (persisted)

    private let selectedModelKey = "com.textrefiner.selectedModel"

    /// The currently selected model ID. Persisted in UserDefaults.
    /// Falls back to `defaultModelID` if nothing is saved.
    var selectedModelID: String {
        get { UserDefaults.standard.string(forKey: selectedModelKey) ?? Self.defaultModelID }
        set { UserDefaults.standard.set(newValue, forKey: selectedModelKey) }
    }

    /// Returns the RecommendedModel struct for the currently selected model.
    var selectedModel: RecommendedModel? {
        Self.recommendedModels.first { $0.id == selectedModelID }
    }

    // MARK: - Ollama Model Queries

    /// Queries Ollama /api/tags and returns the set of downloaded model ID prefixes.
    /// Returns an empty set if Ollama is unreachable.
    func fetchDownloadedModels() async -> Set<String> {
        let url = URL(string: "http://localhost:11434/api/tags")!
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5  // Fast timeout — localhost should respond instantly
        let session = URLSession(configuration: config)

        do {
            let (data, _) = try await session.data(from: url)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else {
                return []
            }

            var downloaded = Set<String>()
            for model in models {
                if let name = model["name"] as? String {
                    // Match against our curated list using prefix matching
                    // (Ollama sometimes appends hash suffixes like ":latest")
                    for recommended in Self.recommendedModels {
                        if name.hasPrefix(recommended.id) || name == recommended.id {
                            downloaded.insert(recommended.id)
                        }
                    }
                }
            }
            return downloaded
        } catch {
            return []
        }
    }

    // MARK: - Init

    private init() {}
}
