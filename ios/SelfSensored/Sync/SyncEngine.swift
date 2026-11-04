import CoreLocation
import HealthKit

/// Compact number formatting: 999 → "999", 1500 → "1.5k", 91000 → "91k", 1200000 → "1.2M"
private func compact(_ n: Int) -> String {
    if n < 1_000 { return "\(n)" }
    if n < 10_000 {
        let k = Double(n) / 1_000
        return k.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(k))k" : String(format: "%.1fk", k)
    }
    if n < 1_000_000 { return "\(n / 1_000)k" }
    let m = Double(n) / 1_000_000
    return m.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(m))M" : String(format: "%.1fM", m)
}

/// Per-type sync status for progress tracking.
///
/// `total` is optional on `.reading`/`.syncing`: the streaming pipeline
/// doesn't know the final sample count up front, so the bar renders as a
/// running count without a denominator ("Syncing... 12k") and the
/// progress value stays at 0 (indeterminate) until the type is `.done`.
enum TypeSyncStatus: Sendable {
    case pending
    case reading(syncedSoFar: Int, total: Int?)
    case syncing(synced: Int, total: Int?)
    case done(synced: Int)
    case skipped
    case error(String)

    var progress: Double {
        switch self {
        case .pending, .error: return 0
        case .reading(let syncedSoFar, let total):
            guard let total, total > 0 else { return 0 }
            return Double(syncedSoFar) / Double(total)
        case .syncing(let synced, let total):
            guard let total, total > 0 else { return 0 }
            return Double(synced) / Double(total)
        case .done, .skipped: return 1.0
        }
    }

    var label: String {
        switch self {
        case .pending: return "Waiting"
        case .reading(let syncedSoFar, .some(let total)):
            return "Reading... \(compact(syncedSoFar))/\(compact(total))"
        case .reading(let syncedSoFar, .none):
            return "Reading... \(compact(syncedSoFar))"
        case .syncing(let synced, .some(let total)):
            return "Syncing... \(compact(synced))/\(compact(total))"
        case .syncing(let synced, .none):
            return "Syncing... \(compact(synced))"
        case .done(let synced):
            return synced > 0 ? "\(compact(synced)) synced" : "Up to date"
        case .skipped: return "No data"
        case .error(let msg): return msg
        }
    }

    var isDone: Bool {
        switch self {
        case .done, .skipped: return true
        default: return false
        }
    }

    var isActive: Bool {
        switch self {
        case .reading, .syncing: return true
        default: return false
        }
    }
}

/// Orchestrates reading HealthKit data and posting it to the API using a
/// streaming chunked sync protocol (read → hash-check → push → persist
/// anchor, per chunk).
@MainActor
final class SyncEngine: ObservableObject {
    static let shared = SyncEngine()

    /// True for samples this app wrote itself (voice meal logger) so the
    /// read sync can skip them and avoid a write→read upload loop.
    static func isAppWritten(_ sample: HKSample) -> Bool {
        guard let id = sample.metadata?[HKMetadataKeySyncIdentifier] as? String else {
            return false
        }
        return id.hasPrefix(HKManager.mealSyncIdentifierPrefix)
    }

    @Published var isSyncing = false
    @Published var lastError: String?
    @Published var typeStatus: [String: TypeSyncStatus] = [:]
    @Published var typesCompleted = 0
    @Published var typesTotal = 0
    /// Snapshot of the watchdog state so views can render a stalled banner
    /// without reaching across actor boundaries on every render. Refreshed
    /// from `SyncQueue` after each sync attempt.
    @Published var queueSnapshot: SyncQueue.Snapshot = .init(
        pendingCount: 0, lastSuccessAt: nil, lastFailureAt: nil
    )

    /// Samples per read+sync chunk. Adjustable.
    var syncChunkSize: Int = 5_000

    private let hkManager: any HKSampleQuerying
    private let anchorStore: any HKAnchorStoring
    private let locationManager = LocationHelper()
    /// One runner per sample type: different types sync in parallel, but two
    /// invocations of the *same* type (e.g. an HK observer callback racing a
    /// user-initiated syncAll) still serialize so they don't stomp the anchor.
    private var runners: [String: SyncRunner] = [:]

    init(
        hkManager: any HKSampleQuerying = HKManager.shared,
        anchorStore: any HKAnchorStoring = HKAnchorStore.shared
    ) {
        self.hkManager = hkManager
        self.anchorStore = anchorStore
    }

    // MARK: - Chunked Sync Pipeline

