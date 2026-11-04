import CoreLocation
import HealthKit
import XCTest
@testable import SelfSensored

/// Covers the behavioural surface of the streaming sync pipeline:
///   - `TypeSyncStatus` label / progress / isActive / isDone with and
///     without a known total (indeterminate for the read+sync streaming
///     pipeline; determinate was deleted).
///   - `SyncEngine` accepts injected `HKSampleQuerying` +
///     `HKAnchorStoring` dependencies (the DI seam added so a future
///     follow-up can drive end-to-end streaming tests without touching
///     `APIClient.shared`).
///
/// End-to-end streaming coverage (per-chunk anchor save, mid-stream
/// failure keeps earlier anchors, CancellationError → `.error("Paused")`
/// + enqueue) requires an `APIClient` seam that doesn't exist yet — the
/// sync pipeline still calls `APIClient.shared.checkHashes` / `syncHealth`
/// directly. Those tests are intentionally deferred; the pipeline logic
/// they exercise is, however, strictly linear and trivially reviewable.
@MainActor
final class SyncEngineChunkingTests: XCTestCase {

    // MARK: - TypeSyncStatus

    func testLabelIndeterminateWhenTotalNil() {
        XCTAssertEqual(
            TypeSyncStatus.reading(syncedSoFar: 5_000, total: nil).label,
            "Reading... 5k"
        )
        XCTAssertEqual(
            TypeSyncStatus.syncing(synced: 12_000, total: nil).label,
            "Syncing... 12k"
        )
    }

    func testLabelDeterminateWhenTotalPresent() {
        XCTAssertEqual(
            TypeSyncStatus.reading(syncedSoFar: 1_000, total: 3_000).label,
            "Reading... 1k/3k"
        )
        XCTAssertEqual(
            TypeSyncStatus.syncing(synced: 500, total: 2_500).label,
            "Syncing... 500/2.5k"
        )
    }

    func testDoneLabelFormatsSyncedCount() {
        XCTAssertEqual(TypeSyncStatus.done(synced: 0).label, "Up to date")
        XCTAssertEqual(TypeSyncStatus.done(synced: 42).label, "42 synced")
        XCTAssertEqual(TypeSyncStatus.done(synced: 1_500_000).label, "1.5M synced")
    }

    func testPassiveLabels() {
        XCTAssertEqual(TypeSyncStatus.pending.label, "Waiting")
        XCTAssertEqual(TypeSyncStatus.skipped.label, "No data")
        XCTAssertEqual(TypeSyncStatus.error("Paused").label, "Paused")
    }

    func testProgressIsIndeterminateWhenTotalNil() {
        XCTAssertEqual(TypeSyncStatus.reading(syncedSoFar: 5_000, total: nil).progress, 0)
        XCTAssertEqual(TypeSyncStatus.syncing(synced: 5_000, total: nil).progress, 0)
    }

    func testProgressComputedWhenTotalPresent() {
        XCTAssertEqual(
            TypeSyncStatus.syncing(synced: 250, total: 1_000).progress,
            0.25,
            accuracy: 0.001
        )
        XCTAssertEqual(
            TypeSyncStatus.reading(syncedSoFar: 50, total: 200).progress,
            0.25,
            accuracy: 0.001
        )
    }

    func testProgressIsFullWhenDoneOrSkipped() {
        XCTAssertEqual(TypeSyncStatus.done(synced: 42).progress, 1.0)
        XCTAssertEqual(TypeSyncStatus.skipped.progress, 1.0)
    }

    func testProgressIsZeroForPendingAndError() {
        XCTAssertEqual(TypeSyncStatus.pending.progress, 0)
        XCTAssertEqual(TypeSyncStatus.error("Failed").progress, 0)
    }

    func testIsActiveOnlyWhileStreaming() {
        XCTAssertTrue(TypeSyncStatus.reading(syncedSoFar: 1, total: nil).isActive)
        XCTAssertTrue(TypeSyncStatus.syncing(synced: 1, total: nil).isActive)
        XCTAssertFalse(TypeSyncStatus.pending.isActive)
        XCTAssertFalse(TypeSyncStatus.done(synced: 1).isActive)
        XCTAssertFalse(TypeSyncStatus.skipped.isActive)
        XCTAssertFalse(TypeSyncStatus.error("x").isActive)
    }

