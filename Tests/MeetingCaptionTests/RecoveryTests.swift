import AppKit
import AVFoundation
import AudioCaptureBridge
import AudioCaptureTestSupport
import CaptionCore
import CoreAudio
import Testing
@testable import MeetingCaption

@MainActor
struct RecoveryTests {
    @Test func missingDeviceCannotUsePlaceholderFormat() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        #expect(throws: AppFailure.self) {
            try MicrophoneInput.validate(deviceID: kAudioObjectUnknown, format: format)
        }
    }

    @Test func nativeTapExceptionBecomesSwiftError() async throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        do {
            try MCAudioTap.installInputTap(MCMakeThrowingTapNode(), format: format) { _, _ in }
            Issue.record("Expected the invalid hardware format to be reported.")
        } catch {
            #expect(error.localizedDescription == "Input HW format is invalid")
        }
        await Task.yield()
        MainActor.preconditionIsolated()
    }

    @Test func translationPreparationCanRetrySamePair() throws {
        let state = MeetingViewState()
        let language = Locale.Language(identifier: "en")
        state.prepareTranslation(source: language)
        let first = try #require(state.translationConfiguration)
        state.prepareTranslation(source: language)
        #expect(state.translationConfiguration != first)
    }

    @Test func failedSaveKeepsTheOnlyCopyOfTheMeeting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let displaced = directory.appendingPathExtension("held")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: displaced)
        }
        let model = MeetingModel(library: directory, translationKeyStores: emptyTranslationKeyStores(includingGoogle: true))
        model.transcript.captions = [Caption(start: 0, end: 1, text: "Keep this sentence.")]
        let title = model.transcript.title
        try FileManager.default.moveItem(at: directory, to: displaced)
        try Data("not a directory".utf8).write(to: directory)
        model.newSession()
        #expect(model.transcript.plainText == "Keep this sentence.")
        #expect(model.transcript.title == title)
        #expect(model.errorMessage != nil)
        #expect(await model.shutdown() == false)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: displaced, to: directory)
        #expect(await model.shutdown())
    }

    @Test func exportCollisionDoesNotOverwriteAnyFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("meeting.txt")
        let sidecar = directory.appendingPathComponent("meeting.ko.txt")
        try "Original sentinel".write(to: original, atomically: true, encoding: .utf8)
        try "Korean sentinel".write(to: sidecar, atomically: true, encoding: .utf8)
        var transcript = Transcript(title: "Meeting", locale: "en-US", source: "system")
        transcript.captions = [Caption(start: 0, end: 1, text: "Hello", koreanText: "안녕하세요")]
        #expect(throws: TranscriptExportError.self) {
            try TranscriptExport.write(transcript, to: original, format: .txt)
        }
        #expect(try String(contentsOf: original, encoding: .utf8) == "Original sentinel")
        #expect(try String(contentsOf: sidecar, encoding: .utf8) == "Korean sentinel")
    }
}

@MainActor
struct SettingsWindowTests {
    @Test func everyPaneHasATitleAndTheNavigationStartsOnGeneral() {
        #expect(SettingsPane.allCases.map(\.title) == ["일반", "번역", "AI", "용어집", "업데이트", "개인정보"])
        #expect(SettingsNavigation().pane == .general)
    }

    @Test func cloudTranslationAsksForConsentThenKeysInTheMainWindow() {
        func notice(_ provider: CaptionTranslationProvider, consent: Bool, keys: Bool, locked: Bool = true,
                    status: String = "") -> TranslationNotice {
            .current(enabled: true, provider: provider, consent: consent, hasKeys: keys, sourceIsKorean: false,
                     hasPending: false, isLocked: locked, status: status)
        }
        #expect(notice(.google, consent: false, keys: true) == .needsConsent)
        #expect(notice(.google, consent: true, keys: false) == .needsKeys)
        #expect(notice(.google, consent: true, keys: true) == .none)
        #expect(notice(.google, consent: false, keys: true, locked: false) == .none)
        #expect(notice(.apple, consent: false, keys: false, status: "번역 모델 준비를 눌러 언어 모델을 설치해 주세요.")
                == .problem("번역 모델 준비를 눌러 언어 모델을 설치해 주세요."))
        #expect(notice(.apple, consent: false, keys: false, status: "Apple 번역 켜짐") == .none)
    }
}