    /// Sync a single sample type via a streaming chunked pipeline:
    /// read → hash-check → push needed samples → persist anchor, per chunk.
    /// Serialized per-type via `SyncRunner` so concurrent invocations of
    /// the same type (e.g. observer wake vs user-initiated syncAll) queue.
    ///
    /// `deadline` is a cooperative budget used by the background delivery
    /// path: checked between chunks (after the anchor has been saved), so
    /// a live `/sync` request is never cancelled mid-HTTP. Nil means run
    /// to completion (foreground syncAll).
    func syncType(_ sampleType: HKSampleType, deadline: ContinuousClock.Instant? = nil) async {
        let typeRunner = runner(for: sampleType.identifier)
        await typeRunner.run { [weak self] in
            await self?.syncTypeInternal(sampleType, deadline: deadline)
        }
    }

    private func runner(for typeId: String) -> SyncRunner {
        if let r = runners[typeId] { return r }
        let r = SyncRunner()
        runners[typeId] = r
        return r
    }

    /// Single-pass streaming sync:
    ///  - Walk HealthKit via anchored queries in `syncChunkSize` chunks.
    ///  - For each chunk: build payloads, hash-check, push needed samples, save anchor.
    ///  - No separate count phase — the old two-phase design doubled HK I/O
    ///    and the count timeout was permanently tripping on high-volume types
    ///    (ActiveEnergyBurned, HeartRate, StepCount) for users with years
    ///    of Watch history.
    ///  - Anchor persists after *every* successful chunk so a mid-stream
    ///    failure (network hiccup, HK observer budget expiry) doesn't throw
    ///    away earlier chunks' work on retry.
    private func syncTypeInternal(_ sampleType: HKSampleType, deadline: ContinuousClock.Instant? = nil) async {
        let typeId = sampleType.identifier
        let shortName = typeId
            .replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKWorkoutType", with: "Workout")

        do {
            guard let deviceId = await APIClient.shared.deviceId else {
                typeStatus[typeId] = .error("No device")
                typesCompleted += 1
                return
            }

            var chunkAnchor = anchorStore.load(for: sampleType)
            var syncedSoFar = 0
            var sawAnyData = false
            let location = locationManager.currentLocation
            var chunkNum = 0

            typeStatus[typeId] = .reading(syncedSoFar: 0, total: nil)
            print("SYNC START: \(shortName)")

            while true {
                chunkNum += 1
                typeStatus[typeId] = .reading(syncedSoFar: syncedSoFar, total: nil)
                print("SYNC READ: \(shortName) chunk=\(chunkNum) reading...")

                let chunk = try await hkManager.querySamples(
                    type: sampleType, anchor: chunkAnchor, limit: syncChunkSize
                )

                let chunkSamples = chunk.samples.filter { !Self.isAppWritten($0) }
                let chunkDeleted = chunk.deleted.map { $0.uuid.uuidString }

                print("SYNC READ: \(shortName) chunk=\(chunkNum) got=\(chunkSamples.count) deleted=\(chunkDeleted.count)")

                // First-call empty response = nothing new anywhere. Persist
                // the fresh anchor so future syncs start from "all current
                // data seen" even if nothing moved.
                if chunkSamples.isEmpty && chunkDeleted.isEmpty && !sawAnyData {
                    if let anchor = chunk.newAnchor {
                        anchorStore.save(anchor, for: sampleType)
                    }
                    print("SYNC SKIP: \(shortName)")
                    typeStatus[typeId] = .skipped
                    typesCompleted += 1
                    return
                }
                sawAnyData = sawAnyData || !chunkSamples.isEmpty || !chunkDeleted.isEmpty

                // Build payloads + hashes
                var hashItems: [HashCheckItem] = []
                var samplePayloads: [HealthSamplePayload] = []
                var workoutPayloads: [WorkoutPayload] = []

                if sampleType == HKSampleType.workoutType() {
                    workoutPayloads = chunkSamples.compactMap { s in
                        guard let w = s as? HKWorkout else { return nil }
                        return WorkoutPayload(from: w, deviceId: deviceId)
                    }
                    hashItems = workoutPayloads.map {
                        HashCheckItem(hkUuid: $0.hkUuid, contentHash: $0.contentHash)
                    }
                } else {
                    samplePayloads = chunkSamples.map {
                        HealthSamplePayload(from: $0, deviceId: deviceId)
                    }
                    hashItems = samplePayloads.map {
                        HashCheckItem(hkUuid: $0.hkUuid, contentHash: $0.contentHash)
                    }
                }

                typeStatus[typeId] = .syncing(synced: syncedSoFar, total: nil)

                // Hash check
                let checkStart = Date()
                print("SYNC CHECK: \(shortName) chunk=\(chunkNum) checking \(hashItems.count) hashes...")
                let checkRequest = HashCheckRequest(
                    deviceId: deviceId,
                    sampleType: sampleType.identifier,
                    items: hashItems
                )
                let checkResponse = try await APIClient.shared.checkHashes(checkRequest)
                let checkMs = Int(Date().timeIntervalSince(checkStart) * 1000)
                print("SYNC CHECK: \(shortName) chunk=\(chunkNum) needed=\(checkResponse.neededUuids.count)/\(hashItems.count) [\(checkMs)ms]")

                let neededCount = checkResponse.neededUuids.count
                if !checkResponse.neededUuids.isEmpty || !chunkDeleted.isEmpty {
                    let neededSet = Set(checkResponse.neededUuids)
                    var payload = SyncPayload(
                        sessionId: checkResponse.sessionId,
                        deviceId: deviceId,
                        sampleType: sampleType.identifier,
                        location: location
                    )
                    if sampleType == HKSampleType.workoutType() {
                        payload.workouts = workoutPayloads.filter { neededSet.contains($0.hkUuid) }
                    } else {
                        payload.samples = samplePayloads.filter { neededSet.contains($0.hkUuid) }
                    }
                    payload.deletedUuids = chunkDeleted

                    let pushStart = Date()
                    print("SYNC PUSH: \(shortName) chunk=\(chunkNum) sending \(neededCount) samples...")
                    _ = try await APIClient.shared.syncHealth(payload)
                    let pushMs = Int(Date().timeIntervalSince(pushStart) * 1000)
                    print("SYNC PUSH: \(shortName) chunk=\(chunkNum) done [\(pushMs)ms]")
                }

                // Sync GPS routes for any workouts in this chunk
                if sampleType == HKSampleType.workoutType() {
                    let rawWorkouts = chunkSamples.compactMap { $0 as? HKWorkout }
                    await syncRoutes(for: rawWorkouts)
                }

                syncedSoFar += chunkSamples.count
                typeStatus[typeId] = .syncing(synced: syncedSoFar, total: nil)

                // Durability: persist anchor after each successful chunk so
                // a mid-stream failure can resume from here rather than re-
                // reading everything.
                if let anchor = chunk.newAnchor {
                    anchorStore.save(anchor, for: sampleType)
                    chunkAnchor = anchor
                }

                // HK returns < syncChunkSize when caught up; safely terminates.
                if chunkSamples.count < syncChunkSize && chunkDeleted.isEmpty {
                    break
                }

                // Cooperative deadline check for background wake-ups. Fires
                // only between chunks, after the anchor is saved — never
                // mid-HTTP — so the in-flight /sync always runs to commit.
                if let deadline, ContinuousClock.now >= deadline {
                    print("SYNC DEADLINE: \(shortName) chunk=\(chunkNum) synced=\(syncedSoFar)")
                    typeStatus[typeId] = .error("Paused")
                    typesCompleted += 1
                    await SyncQueue.shared.enqueue(sampleType)
                    return
                }
            }

            SyncState.shared.markSynced(typeIdentifier: sampleType.identifier)
            await SyncQueue.shared.recordSuccess()
            queueSnapshot = await SyncQueue.shared.snapshot()
            print("SYNC DONE: \(shortName) synced=\(syncedSoFar)")
            typeStatus[typeId] = .done(synced: syncedSoFar)
            typesCompleted += 1

        } catch is CancellationError {
            // Background budget expired mid-chunk. Per-chunk anchor save
            // already preserved partial progress; enqueue for foreground
            // resume.
            print("SYNC PAUSED: \(shortName)")
            typeStatus[sampleType.identifier] = .error("Paused")
            typesCompleted += 1
            await SyncQueue.shared.enqueue(sampleType)
            queueSnapshot = await SyncQueue.shared.snapshot()
        } catch {
            // Loud failure: record the timestamp so the watchdog/banner can
            // show a real "stalled" state, and broadcast the error so the
            // app-level notification scheduler can decide whether to nudge
            // the user.
            print("SYNC ERROR: \(shortName) \(error)")
            typeStatus[sampleType.identifier] = .error("Failed: \(error.localizedDescription)")
            typesCompleted += 1
            await SyncQueue.shared.enqueue(sampleType)
            await SyncQueue.shared.recordFailure()
            queueSnapshot = await SyncQueue.shared.snapshot()
            NotificationCenter.default.post(
                name: .healthSyncFailed,
                object: nil,
                userInfo: ["error": error.localizedDescription]
            )
        }
    }

