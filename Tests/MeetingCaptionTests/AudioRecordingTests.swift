import AppKit
import AVFoundation
import CaptionCore
import Foundation
import Speech
import Testing
@testable import MeetingCaption

/// The recognizer's input format on Apple Silicon (SpeechAnalyzer.bestAvailableAudioFormat).
private let speechFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

private func tone(seconds: Double, amplitude: Int16 = 8_000) -> AVAudioPCMBuffer {
    let frames = AVAudioFrameCount(seconds * speechFormat.sampleRate)
    let buffer = AVAudioPCMBuffer(pcmFormat: speechFormat, frameCapacity: frames)!
    buffer.frameLength = frames
    let samples = buffer.int16ChannelData![0]
    for i in 0..<Int(frames) {
        samples[i] = Int16(Double(amplitude) * sin(Double(i) * 2 * .pi * 440 / speechFormat.sampleRate))
    }
    return buffer
}

private func decoded(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

@Suite(.serialized)
struct AudioSegmentWriterTests {
    @Test func writesAPlayableM4AWhoseTimelineMatchesCaptionTimes() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        // The session started at caption time 10 s. One second of tone, a 2 s capture gap
        // (the recognizer timeline skips it), then one more second of tone.
        let writer = AudioSegmentWriter(url: url, timelineStart: 10)
        let rate = Int64(speechFormat.sampleRate)
        writer.append(tone(seconds: 1), atFrame: 10 * rate)
        writer.append(tone(seconds: 1), atFrame: 13 * rate)
        let length = try #require(await writer.finish())
        #expect(length == 4)

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
        #expect(file.length == 4 * rate)
        let samples = try decoded(url)
        func level(_ from: Double, _ to: Double) -> Float {
            let range = Int(from * Double(rate))..<Int(to * Double(rate))
            return range.map { abs(samples[$0]) }.max() ?? 0
        }
        #expect(level(0.1, 0.9) > 0.1)
        #expect(level(1.1, 2.9) < 0.01)  // the gap is silence at its real position
        #expect(level(3.1, 3.9) > 0.1)
        // The second tone starts where caption time 13 s maps (offset 3 s), within 10 ms.
        let onset = try #require((Int(2.9 * Double(rate))..<samples.count).first { abs(samples[$0]) > 0.05 })
        #expect(abs(Double(onset) / Double(rate) - 3) < 0.01)
        #expect(AudioFileProbe.duration(url) == 4)
    }

    @Test func fileCutShortMidRecordingStillPlaysItsWrittenFragments() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        let cut = url.deletingPathExtension().appendingPathExtension("cut.m4a")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: cut)
        }
        let writer = AudioSegmentWriter(url: url, timelineStart: 0)
        for second in 0..<30 { writer.append(tone(seconds: 1), atFrame: Int64(second) * 16_000) }
        // Snapshot the file while it is still being written (what a crash would leave), cut
        // inside its last fragment; finishing afterwards rewrites the original as a whole file.
        let fragment = Data("moof".utf8)
        var snapshot = Data()
        for _ in 0..<100 {
            snapshot = (try? Data(contentsOf: url)) ?? Data()
            var count = 0
            var searchRange = snapshot.startIndex..<snapshot.endIndex
            while let found = snapshot.range(of: fragment, in: searchRange) {
                count += 1
                searchRange = found.upperBound..<snapshot.endIndex
            }
            if count >= 3 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try snapshot.prefix(snapshot.count - 100).write(to: cut)
        #expect(await writer.finish() == 30)
        let recovered = try #require(AudioFileProbe.duration(cut))
        #expect(recovered >= AudioSegmentWriter.fragmentSeconds && recovered < 30)
    }

    /// The real conversion path: 48 kHz capture with a 1.5 s capture-clock gap goes through
    /// `AudioFeeder`; the recognizer's buffer times and the file's timeline must agree.
    @Test func feederRecordsExactlyWhatRecognitionHearsAtTheSameTimes() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let capture = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let recorder = AudioSegmentWriter(url: url, timelineStart: 7)
        let feeder = AudioFeeder(target: speechFormat, continuation: continuation, offset: 7, recorder: recorder) { _ in }
        func chunk(silent: Bool) -> AVAudioPCMBuffer {
            let buffer = AVAudioPCMBuffer(pcmFormat: capture, frameCapacity: 4_800)!
            buffer.frameLength = 4_800
            for i in 0..<4_800 { buffer.floatChannelData![0][i] = silent ? 0 : Float(0.25 * sin(Double(i) * 2 * .pi * 440 / 48_000)) }
            return buffer
        }
        for i in 0..<10 { feeder.append(chunk(silent: true), timestamp: 100 + Double(i) * 0.1) }
        for i in 0..<10 { feeder.append(chunk(silent: false), timestamp: 102.5 + Double(i) * 0.1) }
        await feeder.finish()
        // Where recognition first hears the tone, on its own (caption) timeline.
        var heard: Double?
        for await input in stream where heard == nil {
            let buffer = input.buffer
            let start = try #require(input.bufferStartTime).seconds
            if let index = (0..<Int(buffer.frameLength)).first(where: { abs(Int(buffer.int16ChannelData![0][$0])) > 1_600 }) {
                heard = start + Double(index) / 16_000
            }
        }
        let speech = try #require(heard)
        // After the 1.5 s capture gap: caption time 7 + 2.5 s, give or take the resampler delay.
        #expect(abs(speech - 9.5) < 0.03)
        let length = try #require(await recorder.finish())
        #expect(abs(length - 3.5) < 0.05)
        let samples = try decoded(url)
        let onset = try #require(samples.indices.first { abs(samples[$0]) > 0.05 })
        // The file plays the tone at exactly caption time − segment start.
        #expect(abs(Double(onset) / 16_000 - (speech - 7)) < 0.005)
    }

    @Test func stopWhileARetryIsQueuedCompletesExactlyOnce() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        final class FirstBusy: @unchecked Sendable { var calls = 0 }
        let busy = FirstBusy()
        // The encoder is busy on the first append (a 20 ms retry is queued); finish() then drains
        // and completes before that retry fires.
        let writer = AudioSegmentWriter(url: url, timelineStart: 0, isReady: { input in
            busy.calls += 1
            return busy.calls > 1 && input.isReadyForMoreMediaData
        })
        writer.append(tone(seconds: 1), atFrame: 0)
        #expect(await writer.finish() == 1)
        try await Task.sleep(for: .milliseconds(150))
        #expect(writer.diagnostics.completions == 1)
        #expect(await writer.finish() == nil)
        #expect(writer.diagnostics.completions == 1)
    }

    @Test func longCaptureGapHoldsNoSilenceInMemory() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = AudioSegmentWriter(url: url, timelineStart: 0)
        let rate = Int64(speechFormat.sampleRate)
        writer.append(tone(seconds: 0.5), atFrame: 0)
        writer.append(tone(seconds: 0.5), atFrame: 600 * rate)  // a 10-minute gap
        let length = try #require(await writer.finish())
        #expect(length == 600.5)
        #expect(AudioFileProbe.duration(url) == 600.5)
        #expect(writer.diagnostics.peakHeldFrames <= rate)
    }

    @Test func nothingRecordedLeavesNoFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        let writer = AudioSegmentWriter(url: url, timelineStart: 0)
        #expect(await writer.finish() == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let discarded = AudioSegmentWriter(url: url, timelineStart: 0)
        discarded.append(tone(seconds: 1), atFrame: 0)
        await discarded.discard()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

