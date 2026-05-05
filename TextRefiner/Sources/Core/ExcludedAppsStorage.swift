import Foundation

/// Stores user-selected apps where the typing indicator pill is suppressed.
/// The hotkey continues to work in excluded apps — only the pill is hidden.
final class ExcludedAppsStorage {

    static let shared = ExcludedAppsStorage()

    private static let defaultsKey = "com.textrefiner.excludedBundleIDs"
    private let defaults = UserDefaults.standard

    private init() {}

    func add(name: String, bundleID: String) {
        var entries = readRaw()
        // Deduplicate by bundle ID — adding the same app twice is a no-op.
        guard !entries.contains(where: { $0["bundleID"] == bundleID }) else { return }
        entries.append(["name": name, "bundleID": bundleID])
        defaults.set(entries, forKey: Self.defaultsKey)
    }

    func remove(bundleID: String) {
        let entries = readRaw().filter { $0["bundleID"] != bundleID }
        defaults.set(entries, forKey: Self.defaultsKey)
    }

    func contains(_ bundleID: String) -> Bool {
        readRaw().contains(where: { $0["bundleID"] == bundleID })
    }

    func all() -> [(name: String, bundleID: String)] {
        readRaw().compactMap { entry in
            guard let name = entry["name"], let bundleID = entry["bundleID"] else { return nil }
            return (name: name, bundleID: bundleID)
        }
    }

    private func readRaw() -> [[String: String]] {
        defaults.array(forKey: Self.defaultsKey) as? [[String: String]] ?? []
    }
}
