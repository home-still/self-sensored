import AVFoundation
import Foundation
@preconcurrency import Speech

enum SpeechError: Error, Sendable {
    case notAuthorized
    case unavailable
    case audioEngineFailure(String)
    case recognizerFailure(String)
}

actor SpeechService {
    private let recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Sibling task that finishes the stream with `.recognizerFailure` when
    /// the recognizer stays silent for too long (iOS 17+ regression where
    /// `isAvailable == true` but no results ever arrive).
    private var silenceWatchdog: Task<Void, Never>?

    init(locale: Locale = .current) {
        self.recognizer = SFSpeechRecognizer(locale: locale)
    }

    static func requestAuthorization() async -> Bool {
        let speechOk = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        let micOk = await AVAudioApplication.requestRecordPermission()
        return speechOk && micOk
    }

    /// Stream transcription updates from live microphone input. The stream
    /// yields the best-hypothesis transcript after each partial result and
    /// finishes when the recognizer reports `isFinal`.
    func transcribe() async throws -> AsyncThrowingStream<String, Error> {
        guard let recognizer, recognizer.isAvailable else {
            throw SpeechError.unavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        request.customizedLanguageModel = await FoodLanguageModel.configuration()
        self.request = request

        // Track whether setup got far enough that we own resources to clean up.
        // Guarantees the audio session is deactivated and the tap removed on
        // every throw path.
        var succeeded = false
        defer {
            if !succeeded {
                resetAudioState()
            }
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw SpeechError.audioEngineFailure(error.localizedDescription)
        }

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)

        // Start the engine *before* installing the tap. A failed start with a
        // tap already installed leaves an orphan that the next `stop()` won't
        // remove (isRunning == false).
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            throw SpeechError.audioEngineFailure(error.localizedDescription)
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }

        succeeded = true

        return AsyncThrowingStream { continuation in
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    continuation.finish(throwing: SpeechError.recognizerFailure(error.localizedDescription))
                    return
                }
                if let result {
                    continuation.yield(result.bestTranscription.formattedString)
                    if result.isFinal {
                        continuation.finish()
                    }
                }
            }
            self.task = task

            // 10 s silence watchdog — surfaces the "speech silent" iOS 17
            // regression as an actionable error instead of a hung UI.
            self.silenceWatchdog = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self else { return }
                if await self.hasTaskRunning() {
                    continuation.finish(throwing: SpeechError.recognizerFailure(
                        "speech service silent — check Siri/Dictation settings"
                    ))
                }
            }

            continuation.onTermination = { @Sendable _ in
                Task { await self.stop() }
            }
        }
    }

    /// Snapshot used by the watchdog to decide whether to fire.
    fileprivate func hasTaskRunning() -> Bool {
        task != nil
    }

    func stop() {
        silenceWatchdog?.cancel()
        silenceWatchdog = nil
        resetAudioState()
        task?.cancel()
        task = nil
    }

    /// Tear down the audio engine / tap / session. Safe to call multiple times
    /// and from any throw path — idempotent.
    private func resetAudioState() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