@Suite(.serialized)
@MainActor
struct AudioRecordLifecycleTests {
    @Test func recordingFollowsTheRecordThroughSaveAndNewRenameRestoreAndTrash() async throws {
        try await withAudioModel { model, engine, trashed in
            model.start()
            for await recording in model.$isRecording.values where recording { break }
            engine.feed(seconds: 3)
            engine.emit("First lecture sentence.", start: 0.5, end: 2)
            #expect(model.playableCaptionIDs.isEmpty)  // never while recording
            model.saveAndStartNewSession()
            for await switching in model.$isSwitchingSession.values where !switching { break }
            for await recording in model.$isRecording.values where recording { break }

            let first = try #require(model.sessions.first)
            let firstRecord = try TranscriptDisk.load(first.url)
            let firstSegment = try #require(firstRecord.audio?.first)
            #expect(firstRecord.audio?.count == 1)
            #expect(firstSegment.start == 0)
            #expect(firstSegment.end == 3)
            let firstAudio = try #require(RecordAudio.url(of: firstSegment, record: first.url))
            #expect(firstAudio.lastPathComponent.hasPrefix(first.url.deletingPathExtension().lastPathComponent))
            #expect(AudioFileProbe.duration(firstAudio) == 3)
            #expect(first.audioFiles == [firstAudio])
            #expect(first.audioBytes > 0)
            #expect(model.totalAudioBytes == first.audioBytes)
            #expect(model.filesToReveal(first.url) == [first.url, firstAudio])

            // The new record is recording into its own file, not the previous record's.
            #expect(model.currentRecordURL != first.url)
            let second = try #require(model.transcript.audio?.first)
            #expect(second.end == nil)
            #expect(second.file != firstSegment.file)
            engine.feed(seconds: 1)
            model.stop()
            for await stopping in model.$isStopping.values where !stopping { break }
            #expect(model.transcript.audio?.first?.end == 1)

            model.rename(first.url, to: "Week 1")
            #expect(model.restore(url: first.url))
            #expect(model.transcript.title == "Week 1")
            #expect(model.hasPlayableAudio)
            let cue = try #require(model.transcript.captions.first)
            #expect(model.playableCaptionIDs == [cue.id])
            model.player.onPosition(0, 1)
            #expect(model.playingCaptionID == cue.id)

            model.trashRecord(first.url)
            #expect(trashed() == [first.url, firstAudio])
            #expect(!FileManager.default.fileExists(atPath: firstAudio.path))
            #expect(!model.hasPlayableAudio)
        }
    }

