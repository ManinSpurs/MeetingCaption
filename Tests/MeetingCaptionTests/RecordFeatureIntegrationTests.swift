import AppKit
import CaptionCore
import Combine
import Foundation
import Testing
@testable import MeetingCaption

@Suite(.serialized)
@MainActor
struct RecordFeatureIntegrationTests {
    @Test func markOnGrowingPauseMergedSentenceSurvivesGrowthLateTranslationAndRestore() async throws {
        try await withRecording { model, engine, gate in
            engine.emit("We discussed", start: 0, end: 1)
            for await _ in gate.started { break }
            model.toggleMarkOnNewest()
            #expect(model.transcript.captions.last?.isBookmarked == true)
            engine.emit("the policy.", start: 2, end: 3)
            for await _ in gate.started { break }
            #expect(model.transcript.plainText == "We discussed the policy.")
            #expect(model.transcript.captions.map(\.isBookmarked) == [true])
            gate.release()
            for await waiting in model.$isWaitingForCaptionPause.values where !waiting { break }
            let id = try #require(model.transcript.captions.first?.id)
            model.transcript.captions[0].koreanText = "정책을 논의했습니다."
            engine.emit("We discussed", start: 0, end: 1)
            #expect(model.transcript.captions.first?.isBookmarked == true)
            #expect(model.transcript.captions.first?.koreanText == "정책을 논의했습니다.")
            engine.emit("Next topic.", start: 9, end: 10)
            #expect(model.transcript.captions.map(\.isBookmarked) == [true, false])
            #expect(model.persist())
            model.refreshLibrary()
            let saved = try #require(model.sessions.first)
            #expect(saved.bookmarkCount == 1)
            #expect(try TranscriptDisk.load(saved.url).captions.first { $0.id == id }?.isBookmarked == true)
            gate.release()
        }
    }

    @Test func glossaryCorrectsFinalTextBeforeSaving() async throws {
        try await withRecording(pause: 0) { model, engine, _ in
            model.glossary = Glossary(entries: [GlossaryEntry(term: "eigenvalue", variants: ["eigen value"])])
            engine.emit("Find the Eigen value.", start: 0, end: 1)
            #expect(model.transcript.plainText == "Find the eigenvalue.")
            engine.emit("Find the Eigen value.", start: 0, end: 1)
            #expect(model.transcript.captions.count == 1)
        }
    }

    @Test func fixedRenderingIsUsedOrFallsBackToANormalTranslation() async throws {
        var calls: [String] = []
        try await withGoogleModel(translate: { text, _, _ in
            calls.append(text)
            if text == "QXZ0Q is big." { return "QXZ0Q가 큽니다." }
            if text == "QXZ0Q is small." { return "작은 것." }  // placeholder lost
            return "일반 번역: " + text
        }) { model in
            model.glossary = Glossary(entries: [GlossaryEntry(term: "heap", korean: "힙")])
            model.transcript.captions = [
                Caption(start: 0, end: 1, text: "Heap is big."),
                Caption(start: 2, end: 3, text: "Heap is small.")
            ]
            model.cloudTranslationConsent = true
            let work = Task { await model.runCloudTranslation() }
            for await transcript in model.$transcript.values where transcript.captions.last?.koreanText != nil { break }
            work.cancel()
            await work.value
            #expect(model.transcript.captions.map(\.koreanText) == ["힙이 큽니다.", "일반 번역: Heap is small."])
            #expect(calls == ["QXZ0Q is big.", "QXZ0Q is small.", "Heap is small."])
        }
    }

    @Test func searchOpensRecordAndHighlightsMatchingCaption() async throws {
        try await withIdleModel { model, _ in
            model.transcript.captions = [
                Caption(start: 0, end: 1, text: "Intro."),
                Caption(start: 2, end: 3, text: "The Résumé matters.", koreanText: "이력서")
            ]
            let target = model.transcript.captions[1].id
            model.newSession()
            model.transcript.captions = [Caption(start: 0, end: 1, text: "Current record.")]
            model.searchQuery = "RESUME"
            await model.runSearch()
            let result = try #require(model.searchResults.first)
            #expect(model.searchResults.count == 1)
            let hit = try #require(result.hits.first)
            #expect(hit.captionID == target)
            model.showsMarkedOnly = true
            model.openSearchHit(result, hit: hit)
            #expect(model.transcript.captions.count == 2)
            #expect(model.highlight?.captionID == target)
            #expect(!model.showsMarkedOnly)
            #expect(model.currentRecordURL == result.url)
            model.searchQuery = ""
            #expect(model.searchResults.isEmpty)
        }
    }

