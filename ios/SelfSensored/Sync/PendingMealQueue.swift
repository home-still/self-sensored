import Foundation

/// On-disk queue of meal-parse requests that couldn't reach the server. Each
/// successful `parseMeal` call drains the queue in FIFO order.
///
/// Bounds: entries older than 7 days are discarded on load so a phone left
/// offline for a month doesn't flood the server with stale logs.
actor PendingMealQueue {
    static let shared = PendingMealQueue()

    struct Entry: Codable, Sendable {
        let text: String
        let mealType: String
        let createdAt: Date
    }

    private var entries: [Entry] = []
    private let maxAge: TimeInterval = 7 * 24 * 60 * 60
    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.init(fileURL: dir.appendingPathComponent("pending_meals.json"))
    }

    /// Test-friendly initializer that lets callers point the queue at a
    /// throwaway path (typically inside `NSTemporaryDirectory()`).
    init(fileURL: URL) {
        self.fileURL = fileURL

        // Hydrate from disk inline so the actor is usable immediately without a
        // pending async init. Stale entries (> maxAge) are dropped here.
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder.iso8601().decode([Entry].self, from: data) {
            let cutoff = Date().addingTimeInterval(-maxAge)
            self.entries = decoded.filter { $0.createdAt >= cutoff }
        }
    }

    /// Snapshot the current queue contents — used by tests.
    func snapshot() -> [Entry] {
        entries
    }

    func enqueue(_ entry: Entry) {
        entries.append(entry)
        persist()
    }

    /// Replay every queued entry through `parseMeal`. Entries that still fail
    /// with a network error are re-queued for the next drain; non-network
    /// failures (4xx/5xx) are dropped because retrying won't help.
    func drain(apiClient: APIClient) async {
        guard !entries.isEmpty else { return }
        let batch = entries
        entries.removeAll()
        persist()

        for entry in batch {
            do {
                _ = try await apiClient.parseMeal(text: entry.text, mealType: entry.mealType)
            } catch {
                if APIClient.isNetworkError(error) {
                    entries.append(entry)
                }
            }
        }
        persist()
    }

    private func persist() {
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        guard let data = try? JSONEncoder.iso8601().encode(entries) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

private extension JSONEncoder {
    static func iso8601() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

private extension JSONDecoder {
    static func iso8601() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
