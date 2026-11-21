import AVFoundation
import CaptionCore
import Foundation
import Speech
import Testing
@testable import MeetingCaption

/// The recognizer's input format on Apple Silicon (SpeechAnalyzer.bestAvailableAudioFormat).
private let recognizerFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

private func recognizerTone(seconds: Double) -> AVAudioPCMBuffer {
    let frames = AVAudioFrameCount(seconds * recognizerFormat.sampleRate)
    let buffer = AVAudioPCMBuffer(pcmFormat: recognizerFormat, frameCapacity: frames)!
    buffer.frameLength = frames
    let samples = buffer.int16ChannelData![0]
    for i in 0..<Int(frames) {
        samples[i] = Int16(8_000 * sin(Double(i) * 2 * .pi * 440 / recognizerFormat.sampleRate))
    }
    return buffer
}

/// A stereo 44.1 kHz WAV: nothing about it matches the recognizer's format.
private func writeStereoWAV(seconds: Double, to url: URL) throws {
    let file = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
    ])
    let frames = AVAudioFrameCount(seconds * 44_100)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
    buffer.frameLength = frames
    for channel in 0..<2 {
        let samples = buffer.floatChannelData![channel]
        for i in 0..<Int(frames) { samples[i] = Float(0.4 * sin(Double(i) * 2 * .pi * 440 / 44_100)) }
    }
    try file.write(from: buffer)
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []
    func add(_ value: Double) { lock.lock(); recorded.append(value); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return recorded }
}

@Suite(.serialized)
struct FileAudioSourceTests {
    @Test func decodesAnyAudioFileOntoTheCaptionTimelineAndKeepsACopy() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wav = directory.appendingPathComponent("lecture.wav")
        try writeStereoWAV(seconds: 2, to: wav)
        let copy = directory.appendingPathComponent("copy.m4a")
        let writer = AudioSegmentWriter(url: copy, timelineStart: 0)
        let progress = ProgressLog()
        let source = try await FileAudioSource(url: wav, target: recognizerFormat, recorder: writer) { progress.add($0) }
        #expect(abs(source.duration - 2) < 0.01)

        var expectedStart: Int64 = 0
        while let input = source.next() {
            #expect(input.buffer.format == recognizerFormat)
            // Chunks sit back to back, so a caption time is a position in the file.
            #expect(input.bufferStartTime == CMTime(value: expectedStart, timescale: 16_000))
            expectedStart += Int64(input.buffer.frameLength)
        }
        #expect(abs(expectedStart - 32_000) <= 160)
        #expect(source.failure == nil)
        #expect(progress.values.last == 1)
        #expect(progress.values == progress.values.sorted())

        let length = try #require(await writer.finish())
        #expect(abs(length - 2) < 0.02)
        #expect(AudioFileProbe.duration(copy) == length)
    }

    @Test func stoppingEndsTheInputWithoutAnError() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wav = directory.appendingPathComponent("long.wav")
        try writeStereoWAV(seconds: 2, to: wav)
        let source = try await FileAudioSource(url: wav, target: recognizerFormat)
        #expect(source.next() != nil)
        source.stop()
        #expect(source.next() == nil)
        #expect(source.failure == nil)
    }

    @Test func aFileWithoutSoundIsRefusedWithAReason() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("not audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: AppFailure.self) {
            _ = try await FileAudioSource(url: url, target: recognizerFormat)
        }
    }
}

@Suite(.serialized)
@MainActor
struct FileImportTests {
    @Test func importedFileBecomesItsOwnRecordWithReplayableAudio() async throws {
        try await withImportModel { model, engine in
            // A live record is open and has a sentence; importing must not touch it.
            model.start()
            for await recording in model.$isRecording.values where recording { break }
            engine.emit("Live sentence.", start: 0, end: 1)
            model.stop()
            for await stopping in model.$isStopping.values where !stopping { break }
            let live = try #require(model.currentRecordURL)
            let finishedBefore = engine.finishCalls

            model.importFile(URL(fileURLWithPath: "/tmp/Lecture 3.m4a"))
            for await recording in model.$isRecording.values where recording { break }
            let record = try #require(model.currentRecordURL)
            #expect(record != live)
            #expect(engine.fileURL?.lastPathComponent == "Lecture 3.m4a")
            #expect(model.isImporting && model.isLocked)
            #expect(model.transcript.title == "Lecture 3")
            #expect(model.transcript.source == MeetingModel.fileSource)
            #expect(model.transcript.captions.isEmpty)

            engine.feed(seconds: 3)
            engine.emit("First point of the lecture.", start: 0.5, end: 2)
            engine.progress?(0.5)
            for await progress in model.$importProgress.values where progress == 0.5 { break }

            engine.reachEnd()
            for await progress in model.$importProgress.values where progress == nil { break }
            #expect(!model.isLocked)
            #expect(engine.finishCalls == finishedBefore + 1)
            #expect(model.status.hasPrefix("파일 받아쓰기를 마쳤습니다."))
            #expect(model.transcript.audio?.map(\.end) == [3])
            #expect(model.hasPlayableAudio)
            let cue = try #require(model.transcript.captions.first)
            #expect(model.playableCaptionIDs == [cue.id])
            #expect(model.sessions.first { model.isCurrentRecord($0.url) }?.title == "Lecture 3")
            #expect(try TranscriptDisk.load(live).captions.map(\.text) == ["Live sentence."])

            // Live speech is never appended to a record that came from a file.
            model.start()
            for await recording in model.$isRecording.values where recording { break }
            #expect(model.currentRecordURL != record)
            #expect(model.transcript.source == "system")
            #expect(!model.isImporting)
        }
    }