    @Test func renameSubjectAndTrashKeepTheOpenRecordConsistent() async throws {
        try await withIdleModel { model, trashed in
            model.transcript.captions = [Caption(start: 0, end: 1, text: "Archived.")]
            model.newSession()
            let archived = try #require(model.sessions.first)
            model.rename(archived.url, to: "  Week 1 ")
            model.setSubject(archived.url, to: "Algorithms")
            model.rename(archived.url, to: "   ")
            #expect(model.errorMessage != nil)
            let renamed = try #require(model.sessions.first)
            #expect(renamed.title == "Week 1")
            #expect(renamed.subject == "Algorithms")

            model.setCurrentSubject("Physics")
            model.transcript.captions = [Caption(start: 0, end: 1, text: "Open.")]
            model.newSession()
            #expect(model.transcript.subject == "Physics")
            #expect(model.knownSubjects == ["Algorithms", "Physics"])

            let open = try #require(model.sessions.first { $0.subject == "Physics" })
            #expect(model.restore(url: open.url))
            model.trashRecord(open.url)
            #expect(trashed() == [open.url])
            #expect(model.transcript.captions.isEmpty)
            #expect(model.currentRecordURL != open.url)
            #expect(!FileManager.default.fileExists(atPath: open.url.path))
            #expect(model.sessions.map(\.url) == [archived.url])
            _ = await model.shutdown()
            #expect(!FileManager.default.fileExists(atPath: open.url.path))
        }
    }

    @Test func transcriptShowsMarksAndKeepsSelectAllWhileMarking() throws {
        let text = NSTextView()
        let coordinator = MeetingTranscriptText.Coordinator()
        var toggled: [UUID] = []
        var view = MeetingTranscriptText(
            captions: [Caption(start: 1, end: 2, text: "First."), Caption(start: 3, end: 4, text: "Second.")],
            provisional: "",
            showsTranslation: false,
            autoScroll: false,
            onToggleMark: { toggled.append($0) }
        )
        view.updateText(text, coordinator: coordinator)
        text.selectAll(nil)
        view.captions[0].isBookmarked = true
        view.updateText(text, coordinator: coordinator)
        #expect(text.string == "00:00:03.000  Second.\n★ 00:00:01.000  First.\n")
        #expect(text.selectedRange() == NSRange(location: 0, length: (text.string as NSString).length))
        view.captions.append(Caption(start: 5, end: 6, text: "Third."))
        view.updateText(text, coordinator: coordinator)
        #expect(text.selectedRange() == NSRange(location: 0, length: (text.string as NSString).length))

        let starIndex = (text.string as NSString).range(of: "★").location
        #expect(coordinator.captionID(in: text, at: starIndex) == view.captions[0].id)
        let link = try #require(text.textStorage?.attribute(.link, at: starIndex, effectiveRange: nil))
        #expect(coordinator.textView(text, clickedOnLink: link, at: starIndex))
        #expect(toggled == [view.captions[0].id])
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = coordinator.textView(text, menu: NSMenu(), for: event, at: 0)
        #expect(menu?.items.first?.title == "중요 표시")
    }