    func testIsDoneOnlyForDoneAndSkipped() {
        XCTAssertTrue(TypeSyncStatus.done(synced: 1).isDone)
        XCTAssertTrue(TypeSyncStatus.skipped.isDone)
        XCTAssertFalse(TypeSyncStatus.reading(syncedSoFar: 1, total: nil).isDone)
        XCTAssertFalse(TypeSyncStatus.syncing(synced: 1, total: nil).isDone)
        XCTAssertFalse(TypeSyncStatus.pending.isDone)
        XCTAssertFalse(TypeSyncStatus.error("x").isDone)
    }

    // MARK: - SyncEngine DI seam

    func testSyncEngineAcceptsInjectedDependencies() {
        // Compile-time contract: both `HKSampleQuerying` and
        // `HKAnchorStoring` satisfy `SyncEngine.init`, and a fresh
        // engine starts with no published state.
        let engine = SyncEngine(
            hkManager: FakeHKSampleQuerier(),
            anchorStore: FakeHKAnchorStore()
        )
        XCTAssertFalse(engine.isSyncing)
        XCTAssertNil(engine.lastError)
        XCTAssertTrue(engine.typeStatus.isEmpty)
        XCTAssertEqual(engine.typesCompleted, 0)
        XCTAssertEqual(engine.typesTotal, 0)
    }

    func testFakeAnchorStoreRoundTrips() {
        let store = FakeHKAnchorStore()
        let type = HKQuantityType(.stepCount)
        XCTAssertNil(store.load(for: type))

        let anchor = HKQueryAnchor(fromValue: 7)
        store.save(anchor, for: type)
        XCTAssertEqual(store.load(for: type), anchor)

        store.remove(for: type)
        XCTAssertNil(store.load(for: type))
    }
}

// MARK: - Test doubles

/// Records incoming `querySamples` calls and replays scripted responses.
/// Safe for `@MainActor` use because the whole engine is MainActor-isolated.
@MainActor
final class FakeHKSampleQuerier: HKSampleQuerying {
    struct Response {
        var samples: [HKSample] = []
        var deleted: [HKDeletedObject] = []
        var newAnchor: HKQueryAnchor?
        var error: Error?
    }

    var responses: [Response] = []
    private(set) var calls: [(type: HKSampleType, anchor: HKQueryAnchor?, limit: Int)] = []

    func querySamples(
        type sampleType: HKSampleType,
        anchor: HKQueryAnchor?,
        limit: Int
    ) async throws -> (samples: [HKSample], deleted: [HKDeletedObject], newAnchor: HKQueryAnchor?) {
        calls.append((sampleType, anchor, limit))
        guard !responses.isEmpty else {
            return (samples: [], deleted: [], newAnchor: nil)
        }
        let r = responses.removeFirst()
        if let err = r.error { throw err }
        return (samples: r.samples, deleted: r.deleted, newAnchor: r.newAnchor)
    }

    func workoutRoutes(for workout: HKWorkout) async throws -> [HKWorkoutRoute] {
        []
    }

    func routeLocations(for route: HKWorkoutRoute) async throws -> [CLLocation] {
        []
    }
}

/// In-memory anchor store so tests don't touch `UserDefaults.standard`.
final class FakeHKAnchorStore: HKAnchorStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var anchors: [String: HKQueryAnchor] = [:]

    func load(for sampleType: HKSampleType) -> HKQueryAnchor? {
        lock.lock(); defer { lock.unlock() }
        return anchors[sampleType.identifier]
    }

    func save(_ anchor: HKQueryAnchor, for sampleType: HKSampleType) {
        lock.lock(); defer { lock.unlock() }
        anchors[sampleType.identifier] = anchor
    }

    func remove(for sampleType: HKSampleType) {
        lock.lock(); defer { lock.unlock() }
        anchors.removeValue(forKey: sampleType.identifier)
    }
}
