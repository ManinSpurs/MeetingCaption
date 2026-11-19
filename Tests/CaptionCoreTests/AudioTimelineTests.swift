import Foundation
import Testing
@testable import CaptionCore

@Suite("Audio timeline")
struct AudioTimelineTests {
    @Test func captionTimesMapOntoTheirSessionsAudio() throws {
        // Session 1 recorded 0–95 s of audio; its last caption ended at 90 s, where session 2
        // (no audio) started; session 3 started at 120 s with audio.
        var segments = [AudioSegment(file: "a-1.m4a", start: 0, end: 95)]
        AudioTimeline.closeSegments(&segments, at: 90)
        AudioTimeline.closeSegments(&segments, at: 120)
        segments.append(AudioSegment(file: "a-2.m4a", start: 120, end: 180))

        #expect(AudioTimeline.locate(12.5, in: segments)?.index == 0)
        #expect(AudioTimeline.locate(12.5, in: segments)?.offset == 12.5)
        // Session 2 captions have no audio, even though the first file is longer than 90 s.
        #expect(AudioTimeline.locate(92, in: segments) == nil)
        #expect(AudioTimeline.locate(119, in: segments) == nil)
        let late = try #require(AudioTimeline.locate(150.25, in: segments))
        #expect(late.index == 1)
        #expect(abs(late.offset - 30.25) < 1e-9)
        // A recognizer time a hair before the rounded first frame still plays from 0.
        #expect(AudioTimeline.locate(119.995, in: segments).map { [$0.index] } == [1])
        #expect(AudioTimeline.locate(119.995, in: segments)?.offset == 0)
        #expect(AudioTimeline.locate(181, in: segments) == nil)
    }

    @Test func unfinishedSegmentIsNeverPlayable() {
        let segments = [AudioSegment(file: "a-1.m4a", start: 0)]
        #expect(AudioTimeline.locate(1, in: segments) == nil)
    }

    @Test func pauseMergedSentenceStartsAtItsFirstWordsAndStaysLitThroughPauses() {
        // A 2 s pause merge joined "We discussed" (10–11 s) and "the policy." (12.5–13 s); the
        // speaker then paused until 20 s.
        let segments = [AudioSegment(file: "a-1.m4a", start: 5, end: 40)]
        let merged = Caption(start: 10, end: 13, text: "We discussed the policy.")
        let next = Caption(start: 20, end: 21, text: "Next topic.")
        let captions = [merged, next]
        #expect(AudioTimeline.locate(merged.start, in: segments)?.offset == 5)
        #expect(AudioTimeline.caption(atOffset: 4, segment: 0, in: segments, captions: captions) == nil)
        #expect(AudioTimeline.caption(atOffset: 7.6, segment: 0, in: segments, captions: captions)?.id == merged.id)
        #expect(AudioTimeline.caption(atOffset: 12, segment: 0, in: segments, captions: captions)?.id == merged.id)
        #expect(AudioTimeline.caption(atOffset: 15, segment: 0, in: segments, captions: captions)?.id == next.id)
    }

    @Test func playingOneSegmentNeverLightsAnotherSessionsCaption() {
        let segments = [AudioSegment(file: "a-1.m4a", start: 0, end: 30),
                        AudioSegment(file: "a-2.m4a", start: 30, end: 60)]
        let first = Caption(start: 25, end: 29, text: "End of part one.")
        let second = Caption(start: 31, end: 33, text: "Part two.")
        // The first file runs on past 30 s (the tail after its last sentence).
        #expect(AudioTimeline.caption(atOffset: 34, segment: 0, in: segments, captions: [first, second])?.id == first.id)
        #expect(AudioTimeline.caption(atOffset: 1, segment: 1, in: segments, captions: [first, second])?.id == second.id)
    }
}