    @Test func markingAnOlderCaptionKeepsTheReadingPosition() throws {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        let coordinator = MeetingTranscriptText.Coordinator()
        var view = MeetingTranscriptText(
            captions: (0..<60).map { Caption(start: Double($0), end: Double($0) + 0.5, text: "Sentence \($0).") },
            provisional: "",
            showsTranslation: true,
            autoScroll: true
        )
        view.updateText(text, coordinator: coordinator)
        text.layoutManager?.ensureLayout(for: try #require(text.textContainer))
        text.scroll(NSPoint(x: 0, y: 600))
        let reading = scroll.contentView.bounds.origin.y
        #expect(reading > 0)

        view.captions[3].isBookmarked = true
        view.updateText(text, coordinator: coordinator)
        #expect(text.string.contains("★"))
        #expect(scroll.contentView.bounds.origin.y == reading)
        view.captions[3].isBookmarked = false
        view.captions[59].isBookmarked = true
        view.updateText(text, coordinator: coordinator)
        #expect(scroll.contentView.bounds.origin.y == reading)

        view.captions.append(Caption(start: 70, end: 71, text: "Newest."))
        view.updateText(text, coordinator: coordinator)
        #expect(scroll.contentView.bounds.origin.y == 0)
    }

    @Test func openingAnotherRecordScrollsToItsNewestCaptionEvenIfEarlier() throws {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        let coordinator = MeetingTranscriptText.Coordinator()
        var view = MeetingTranscriptText(
            captions: (0..<60).map { Caption(start: 3000 + Double($0), end: 3000.5 + Double($0), text: "A \($0).") },
            provisional: "",
            showsTranslation: true,
            autoScroll: true,
            record: Date(timeIntervalSince1970: 1)
        )
        view.updateText(text, coordinator: coordinator)
        text.layoutManager?.ensureLayout(for: try #require(text.textContainer))
        text.scroll(NSPoint(x: 0, y: 600))
        #expect(scroll.contentView.bounds.origin.y > 0)

        view.captions = (0..<60).map { Caption(start: 1100 + Double($0), end: 1100.5 + Double($0), text: "B \($0).") }
        view.record = Date(timeIntervalSince1970: 2)
        view.updateText(text, coordinator: coordinator)
        #expect(scroll.contentView.bounds.origin.y == 0)
    }

    @Test func autoScrollFollowsOnlyNewOrGrowingSpeech() {
        typealias Newest = MeetingTranscriptText.NewestContent
        let older = Caption(start: 1, end: 2, text: "Older.")
        var newest = Caption(start: 3, end: 4, text: "Newest")
        let base = Newest(captions: [older, newest], provisional: "", showsTranslation: true)
        newest.isBookmarked = true
        #expect(!Newest(captions: [older, newest], provisional: "", showsTranslation: true).advances(from: base))
        #expect(!Newest(captions: [older], provisional: "", showsTranslation: true).advances(from: base))
        #expect(Newest(captions: [older, newest], provisional: "and", showsTranslation: true).advances(from: base))
        newest.text = "Newest grows."
        #expect(Newest(captions: [older, newest], provisional: "", showsTranslation: true).advances(from: base))
        newest.text = "Newest"
        newest.koreanText = "최신"
        #expect(Newest(captions: [older, newest], provisional: "", showsTranslation: true).advances(from: base))
        #expect(!Newest(captions: [older, newest], provisional: "", showsTranslation: false)
            .advances(from: Newest(captions: [older, newest], provisional: "", showsTranslation: false)))
        #expect(Newest(captions: [older, newest, Caption(start: 5, end: 6, text: "Next.")], provisional: "", showsTranslation: true)
            .advances(from: base))
    }

    @Test func sidebarShowsSubjectAndMarksOfTheOpenRecordImmediately() async throws {
        try await withIdleModel { model, _ in
            model.transcript.captions = [Caption(start: 0, end: 1, text: "Open record.")]
            #expect(model.persist())
            model.refreshLibrary()
            let url = try #require(model.currentRecordURL)
            model.setCurrentSubject("  Physics ")
            model.toggleMark(model.transcript.captions[0].id)
            let row = try #require(model.sessions.first { model.isCurrentRecord($0.url) })
            #expect(row.subject == "Physics")
            #expect(row.bookmarkCount == 1)
            #expect(try TranscriptDisk.load(url).subject == nil)  // the throttled save hasn't run yet
            model.refreshLibrary()
            #expect(model.sessions.first { model.isCurrentRecord($0.url) }?.bookmarkCount == 1)
        }
    }