    @Test func resumedRecordAddsASegmentAtTheNextCaptionTime() async throws {
        try await withAudioModel { model, engine, _ in
            model.start()
            for await recording in model.$isRecording.values where recording { break }
            engine.feed(seconds: 4)
            engine.emit("Part one.", start: 1, end: 2.5)
            model.stop()
            for await stopping in model.$isStopping.values where !stopping { break }
            model.start()
            for await recording in model.$isRecording.values where recording { break }
            #expect(engine.offset == 2.5)
            engine.feed(seconds: 2)
            engine.emit("Part two.", start: 3, end: 4)
            model.stop()
            for await stopping in model.$isStopping.values where !stopping { break }
            let segments = try #require(model.transcript.audio)
            #expect(segments.map(\.start) == [0, 2.5])
            #expect(segments.map(\.end) == [2.5, 4.5])
            let ids = model.transcript.captions.map(\.id)
            #expect(model.playableCaptionIDs == Set(ids))
            #expect(AudioTimeline.locate(3, in: model.player.segments)?.index == 1)
            #expect(AudioTimeline.locate(3, in: model.player.segments)?.offset == 0.5)
        }
    }

    @Test func failedSaveKeepsAudioLinkedToItsOwnRecord() async throws {
        try await withAudioModel { model, engine, _ in
            model.start()
            for await recording in model.$isRecording.values where recording { break }
            engine.feed(seconds: 2)
            engine.emit("Keep this sentence.", start: 0, end: 1)
            let record = try #require(model.currentRecordURL)
            let directory = record.deletingLastPathComponent()
            let firstSegment = try #require(model.transcript.audio?.first)
            let audio = try #require(RecordAudio.url(of: firstSegment, record: record))
            for _ in 0..<100 where !FileManager.default.fileExists(atPath: audio.path) {
                try await Task.sleep(for: .milliseconds(20))
            }
            let displaced = directory.appendingPathExtension("held")
            defer { try? FileManager.default.removeItem(at: displaced) }
            try FileManager.default.moveItem(at: directory, to: displaced)
            try Data("not a directory".utf8).write(to: directory)

            model.saveAndStartNewSession()
            for await switching in model.$isSwitchingSession.values where !switching { break }
            // Saving failed, so no new record started and the audio stays with this one.
            #expect(model.currentRecordURL == record)
            #expect(model.transcript.plainText == "Keep this sentence.")
            #expect(model.transcript.audio?.count == 1)
            #expect(model.transcript.audio?.first?.end == 2)

            try FileManager.default.removeItem(at: directory)
            try FileManager.default.moveItem(at: displaced, to: directory)
            #expect(await model.shutdown())
            let saved = try TranscriptDisk.load(record)
            let segment = try #require(saved.audio?.first)
            #expect(segment.end == 2)
            #expect(AudioFileProbe.duration(try #require(RecordAudio.url(of: segment, record: record))) == 2)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasSuffix(".m4a") } == [segment.file])
        }
    }