    /// Sync GPS routes for workouts that were just synced.
    private func syncRoutes(for workouts: [HKWorkout]) async {
        print("syncRoutes: checking \(workouts.count) workouts for routes")
        var routeCount = 0
        for workout in workouts {
            do {
                let routes = try await hkManager.workoutRoutes(for: workout)
                guard !routes.isEmpty else { continue }
                routeCount += 1
                print("syncRoutes: workout \(workout.workoutActivityType.rawValue) has \(routes.count) route(s)")

                for route in routes {
                    let locations = try await hkManager.routeLocations(for: route)
                    guard !locations.isEmpty else { continue }

                    let points = locations.map { loc in
                        RoutePoint(
                            timestamp: loc.timestamp,
                            latitude: loc.coordinate.latitude,
                            longitude: loc.coordinate.longitude,
                            altitude: loc.verticalAccuracy >= 0 ? loc.altitude : nil,
                            horizontalAccuracy: loc.horizontalAccuracy >= 0 ? loc.horizontalAccuracy : nil,
                            verticalAccuracy: loc.verticalAccuracy >= 0 ? loc.verticalAccuracy : nil,
                            speed: loc.speed >= 0 ? loc.speed : nil,
                            course: loc.course >= 0 ? loc.course : nil
                        )
                    }

                    let payload = WorkoutRoutePayload(
                        workoutHkUuid: workout.uuid.uuidString,
                        points: points
                    )

                    try await APIClient.shared.syncWorkoutRoutes(payload)
                }
            } catch {
                print("Route sync failed for workout \(workout.uuid): \(error)")
            }
        }
        print("syncRoutes: done — \(routeCount) workouts had routes")
    }

