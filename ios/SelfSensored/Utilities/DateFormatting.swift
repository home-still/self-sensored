import Foundation

enum ISO8601 {
    /// Thread-safe ISO 8601 formatter matching the API's expected date format.
    nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

extension Date {
    var iso8601String: String {
        ISO8601.formatter.string(from: self)
    }
}
