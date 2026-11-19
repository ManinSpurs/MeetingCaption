import CaptionCore
import Combine
import Foundation
import Testing
@testable import MeetingCaption

@MainActor
struct SessionTransitionTests {
    @Test func splittingSavesTheTailAndStartsOnlyOneFreshRecording() async throws {
        try await withModel { model, first, second in
            let source = model.source.rawValue
            let locale = model.localeID
            model.cloudTranslationConsent = true
            model.saveAndStartNewSession()
            model.saveAndStartNewSession()
            for await _ in first.finishing { break }
            #expect(second.starts.isEmpty)
            first.release()
            for await recording in model.$isRecording.values {
                if recording { break }
            }
            #expect(second.starts.count == 1)
            #expect(second.starts.first?.source == source)
            #expect(second.starts.first?.locale == locale)
            #expect(second.starts.first?.offset == 0)
            #expect(model.transcript.captions.isEmpty)
            #expect(!model.cloudTranslationConsent)
            let archived = try #require(model.sessions.first { $0.count == 2 })
            #expect(model.recentlySavedURL?.standardizedFileURL.path == archived.url.standardizedFileURL.path)
            #expect(try TranscriptDisk.load(archived.url).plainText == "Before the split.\nLast sentence.")
            first.onPacket(SpeechPacket(
                captions: [Caption(start: 4, end: 5, text: "Stale packet.")],
                text: "Stale packet.", isFinal: true
            ))
            #expect(model.transcript.captions.isEmpty)
        }
    }

    @Test func failedSaveKeepsTheOldRecordAndDoesNotRestart() async throws {
        try await withModel { model, first, second in
            let original = model.transcript.created
            let displaced = model.library.appendingPathExtension("held")
            model.saveAndStartNewSession()
            for await _ in first.finishing { break }
            try FileManager.default.moveItem(at: model.library, to: displaced)
            try Data("not a directory".utf8).write(to: model.library)
            first.release()
            for await switching in model.$isSwitchingSession.values {
                if !switching { break }
            }
            #expect(second.starts.isEmpty)
            #expect(model.transcript.created == original)
            #expect(model.transcript.plainText == "Before the split.\nLast sentence.")
            #expect(model.errorMessage != nil)
            try FileManager.default.removeItem(at: model.library)
            try FileManager.default.moveItem(at: displaced, to: model.library)
        }
    }

    @Test func quittingDuringSplitSavesWithoutStartingAnotherRecording() async throws {
        try await withModel { model, first, second in
            model.saveAndStartNewSession()
            for await _ in first.finishing { break }
            let release = Task { @MainActor in first.release() }
            #expect(await model.shutdown())
            await release.value
            #expect(second.starts.isEmpty)
            #expect(!model.isLocked)
            #expect(model.transcript.plainText == "Before the split.\nLast sentence.")
        }
    }

    private func withModel(
        body: (MeetingModel, SessionEngine, SessionEngine) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = SessionEngine(holdsFinish: true)
        let second = SessionEngine(holdsFinish: false)
        var madeFirst = false
        let model = MeetingModel(library: directory, engineFactory: {
            if !madeFirst { madeFirst = true; return first }
            return second
        }, googleKeyStore: SessionEmptyKeyStore(), translationKeyStores: emptyTranslationKeyStores())
        let pauseKey = "meetingCaptionPauseSeconds"
        let previousPause = UserDefaults.standard.object(forKey: pauseKey)
        model.captionPauseSeconds = 0
        if let previousPause { UserDefaults.standard.set(previousPause, forKey: pauseKey) }
        else { UserDefaults.standard.removeObject(forKey: pauseKey) }
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: directory.appendingPathExtension("held"))
        }
        model.start()
        for await recording in model.$isRecording.values {
            if recording { break }
        }
        first.onPacket(SpeechPacket(
            captions: [Caption(start: 0, end: 1, text: "Before the split.")],
            text: "Before the split.", isFinal: true
        ))
        do {
            try await body(model, first, second)
        } catch {
            first.release()
            _ = await model.shutdown()
            throw error
        }
        _ = await model.shutdown()
    }
}

private struct SessionEmptyKeyStore: MeetingAIKeyStoring {
    func loadAPIKey() -> String? { nil }
    func saveAPIKey(_ key: String) throws {}
    func removeAPIKey() throws {}
}

@MainActor
private final class SessionEngine: MeetingSpeechEngine {
    var onPacket: (SpeechPacket) -> Void = { _ in }
    var onStatus: (String) -> Void = { _ in }
    var onFailure: (String) -> Void = { _ in }
    var starts: [(source: String, locale: String, offset: Double)] = []
    let finishing: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private let holdsFinish: Bool
    private var pending: CheckedContinuation<Void, Never>?

    init(holdsFinish: Bool) {
        self.holdsFinish = holdsFinish
        (finishing, signal) = AsyncStream<Void>.makeStream()
    }

    func startLive(source: String, localeID: String, offset: Double) async throws {
        starts.append((source, localeID, offset))
    }

    func finish() async throws {
        if holdsFinish {
            await withCheckedContinuation {
                pending = $0
                signal.yield(())
                signal.finish()
            }
            onPacket(SpeechPacket(
                captions: [Caption(start: 2, end: 3, text: "Last sentence.")],
                text: "Last sentence.", isFinal: true
            ))
        }
    }

    func cancel() async { release() }
    func release() { pending?.resume(); pending = nil }
}
