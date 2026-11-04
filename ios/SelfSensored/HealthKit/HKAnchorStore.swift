import HealthKit

/// Seam for persisting/loading per-type HK anchors. Lets the sync pipeline
/// be driven against an in-memory fake in unit tests without touching
/// shared `UserDefaults` state.
protocol HKAnchorStoring: Sendable {
    func load(for sampleType: HKSampleType) -> HKQueryAnchor?
    func save(_ anchor: HKQueryAnchor, for sampleType: HKSampleType)
    func remove(for sampleType: HKSampleType)
}

/// Persists HKQueryAnchor per sample type in UserDefaults.
/// UserDefaults is thread-safe but not marked Sendable by Apple.
final class HKAnchorStore: HKAnchorStoring, @unchecked Sendable {
    static let shared = HKAnchorStore()

    private let defaults = UserDefaults.standard
    private let prefix = "hk_anchor_"

    private init() {}

    func load(for sampleType: HKSampleType) -> HKQueryAnchor? {
        guard let data = defaults.data(forKey: key(for: sampleType)) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: HKQueryAnchor.self,
            from: data
        )
    }

    func save(_ anchor: HKQueryAnchor, for sampleType: HKSampleType) {
        guard let data = try? NSKeyedArchiver.archivedData(
            withRootObject: anchor,
            requiringSecureCoding: true
        ) else { return }
        defaults.set(data, forKey: key(for: sampleType))
    }

    func remove(for sampleType: HKSampleType) {
        defaults.removeObject(forKey: key(for: sampleType))
    }

    func resetAll() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }

    private func key(for sampleType: HKSampleType) -> String {
        "\(prefix)\(sampleType.identifier)"
    }
}
