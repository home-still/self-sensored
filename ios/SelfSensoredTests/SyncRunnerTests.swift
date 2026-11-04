import XCTest
@testable import SelfSensored

final class SyncRunnerTests: XCTestCase {
    /// Two `run` calls submitted concurrently must execute strictly serially.
    /// We verify by recording start/finish ticks and asserting the second
    /// call's start happens after the first call's finish.
    func testRunSerializesConcurrentTasks() async {
        let runner = SyncRunner()
        let recorder = TickRecorder()

        async let first: Void = runner.run {
            await recorder.record("a-start")
            try? await Task.sleep(nanoseconds: 50_000_000)
            await recorder.record("a-end")
        }
        async let second: Void = runner.run {
            await recorder.record("b-start")
            try? await Task.sleep(nanoseconds: 10_000_000)
            await recorder.record("b-end")
        }

        _ = await (first, second)
        let ticks = await recorder.snapshot()

        XCTAssertEqual(ticks.first, "a-start")
        let aEndIdx = ticks.firstIndex(of: "a-end")!
        let bStartIdx = ticks.firstIndex(of: "b-start")!
        XCTAssertLessThan(
            aEndIdx, bStartIdx,
            "second task started before first finished: \(ticks)"
        )
    }
}

private actor TickRecorder {
    private var ticks: [String] = []
    func record(_ tick: String) { ticks.append(tick) }
    func snapshot() -> [String] { ticks }
}
