import Foundation
import Testing
@testable import CaptionCore

@Suite("Bookmarks")
struct BookmarkTests {
    @Test func markSurvivesRevisedTextAndSaveLoad() throws {
        var transcript = Transcript(title: "Lecture", locale: "en-US", source: "system")
        transcript.mergeFinal([Caption(start: 0, end: 1, text: "Grows"), Caption(start: 2, end: 3, text: "Other.")])
        transcript.captions[0].isBookmarked = true
        transcript.mergeFinal([Caption(start: 0, end: 1.5, text: "Grows longer.")])
        #expect(transcript.captions[0].text == "Grows longer.")
        #expect(transcript.captions[0].isBookmarked)
        #expect(!transcript.captions[1].isBookmarked)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try TranscriptDisk.save(transcript, at: url, srt: false)
        let loaded = try TranscriptDisk.load(url)
        #expect(loaded.captions.map(\.isBookmarked) == [true, false])
        // An unmarked caption writes no key, so older builds see exactly the 1.4 shape.
        let json = try String(contentsOf: url, encoding: .utf8)
        #expect(json.components(separatedBy: "\"bookmarked\"").count == 2)
    }

    @Test func txtExportIndicatesMarksAndCanExportMarkedOnly() {
        var transcript = Transcript(title: "Lecture", locale: "en-US", source: "system")
        transcript.captions = [
            Caption(start: 0, end: 1, text: "Intro.", koreanText: "소개."),
            Caption(start: 2, end: 3, text: "Key point.", koreanText: "핵심."),
            Caption(start: 4, end: 5, text: "Outro.")
        ]
        transcript.captions[1].isBookmarked = true
        let url = URL(fileURLWithPath: "/tmp/lecture.txt")
        let full = TranscriptExport.files(for: transcript, to: url, format: .txt)
        #expect(full.map(\.text) == [
            "Intro.\n★ Key point.\nOutro.",
            "소개.\n★ 핵심.",
            "Intro.\n소개.\n\n★ Key point.\n핵심.\n\nOutro."
        ])
        let marked = TranscriptExport.files(for: transcript, to: url, format: .txt, markedOnly: true)
        #expect(marked.map(\.text) == ["Key point.", "핵심.", "Key point.\n핵심."])
        let srt = TranscriptExport.files(for: transcript, to: url, format: .srt)
        #expect(!srt[0].text.contains("★"))
        #expect(transcript.plainText == "Intro.\nKey point.\nOutro.")
    }
}

@Suite("Storage compatibility")
struct StorageCompatibilityTests {
    /// Exactly what 1.0–1.4 wrote (sorted keys, no subject/bookmark fields).
    static let legacyJSON = """
    {
      "captions" : [
        {
          "end" : 2.5,
          "id" : "6F9619FF-8B86-D011-B42D-00C04FC964FF",
          "koreanText" : "안녕하세요.",
          "start" : 1,
          "text" : "Hello."
        },
        {
          "end" : 4,
          "id" : "7F9619FF-8B86-D011-B42D-00C04FC964FF",
          "start" : 3,
          "text" : "Untranslated."
        }
      ],
      "created" : 780000000,
      "locale" : "en-US",
      "source" : "system",
      "title" : "Old lecture",
      "version" : 1
    }
    """

    @Test func legacyRecordLoadsUnchangedAndListsAsUnclassified() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("meeting-old.json")
        try Self.legacyJSON.write(to: url, atomically: true, encoding: .utf8)
        let loaded = try TranscriptDisk.load(url)
        #expect(loaded.title == "Old lecture")
        #expect(loaded.subject == nil)
        #expect(loaded.captions.map(\.text) == ["Hello.", "Untranslated."])
        #expect(loaded.captions.map(\.koreanText) == ["안녕하세요.", nil])
        #expect(loaded.captions.allSatisfy { !$0.isBookmarked })
        let entry = try #require(TranscriptLibrary.entries(in: directory).first)
        #expect(entry.subject == nil)
        #expect(entry.bookmarkCount == 0)
    }

    /// The 1.4 Codable shape, standing in for an older build reading a 1.5 file.
    struct LegacyCaption: Codable { var id: UUID; var start: Double; var end: Double; var text: String; var koreanText: String? }
    struct LegacyTranscript: Codable {
        var version: Int; var title: String; var locale: String; var source: String
        var created: Date; var captions: [LegacyCaption]
    }

    @Test func newFieldsStayReadableByTheOldShape() throws {
        var transcript = Transcript(title: "New", locale: "en-US", source: "microphone")
        transcript.subject = "자료구조"
        transcript.captions = [Caption(start: 0, end: 1, text: "Marked.", koreanText: "표시됨.")]
        transcript.captions[0].isBookmarked = true
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try TranscriptDisk.save(transcript, at: url, srt: false)
        let old = try JSONDecoder().decode(LegacyTranscript.self, from: Data(contentsOf: url))
        #expect(old.version == 1)
        #expect(old.captions.map(\.text) == ["Marked."])
        #expect(old.captions.map(\.koreanText) == ["표시됨."])
        let reloaded = try TranscriptDisk.load(url)
        #expect(reloaded.subject == "자료구조")
        #expect(reloaded.captions[0].isBookmarked)
    }

    @Test func renameAndSubjectRewriteOnlyThoseFields() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.legacyJSON.write(to: url, atomically: true, encoding: .utf8)
        let before = try TranscriptDisk.load(url)
        try TranscriptLibrary.update(url) {
            $0.title = "Week 1"
            $0.subject = "  Algorithms "
        }
        let after = try TranscriptDisk.load(url)
        #expect(after.title == "Week 1")
        #expect(Transcript.normalizedSubject(after.subject) == "Algorithms")
        #expect(after.captions == before.captions)
        #expect(after.created == before.created)
    }
}