    @Test func failedStartLeavesNoAudioBehind() async throws {
        try await withAudioModel { model, engine, _ in
            engine.failsToStart = true
            model.start()
            for await starting in model.$isStarting.values where !starting { break }
            #expect(model.errorMessage != nil)
            #expect(model.transcript.audio == nil)
            let record = try #require(model.currentRecordURL)
            #expect(try TranscriptDisk.load(record).audio == nil)
            #expect(try FileManager.default.contentsOfDirectory(atPath: record.deletingLastPathComponent().path)
                .allSatisfy { !$0.hasSuffix(".m4a") })
        }
    }

    @Test func settingOffRecordsNothing() async throws {
        try await withAudioModel(recording: false) { model, engine, _ in
            model.start()
            for await recording in model.$isRecording.values where recording { break }
            #expect(engine.recorder == nil)
            engine.emit("No audio.", start: 0, end: 1)
            model.stop()
            for await stopping in model.$isStopping.values where !stopping { break }
            #expect(model.transcript.audio == nil)
            #expect(!model.hasPlayableAudio)
            #expect(model.playableCaptionIDs.isEmpty)
            let record = try #require(model.currentRecordURL)
            #expect(!(try String(contentsOf: record, encoding: .utf8)).contains("\"audio\""))
        }
    }

    @Test func launchRecoversInterruptedAudioAndCleansUpUnplayableFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = directory.appendingPathComponent("meeting-crashed.json")
        let playable = directory.appendingPathComponent("meeting-crashed-audio-1.m4a")
        let writer = AudioSegmentWriter(url: playable, timelineStart: 0)
        writer.append(tone(seconds: 2), atFrame: 0)
        _ = await writer.finish()
        try Data("truncated before the first fragment".utf8).write(to: directory.appendingPathComponent("meeting-crashed-audio-2.m4a"))
        var crashed = Transcript(title: "Crashed", locale: "en-US", source: "system")
        crashed.captions = [Caption(start: 0.2, end: 1, text: "Before the crash.")]
        crashed.audio = [AudioSegment(file: playable.lastPathComponent, start: 0),
                         AudioSegment(file: "meeting-crashed-audio-2.m4a", start: 1)]
        try TranscriptDisk.save(crashed, at: record, srt: false)

        let model = MeetingModel(library: directory, googleKeyStore: AudioEmptyKeyStore(), translationKeyStores: emptyTranslationKeyStores())
        #expect(model.status.contains("복구"))
        #expect(model.status.contains("정리"))
        let repaired = try TranscriptDisk.load(record)
        #expect(repaired.audio == [AudioSegment(file: playable.lastPathComponent, start: 0, end: 1)])
        #expect(repaired.captions.map(\.text) == ["Before the crash."])
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("meeting-crashed-audio-2.m4a").path))
        #expect(model.restore(url: record))
        #expect(model.hasPlayableAudio)
        _ = await model.shutdown()
    }

    @Test func captionsWithAudioOfferPlayFromHere() throws {
        let text = TranscriptTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        text.textContainerInset = NSSize(width: 20, height: 14)
        let coordinator = MeetingTranscriptText.Coordinator()
        let cues = [Caption(start: 1, end: 2, text: "Heard."), Caption(start: 3, end: 4, text: "Not recorded.")]
        var played: [UUID] = []
        var view = MeetingTranscriptText(captions: cues, provisional: "", showsTranslation: false, autoScroll: true,
                                         playable: [cues[0].id], playing: cues[0].id, onPlay: { played.append($0) })
        view.updateText(text, coordinator: coordinator)
        // The ▶ marker is drawn in the margin, never part of the selectable/copyable text.
        #expect(text.string == "00:00:03.000  Not recorded.\n00:00:01.000  Heard.\n")
        let markers = text.playMarkers()
        #expect(markers.map(\.id) == [cues[0].id])
        let marker = try #require(markers.first)
        let heard = (text.string as NSString).range(of: "Heard.").location
        let layout = try #require(text.layoutManager)
        let line = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: heard), effectiveRange: nil)
        #expect(abs(marker.rect.minY - (line.minY + text.textContainerOrigin.y)) < 0.5)
        #expect(marker.rect.maxX <= text.textContainerOrigin.x)
        #expect(text.clickPlayMarker(at: NSPoint(x: marker.rect.midX, y: marker.rect.midY)))
        #expect(!text.clickPlayMarker(at: NSPoint(x: 200, y: marker.rect.midY)))
        #expect(played == [cues[0].id])
        text.selectAll(nil)
        view.captions.append(Caption(start: 5, end: 6, text: "New."))
        view.playable.insert(view.captions[2].id)
        view.updateText(text, coordinator: coordinator)
        let all = text.selectedRange()
        #expect(all == NSRange(location: 0, length: (text.string as NSString).length))
        #expect(!(text.string as NSString).substring(with: all).contains("▶"))
        #expect(text.playMarkers().count == 2)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let heardNow = (text.string as NSString).range(of: "Heard.").location
        let unrecorded = (text.string as NSString).range(of: "Not recorded.").location
        #expect(coordinator.textView(text, menu: NSMenu(), for: event, at: heardNow)?.items.map(\.title).prefix(2) == ["중요 표시", "여기부터 듣기"])
        #expect(coordinator.textView(text, menu: NSMenu(), for: event, at: unrecorded)?.items.map(\.title).contains("여기부터 듣기") == false)
    }

    // MARK: Harness

    private func withAudioModel(recording: Bool = true,
                                body: (MeetingModel, AudioFeedingEngine, () -> [URL]) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = UserDefaults.standard
        let keys = ["meetingRecordAudio", "meetingCaptionPauseSeconds"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            try? FileManager.default.removeItem(at: directory)
        }
        let engine = AudioFeedingEngine()
        var trashed: [URL] = []
        let model = MeetingModel(library: directory, engineFactory: { engine }, googleKeyStore: AudioEmptyKeyStore(), translationKeyStores: emptyTranslationKeyStores(),
                                 trashItem: {
                                     trashed.append($0)
                                     try FileManager.default.removeItem(at: $0)
                                 })
        model.captionPauseSeconds = 0
        model.recordsAudio = recording
        try await body(model, engine, { trashed })
        _ = await model.shutdown()
    }
}

