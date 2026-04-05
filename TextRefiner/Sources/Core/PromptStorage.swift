import Foundation

/// Manages the active prompt and prompt history.
/// Persists to ~/Library/Application Support/TextRefiner/prompts.json.
/// Falls back to the built-in default prompt if the file is missing or corrupted.
final class PromptStorage {
    static let shared = PromptStorage()

    /// The improved default prompt — shorter than v1 for better adherence on small models.
    /// Uses [TEXT_START]/[TEXT_END] delimiters to isolate user text from instructions.
    /// Ends with "Refined text:" to prime the model to output immediately.
    static let defaultPrompt = """
    Fix grammar, spelling, and punctuation. Remove redundant words. Keep the original tone, structure, and meaning intact.

    Rules:
    - Output ONLY the refined text, nothing else.
    - Do NOT reorder sentences or add new content.
    - Do NOT change the author's voice or style.
    - If a sentence is already correct, leave it unchanged.

    [TEXT_START]
    {{USER_TEXT}}
    [TEXT_END]

    Refined text:
    """

    // MARK: - Storage Types

    struct PromptHistoryEntry: Codable, Identifiable {
        let id: UUID
        let prompt: String
        let savedAt: Date
    }

    private struct PromptData: Codable {
        var activePrompt: String
        var history: [PromptHistoryEntry]
    }

    // MARK: - State

    private var data: PromptData
    private let fileURL: URL
    private static let maxHistoryEntries = 20

    // MARK: - Public API

    /// The currently active prompt template. Must contain {{USER_TEXT}}.
    var activePrompt: String {
        get { data.activePrompt }
        set {
            data.activePrompt = newValue
            persist()
        }
    }

    /// All saved prompt history entries, newest first.
    var history: [PromptHistoryEntry] {
        data.history.sorted { $0.savedAt > $1.savedAt }
    }

    /// Validates that the prompt contains {{USER_TEXT}}, saves it as active,
    /// and appends a new history entry. Throws if validation fails.
    func saveCurrentPrompt(_ prompt: String) throws {
        guard prompt.contains("{{USER_TEXT}}") else {
            throw PromptValidationError.missingPlaceholder
        }

        data.activePrompt = prompt

        let entry = PromptHistoryEntry(
            id: UUID(),
            prompt: prompt,
            savedAt: Date()
        )
        data.history.append(entry)

        // Cap history at maxHistoryEntries — drop oldest entries
        if data.history.count > Self.maxHistoryEntries {
            let sorted = data.history.sorted { $0.savedAt < $1.savedAt }
            data.history = Array(sorted.suffix(Self.maxHistoryEntries))
        }

        persist()
    }

    /// Restores a historical prompt as active WITHOUT creating a new history entry.
    /// Use this for "revert" — the original entry stays in history as-is.
    func revertToHistoryEntry(_ entry: PromptHistoryEntry) {
        data.activePrompt = entry.prompt
        persist()
    }

    /// Resets to the built-in default prompt and creates a history entry
    /// so the user can undo the reset via revert.
    func resetToDefault() {
        // Save the current prompt to history before resetting, so nothing is lost
        let entry = PromptHistoryEntry(
            id: UUID(),
            prompt: data.activePrompt,
            savedAt: Date()
        )
        data.history.append(entry)

        // Cap history
        if data.history.count > Self.maxHistoryEntries {
            let sorted = data.history.sorted { $0.savedAt < $1.savedAt }
            data.history = Array(sorted.suffix(Self.maxHistoryEntries))
        }

        data.activePrompt = Self.defaultPrompt
        persist()
    }

    // MARK: - Init (loads from disk or creates default)

    private init() {
        // Build path: ~/Library/Application Support/TextRefiner/prompts.json
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("TextRefiner", isDirectory: true)
        self.fileURL = appDir.appendingPathComponent("prompts.json")

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

        // Load existing data or fall back to defaults
        if let jsonData = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder.withISO8601.decode(PromptData.self, from: jsonData) {
            self.data = decoded
        } else {
            // First launch or corrupted file — start fresh
            self.data = PromptData(activePrompt: Self.defaultPrompt, history: [])
        }
    }

    // MARK: - Persistence

    private func persist() {
        do {
            let encoded = try JSONEncoder.withISO8601.encode(data)
            try encoded.write(to: fileURL, options: .atomic)
        } catch {
            print("[TextRefiner] Failed to save prompts.json: \(error.localizedDescription)")
        }
    }
}

// MARK: - Errors

enum PromptValidationError: Error, LocalizedError {
    case missingPlaceholder

    var errorDescription: String? {
        switch self {
        case .missingPlaceholder:
            return "Prompt must contain {{USER_TEXT}} placeholder."
        }
    }
}

// MARK: - JSON Encoder/Decoder with ISO 8601 dates

private extension JSONEncoder {
    static let withISO8601: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

private extension JSONDecoder {
    static let withISO8601: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