@Suite("Record audio files")
struct RecordAudioFileTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func segmentNamesFollowTheRecordAndNeverCollide() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = directory.appendingPathComponent("meeting-X.json")
        var transcript = Transcript(title: "T", locale: "en-US", source: "system")
        #expect(RecordAudio.newSegmentFile(for: transcript, record: record) == "meeting-X-audio-1.m4a")
        try Data().write(to: directory.appendingPathComponent("meeting-X-audio-1.m4a"))
        #expect(RecordAudio.newSegmentFile(for: transcript, record: record) == "meeting-X-audio-2.m4a")
        transcript.audio = [AudioSegment(file: "meeting-X-audio-2.m4a", start: 0, end: 1)]
        #expect(RecordAudio.newSegmentFile(for: transcript, record: record) == "meeting-X-audio-3.m4a")
        // A stored name cannot point outside the archive folder.
        let escaped = RecordAudio.url(of: AudioSegment(file: "../../etc/x.m4a", start: 0), record: record)
        #expect(escaped == directory.appendingPathComponent("x.m4a"))
    }

    @Test func audioLinksNamingTheFolderOrItsParentAreRejected() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = directory.appendingPathComponent("meeting-X.json")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("sub.m4a"), withIntermediateDirectories: true)
        for name in ["..", ".", "", "/", "a/..", "../", ".hidden.m4a"] {
            #expect(RecordAudio.url(of: AudioSegment(file: name, start: 0), record: record) == nil, "\(name)")
        }
        var transcript = Transcript(title: "T", locale: "en-US", source: "system")
        transcript.audio = [AudioSegment(file: "..", start: 0), AudioSegment(file: ".", start: 1),
                            AudioSegment(file: "sub.m4a", start: 2, end: 3)]
        #expect(RecordAudio.files(of: transcript, record: record).isEmpty)
        // Recovery unlinks such entries without touching anything on disk.
        transcript.audio = [AudioSegment(file: "..", start: 0), AudioSegment(file: "sub.m4a", start: 2)]
        let recovery = RecordAudio.recover(&transcript, record: record) { _ in nil }
        #expect(recovery.removed == 2)
        #expect(transcript.audio == nil)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("sub.m4a").path))
        #expect(TranscriptLibrary.entries(in: directory).allSatisfy { $0.audioFiles.isEmpty })
    }

    @Test func interruptedSegmentsAreRecoveredOrCleanedUp() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = directory.appendingPathComponent("meeting-X.json")
        let playable = directory.appendingPathComponent("meeting-X-audio-1.m4a")
        let broken = directory.appendingPathComponent("meeting-X-audio-2.m4a")
        try Data("fragments".utf8).write(to: playable)
        try Data("no header".utf8).write(to: broken)
        var transcript = Transcript(title: "T", locale: "en-US", source: "system")
        transcript.audio = [
            AudioSegment(file: "meeting-X-audio-1.m4a", start: 0),
            AudioSegment(file: "meeting-X-audio-2.m4a", start: 50),
            AudioSegment(file: "meeting-X-audio-3.m4a", start: 70)  // crashed before any audio
        ]
        let recovery = RecordAudio.recover(&transcript, record: record) { $0 == playable ? 62 : nil }
        #expect(recovery == RecordAudio.Recovery(recovered: 1, removed: 2))
        // 62 s were playable, but session 2 began at 50 s and owns the captions from there.
        #expect(transcript.audio == [AudioSegment(file: "meeting-X-audio-1.m4a", start: 0, end: 50)])
        #expect(FileManager.default.fileExists(atPath: playable.path))
        #expect(!FileManager.default.fileExists(atPath: broken.path))
        #expect(RecordAudio.recover(&transcript, record: record) { _ in nil } == RecordAudio.Recovery())

        var lost = Transcript(title: "T", locale: "en-US", source: "system")
        lost.audio = [AudioSegment(file: "gone.m4a", start: 0)]
        #expect(RecordAudio.recover(&lost, record: record) { _ in nil }.removed == 1)
        #expect(lost.audio == nil)
    }

    @Test func recoveredSegmentIsCutAtTheNextSession() {
        var transcript = Transcript(title: "T", locale: "en-US", source: "system")
        transcript.audio = [AudioSegment(file: "a-1.m4a", start: 0), AudioSegment(file: "a-2.m4a", start: 40, end: 60)]
        _ = RecordAudio.recover(&transcript, record: URL(fileURLWithPath: "/tmp/r.json")) { _ in 45 }
        #expect(transcript.audio?.first?.end == 40)
    }

    @Test func recordsWithoutAudioKeepTheirShapeAndAudioOnlyRecordsAreListed() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = directory.appendingPathComponent("meeting-old.json")
        try StorageCompatibilityTests.legacyJSON.write(to: legacy, atomically: true, encoding: .utf8)
        let loaded = try TranscriptDisk.load(legacy)
        #expect(loaded.audio == nil)
        try TranscriptDisk.save(loaded, at: legacy, srt: false)
        #expect(!(try String(contentsOf: legacy, encoding: .utf8)).contains("\"audio\""))

        // Silence recognized as nothing still leaves a listed record, so its audio is never hidden.
        let record = directory.appendingPathComponent("meeting-new.json")
        var withAudio = Transcript(title: "Audio only", locale: "en-US", source: "microphone")
        withAudio.audio = [AudioSegment(file: "meeting-new-audio-1.m4a", start: 0, end: 3)]
        try TranscriptDisk.save(withAudio, at: record, srt: false)
        try Data(count: 1234).write(to: directory.appendingPathComponent("meeting-new-audio-1.m4a"))
        let entries = TranscriptLibrary.entries(in: directory)
        #expect(entries.map(\.title) == ["Audio only", "Old lecture"])
        #expect(entries[0].audioBytes == 1234)
        #expect(entries[0].audioFiles.map(\.lastPathComponent) == ["meeting-new-audio-1.m4a"])
        #expect(entries[1].audioFiles.isEmpty)

        // Without its file an audio-only empty record disappears like any empty record.
        try FileManager.default.removeItem(at: directory.appendingPathComponent("meeting-new-audio-1.m4a"))
        #expect(TranscriptLibrary.entries(in: directory).map(\.title) == ["Old lecture"])
    }

    @Test func audioLinkIsInvisibleToTheOldRecordShapeAndSurvivesRename() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        var transcript = Transcript(title: "New", locale: "en-US", source: "system")
        transcript.captions = [Caption(start: 0, end: 1, text: "Hello.")]
        transcript.audio = [AudioSegment(file: "a-1.m4a", start: 0, end: 12.5)]
        try TranscriptDisk.save(transcript, at: url, srt: false)
        let old = try JSONDecoder().decode(StorageCompatibilityTests.LegacyTranscript.self, from: Data(contentsOf: url))
        #expect(old.version == 1)
        #expect(old.captions.map(\.text) == ["Hello."])
        try TranscriptLibrary.update(url) { $0.title = "Renamed" }
        let reloaded = try TranscriptDisk.load(url)
        #expect(reloaded.title == "Renamed")
        #expect(reloaded.audio == transcript.audio)
    }
}
