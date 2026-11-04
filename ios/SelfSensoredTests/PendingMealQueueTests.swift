import XCTest
@testable import SelfSensored

final class PendingMealQueueTests: XCTestCase {
    private func tempFileURL() -> URL {
        let name = "pending_meals_\(UUID().uuidString).json"
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
    }

    override func tearDown() async throws {
        // Test files are randomized per test; nothing to share. Best-effort
        // cleanup happens via the OS temp purge.
    }

    func testEnqueueAndPersistRoundTrip() async throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let queue = PendingMealQueue(fileURL: url)
        await queue.enqueue(.init(text: "yogurt", mealType: "snack", createdAt: Date()))

        let reloaded = PendingMealQueue(fileURL: url)
        let snapshot = await reloaded.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot[0].text, "yogurt")
    }

    func testStaleEntriesDroppedOnLoad() async throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // Hand-craft a JSON file with one fresh and one 30-day-old entry.
        let oldDate = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        let freshDate = Date()
        let json = """
        [
            {"text":"old","mealType":"snack","createdAt":"\(ISO8601DateFormatter().string(from: oldDate))"},
            {"text":"fresh","mealType":"snack","createdAt":"\(ISO8601DateFormatter().string(from: freshDate))"}
        ]
        """
        try json.data(using: .utf8)!.write(to: url)

        let queue = PendingMealQueue(fileURL: url)
        let snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.count, 1, "expected stale entry to be dropped")
        XCTAssertEqual(snapshot[0].text, "fresh")
    }

    func testEmptyOnFreshLoad() async {
        let url = tempFileURL()
        let queue = PendingMealQueue(fileURL: url)
        let snapshot = await queue.snapshot()
        XCTAssertTrue(snapshot.isEmpty)
    }
}
