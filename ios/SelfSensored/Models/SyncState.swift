import Foundation

/// Tracks the last successful sync timestamp per data type.
/// UserDefaults is thread-safe but not marked Sendable by Apple.
final class SyncState: @unchecked Sendable {
    static let shared = SyncState()

    private let defaults = UserDefaults.standard
    private let prefix = "sync_last_"

    private init() {}

    func lastSync(for typeIdentifier: String) -> Date? {
        let interval = defaults.double(forKey: "\(prefix)\(typeIdentifier)")
        return interval > 0 ? Date(timeIntervalSince1970: interval) : nil
    }

    func markSynced(typeIdentifier: String, at date: Date = .now) {
        defaults.set(date.timeIntervalSince1970, forKey: "\(prefix)\(typeIdentifier)")
    }
}
