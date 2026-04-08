import CryptoKit
import Foundation

/// Stores the last 10 refinement results on disk, encrypted.
/// History data: ~/Library/Application Support/TextRefiner/history.json (AES-GCM encrypted)
/// Encryption key: ~/Library/Application Support/TextRefiner/.history-key (0600 permissions)
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
    private let keyURL: URL
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
        self.keyURL = appDir.appendingPathComponent(".history-key")

        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

        self.entries = [] // satisfies Swift's init requirement; overwritten below if data loads

        if let rawData = try? Data(contentsOf: fileURL) {
            // Try encrypted format first (normal path after first migration)
            if let key = try? getOrCreateKey(),
               let sealedBox = try? AES.GCM.SealedBox(combined: rawData),
               let decrypted = try? AES.GCM.open(sealedBox, using: key),
               let decoded = try? Self.decoder.decode([Entry].self, from: decrypted) {
                self.entries = decoded
                return
            }
            // Fallback: try plaintext JSON (one-time migration from old unencrypted format)
            if let decoded = try? Self.decoder.decode([Entry].self, from: rawData) {
                self.entries = decoded
                persist() // re-save encrypted immediately
                return
            }
        }
        self.entries = []
    }

    // MARK: - Encryption

    private func getOrCreateKey() throws -> SymmetricKey {
        if let keyData = try? Data(contentsOf: keyURL) {
            return SymmetricKey(data: keyData)
        }
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        try keyData.write(to: keyURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        return key
    }

    // MARK: - Persistence

    private func persist() {
        do {
            let key = try getOrCreateKey()
            let encoded = try Self.encoder.encode(entries)
            let sealedBox = try AES.GCM.seal(encoded, using: key)
            guard let combined = sealedBox.combined else { return }
            try combined.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
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