    // MARK: - Sync All

    func syncAll() async {
        isSyncing = true
        lastError = nil
        typeStatus = [:]
        typesCompleted = 0
        typesTotal = HKTypes.allSampleTypes.count

        for sampleType in HKTypes.allSampleTypes {
            typeStatus[sampleType.identifier] = .pending
        }

        // Check auth
        guard await APIClient.shared.token != nil else {
            lastError = "Not logged in. Go to Settings → Login/Register."
            isSyncing = false
            return
        }

        // Register device if needed. 401s are handled centrally in
        // APIClient (clears auth + posts .healthSyncAuthExpired); we just
        // surface the message to the local UI here.
        if await APIClient.shared.deviceId == nil {
            let reg = DeviceInfo.collect()
            do {
                let resp = try await APIClient.shared.registerDevice(reg)
                await APIClient.shared.setDeviceId(resp.deviceId)
            } catch let error as APIError {
                if case .server(let code, _) = error, code == 401 {
                    lastError = "Session expired. Go to Settings → Login/Register."
                } else {
                    lastError = error.localizedDescription
                }
                isSyncing = false
                return
            } catch {
                lastError = error.localizedDescription
                isSyncing = false
                return
            }
        }

        // Fan out across sample types with a bounded concurrency window.
        // Types have independent HK anchors and independent API chunks, so
        // there's no cross-type ordering requirement. Workout routes are
        // synced inside the workout type's own pipeline, so the workout→route
        // ordering is preserved automatically.
        // 2 is the sweet spot for this DB: 4 caused plan-cache thrash on the
        // Pi5 postgres (every /check plans across 130 hypertable chunks), and
        // single-threaded left high-volume types starving behind each other.
        let concurrencyLimit = 2
        await withTaskGroup(of: Void.self) { group in
            var iterator = HKTypes.allSampleTypes.makeIterator()
            for _ in 0..<concurrencyLimit {
                guard let t = iterator.next() else { break }
                group.addTask { [weak self] in await self?.syncType(t) }
            }
            while await group.next() != nil {
                if let t = iterator.next() {
                    group.addTask { [weak self] in await self?.syncType(t) }
                }
            }
        }

        // Retry queued failures
        await SyncQueue.shared.retryAll { @Sendable [weak self] sampleType in
            await self?.syncType(sampleType)
        }

        queueSnapshot = await SyncQueue.shared.snapshot()
        isSyncing = false
    }

    /// Hydrate `queueSnapshot` at app launch so the banner reflects on-disk
    /// state before any sync attempt has run this session.
    func refreshQueueSnapshot() async {
        queueSnapshot = await SyncQueue.shared.snapshot()
    }
}

// MARK: - Sync Runner

/// Serializes SyncEngine work through an actor-isolated task chain. Every
/// caller of `run` waits for the previous task to complete before its closure
/// starts, so observer callbacks and user-initiated syncs can't interleave.
actor SyncRunner {
    private var tail: Task<Void, Never>?

    func run(_ work: @Sendable @escaping () async -> Void) async {
        let previous = tail
        let task = Task<Void, Never> {
            await previous?.value
            await work()
        }
        tail = task
        await task.value
    }
}

// MARK: - Location Helper

final class LocationHelper: @unchecked Sendable {
    private let manager = CLLocationManager()

    var currentLocation: Location? {
        guard let loc = manager.location else { return nil }
        return Location(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude)
    }

    init() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }
}