    @Test func stoppingAnImportKeepsWhatWasRecognizedSoFar() async throws {
        try await withImportModel { model, engine in
            model.importFile(URL(fileURLWithPath: "/tmp/Seminar.mp4"))
            for await recording in model.$isRecording.values where recording { break }
            engine.feed(seconds: 2)
            engine.emit("Only the opening was read.", start: 0, end: 1.5)
            model.stop()
            for await progress in model.$importProgress.values where progress == nil { break }
            #expect(!model.isLocked)
            #expect(model.status.hasPrefix("파일 받아쓰기를 중지했습니다."))
            #expect(model.transcript.captions.map(\.text) == ["Only the opening was read."])
            #expect(model.transcript.audio?.map(\.end) == [2])
            let record = try #require(model.currentRecordURL)
            #expect(try TranscriptDisk.load(record).captions.count == 1)
        }
    }

    @Test func aFileThatCannotBeReadLeavesNoAudioLinkAndSaysWhy() async throws {
        try await withImportModel { model, engine in
            engine.startFailure = "이 파일에는 받아쓸 소리가 없습니다."
            model.importFile(URL(fileURLWithPath: "/tmp/Slides.mov"))
            #expect(model.isStarting)
            for await starting in model.$isStarting.values where !starting { break }
            #expect(!model.isLocked && !model.isImporting)
            #expect(model.errorMessage == "이 파일에는 받아쓸 소리가 없습니다.")
            #expect(model.transcript.audio == nil)
            let folder = try #require(model.currentRecordURL).deletingLastPathComponent()
            let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            #expect(!left.contains { $0.hasSuffix(".m4a") })
        }
    }

    @Test func importIsRefusedWhileARecordingIsRunning() async throws {
        try await withImportModel { model, engine in
            model.start()
            for await recording in model.$isRecording.values where recording { break }
            let record = model.currentRecordURL
            model.importFile(URL(fileURLWithPath: "/tmp/Other.m4a"))
            #expect(model.currentRecordURL == record)
            #expect(engine.fileURL == nil)
            #expect(!model.isImporting)
        }
    }

    /// A time cited in a summary selects its caption; one the record does not have says so
    /// and leaves the reader where they were.
    @Test func summaryTimeOpensItsCaption() async throws {
        try await withImportModel { model, engine in
            model.start()
            for await recording in model.$isRecording.values where recording { break }
            engine.emit("Opening remark.", start: 3, end: 6)
            engine.emit("The decision.", start: 40.4, end: 44)
            model.stop()
            for await stopping in model.$isStopping.values where !stopping { break }
            let decision = try #require(model.transcript.captions.last)

            model.showsMarkedOnly = true
            model.openStamp("00:40")
            #expect(model.highlight?.captionID == decision.id)
            #expect(!model.showsMarkedOnly)

            let shown = model.highlight
            model.openStamp("59:00")
            #expect(model.highlight == shown)
            #expect(model.status.contains("59:00"))
        }
    }

    // MARK: Harness

    private func withImportModel(body: (MeetingModel, FileEngine) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = UserDefaults.standard
        let keys = ["meetingRecordAudio", "meetingCaptionPauseSeconds", "meetingInputSource"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            try? FileManager.default.removeItem(at: directory)
        }
        defaults.set("system", forKey: "meetingInputSource")
        let engine = FileEngine()
        let model = MeetingModel(library: directory, engineFactory: { engine }, googleKeyStore: ImportEmptyKeyStore(),
                                 translationKeyStores: emptyTranslationKeyStores())
        model.captionPauseSeconds = 0
        model.recordsAudio = false
        try await body(model, engine)
        _ = await model.shutdown()
    }
}

private struct ImportEmptyKeyStore: MeetingAIKeyStoring {
    func loadAPIKey() -> String? { nil }
    func saveAPIKey(_ key: String) throws {}
    func removeAPIKey() throws {}
}

/// Stands in for the recognizer: a file "plays" for as long as the test wants, and the test
/// feeds recognizer-format audio and captions the way a real file would produce them.
@MainActor
private final class FileEngine: MeetingSpeechEngine {
    var onPacket: (SpeechPacket) -> Void = { _ in }
    var onStatus: (String) -> Void = { _ in }
    var onFailure: (String) -> Void = { _ in }
    var startFailure: String?
    private(set) var fileURL: URL?
    private(set) var progress: (@Sendable (Double) -> Void)?
    private(set) var finishCalls = 0
    private var recorder: AudioSegmentWriter?
    private var fed: Int64 = 0
    private var ended = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func startLive(source: String, localeID: String, offset: Double) async throws {}

    func startFile(url: URL, localeID: String, recorder: AudioSegmentWriter?,
                   progress: @escaping @Sendable (Double) -> Void) async throws {
        if let startFailure { throw AppFailure(startFailure) }
        fileURL = url
        self.recorder = recorder
        self.progress = progress
        fed = 0
        ended = false
    }

    func waitUntilFileEnds() async throws {
        guard !ended else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func reachEnd() {
        ended = true
        waiters.forEach { $0.resume() }
        waiters = []
    }

    func finish() async throws {
        finishCalls += 1
        reachEnd()
    }

    func cancel() async { reachEnd() }

    func feed(seconds: Double) {
        let buffer = recognizerTone(seconds: seconds)
        recorder?.append(buffer, atFrame: fed)
        fed += Int64(buffer.frameLength)
    }

    func emit(_ text: String, start: Double, end: Double) {
        onPacket(SpeechPacket(captions: [Caption(start: start, end: end, text: text)], text: text, isFinal: true))
    }
}
