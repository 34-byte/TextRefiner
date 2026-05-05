import CryptoKit
import Foundation
import Security

/// Stores the last 10 refinement results on disk, encrypted.
/// History data: ~/Library/Application Support/TextRefiner/history.json (AES-GCM encrypted)
/// Encryption key: macOS Keychain (service: com.textrefiner.app, account: history-encryption-key)
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

    private static let keychainService = "com.textrefiner.app"
    private static let keychainAccount = "history-encryption-key"

    private func getOrCreateKey() throws -> SymmetricKey {
        // --- One-time migration: move legacy .history-key file into Keychain ---
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        let legacyKeyURL = appSupport
            .appendingPathComponent("TextRefiner", isDirectory: true)
            .appendingPathComponent(".history-key")

        if FileManager.default.fileExists(atPath: legacyKeyURL.path),
           let legacyData = try? Data(contentsOf: legacyKeyURL) {
            let status = saveKeyToKeychain(legacyData)
            if status == errSecSuccess || status == errSecDuplicateItem {
                try? FileManager.default.removeItem(at: legacyKeyURL)
                return SymmetricKey(data: legacyData)
            }
            // Keychain write failed — fall back to file for this session
            #if DEBUG
            print("[TextRefiner] Keychain migration failed (\(status)), using file key as fallback")
            #endif
            return SymmetricKey(data: legacyData)
        }

        // --- Try Data Protection Keychain first (no app-specific ACL, no password prompts) ---
        let dpQuery: [CFString: Any] = [
            kSecClass:                     kSecClassGenericPassword,
            kSecAttrService:               Self.keychainService,
            kSecAttrAccount:               Self.keychainAccount,
            kSecUseDataProtectionKeychain: true,
            kSecReturnData:                true,
            kSecMatchLimit:                kSecMatchLimitOne,
        ]
        var dpResult: AnyObject?
        if SecItemCopyMatching(dpQuery as CFDictionary, &dpResult) == errSecSuccess,
           let data = dpResult as? Data {
            return SymmetricKey(data: data)
        }

        // --- Migrate from login.keychain if present (prompts once, then moves to DP Keychain) ---
        let legacyQuery: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: Self.keychainAccount,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne,
        ]
        var legacyResult: AnyObject?
        if SecItemCopyMatching(legacyQuery as CFDictionary, &legacyResult) == errSecSuccess,
           let data = legacyResult as? Data {
            let deleteQuery: [CFString: Any] = [
                kSecClass:       kSecClassGenericPassword,
                kSecAttrService: Self.keychainService,
                kSecAttrAccount: Self.keychainAccount,
            ]
            SecItemDelete(deleteQuery as CFDictionary)
            _ = saveKeyToKeychain(data)
            return SymmetricKey(data: data)
        }

        // --- Key not found: generate a new one and store it ---
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        let addStatus = saveKeyToKeychain(keyData)
        guard addStatus == errSecSuccess else {
            throw KeychainError.saveFailed(addStatus)
        }
        return key
    }

    @discardableResult
    private func saveKeyToKeychain(_ keyData: Data) -> OSStatus {
        let attributes: [CFString: Any] = [
            kSecClass:                     kSecClassGenericPassword,
            kSecAttrService:               Self.keychainService,
            kSecAttrAccount:               Self.keychainAccount,
            kSecAttrAccessible:            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecUseDataProtectionKeychain: true,
            kSecValueData:                 keyData,
        ]
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    private enum KeychainError: Error {
        case saveFailed(OSStatus)
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
            #if DEBUG
            print("[TextRefiner] Failed to save history.json: \(error.localizedDescription)")
            #endif
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
