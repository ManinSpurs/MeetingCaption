import CaptionCore
import Combine
import Foundation
import Testing
@testable import MeetingCaption

@Suite(.serialized)
@MainActor
struct GoogleTranslationIntegrationTests {
    @Test func consentBlocksTransmissionAndFinishedCaptionsTranslateInOrder() async throws {
        var calls: [String] = []
        try await withModel(translate: { text, locale, key in
            #expect(locale == "en-US")
            #expect(key == "google-test-key-no-network-12345")
            calls.append(text)
            return text == "First." ? "첫 번째." : "두 번째."
        }) { model in
            model.transcript.captions = [
                Caption(start: 0, end: 1, text: "First."),
                Caption(start: 2, end: 3, text: "Second.")
            ]
            await model.runCloudTranslation()
            #expect(calls.isEmpty)
            model.cloudTranslationConsent = true
            let work = Task { await model.runCloudTranslation() }
            for await transcript in model.$transcript.values {
                if transcript.captions.last?.koreanText == "두 번째." { break }
            }
            work.cancel()
            await work.value
            #expect(calls == ["First.", "Second."])
            #expect(model.transcript.captions.map(\.koreanText) == ["첫 번째.", "두 번째."])
        }
    }

    @Test func revokingConsentRejectsLateResultAndStopsNextRequest() async throws {
        let gate = GoogleResultGate()
        try await withModel(translate: { _, _, _ in await gate.respond() }) { model in
            model.transcript.captions = [
                Caption(start: 0, end: 1, text: "One."),
                Caption(start: 2, end: 3, text: "Two.")
            ]
            model.cloudTranslationConsent = true
            let work = Task { await model.runCloudTranslation() }
            for await _ in gate.started { break }
            model.cloudTranslationConsent = false
            gate.release()
            await work.value
            #expect(gate.calls == 1)
            #expect(model.transcript.captions.allSatisfy { $0.koreanText == nil })
        }
    }

    @Test(arguments: [true, false])
    func changingRecordRequiresFreshConsent(restoreArchive: Bool) async throws {
        var calls = 0
        try await withModel(translate: { _, _, _ in
            calls += 1
            throw URLError(.notConnectedToInternet)
        }) { model in
            model.transcript.captions = [Caption(start: 0, end: 1, text: "Archived record.")]
            model.newSession()
            let archive = try #require(model.sessions.first { $0.count == 1 })
            model.cloudTranslationConsent = true
            if restoreArchive {
                model.restore(archive)
            } else {
                model.newSession()
                model.transcript.captions = [Caption(start: 0, end: 1, text: "New record.")]
            }
            await model.runCloudTranslation()
            #expect(calls == 0)
            #expect(model.transcript.captions.allSatisfy { $0.koreanText == nil })
        }
    }

    private func withModel(
        translate: @escaping (String, String, String) async throws -> String,
        body: (MeetingModel) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = UserDefaults.standard
        let keys = ["captionTranslationProvider", "meetingSpeechLocale"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            try? FileManager.default.removeItem(at: directory)
        }
        let model = MeetingModel(library: directory, googleKeyStore: FakeGoogleKeyStore(), translationKeyStores: emptyTranslationKeyStores(), cloudTranslate: { _, text, locale, keys in try await translate(text, locale, keys[0]) })
        model.localeID = "en-US"
        model.translationProvider = .google
        try await body(model)
        _ = await model.shutdown()
    }
}

private struct FakeGoogleKeyStore: MeetingAIKeyStoring {
    func loadAPIKey() -> String? { "google-test-key-no-network-12345" }
    func saveAPIKey(_ key: String) throws {}
    func removeAPIKey() throws {}
}

@MainActor
private final class GoogleResultGate {
    let started: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private var pending: CheckedContinuation<String, Never>?
    private(set) var calls = 0
    init() { (started, signal) = AsyncStream<Void>.makeStream() }
    func respond() async -> String {
        calls += 1
        return await withCheckedContinuation {
            pending = $0
            signal.yield(())
            signal.finish()
        }
    }
    func release() { pending?.resume(returning: "늦은 결과"); pending = nil }
}
