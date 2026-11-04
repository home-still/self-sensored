import CoreLocation
import HealthKit
import os

/// Tiny seam over `HKManager`'s read-side query surface so the sync
/// pipeline can be driven by a fake HealthKit store in unit tests.
/// Only the methods `SyncEngine` actually consumes are on the protocol.
@MainActor
protocol HKSampleQuerying: AnyObject {
    func querySamples(
        type sampleType: HKSampleType,
        anchor: HKQueryAnchor?,
        limit: Int
    ) async throws -> (samples: [HKSample], deleted: [HKDeletedObject], newAnchor: HKQueryAnchor?)

    func workoutRoutes(for workout: HKWorkout) async throws -> [HKWorkoutRoute]

    func routeLocations(for route: HKWorkoutRoute) async throws -> [CLLocation]
}

/// Singleton managing HealthKit authorization and sample queries.
@MainActor
final class HKManager: ObservableObject, HKSampleQuerying {
    static let shared = HKManager()

    private let store = HKHealthStore()
    @Published var isAuthorized = false
    /// Subset of `HKTypes.dietaryWriteIdentifiers` the user has granted write access to.
    /// `writeMealCorrelation` only emits samples for identifiers in this set so a
    /// partial denial surfaces as "skipped" rather than a silent `save()` throw.
    @Published var authorizedWriteIdentifiers: Set<HKQuantityTypeIdentifier> = []

    private init() {}

    var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    func requestAuthorization() async {
        guard isAvailable else { return }

        do {
            try await store.requestAuthorization(
                toShare: HKTypes.allWriteTypes,
                read: HKTypes.allReadTypes
            )
            isAuthorized = true
            refreshAuthorizedWriteIdentifiers()
        } catch {
            print("HealthKit authorization failed: \(error)")
        }
    }

    /// Re-read the per-type write authorization status. `.sharingAuthorized` means
    /// the user granted write access; `.sharingDenied` and `.notDetermined` don't.
    /// Note that HealthKit intentionally won't tell you which of the two a denial
    /// falls under — so we treat anything non-authorized as "skip this nutrient".
    private func refreshAuthorizedWriteIdentifiers() {
        var granted: Set<HKQuantityTypeIdentifier> = []
        for id in HKTypes.dietaryWriteIdentifiers {
            let status = store.authorizationStatus(for: HKQuantityType(id))
            if status == .sharingAuthorized {
                granted.insert(id)
            }
        }
        // Only publish if actually different — otherwise every save() bounces
        // SwiftUI views subscribed to this object.
        if granted != authorizedWriteIdentifiers {
            authorizedWriteIdentifiers = granted
        }
    }

    /// Prefix every app-written correlation carries in `HKMetadataKeySyncIdentifier`,
    /// so the read sync in `SyncEngine` can skip the app's own writes.
    static let mealSyncIdentifierPrefix = "selfsensored-meal-"

    /// Write a food correlation atomically. Zero-valued nutrients are skipped.
    func writeMealCorrelation(
        foodName: String,
        mealType: String,
        nutrients: [HKQuantityTypeIdentifier: (amount: Double, unit: HKUnit)],
        syncIdentifier: UUID,
        date: Date = Date()
    ) async throws -> WriteResult {
        refreshAuthorizedWriteIdentifiers()
        var samples = Set<HKSample>()
        var skipped: [HKQuantityTypeIdentifier] = []
        for (id, entry) in nutrients where entry.amount > 0 {
            guard authorizedWriteIdentifiers.contains(id) else {
                skipped.append(id)
                continue
            }
            let quantity = HKQuantity(unit: entry.unit, doubleValue: entry.amount)
            let sample = HKQuantitySample(
                type: HKQuantityType(id),
                quantity: quantity,
                start: date,
                end: date
            )
            samples.insert(sample)
        }

        guard !samples.isEmpty,
              let correlationType = HKCorrelationType.correlationType(forIdentifier: .food) else {
            return WriteResult(written: 0, skipped: skipped)
        }

        // HealthKit semantics: when two correlations share a sync_identifier, the
        // one with the higher sync_version replaces the prior entry. Track our
        // version per sync_identifier in the Keychain so re-saves of the same
        // logical meal can update the existing HK record.
        let version = MealSyncVersionStore.nextVersion(for: syncIdentifier)

        let metadata: [String: Any] = [
            HKMetadataKeyFoodType: foodName,
            "HKFoodMeal": mealType,
            HKMetadataKeySyncIdentifier: Self.mealSyncIdentifierPrefix + syncIdentifier.uuidString,
            HKMetadataKeySyncVersion: version,
            HKMetadataKeyWasUserEntered: true,
        ]

        let correlation = HKCorrelation(
            type: correlationType,
            start: date,
            end: date,
            objects: samples,
            metadata: metadata
        )

        try await store.save(correlation)
        return WriteResult(written: samples.count, skipped: skipped)
    }

