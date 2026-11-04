import HealthKit

/// Registers observer queries and enables background delivery for all tracked types.
final class HKBackgroundDelivery: @unchecked Sendable {
    static let shared = HKBackgroundDelivery()

    private let store: HKHealthStore
    private var registered = false
    private var activeQueries: [HKObserverQuery] = []

    /// iOS gives background observer wake-ups roughly 30 seconds before it
    /// throttles or disables delivery. Stop at 25s to leave margin for the
    /// completion handler itself. Enforced as a cooperative deadline that
    /// the sync pipeline checks between chunks — never mid-HTTP, because
    /// cancelling a live `URLSession` request for `/sync` leaves the server
    /// handler's transaction orphaned and rolled back (sample loss + zombie
    /// pending `sync_sessions` rows).
    private static let wakeBudget: Duration = .seconds(25)

    private init() {
        store = HKHealthStore()
    }

    /// Register background delivery for every sample type. Idempotent — calling
    /// it twice is a no-op rather than double-registering observers.
    func registerAll() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        guard !registered else { return }
        registered = true

        for sampleType in HKTypes.allSampleTypes {
            let query = HKObserverQuery(sampleType: sampleType, predicate: nil) {
                _, completionHandler, error in
                let type = sampleType
                // HKObserver completion handlers are C callbacks safe to call
                // from any thread; nonisolated(unsafe) is required to hand
                // them across the Task boundary under strict concurrency.
                nonisolated(unsafe) let handler = completionHandler

                guard error == nil else {
                    handler()
                    return
                }

                // Run sync time-boxed to our background budget. Whatever the
                // outcome (success, timeout, thrown error), we must invoke
                // handler() exactly once so iOS keeps delivering wake-ups.
                Task {
                    await Self.runWithBudget(type: type)
                    handler()
                }
            }
            store.execute(query)
            activeQueries.append(query)

            store.enableBackgroundDelivery(for: sampleType, frequency: .immediate) { success, error in
                if let error {
                    print("Background delivery failed for \(sampleType): \(error)")
                } else if success {
                    print("Background delivery enabled for \(sampleType)")
                }
            }
        }
    }

    /// Stop all observer queries. Intended for logout / teardown.
    func unregisterAll() {
        for query in activeQueries {
            store.stop(query)
        }
        activeQueries.removeAll()
        registered = false
    }

    /// Run a sync for `type` with a cooperative deadline. SyncEngine checks
    /// the deadline at chunk boundaries (after the anchor is saved) and
    /// enqueues the type for foreground resume if the budget expired. No
    /// `Task.cancel()` — that would abort a live `URLSession` request and
    /// orphan the server handler's transaction.
    private static func runWithBudget(type: HKSampleType) async {
        let deadline = ContinuousClock.now.advanced(by: wakeBudget)
        await SyncEngine.shared.syncType(type, deadline: deadline)
    }
}