@Suite("Record grouping")
struct RecordGroupingTests {
    @Test func groupsBySubjectCaseInsensitivelyWithUnclassifiedLast() {
        let items: [(String, String?)] = [("a", "Physics"), ("b", nil), ("c", "algorithms"), ("d", "physics "), ("e", "  ")]
        let groups = RecordGrouping.grouped(items) { $0.1 }
        #expect(groups.map(\.subject) == ["algorithms", "Physics", nil])
        #expect(groups.map { $0.items.map(\.0) } == [["c"], ["a", "d"], ["b", "e"]])
        #expect(RecordGrouping.subjects(["B", nil, "a", "b"]) == ["a", "B"])
    }
}

@Suite("Record search")
struct RecordSearchTests {
    private func record(_ title: String, created: TimeInterval, _ captions: [Caption]) -> Transcript {
        var transcript = Transcript(title: title, locale: "en-US", source: "system")
        transcript.created = Date(timeIntervalSince1970: created)
        transcript.captions = captions
        return transcript
    }

    @Test func matchesOriginalTranslationAndTitleIgnoringCaseAndDiacritics() throws {
        let cue = Caption(start: 0, end: 1, text: "The CAFÉ example uses a Résumé.", koreanText: "카페 예시")
        let older = record("Week 1", created: 10, [cue])
        let newer = record("Cafe chat", created: 20, [Caption(start: 0, end: 1, text: "Nothing here.")])
        let url1 = URL(fileURLWithPath: "/tmp/1.json"), url2 = URL(fileURLWithPath: "/tmp/2.json")
        let results = RecordSearch.search("cafe", in: [(url1, older), (url2, newer)])
        #expect(results.map(\.url) == [url2, url1])
        #expect(results[0].hits.map(\.field) == [.title])
        #expect(results[0].hits[0].captionID == nil)
        let hit = try #require(results[1].hits.first)
        #expect(hit.captionID == cue.id)
        #expect(hit.field == .original)
        #expect(hit.match == "CAFÉ")
        #expect(hit.snippet == cue.text)

        let korean = RecordSearch.search("카페", in: [(url1, older)])
        #expect(korean.first?.hits.map(\.field) == [.translation])
        #expect(RecordSearch.search("resume", in: [(url1, older)]).count == 1)
        #expect(RecordSearch.search("   ", in: [(url1, older)]).isEmpty)
        #expect(RecordSearch.search("absent", in: [(url1, older)]).isEmpty)
    }

    @Test func longCaptionsGiveTrimmedSnippetsAndCountAllMatches() throws {
        let long = String(repeating: "a", count: 100) + " target " + String(repeating: "b", count: 100)
        let transcript = record("T", created: 0, (0..<5).map { Caption(start: Double($0), end: Double($0) + 0.5, text: long) })
        let result = try #require(RecordSearch.result(for: "TARGET", in: transcript, url: URL(fileURLWithPath: "/tmp/x.json")))
        #expect(result.matchCount == 5)
        #expect(result.hits.count == 3)
        #expect(result.hits[0].before.hasPrefix("…"))
        #expect(result.hits[0].after.hasSuffix("…"))
        #expect(result.hits[0].match == "target")
        #expect(result.hits[0].snippet.count < long.count)
    }
}

@Suite("Glossary")
struct GlossaryTests {
    let glossary = Glossary(entries: [
        GlossaryEntry(term: "eigenvalue", korean: "고유값", variants: ["eigen value", "I can value"]),
        GlossaryEntry(term: "Big-O", korean: "", variants: ["big oh"]),
        GlossaryEntry(term: "heap", korean: "힙", variants: ["hip"]),
        GlossaryEntry(term: "machine learning", korean: "기계학습")
    ])