    @Test func reopeningTheOpenRecordKeepsItsPendingChange() async throws {
        try await withIdleModel { model, _ in
            model.transcript.captions = [Caption(start: 0, end: 1, text: "Open record.")]
            #expect(model.persist())
            let url = try #require(model.currentRecordURL)
            model.toggleMark(model.transcript.captions[0].id)
            model.transcript.captions[0].koreanText = "열린 기록."
            #expect(model.restore(url: url))
            #expect(model.transcript.captions[0].isBookmarked)
            #expect(model.transcript.captions[0].koreanText == "열린 기록.")
        }
    }

    @Test func glossaryCSVExchangeWorksOnTheDraftOnly() async throws {
        try await withIdleModel { model, _ in
            let saved = Glossary(entries: [GlossaryEntry(term: "heap", korean: "힙")])
            model.glossary = saved
            let draft = Glossary(entries: saved.entries + [GlossaryEntry(term: "stack", korean: "스택")])
            let csv = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
            defer { try? FileManager.default.removeItem(at: csv) }
            model.exportGlossary(draft, to: csv)
            #expect(try String(contentsOf: csv, encoding: .utf8).contains("stack,스택"))
            try "queue,큐\n".write(to: csv, atomically: true, encoding: .utf8)
            let merged = try #require(model.importGlossary(from: csv, into: draft))
            #expect(merged.entries.map(\.term) == ["heap", "stack", "queue"])
            #expect(model.glossary == saved)
        }
    }

    // MARK: Harness

    private func withIdleModel(body: (MeetingModel, () -> [URL]) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var trashed: [URL] = []
        let model = MeetingModel(library: directory, googleKeyStore: FeatureEmptyKeyStore(), translationKeyStores: emptyTranslationKeyStores(), trashItem: {
            trashed.append($0)
            try FileManager.default.removeItem(at: $0)
        })
        try await body(model, { trashed })
        _ = await model.shutdown()
    }

    private func withGoogleModel(
        translate: @escaping (String, String, String) async throws -> String,
        body: (MeetingModel) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = UserDefaults.standard
        let keys = ["captionTranslationProvider", "meetingSpeechLocale"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            try? FileManager.default.removeItem(at: directory)
        }
        let model = MeetingModel(library: directory, googleKeyStore: FeatureKeyStore(), translationKeyStores: emptyTranslationKeyStores(), cloudTranslate: { _, text, locale, keys in try await translate(text, locale, keys[0]) })
        model.localeID = "en-US"
        model.translationProvider = .google
        try await body(model)
        _ = await model.shutdown()
    }

    private func withRecording(pause: Double = 2,
                               body: (MeetingModel, FeatureEngine, FeatureGate) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let engine = FeatureEngine()
        let gate = FeatureGate()
        let model = MeetingModel(library: directory, engineFactory: { engine },
                                 googleKeyStore: FeatureEmptyKeyStore(), translationKeyStores: emptyTranslationKeyStores(),
                                 captionPauseSleep: { await gate.wait($0) })
        let key = "meetingCaptionPauseSeconds"
        let previous = UserDefaults.standard.object(forKey: key)
        model.captionPauseSeconds = pause
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
            try? FileManager.default.removeItem(at: directory)
        }
        model.start()
        for await recording in model.$isRecording.values where recording { break }
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

private struct FeatureEmptyKeyStore: MeetingAIKeyStoring {
    func loadAPIKey() -> String? { nil }
    func saveAPIKey(_ key: String) throws {}
    func removeAPIKey() throws {}
}

private struct FeatureKeyStore: MeetingAIKeyStoring {
    func loadAPIKey() -> String? { "google-test-key-no-network-12345" }
    func saveAPIKey(_ key: String) throws {}
    func removeAPIKey() throws {}
}

@MainActor
private final class FeatureGate {
    let started: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private var pending: [CheckedContinuation<Void, Never>] = []
    init() { (started, signal) = AsyncStream<Void>.makeStream() }
    func wait(_ delay: Double) async {
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
private final class FeatureEngine: MeetingSpeechEngine {
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
