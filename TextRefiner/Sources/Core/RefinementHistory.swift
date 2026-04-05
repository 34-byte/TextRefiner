import Foundation

/// Stores the last 10 refinement results on disk.
/// Persists to ~/Library/Application Support/TextRefiner/history.json.
final class RefinementHistory {
    static let shared = RefinementHistory()

    // MARK: - Types

    struct Entry: Codable, Identifiable {
        let id: UUID
        let originalText: String
        let refinedText: String
        let modelUsed: String
        let timestamp: Date
    }

    // MARK: - State

    private var entries: [Entry]
    private let fileURL: URL
    private static let maxEntries = 10

    // MARK: - Public API

    /// All entries, newest first.
    var allEntries: [Entry] {
        entries.sorted { $0.timestamp > $1.timestamp }
    }

    /// Records a new refinement. Drops the oldest entry if count exceeds 10.
    func add(originalText: String, refinedText: String, modelUsed: String) {
        let entry = Entry(
            id: UUID(),
            originalText: originalText,
            refinedText: refinedText,
            modelUsed: modelUsed,
            timestamp: Date()
        )
        entries.append(entry)

        // Cap at maxEntries — drop oldest
        if entries.count > Self.maxEntries {
            let sorted = entries.sorted { $0.timestamp < $1.timestamp }
            entries = Array(sorted.suffix(Self.maxEntries))
        }

        persist()
    }

    /// Removes all history entries.
    func clearAll() {
        entries = []
        persist()
    }

    // MARK: - Init

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("TextRefiner", isDirectory: true)
        self.fileURL = appDir.appendingPathComponent("history.json")

        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

        if let jsonData = try? Data(contentsOf: fileURL),
           let decoded = try? Self.decoder.decode([Entry].self, from: jsonData) {
            self.entries = decoded
        } else {
            self.entries = []
        }
    }

    // MARK: - Persistence

    private func persist() {
        do {
            let encoded = try Self.encoder.encode(entries)
            try encoded.write(to: fileURL, options: .atomic)
        } catch {
            print("[TextRefiner] Failed to save history.json: \(error.localizedDescription)")
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
