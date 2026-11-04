import HealthKit
import XCTest
@testable import SelfSensored

@MainActor
final class SelfSensoredTests: XCTestCase {
    func testIsAppWrittenFiltersAppMealSamples() throws {
        let id = UUID()
        let metadata: [String: Any] = [
            HKMetadataKeySyncIdentifier: HKManager.mealSyncIdentifierPrefix + id.uuidString,
            HKMetadataKeySyncVersion: 1,
        ]
        let sample = HKQuantitySample(
            type: HKQuantityType(.dietaryProtein),
            quantity: HKQuantity(unit: .gram(), doubleValue: 25.0),
            start: Date(),
            end: Date(),
            metadata: metadata
        )
        XCTAssertTrue(SyncEngine.isAppWritten(sample))

        let foreign = HKQuantitySample(
            type: HKQuantityType(.dietaryProtein),
            quantity: HKQuantity(unit: .gram(), doubleValue: 25.0),
            start: Date(),
            end: Date()
        )
        XCTAssertFalse(SyncEngine.isAppWritten(foreign))
    }

    func testSyncPayloadEncoding() throws {
        let payload = SyncPayload(
            sessionId: 42,
            deviceId: UUID(),
            sampleType: "HKQuantityTypeIdentifierStepCount",
            deletedUuids: ["test-uuid"]
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(payload)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(json)
        XCTAssertEqual(json?["deleted_uuids"] as? [String], ["test-uuid"])
        XCTAssertEqual((json?["samples"] as? [Any])?.count, 0)
    }

    func testSyncResponseDecoding() throws {
        let json = """
        {"samples_synced": 5, "workouts_synced": 1, "deleted": 2}
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let response = try decoder.decode(SyncResponse.self, from: json)

        XCTAssertEqual(response.samplesSynced, 5)
        XCTAssertEqual(response.workoutsSynced, 1)
        XCTAssertEqual(response.deleted, 2)
    }
}
