import Foundation

/// Communicates with the local Ollama REST API on localhost:11434.
/// Streams LLM responses token-by-token using URLSession.bytes for NDJSON parsing.
///
/// Model and prompt are no longer hardcoded — they are read from
/// `ModelManager.shared.selectedModelID` and `PromptStorage.shared.activePrompt`
/// at call time, so changes take effect on the next refinement without restarting.
final class OllamaService {
    private let baseURL = URL(string: "http://localhost:11434")!
    private let session: URLSession

    /// Reads the active prompt from PromptStorage at call time.
    /// This ensures any changes made in Prompt Settings take effect immediately.
    private var promptTemplate: String {
        PromptStorage.shared.activePrompt
    }

    /// Reads the selected model from ModelManager at call time.
    /// This ensures model picker changes take effect on the next refinement.
    private var modelID: String {
        ModelManager.shared.selectedModelID
    }

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    // MARK: - Health Check

    /// Pre-warms the connection by hitting /api/tags.
    /// Call this on app launch so first use doesn't pay connection setup cost.
    func prewarm() async {
        let url = baseURL.appendingPathComponent("api/tags")
        _ = try? await session.data(from: url)
    }

    /// Returns true if Ollama is reachable on localhost:11434.
    func isAvailable() async -> Bool {
        let url = baseURL.appendingPathComponent("api/tags")
        do {
            let (_, response) = try await session.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Model Management

    /// Returns true if the specified model (or the currently selected model) is downloaded.
    /// Uses prefix matching because Ollama sometimes appends ":latest" or hash suffixes.
    func isModelAvailable(modelID: String? = nil) async -> Bool {
        let target = modelID ?? self.modelID
        let url = baseURL.appendingPathComponent("api/tags")
        do {
            let (data, _) = try await session.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [[String: Any]] {
                return models.contains { model in
                    if let name = model["name"] as? String {
                        return name.hasPrefix(target)
                    }
                    return false
                }
            }
        } catch {}
        return false
    }

    /// Returns the names of all models downloaded in Ollama.
    func fetchAvailableModels() async -> [String] {
        let url = baseURL.appendingPathComponent("api/tags")
        do {
            let (data, _) = try await session.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [[String: Any]] {
                return models.compactMap { $0["name"] as? String }
            }
        } catch {}
        return []
    }

    /// Pulls a model from Ollama's registry. Reports progress via callback.
    /// If no name is provided, pulls the currently selected model.
    /// This is a long-running operation — download sizes range from ~1 GB to ~13 GB.
    func pullModel(name: String? = nil, progress: @escaping (String) -> Void) async throws {
        let targetModel = name ?? self.modelID
        let url = baseURL.appendingPathComponent("api/pull")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Long timeout — model download can take many minutes
        request.timeoutInterval = 3600

        let body: [String: Any] = ["name": targetModel]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 3600
        config.timeoutIntervalForResource = 3600
        let longSession = URLSession(configuration: config)

        let (bytes, response) = try await longSession.bytes(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OllamaError.serverError
        }

        for try await line in bytes.lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            // Parse progress from the pull response
            if let status = json["status"] as? String {
                if let total = json["total"] as? Int64, total > 0,
                   let completed = json["completed"] as? Int64 {
                    let pct = Int(Double(completed) / Double(total) * 100)
                    progress("Downloading \(targetModel): \(pct)%")
                } else {
                    progress(status)
                }
            }
        }
    }

    /// Deletes a model from Ollama to free storage.
    /// Calls DELETE /api/delete with the model name.
    func deleteModel(name: String) async throws {
        let url = baseURL.appendingPathComponent("api/delete")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["name": name]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OllamaError.serverError
        }
    }

    // MARK: - Response Post-Processing

    /// Strips prompt artifacts that small models may leak in their output.
    /// Called after full response accumulation (not per-token) to avoid mid-word false positives.
    ///
    /// Known failure modes for small models with no system/user role separation:
    /// 1. Closing anchor echo: "Refined text:" or "Rewritten text:" at the start of output
    /// 2. Delimiter leakage: [TEXT_START] or [TEXT_END] echoed in output
    /// 3. Quote wrapping: model wraps output in "double quotes"
    /// 4. Preamble: "Here is..." or "Sure," before the actual rewrite
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

    // MARK: - Streaming Rewrite

    /// Sends text to Ollama and streams back rewritten tokens.
    /// Uses the currently selected model and active prompt from their respective managers.
    /// Returns an AsyncThrowingStream that yields individual tokens as they arrive.
    func streamRewrite(text: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let url = baseURL.appendingPathComponent("api/generate")
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    // Inject user text into the template between [TEXT_START] and [TEXT_END].
                    // This is safer than direct concatenation — delimiters separate instructions from data.
                    let fullPrompt = self.promptTemplate.replacingOccurrences(of: "{{USER_TEXT}}", with: text)

                    let body: [String: Any] = [
                        "model": self.modelID,
                        "prompt": fullPrompt,
                        "stream": true
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await self.session.bytes(for: request)

                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        continuation.finish(throwing: OllamaError.serverError)
                        return
                    }

                    // Ollama streams NDJSON — one JSON object per line
                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let token = json["response"] as? String else {
                            continue
                        }

                        continuation.yield(token)

                        if let done = json["done"] as? Bool, done {
                            break
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

enum OllamaError: Error, LocalizedError {
    case serverError
    case notRunning

    var errorDescription: String? {
        switch self {
        case .serverError: return "Ollama returned an error."
        case .notRunning: return "Could not connect to Ollama. Is it running?"
        }
    }
}