    @Test func correctsVariantsWholeWordCaseInsensitively() {
        #expect(glossary.corrected("The Eigen Value and the i can value.") == "The eigenvalue and the eigenvalue.")
        #expect(glossary.corrected("Big Oh notation; shipping hips? hip.") == "Big-O notation; shipping hips? heap.")
        #expect(glossary.corrected("chipmunk") == "chipmunk")
        #expect(glossary.corrected("") == "")
        #expect(Glossary().corrected("hip") == "hip")
    }

    @Test func fixedRenderingReplacesPlaceholdersAndRepairsParticles() throws {
        let protection = try #require(glossary.protect("The Eigenvalue of a heap and machine learning."))
        #expect(protection.text == "The QXZ0Q of a QXZ1Q and QXZ2Q.")
        #expect(protection.renderings == ["고유값", "힙", "기계학습"])
        // The translator picked particles for the placeholder; they follow the rendering.
        #expect(protection.restore("QXZ1Q의 QXZ0Q를 QXZ2Q가 계산합니다.") == "힙의 고유값을 기계학습이 계산합니다.")
        #expect(protection.restore("QXZ2Q으로 QXZ1Q을 QXZ0Q이다.") == "기계학습으로 힙을 고유값이다.")
        #expect(glossary.protect("No terms here.") == nil)
        #expect(glossary.protect("heaps of data") == nil)
    }

    @Test func shortTermsSkipSymbolJoinedTokens() throws {
        let short = Glossary(entries: [
            GlossaryEntry(term: "C", korean: "씨", variants: ["see"]),
            GlossaryEntry(term: "NET", korean: "넷"),
            GlossaryEntry(term: "O", korean: "오"),
            GlossaryEntry(term: "heap", korean: "힙")
        ])
        let protection = try #require(short.protect("C++ uses a heap"))
        #expect(protection.text == "C++ uses a QXZ0Q")
        #expect(short.protect("C# runs on .NET and ASP.NET with Big-O and TCP/IP") == nil)
        #expect(short.protect("a heap-based queue, R&D, see-saw") == nil)
        #expect(short.protect("C, then the heap. O!")?.text == "QXZ0Q, then the QXZ1Q. QXZ2Q!")
        #expect(short.corrected("see++ and see# but see.") == "see++ and see# but C.")
    }

    @Test func manglesFallBackToNormalTranslation() throws {
        let protection = try #require(glossary.protect("heap and heap"))
        #expect(protection.text == "QXZ0Q and QXZ1Q")
        #expect(protection.restore("힙과 힙") == nil)
        #expect(protection.restore("QXZ0Q와 QXZ0Q") == nil)
        #expect(protection.restore("QXZ0Q와 qxz1q") == nil)
        #expect(protection.restore("QXZ0Q와 QXZ 1Q") == nil)
        #expect(protection.restore("QXZ0Q과 QXZ1Q") == "힙과 힙")
        #expect(glossary.protect("the qxz heap") == nil)
    }

    @Test func csvRoundTripsAndMergesByTerm() throws {
        var source = glossary
        source.entries.append(GlossaryEntry(term: "a, \"b\"", korean: "따옴표", variants: ["x"]))
        let parsed = Glossary.parseCSV(source.csv)
        #expect(parsed.map(\.term) == source.entries.map(\.term))
        #expect(parsed.map(\.korean) == source.entries.map(\.korean))
        #expect(parsed.map(\.variants) == source.entries.map(\.variants))

        let imported = Glossary.parseCSV("\u{FEFF}용어,한국어,변형\r\nHEAP,더미,hip|hep\r\nstack\r\n,빈 용어\r\n")
        #expect(imported.map(\.term) == ["HEAP", "stack"])
        let merged = glossary.merging(imported)
        #expect(merged.entries.count == glossary.entries.count + 1)
        #expect(merged.entries[2].id == glossary.entries[2].id)
        #expect(merged.entries[2].korean == "더미")
        #expect(merged.entries[2].variants == ["hip", "hep"])
    }

    @Test func persistsAndToleratesMissingFields() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("Glossary.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(try GlossaryDisk.load(url) == Glossary())
        try GlossaryDisk.save(glossary, to: url)
        #expect(try GlossaryDisk.load(url) == glossary)
        try Data("{\"entries\":[{\"term\":\"stack\"}]}".utf8).write(to: url)
        let sparse = try GlossaryDisk.load(url)
        #expect(sparse.entries.map(\.term) == ["stack"])
        #expect(sparse.entries[0].variants.isEmpty)
        try Data("not json".utf8).write(to: url)
        #expect(throws: (any Error).self) { try GlossaryDisk.load(url) }
    }
}
