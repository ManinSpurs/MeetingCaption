import Foundation
import Testing
@testable import CaptionCore

// XCTest is unavailable in a CommandLineTools-only install, so these assertions use Swift Testing.
@Suite("Transcript")
struct TranscriptTests {
    @Test func longTranscriptSurvivesSaveAndSRT() throws {
        var transcript = Transcript(title: "강의", locale: "en-US", source: "system")
        transcript.captions = (0..<150).map { Caption(start: Double($0) * 3.25, end: Double($0) * 3.25 + 2, text: "문장 \($0): 정책과 public policy.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("lecture.json")
        try TranscriptDisk.save(transcript, at: url, srt: true)
        #expect(try TranscriptDisk.load(url).captions == transcript.captions)
        let parsed = try Transcript.parseSRT(String(contentsOf: url.deletingPathExtension().appendingPathExtension("srt"), encoding: .utf8))
        #expect(parsed.count == 150)
        #expect(parsed.map(\.text) == transcript.captions.map(\.text))
        #expect(abs(parsed.last!.start - transcript.captions.last!.start) < 0.001)
        #expect(transcript.plainText.contains("문장 149"))
    }

    @Test func koreanTranslationPreservesOriginalAndTimes() throws {
        var transcript = Transcript(title: "Test", locale: "ja-JP", source: "web")
        transcript.captions = [Caption(start: 2, end: 4, text: "こんにちは。", koreanText: "안녕하세요."), Caption(start: 5, end: 7, text: "未完了")]
        let data = try JSONEncoder().encode(transcript)
        let loaded = try JSONDecoder().decode(Transcript.self, from: data)
        #expect(loaded.plainText == "こんにちは。\n未完了")
        #expect(loaded.koreanTranscript.captions.count == 1)
        #expect(loaded.koreanTranscript.captions[0].start == 2)
        #expect(loaded.koreanTranscript.srt.contains("안녕하세요."))
        #expect(!loaded.srt.contains("안녕하세요."))
        let legacy = Data("{\"id\":\"00000000-0000-0000-0000-000000000001\",\"start\":0,\"end\":1,\"text\":\"Old\"}".utf8)
        #expect(try JSONDecoder().decode(Caption.self, from: legacy).koreanText == nil)
    }

    @Test func timeRoundingAndLongRecording() {
        #expect(Transcript.timestamp(3599.9996) == "01:00:00,000")
        #expect(Transcript.timestamp(360_000.125) == "100:00:00,125")
        #expect(Transcript.timestamp(-3) == "00:00:00,000")
    }

    @Test func importMultilineAndRejectBadTimes() throws {
        let cues = try Transcript.parseSRT("\u{FEFF}1\r\n00:01:00,125 --> 00:01:03,500\r\nHello\r\n안녕하세요\r\n")
        #expect(cues.first?.text == "Hello\n안녕하세요")
        #expect(cues.first?.start == 60.125)
        #expect(throws: Transcript.FormatError.self) { try Transcript.parseSRT("1\n00:00:03,000 --> 00:00:02,000\ninvalid") }
    }
}

