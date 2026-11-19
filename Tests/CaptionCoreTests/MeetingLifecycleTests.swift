import Foundation
import Testing
@testable import CaptionCore

@Suite("Meeting lifecycle")
struct MeetingLifecycleTests {
    @Test func finalMergeKeepsTranslationAndStaysChronological() {
        var transcript = Transcript(title: "회의", locale: "en-US", source: "system")
        transcript.mergeFinal([Caption(start: 4, end: 6, text: "Second."), Caption(start: 1, end: 3, text: "First.")])
        #expect(transcript.captions.map(\.text) == ["First.", "Second."])
        let firstID = transcript.captions[0].id
        transcript.captions[0].koreanText = "첫 번째."

        // The recognizer re-delivers the same cue with unchanged text.
        transcript.mergeFinal([Caption(start: 1, end: 3, text: "First.")])
        #expect(transcript.captions.count == 2)
        #expect(transcript.captions[0].id == firstID)
        #expect(transcript.captions[0].koreanText == "첫 번째.")

        // Changed text must not display a translation of the old text.
        transcript.mergeFinal([Caption(start: 1, end: 3.5, text: "First, corrected.")])
        #expect(transcript.captions[0].koreanText == nil)
        #expect(transcript.captions[0].id == firstID)
    }

    @Test func repeatedWordsAtDifferentTimesStaySeparate() {
        var transcript = Transcript(title: "회의", locale: "en-US", source: "microphone")
        transcript.mergeFinal([Caption(start: 0, end: 1, text: "Yes."), Caption(start: 2, end: 3, text: "Yes.")])
        #expect(transcript.captions.count == 2)
        #expect(transcript.nextStartTime == 3)
    }

    @Test func translationFollowsChronologicalOrder() {
        var transcript = Transcript(title: "회의", locale: "en-US", source: "system")
        transcript.captions = [
            Caption(start: 0, end: 1, text: "One", koreanText: "하나"),
            Caption(start: 1, end: 2, text: "Two"),
            Caption(start: 2, end: 3, text: "Three")
        ]
        #expect(transcript.firstUntranslated?.text == "Two")
        transcript.captions[1].koreanText = "둘"
        #expect(transcript.firstUntranslated?.text == "Three")
        transcript.captions[2].koreanText = "셋"
        #expect(transcript.firstUntranslated == nil)
    }

    @Test func exportKeepsOriginalAndAddsKoreanAndBilingualFiles() throws {
        var transcript = Transcript(title: "회의/기록", locale: "en-US", source: "system")
        transcript.captions = [Caption(start: 0, end: 1.5, text: "Hello", koreanText: "안녕하세요"), Caption(start: 2, end: 3, text: "Bye")]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let txt = directory.appendingPathComponent("meeting.txt")
        let written = try TranscriptExport.write(transcript, to: txt, format: .txt)
        #expect(written.map(\.lastPathComponent).sorted() == ["meeting.bilingual.txt", "meeting.ko.txt", "meeting.txt"])
        #expect(try String(contentsOf: txt, encoding: .utf8) == "Hello\nBye")
        #expect(try String(contentsOf: directory.appendingPathComponent("meeting.ko.txt"), encoding: .utf8) == "안녕하세요")

        let srt = directory.appendingPathComponent("meeting.srt")
        _ = try TranscriptExport.write(transcript, to: srt, format: .srt)
        let original = try String(contentsOf: srt, encoding: .utf8)
        #expect(!original.contains("안녕하세요"))
        let bilingual = try String(contentsOf: directory.appendingPathComponent("meeting.bilingual.srt"), encoding: .utf8)
        #expect(bilingual.contains("Hello\n안녕하세요"))
        #expect(try Transcript.parseSRT(bilingual).count == 2)
    }

    @Test func exportWithoutTranslationsWritesOnlyOriginal() {
        var transcript = Transcript(title: "회의", locale: "en-US", source: "system")
        transcript.captions = [Caption(start: 0, end: 1, text: "Hello")]
        #expect(TranscriptExport.files(for: transcript, to: URL(fileURLWithPath: "/tmp/m.srt"), format: .srt).map(\.url.lastPathComponent) == ["m.srt"])
        // A panel result without the expected suffix still produces the intended format.
        #expect(TranscriptExport.files(for: transcript, to: URL(fileURLWithPath: "/tmp/m"), format: .srt).map(\.url.lastPathComponent) == ["m.srt"])
    }

    @Test func libraryListsOnlyReadableRecordsNewestFirst() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var older = Transcript(title: "어제 회의", locale: "en-US", source: "system")
        older.created = Date(timeIntervalSince1970: 1_000)
        older.captions = [Caption(start: 0, end: 1, text: "a")]
        var newer = Transcript(title: "오늘 회의", locale: "en-US", source: "microphone")
        newer.created = Date(timeIntervalSince1970: 2_000)
        newer.captions = [Caption(start: 0, end: 1, text: "b"), Caption(start: 1, end: 2, text: "c")]
        try TranscriptDisk.save(older, at: directory.appendingPathComponent("older.json"), srt: false)
        try TranscriptDisk.save(newer, at: directory.appendingPathComponent("newer.json"), srt: false)
        // Unreadable and empty records must not appear as history.
        try Data("{ not json".utf8).write(to: directory.appendingPathComponent("broken.json"))
        try TranscriptDisk.save(Transcript(title: "빈 기록", locale: "en-US", source: "system"), at: directory.appendingPathComponent("empty.json"), srt: false)

        let entries = TranscriptLibrary.entries(in: directory)
        #expect(entries.map(\.title) == ["오늘 회의", "어제 회의"])
        #expect(entries.map(\.count) == [2, 1])
    }

    @Test func restoredRecordRoundTripsWithoutLoss() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var transcript = Transcript(title: "회의", locale: "en-US", source: "microphone")
        transcript.captions = [Caption(start: 0, end: 1.25, text: "Hello", koreanText: "안녕하세요")]
        let url = TranscriptLibrary.newSessionURL(in: directory)
        try TranscriptDisk.save(transcript, at: url, srt: false)
        let loaded = try TranscriptDisk.load(url)
        #expect(loaded.captions == transcript.captions)
        #expect(loaded.source == "microphone")
        // Directory listings return /private/var/... while the temp dir is /var/..., so compare resolved paths.
        let listed = try #require(TranscriptLibrary.entries(in: directory).first?.url)
        #expect(listed.resolvingSymlinksInPath() == url.resolvingSymlinksInPath())
    }
}

