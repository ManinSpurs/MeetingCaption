import CaptionCore
import Combine
import Foundation
import Testing
@testable import MeetingCaption

@MainActor
struct CaptionPauseIntegrationTests {
    @Test func shortPausesJoinBeforeTranslationAndSaveImmediately() async throws {
        try await withModel { model, engine, gate in
            engine.emit("We discussed", start: 0, end: 1)
            for await _ in gate.started { break }
            #expect(model.nextTranslationCaption == nil)
            engine.emit("the policy.", start: 2, end: 3)
            for await _ in gate.started { break }
            #expect(model.transcript.plainText == "We discussed the policy.")
            #expect(model.nextTranslationCaption == nil)
            #expect(gate.delays == [2, 2])
            #expect(model.persist())
            model.refreshLibrary()
            let saved = try #require(model.sessions.first)
            #expect(try TranscriptDisk.load(saved.url).plainText == "We discussed the policy.")
            gate.release()
            for await waiting in model.$isWaitingForCaptionPause.values {
                if !waiting { break }
            }
            #expect(model.nextTranslationCaption?.text == "We discussed the policy.")
        }
    }

    @Test func longAudioGapReleasesEarlierGroupAndTurningOffReleasesTheLast() async throws {
        try await withModel { model, engine, gate in
            engine.emit("Earlier.", start: 0, end: 1)
            for await _ in gate.started { break }
            engine.emit("Later.", start: 4, end: 5)
            for await _ in gate.started { break }
            #expect(model.transcript.captions.map(\.text) == ["Earlier.", "Later."])
            #expect(model.nextTranslationCaption?.text == "Earlier.")
            let first = try #require(model.transcript.captions.firstIndex { $0.text == "Earlier." })
            model.transcript.captions[first].koreanText = "이전."
            #expect(model.nextTranslationCaption == nil)
            setPause(0, model: model)
            #expect(model.nextTranslationCaption?.text == "Later.")
            engine.emit("Immediate.", start: 6, end: 7)
            #expect(model.transcript.captions.map(\.text) == ["Earlier.", "Later.", "Immediate."])
            #expect(!model.isWaitingForCaptionPause)
        }
    }

    @Test func stopFlushesPendingWordsBeforeStartingAnotherRecord() async throws {
        try await withModel { model, engine, gate in
            engine.emit("Keep these words.", start: 0, end: 1)
            for await _ in gate.started { break }
            model.stop()
            for await stopping in model.$isStopping.values {
                if !stopping { break }
            }
            #expect(!model.isWaitingForCaptionPause)
            #expect(model.nextTranslationCaption?.text == "Keep these words.")
            model.newSession()
            gate.release()
            #expect(model.transcript.captions.isEmpty)
            #expect(!model.isWaitingForCaptionPause)
            let saved = try #require(model.sessions.first)
            #expect(try TranscriptDisk.load(saved.url).plainText == "Keep these words.")
        }
    }

    @Test func releasedGroupKeepsItsWordsAndTranslationWhenAConstituentIsReplayed() async throws {
        try await withModel { model, engine, gate in
            engine.emit("We discussed", start: 0, end: 1)
            for await _ in gate.started { break }
            engine.emit("the policy.", start: 2, end: 3)
            for await _ in gate.started { break }
            gate.release()
            for await waiting in model.$isWaitingForCaptionPause.values {
                if !waiting { break }
            }
            model.transcript.captions[0].koreanText = "정책을 논의했습니다."
            engine.emit("We discussed", start: 0, end: 1)
            #expect(model.transcript.plainText == "We discussed the policy.")
            #expect(model.transcript.captions.first?.koreanText == "정책을 논의했습니다.")
            #expect(model.nextTranslationCaption == nil)
            engine.emit("We reviewed", start: 0, end: 1)
            #expect(model.transcript.plainText == "We reviewed the policy.")
            #expect(model.transcript.captions.first?.koreanText == nil)
        }
    }

    private func setPause(_ seconds: Double, model: MeetingModel) {
        let key = "meetingCaptionPauseSeconds"
        let previous = UserDefaults.standard.object(forKey: key)
        model.captionPauseSeconds = seconds
        if let previous { UserDefaults.standard.set(previous, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    private func withModel(
        body: (MeetingModel, PauseEngine, PauseGate) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let engine = PauseEngine()
        let gate = PauseGate()
        let model = MeetingModel(library: directory, engineFactory: { engine },
                                 googleKeyStore: PauseEmptyKeyStore(), translationKeyStores: emptyTranslationKeyStores(),
                                 captionPauseSleep: { await gate.wait($0) })
        setPause(2, model: model)
        defer { try? FileManager.default.removeItem(at: directory) }
        model.start()
        for await recording in model.$isRecording.values {
            if recording { break }
        }
        do { try await body(model, engine, gate) }
        catch {
            gate.release()
            _ = await model.shutdown()
            throw error
        }
        _ = await model.shutdown()
        gate.release()
    }
}

private struct PauseEmptyKeyStore: MeetingAIKeyStoring {
    func loadAPIKey() -> String? { nil }
    func saveAPIKey(_ key: String) throws {}
    func removeAPIKey() throws {}
}

@MainActor
private final class PauseGate {
    let started: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private var pending: [CheckedContinuation<Void, Never>] = []
    var delays: [Double] = []
    init() { (started, signal) = AsyncStream<Void>.makeStream() }
    func wait(_ delay: Double) async {
        delays.append(delay)
        await withCheckedContinuation {
            pending.append($0)
            signal.yield(())
        }
    }
    func release() {
        let held = pending
        pending.removeAll()
        held.forEach { $0.resume() }
    }
}

@MainActor
private final class PauseEngine: MeetingSpeechEngine {
    var onPacket: (SpeechPacket) -> Void = { _ in }
    var onStatus: (String) -> Void = { _ in }
    var onFailure: (String) -> Void = { _ in }
    func startLive(source: String, localeID: String, offset: Double) async throws {}
    func finish() async throws {}
    func cancel() async {}
    func emit(_ text: String, start: Double, end: Double) {
        onPacket(SpeechPacket(captions: [Caption(start: start, end: end, text: text)], text: text, isFinal: true))
    }
}
