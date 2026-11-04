import Foundation
import SwiftUI

/// ObservableObject wrapper around the `SpeechService` actor.
///
/// SwiftUI view structs get created and destroyed freely; holding an `actor`
/// directly as a view property risks recreating the underlying audio engine
/// on every view re-render. Owning the actor via an `@StateObject`-backed
/// reference type survives those re-renders and lets callers tear down the
/// recorder deterministically on view disappearance.
@MainActor
final class SpeechController: ObservableObject {
    private let service: SpeechService

    init() {
        self.service = SpeechService()
    }

    func transcribe() async throws -> AsyncThrowingStream<String, Error> {
        try await service.transcribe()
    }

    func stop() async {
        await service.stop()
    }
}
