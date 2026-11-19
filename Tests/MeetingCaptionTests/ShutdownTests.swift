import CaptionCore
import Combine
import Foundation
import Testing
@testable import MeetingCaption

@MainActor
struct ShutdownTests {
    @Test func quittingDuringStopPreservesTheFinalSentence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = HeldFinalizationEngine()
        let model = MeetingModel(library: directory, engineFactory: { audio },
                                 translationKeyStores: emptyTranslationKeyStores(includingGoogle: true))
        model.start()
        for await recording in model.$isRecording.values {
            if recording { break }
        }
        model.stop()
        for await _ in audio.finishing { break }

        // The tail can arrive only after shutdown yields to the in-flight finalizer.
        let release = Task { @MainActor in audio.releaseTail() }
        await model.shutdown()
        await release.value
        for await stopping in model.$isStopping.values {
            if !stopping { break }
        }

        #expect(!audio.cancelledDuringFinish)
        #expect(model.transcript.plainText == "The final sentence.")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let saved = try #require(files.first { $0.pathExtension == "json" })
        #expect(try TranscriptDisk.load(saved).plainText == "The final sentence.")
    }
}

@MainActor
private final class HeldFinalizationEngine: MeetingSpeechEngine {
    var onPacket: (SpeechPacket) -> Void = { _ in }
    var onStatus: (String) -> Void = { _ in }
    var onFailure: (String) -> Void = { _ in }
    let finishing: AsyncStream<Void>
    private let entered: AsyncStream<Void>.Continuation
    private var tail: CheckedContinuation<Void, Never>?
    private(set) var cancelledDuringFinish = false
    private var isFinishing = false

    init() {
        (finishing, entered) = AsyncStream<Void>.makeStream()
    }

    func startLive(source: String, localeID: String, offset: Double) async throws {}

    func finish() async throws {
        isFinishing = true
        await withCheckedContinuation { continuation in
            tail = continuation
            entered.yield(())
            entered.finish()
        }
        if !cancelledDuringFinish {
            onPacket(SpeechPacket(captions: [Caption(start: 0, end: 1, text: "The final sentence.")],
                                  text: "The final sentence.", isFinal: true))
        }
        isFinishing = false
    }

    func cancel() async {
        cancelledDuringFinish = isFinishing
        releaseTail()
    }

    func releaseTail() {
        tail?.resume()
        tail = nil
    }
}