private struct AudioEmptyKeyStore: MeetingAIKeyStoring {
    func loadAPIKey() -> String? { nil }
    func saveAPIKey(_ key: String) throws {}
    func removeAPIKey() throws {}
}

/// Stands in for the live engine: hands synthetic recognizer-format audio to the recorder at
/// the recognizer timeline positions `AudioFeeder` would use.
@MainActor
private final class AudioFeedingEngine: MeetingSpeechEngine {
    var onPacket: (SpeechPacket) -> Void = { _ in }
    var onStatus: (String) -> Void = { _ in }
    var onFailure: (String) -> Void = { _ in }
    var recorder: AudioSegmentWriter?
    var offset = 0.0
    var failsToStart = false
    private var fed: Int64 = 0

    func startLive(source: String, localeID: String, offset: Double) async throws {}
    func startLive(source: String, localeID: String, offset: Double, recorder: AudioSegmentWriter?) async throws {
        self.recorder = recorder
        self.offset = offset
        fed = 0
        if failsToStart {
            recorder?.append(tone(seconds: 0.5), atFrame: Int64(offset * 16_000))
            throw AppFailure("권한이 없습니다.")
        }
    }
    func finish() async throws {}
    func cancel() async {}

    func feed(seconds: Double) {
        let buffer = tone(seconds: seconds)
        recorder?.append(buffer, atFrame: Int64((offset * 16_000).rounded()) + fed)
        fed += Int64(buffer.frameLength)
    }

    func emit(_ text: String, start: Double, end: Double) {
        onPacket(SpeechPacket(captions: [Caption(start: start, end: end, text: text)], text: text, isFinal: true))
    }
}
