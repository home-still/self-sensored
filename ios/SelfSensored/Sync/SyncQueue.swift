import HealthKit

/// File-backed queue of sample types that failed to sync, plus the
/// success/failure timestamps the watchdog uses to decide when sync has
/// stalled badly enough to bother the user.
actor SyncQueue {
    static let shared = SyncQueue()

    private var pending: Set<String> = []
    private(set) var lastSuccessAt: Date?
    private(set) var lastFailureAt: Date?

    private let pendingKey = "sync_queue_pending"
    private let lastSuccessKey = "sync_last_success_at"
    private let lastFailureKey = "sync_last_failure_at"

    /// How long without any successful sync counts as stalled. Picked to be
    /// well past a normal background-delivery cycle but short enough that a
    /// real outage gets the user's attention before they wonder.
    static let stallThreshold: TimeInterval = 24 * 60 * 60

    private init() {
        let defaults = UserDefaults.standard
        if let saved = defaults.stringArray(forKey: pendingKey) {
            pending = Set(saved)
        }
        let success = defaults.double(forKey: lastSuccessKey)
        if success > 0 { lastSuccessAt = Date(timeIntervalSince1970: success) }
        let failure = defaults.double(forKey: lastFailureKey)
        if failure > 0 { lastFailureAt = Date(timeIntervalSince1970: failure) }
    }

    func enqueue(_ sampleType: HKSampleType) {
        pending.insert(sampleType.identifier)
        persist()
    }

    /// Record a sync attempt that failed. Used by the watchdog to decide if a
    /// notification should fire, and by the UI banner to show "last failure".
    func recordFailure(at date: Date = .now) {
        lastFailureAt = date
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: lastFailureKey)
    }

    /// Record any successful per-type sync. Strictly monotonic — a stale
    /// timestamp from a clock-skew event won't move the watchdog backward.
    func recordSuccess(at date: Date = .now) {
        if let prev = lastSuccessAt, prev > date { return }
        lastSuccessAt = date
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: lastSuccessKey)
    }

    /// Snapshot of state the UI/notifier reads. Consolidating into one struct
    /// keeps the actor hop count down — one `await` instead of three.
    struct Snapshot: Sendable {
        let pendingCount: Int
        let lastSuccessAt: Date?
        let lastFailureAt: Date?

        /// True when the queue is non-empty and we haven't had a successful
        /// sync in `stallThreshold`. Phrased so a fresh install (no successes
        /// yet, no failures yet, empty queue) doesn't read as stalled.
        var isStalled: Bool {
            guard pendingCount > 0 else { return false }
            guard let last = lastSuccessAt else {
                // Never succeeded but accumulated failures — that's stalled.
                return lastFailureAt != nil
            }
            return Date().timeIntervalSince(last) > SyncQueue.stallThreshold
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(
            pendingCount: pending.count,
            lastSuccessAt: lastSuccessAt,
            lastFailureAt: lastFailureAt
        )
    }

    func retryAll(handler: @Sendable (HKSampleType) async -> Void) async {
        let identifiers = pending
        for identifier in identifiers {
            guard let sampleType = sampleTypeFromIdentifier(identifier) else {
                pending.remove(identifier)
                continue
            }

            // Remove *before* running the handler so that if the handler fails
            // and re-enqueues, our retry loop doesn't immediately wipe the new
            // entry. The handler owns enqueue/dequeue from this point on.
            pending.remove(identifier)
            await handler(sampleType)
        }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(Array(pending), forKey: pendingKey)
    }

    private func sampleTypeFromIdentifier(_ identifier: String) -> HKSampleType? {
        if identifier == HKObjectType.workoutType().identifier {
            return HKSampleType.workoutType()
        }
        // Try quantity type
        if let qt = HKQuantityType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: identifier)) {
            return qt
        }
        // Try category type
        if let ct = HKCategoryType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: identifier)) {
            return ct
        }
        return nil
    }
}