    struct WriteResult: Sendable {
        let written: Int
        let skipped: [HKQuantityTypeIdentifier]
    }

    /// Run an anchored object query for a single sample type with an optional limit.
    /// Use `limit: HKObjectQueryNoLimit` for all results, or a specific number for chunked reads.
    func querySamples(
        type sampleType: HKSampleType,
        anchor: HKQueryAnchor?,
        limit: Int = HKObjectQueryNoLimit
    ) async throws -> (samples: [HKSample], deleted: [HKDeletedObject], newAnchor: HKQueryAnchor?) {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: sampleType,
                predicate: nil,
                anchor: anchor,
                limit: limit
            ) { _, added, deleted, newAnchor, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (
                        samples: added ?? [],
                        deleted: deleted ?? [],
                        newAnchor: newAnchor
                    ))
                }
            }
            store.execute(query)
        }
    }

    /// Get all HKWorkoutRoute objects associated with a workout.
    func workoutRoutes(for workout: HKWorkout) async throws -> [HKWorkoutRoute] {
        try await withCheckedThrowingContinuation { continuation in
            let routeType = HKSeriesType.workoutRoute()
            let predicate = HKQuery.predicateForObjects(from: workout)
            let query = HKSampleQuery(
                sampleType: routeType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    let routes = (samples as? [HKWorkoutRoute]) ?? []
                    continuation.resume(returning: routes)
                }
            }
            store.execute(query)
        }
    }

    /// Stream all CLLocation objects from an HKWorkoutRoute. The query is
    /// time-boxed at 30 s — HealthKit sometimes never fires its `done` callback
    /// for corrupt routes, and we don't want to deadlock the sync pipeline.
    func routeLocations(for route: HKWorkoutRoute) async throws -> [CLLocation] {
        let accumulator = LocationAccumulator()
        let resumed = OneShotGate()
        let store = self.store

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                if let error {
                    if resumed.tryClose() {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                if let locations {
                    accumulator.append(locations)
                }
                if done, resumed.tryClose() {
                    continuation.resume(returning: accumulator.snapshot())
                }
            }

            // Watchdog: if HealthKit hasn't set `done` in 30 s, stop the query
            // and return whatever we have. Prevents an undead continuation.
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                if resumed.tryClose() {
                    store.stop(query)
                    continuation.resume(returning: accumulator.snapshot())
                }
            }

            store.execute(query)
        }
    }

    /// Access the underlying HKHealthStore for background delivery registration.
    var healthStore: HKHealthStore { store }
}

/// Lock-guarded accumulator for HKWorkoutRouteQuery callbacks, which HealthKit
/// may invoke from an internal serial queue.
private final class LocationAccumulator: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var locations: [CLLocation] = []

    func append(_ batch: [CLLocation]) {
        lock.withLock { self.locations.append(contentsOf: batch) }
    }

    func snapshot() -> [CLLocation] {
        lock.withLock { self.locations }
    }
}

/// Single-use latch — ensures `withCheckedThrowingContinuation` resumes at
/// most once even when query callback + watchdog race.
private final class OneShotGate: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var closed = false

    func tryClose() -> Bool {
        lock.withLock {
            if closed { return false }
            closed = true
            return true
        }
    }
}

/// Persists the HK sync-version counter per meal sync_identifier in the
/// Keychain so re-saves of the same meal HKSample can replace the prior entry
/// (HealthKit replaces-on-higher-version). Survives app reinstall.
enum MealSyncVersionStore {
    static func nextVersion(for syncIdentifier: UUID) -> Int {
        let key = "meal-sync-version/\(syncIdentifier.uuidString)"
        let current = KeychainStore.load(key).flatMap(Int.init) ?? 0
        let next = current + 1
        KeychainStore.save(String(next), for: key)
        return next
    }
}
