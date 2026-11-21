import AppKit
import Combine
import Foundation
import Speech
import Translation
import UniformTypeIdentifiers
import CaptionCore

enum MeetingInput: String, CaseIterable, Identifiable {
    case system, microphone
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "컴퓨터 소리"
        case .microphone: "마이크"
        }
    }
}

struct MeetingSession: Identifiable {
    let url: URL
    let title: String
    let date: Date
    let count: Int
    var subject: String? = nil
    var bookmarkCount = 0
    var audioFiles: [URL] = []
    var audioBytes: Int64 = 0
    var id: String { url.path }
}

/// A request to scroll to and highlight one caption; a new revision re-scrolls the same caption.
struct CaptionHighlight: Equatable {
    let captionID: UUID
    let revision = UUID()
}

@MainActor
final class MeetingModel: ObservableObject {
    @Published var source: MeetingInput = MeetingInput(rawValue: UserDefaults.standard.string(forKey: "meetingInputSource") ?? "") ?? .system {
        didSet { sourceChanged(from: oldValue) }
    }
    @Published var localeID: String = UserDefaults.standard.string(forKey: "meetingSpeechLocale") ?? "en-US" {
        didSet { localeChanged(from: oldValue) }
    }
    @Published var locales: [Locale] = []
    @Published var transcript = Transcript(title: "새 회의", locale: "en-US", source: "system")
    @Published var provisional = ""
    @Published var status = "입력을 선택하고 시작해 주세요."
    @Published var errorMessage: String?
    @Published var isStarting = false
    @Published var isRecording = false
    @Published var isStopping = false
    @Published var isSwitchingSession = false
    @Published var captionPauseSeconds: Double = {
        let saved = UserDefaults.standard.object(forKey: "meetingCaptionPauseSeconds") as? Double ?? 2
        return [0, 1, 2, 3, 5].contains(saved) ? saved : 2
    }() {
        didSet {
            flushCaptionPause()
            UserDefaults.standard.set(captionPauseSeconds, forKey: "meetingCaptionPauseSeconds")
        }
    }
    /// Also writes the recognized audio next to the record. Off by default; applies from the
    /// next start, never to a session already running.
    @Published var recordsAudio = UserDefaults.standard.bool(forKey: "meetingRecordAudio") {
        didSet { UserDefaults.standard.set(recordsAudio, forKey: "meetingRecordAudio") }
    }
    let player = AudioPlaybackController()
    /// The open record has finished audio that can be played (never while recording).
    @Published private(set) var hasPlayableAudio = false
    /// The caption at the playback position.
    @Published private(set) var playingCaptionID: UUID?
    private var audioWriter: AudioSegmentWriter?
    private var audioSegmentFile: String?
    /// `Transcript.source` of a record made from a file rather than from a live input.
    static let fileSource = "file"
    /// Fraction of the file read so far while "파일 받아쓰기" runs; nil otherwise.
    @Published private(set) var importProgress: Double?
    private var importTask: Task<Void, Never>?
    private var importReachedEnd = false
    @Published var translationEnabled = true {
        didSet { translationLoopID = UUID() }
    }
    @Published var translationProvider: CaptionTranslationProvider = CaptionTranslationProvider(rawValue: UserDefaults.standard.string(forKey: "captionTranslationProvider") ?? "") ?? .apple {
        didSet {
            translationLoopID = UUID()
            UserDefaults.standard.set(translationProvider.rawValue, forKey: "captionTranslationProvider")
            // Consent covers one provider: sending to another one must be agreed to again.
            if translationProvider != oldValue { cloudTranslationConsent = false }
        }
    }
    /// Per-record consent to send caption text to the selected cloud translation provider.
    @Published var cloudTranslationConsent = false {
        didSet { translationLoopID = UUID() }
    }
    /// Typed credentials never leave these drafts except into the Keychain.
    @Published var translationKeyDrafts: [TranslationCredentialField: String] = [:]
    @Published private(set) var storedTranslationFields: Set<TranslationCredentialField> = []
    @Published var translationStatus = "한국어 번역: 확정된 자막을 기다립니다."
    @Published var translationRetry = 0
    @Published var sessions: [MeetingSession] = []
    @Published var recentlySavedURL: URL?
    @Published var showsMarkedOnly = false
    @Published private(set) var highlight: CaptionHighlight?
    @Published var searchQuery = "" {
        didSet { if searchQuery != oldValue { scheduleSearch() } }
    }
    @Published private(set) var searchResults: [RecordSearchResult] = []
    @Published private(set) var isSearching = false
    @Published var glossary = Glossary() {
        didSet { if glossary != oldValue { saveGlossary() } }
    }
    private let glossaryURL: URL?
    private let searchService = RecordSearchService()
    private var searchTask: Task<Void, Never>?
    private let trashItem: (URL) throws -> Void
    @Published private(set) var glossaryLoadFailed = false
    private var saveNoticeRevision = UUID()

    private func announceSave() {
        guard !transcript.captions.isEmpty, let url = jsonURL else { return }
        let revision = UUID()
        saveNoticeRevision = revision
        recentlySavedURL = url
        Task {
            try? await Task.sleep(for: .seconds(5))
            if saveNoticeRevision == revision { recentlySavedURL = nil }
        }
    }

    let library: URL

    private var engine: (any MeetingSpeechEngine)?
    private let engineFactory: @MainActor () -> any MeetingSpeechEngine
    private let translationKeyStores: [TranslationCredentialField: any MeetingAIKeyStoring]
    private let cloudTranslate: (CaptionTranslationProvider, String, String, [String]) async throws -> String
    private var operation: Task<Void, Never>?
    private var stopTask: Task<Bool, Never>?
    private var sessionTask: Task<Void, Never>?
    private var jsonURL: URL?
    private var persistTask: Task<Void, Never>?
    private var lastPersistenceError: String?
    private var translationLoopID: UUID?
    private var engineID = UUID()
    private var isClosing = false
    private var isSilentChange = false
    private var captionPauseBuffer = CaptionPauseBuffer()
    private var pendingCaptionIDs: Set<UUID> = []
    private var releasedCaptionSources: [UUID: [Caption]] = [:]
    private var captionPauseTask: Task<Void, Never>?
    private var captionPauseRevision = UUID()
    private let captionPauseSleep: (Double) async throws -> Void
    @Published private(set) var isWaitingForCaptionPause = false

    var nextTranslationCaption: Caption? {
        transcript.captions.first {
            $0.koreanText == nil && !$0.text.isEmpty && !pendingCaptionIDs.contains($0.id)
        }
    }

    init(library: URL? = nil,
         engineFactory: @escaping @MainActor () -> any MeetingSpeechEngine = { AppleSpeechEngine() },
         googleKeyStore: any MeetingAIKeyStoring = GoogleTranslationKeyStore(),
         translationKeyStores: [TranslationCredentialField: any MeetingAIKeyStoring] = [:],
         cloudTranslate: @escaping (CaptionTranslationProvider, String, String, [String]) async throws -> String = {
             try await CloudTranslators.translate(provider: $0, text: $1, sourceLocale: $2, credentials: $3)
         },
         captionPauseSleep: @escaping (Double) async throws -> Void = {
             try await Task.sleep(for: .seconds($0))
         },
         glossaryURL: URL? = nil,
         trashItem: @escaping (URL) throws -> Void = {
             try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
         }) {
        self.engineFactory = engineFactory
        var stores = translationKeyStores
        stores[.googleKey] = stores[.googleKey] ?? googleKeyStore
        for field in TranslationCredentialField.allCases where stores[field] == nil { stores[field] = field.defaultStore }
        self.translationKeyStores = stores
        self.cloudTranslate = cloudTranslate
        self.captionPauseSleep = captionPauseSleep
        self.trashItem = trashItem
        self.storedTranslationFields = Set(stores.filter { $0.value.loadAPIKey() != nil }.map(\.key))
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingCaption", isDirectory: true)
        let base = support.appendingPathComponent("Transcripts", isDirectory: true)
        let directory = library ?? base
        self.library = directory
        // A test library keeps its glossary in memory unless one is passed explicitly, so a
        // developer's own glossary never rewrites test captions.
        self.glossaryURL = glossaryURL ?? (library == nil ? support.appendingPathComponent("Glossary.json") : nil)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { errorMessage = "자막 보관 폴더를 만들지 못했습니다: \(error.localizedDescription)" }
        if let url = self.glossaryURL {
            do { glossary = try GlossaryDisk.load(url) }
            catch { glossaryLoadFailed = true; errorMessage = "용어집을 읽지 못했습니다. 파일을 덮어쓰지 않도록 편집을 막았습니다: \(error.localizedDescription)" }
        }
        transcript = Transcript(title: Self.defaultTitle(for: source), locale: localeID, source: source.rawValue)
        jsonURL = TranscriptLibrary.newSessionURL(in: directory)
        player.onPosition = { [weak self] index, offset in self?.playbackMoved(segment: index, offset: offset) }
        recoverInterruptedAudio()
        refreshLibrary()
        Task {
            locales = await SpeechTranscriber.supportedLocales.sorted { $0.identifier < $1.identifier }
            if let equivalent = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID)),
               equivalent.identifier != localeID, transcript.captions.isEmpty {
                // Normalize the stored default without starting a second record.
                isSilentChange = true
                localeID = equivalent.identifier
                isSilentChange = false
                transcript.locale = equivalent.identifier
            }
            if !SpeechTranscriber.isAvailable { status = "이 Mac에서 애플 음성인식을 사용할 수 없습니다." }
        }
    }

    var isLocked: Bool { isStarting || isRecording || isStopping || isSwitchingSession }

    var currentCaption: String { provisional.isEmpty ? transcript.captions.last?.text ?? "" : provisional }
    var currentTranslation: String {
        guard translationEnabled else { return "" }
        return transcript.captions.last?.koreanText ?? ""
    }

    var translationTaskID: String {
        "\(translationEnabled)|\(translationProvider.rawValue)|\(cloudTranslationConsent)|\(transcript.created.timeIntervalSince1970)|\(transcript.locale)|\(translationRetry)"
    }

    private static func defaultTitle(for source: MeetingInput) -> String {
        "\(source.title) · \(Date().formatted(date: .abbreviated, time: .shortened))"
    }

    // MARK: - Input and locale changes

    /// Source and language may only change while idle. A rejected change is reverted, and a
    /// change that conflicts with captured speech starts a new record, so one transcript can
    /// never silently mix two inputs or two languages.
    private func sourceChanged(from old: MeetingInput) {
        guard !isSilentChange else { return }
        guard !isLocked else {
            isSilentChange = true
            source = old
            isSilentChange = false
            return
        }
        guard source != old else { return }
        guard newSession(reason: "입력을 \(source.title)(으)로 바꿔 새 기록을 시작했습니다.") else {
            isSilentChange = true
            source = old
            isSilentChange = false
            return
        }
        UserDefaults.standard.set(source.rawValue, forKey: "meetingInputSource")
    }

    private func localeChanged(from old: String) {
        guard !isSilentChange else { return }
        guard !isLocked, !localeID.isEmpty else {
            isSilentChange = true
            localeID = old
            isSilentChange = false
            return
        }
        guard localeID != old else { return }
        guard newSession(reason: "언어를 \(localeID)(으)로 바꿔 새 기록을 시작했습니다.") else {
            isSilentChange = true
            localeID = old
            isSilentChange = false
            return
        }
        UserDefaults.standard.set(localeID, forKey: "meetingSpeechLocale")
    }

    // MARK: - Lifecycle

    func start() {
        guard !isLocked, !isClosing else { return }
        if jsonURL == nil || transcript.source != source.rawValue || transcript.locale != localeID {
            guard newSession(reason: nil) else { return }
        }
        let offset = transcript.nextStartTime
        let previousAudio = transcript.audio
        if var segments = transcript.audio {
            AudioTimeline.closeSegments(&segments, at: offset)
            transcript.audio = segments
        }
        // The segment is linked (and saved) before any audio is written, so an interrupted
        // session always leaves a record that knows its file.
        var writer: AudioSegmentWriter?
        var segmentFile: String?
        if recordsAudio, let jsonURL {
            let file = RecordAudio.newSegmentFile(for: transcript, record: jsonURL)
            let segment = AudioSegment(file: file, start: offset)
            let audioURL = jsonURL.deletingLastPathComponent().appendingPathComponent(file)
            transcript.audio = (transcript.audio ?? []) + [segment]
            writer = AudioSegmentWriter(url: audioURL, timelineStart: offset) { [weak self] message in
                Task { @MainActor in self?.errorMessage = message }
            }
            segmentFile = file
        }
        guard persist() else {
            transcript.audio = previousAudio
            return
        }
        player.stop()
        playingCaptionID = nil
        hasPlayableAudio = false
        audioWriter = writer
        audioSegmentFile = segmentFile
        isStarting = true
        errorMessage = nil
        highlight = nil
        let service = makeEngine()
        let input = source.rawValue
        let language = localeID
        operation = Task {
            do {
                try await service.startLive(source: input, localeID: language, offset: offset, recorder: writer)
                try Task.checkCancellation()
                isStarting = false
                isRecording = true
                status = writer == nil ? "인식 중입니다. 확정된 자막은 자동 저장됩니다."
                    : "인식 중입니다. 음성도 함께 녹음하며, 확정된 자막은 자동 저장됩니다."
            } catch {
                await service.cancel()
                await finishAudio(keep: false)
                persist()
                engineID = UUID()
                engine = nil
                isStarting = false
                isRecording = false
                if !(error is CancellationError) {
                    errorMessage = error.localizedDescription
                    status = "시작하지 못했습니다."
                }
            }
            operation = nil
        }
    }

    // MARK: - File transcription

    var isImporting: Bool { importProgress != nil }

    /// "파일 받아쓰기…": asks for an audio or video file.
    func chooseFileToImport() {
        guard !isLocked, !isClosing else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = FileAudioSource.contentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "받아쓸 녹음 또는 동영상 파일을 고르세요. \(Locale.current.localizedString(forIdentifier: localeID) ?? localeID)(으)로 인식합니다."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importFile(url)
    }

    /// Turns an audio or video file into a new record: recognized in the selected language from
    /// the file's start, with a compact copy of its sound kept beside the record so every
    /// caption can be replayed. The open record is saved first and is not changed.
    func importFile(_ url: URL) {
        guard !isLocked, !isClosing else { return }
        guard newSession(reason: nil), let jsonURL else { return }
        transcript.source = Self.fileSource
        transcript.title = url.deletingPathExtension().lastPathComponent
        let file = RecordAudio.newSegmentFile(for: transcript, record: jsonURL)
        transcript.audio = [AudioSegment(file: file, start: 0)]
        let writer = AudioSegmentWriter(url: jsonURL.deletingLastPathComponent().appendingPathComponent(file),
                                        timelineStart: 0) { [weak self] message in
            Task { @MainActor in self?.errorMessage = message }
        }
        guard persist() else {
            transcript.audio = nil
            return
        }
        player.stop()
        playingCaptionID = nil
        hasPlayableAudio = false
        audioWriter = writer
        audioSegmentFile = file
        isStarting = true
        importProgress = 0
        importReachedEnd = false
        errorMessage = nil
        highlight = nil
        let service = makeEngine()
        let id = engineID
        let language = localeID
        let name = url.lastPathComponent
        operation = Task {
            do {
                try await service.startFile(url: url, localeID: language, recorder: writer) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, self.engineID == id, self.importProgress != nil else { return }
                        self.importProgress = fraction
                    }
                }
                try Task.checkCancellation()
                isStarting = false
                isRecording = true
                status = "‘\(name)’을(를) 받아쓰고 있습니다. 확정된 자막은 자동 저장됩니다."
                // The file ends on its own; that is the same as pressing 중지.
                importTask = Task { [weak self] in
                    var failure: String?
                    do { try await service.waitUntilFileEnds() }
                    catch { failure = error.localizedDescription }
                    guard let self, self.engineID == id, self.isRecording, !self.isStopping else { return }
                    if let failure { self.errorMessage = failure }
                    self.importReachedEnd = failure == nil
                    self.stop()
                }
            } catch {
                await service.cancel()
                await finishAudio(keep: false)
                persist()
                engineID = UUID()
                engine = nil
                isStarting = false
                isRecording = false
                importProgress = nil
                if !(error is CancellationError) {
                    errorMessage = error.localizedDescription
                    status = "파일을 받아쓰지 못했습니다."
                }
            }
            operation = nil
        }
    }

    func stop() {
        guard !isStopping, !isClosing, isStarting || isRecording else { return }
        isStopping = true
        let wasLive = isRecording
        let wasImporting = isImporting
        isRecording = false
        status = wasLive ? "마지막 문장을 확정하고 저장하고 있습니다." : "시작을 취소하고 있습니다."
        let service = engine
        let running = operation
        if !wasLive { running?.cancel() }
        stopTask = Task {
            var finalized = true
            if wasLive {
                do { try await service?.finish() }
                catch {
                    finalized = false
                    errorMessage = error.localizedDescription
                }
            } else {
                if let running { await running.value }
                else { await service?.cancel() }
            }
            // finish()/cancel() have drained every result, so nothing more may be accepted.
            engineID = UUID()
            engine = nil
            await finishAudio(keep: wasLive)
            flushCaptionPause()
            provisional = ""
            isStopping = false
            isStarting = false
            let saved = persist()
            if saved { announceSave() }
            reloadPlayback()
            refreshLibrary()
            importProgress = nil
            importTask = nil
            if !saved {
                status = "중지했지만 저장하지 못했습니다. 내용을 복사해 보관해 주세요."
            } else if wasImporting && wasLive {
                status = (importReachedEnd ? "파일 받아쓰기를 마쳤습니다." : "파일 받아쓰기를 중지했습니다. 여기까지 받아쓴 내용만 보관합니다.")
                    + " 자막 \(transcript.captions.count)개를 보관했습니다."
            } else {
                status = "중지했습니다. 확정된 자막 \(transcript.captions.count)개를 보관했습니다."
            }
            stopTask = nil
            return saved && finalized
        }
    }

    func saveAndStartNewSession() {
        guard !isClosing, !isStarting, !isStopping, !isSwitchingSession else { return }
        isSwitchingSession = true
        sessionTask = Task {
            defer {
                isSwitchingSession = false
                sessionTask = nil
            }
            if isRecording { stop() }
            if let stopping = stopTask {
                guard await stopping.value else { return }
            }
            guard !Task.isCancelled, !isClosing else { return }
            isSwitchingSession = false
            guard newSession(reason: nil) else { return }
            start()
        }
    }

    func newSession() { newSession(reason: nil) }

    @discardableResult
    private func newSession(reason: String?) -> Bool {
        guard !isLocked else { return false }
        flushCaptionPause()
        guard persist() else { return false }
        announceSave()
        cloudTranslationConsent = false
        startBlankRecord()
        status = reason ?? "새 기록을 준비했습니다."
        refreshLibrary()
        return true
    }

    /// The next record keeps the current subject, so consecutive lectures of one course stay
    /// filed together; it can be changed before or during recording.
    private func startBlankRecord() {
        let subject = Transcript.normalizedSubject(transcript.subject)
        releasedCaptionSources.removeAll()
        transcript = Transcript(title: Self.defaultTitle(for: source), locale: localeID, source: source.rawValue)
        transcript.subject = subject
        jsonURL = TranscriptLibrary.newSessionURL(in: library)
        provisional = ""
        errorMessage = nil
        highlight = nil
        reloadPlayback()
    }

    func restore(_ session: MeetingSession) { restore(url: session.url) }

    @discardableResult
    func restore(url: URL) -> Bool {
        guard !isLocked else { return false }
        // Save first: reopening the open record must read its pending marks and translations.
        flushCaptionPause()
        guard persist() else { return false }
        do {
            var loaded = try TranscriptDisk.load(url)
            let recovery = RecordAudio.recover(&loaded, record: url, duration: AudioFileProbe.duration)
            cloudTranslationConsent = false
            // Assigning the restored source/locale must not be mistaken for a user change.
            isSilentChange = true
            source = MeetingInput(rawValue: loaded.source) ?? source
            localeID = loaded.locale
            isSilentChange = false
            UserDefaults.standard.set(loaded.locale, forKey: "meetingSpeechLocale")
            releasedCaptionSources.removeAll()
            transcript = loaded
            jsonURL = url
            if recovery.changed { persist() }
            provisional = ""
            errorMessage = nil
            highlight = nil
            reloadPlayback()
            status = "기록 \(loaded.captions.count)개를 불러왔습니다. 이어서 인식하거나 내보낼 수 있습니다."
                + (hasPlayableAudio ? " 자막의 ‘여기부터 듣기’로 녹음을 들을 수 있습니다." : "")
            refreshLibrary()
            return true
        } catch {
            errorMessage = "기록을 불러오지 못했습니다: \(error.localizedDescription)"
            return false
        }
    }

    func refreshLibrary() {
        sessions = TranscriptLibrary.entries(in: library).map {
            MeetingSession(url: $0.url, title: $0.title, date: $0.date, count: $0.count,
                           subject: $0.subject, bookmarkCount: $0.bookmarkCount,
                           audioFiles: $0.audioFiles, audioBytes: $0.audioBytes)
        }
        syncCurrentSession()
        if RecordSearch.normalizedQuery(searchQuery) != nil { scheduleSearch() }
    }

    /// The open record's file can lag its throttled save; the sidebar shows the in-memory
    /// subject and marks at once.
    private func syncCurrentSession() {
        guard let index = sessions.firstIndex(where: { isCurrentRecord($0.url) }) else { return }
        sessions[index].subject = Transcript.normalizedSubject(transcript.subject)
        sessions[index].bookmarkCount = markedCount
    }

    var currentRecordURL: URL? { jsonURL }

    /// Directory listings can spell the same file differently ("/var" vs "/private/var").
    func isCurrentRecord(_ url: URL) -> Bool {
        guard let jsonURL else { return false }
        return url.standardizedFileURL.resolvingSymlinksInPath().path
            == jsonURL.standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: - Audio recording and playback

    var totalAudioBytes: Int64 { sessions.reduce(0) { $0 + $1.audioBytes } }

    /// The record's JSON together with its audio files, for "Finder에서 보기".
    func filesToReveal(_ url: URL) -> [URL] {
        if isCurrentRecord(url), let jsonURL { return [jsonURL] + RecordAudio.files(of: transcript, record: jsonURL) }
        return [url] + (sessions.first { $0.url == url }?.audioFiles ?? [])
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting(filesToReveal(url))
    }

    /// Captions that "여기부터 듣기" can start from.
    var playableCaptionIDs: Set<UUID> {
        guard hasPlayableAudio, !isLocked else { return [] }
        let segments = player.segments
        return Set(transcript.captions.filter { AudioTimeline.locate($0.start, in: segments) != nil }.map(\.id))
    }

    func play(from captionID: UUID) {
        guard !isLocked, hasPlayableAudio,
              let cue = transcript.captions.first(where: { $0.id == captionID }),
              let spot = AudioTimeline.locate(cue.start, in: player.segments) else { return }
        player.play(segment: spot.index, at: spot.offset)
    }

    /// A caption time cited in a summary: scrolls to that caption and, when the record has
    /// audio for it, plays from there (never while recording).
    func openStamp(_ stamp: String) {
        guard let cue = MeetingAISourceResolution.caption(forStamp: stamp, in: transcript.captions) else {
            status = "이 기록에서 \(stamp) 자막을 찾지 못했습니다."
            return
        }
        if showsMarkedOnly && !cue.isBookmarked { showsMarkedOnly = false }
        highlight = CaptionHighlight(captionID: cue.id)
        play(from: cue.id)
    }

    private func playbackMoved(segment index: Int, offset: Double) {
        guard !isLocked else { return }
        let id = AudioTimeline.caption(atOffset: offset, segment: index, in: player.segments,
                                       captions: transcript.captions)?.id
        if id != playingCaptionID { playingCaptionID = id }
    }

    /// Only finished files that exist are offered; the segment being recorded never is.
    private func reloadPlayback() {
        let segments = jsonURL.map { record in
            (transcript.audio ?? []).filter {
                $0.isFinished && $0.file != audioSegmentFile &&
                    RecordAudio.url(of: $0, record: record).map(RecordAudio.isRegularFile) == true
            }
        } ?? []
        player.load(segments, record: jsonURL)
        hasPlayableAudio = !segments.isEmpty
        playingCaptionID = nil
    }

    /// Completes the segment being recorded and records its length on the open record (which
    /// cannot change meanwhile: every caller holds the recording lock). A segment that left no
    /// playable file is unlinked, so the record never points at missing audio.
    private func finishAudio(keep: Bool) async {
        guard let writer = audioWriter, let file = audioSegmentFile else { return }
        audioWriter = nil
        audioSegmentFile = nil
        var length: Double?
        if keep { length = await writer.finish() } else { await writer.discard() }
        guard var segments = transcript.audio, let index = segments.firstIndex(where: { $0.file == file }) else { return }
        if let length {
            segments[index].end = segments[index].start + length
        } else {
            segments.remove(at: index)
        }
        transcript.audio = segments.isEmpty ? nil : segments
    }

    /// Settles audio left unfinished when the app last ended unexpectedly.
    private func recoverInterruptedAudio() {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil) else { return }
        var total = RecordAudio.Recovery()
        for url in urls where url.pathExtension.lowercased() == "json" {
            guard var record = try? TranscriptDisk.load(url),
                  record.audio?.contains(where: { !$0.isFinished }) == true else { continue }
            let recovery = RecordAudio.recover(&record, record: url, duration: AudioFileProbe.duration)
            guard recovery.changed, (try? TranscriptDisk.save(record, at: url, srt: false)) != nil else { continue }
            total.recovered += recovery.recovered
            total.removed += recovery.removed
        }
        var notes: [String] = []
        if total.recovered > 0 { notes.append("중단된 녹음 \(total.recovered)개를 마지막으로 저장된 부분까지 복구했습니다.") }
        if total.removed > 0 { notes.append("재생할 수 없는 녹음 \(total.removed)개를 정리했습니다. 자막 기록은 그대로입니다.") }
        if !notes.isEmpty { status = notes.joined(separator: " ") }
    }

    // MARK: - Bookmarks

    func toggleMark(_ id: UUID) {
        guard let index = transcript.captions.firstIndex(where: { $0.id == id }) else { return }
        transcript.captions[index].isBookmarked.toggle()
        status = transcript.captions[index].isBookmarked ? "중요 표시했습니다." : "중요 표시를 해제했습니다."
        schedulePersist()
        syncCurrentSession()
    }

    /// ⌘D: the newest caption is the last one in time order (shown at the top).
    func toggleMarkOnNewest() {
        guard let newest = transcript.captions.last else {
            status = "중요 표시할 확정된 자막이 아직 없습니다."
            return
        }
        toggleMark(newest.id)
    }

    var markedCount: Int { transcript.captions.filter(\.isBookmarked).count }

    // MARK: - Record search

    private func scheduleSearch() {
        searchTask?.cancel()
        guard RecordSearch.normalizedQuery(searchQuery) != nil else {
            searchTask = nil
            searchResults = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.runSearch()
        }
    }

    /// Runs the current query against the archive off the main actor; a result for an
    /// outdated query is discarded.
    func runSearch() async {
        let query = searchQuery
        guard RecordSearch.normalizedQuery(query) != nil else { return }
        persist()
        let results = await searchService.search(query, in: library)
        guard !Task.isCancelled, query == searchQuery else { return }
        searchResults = results
        isSearching = false
    }

    /// Opens a record from search, then scrolls to and highlights the matching caption.
    func openSearchHit(_ result: RecordSearchResult, hit: RecordSearchHit?) {
        guard !isLocked else { return }
        if !isCurrentRecord(result.url) { guard restore(url: result.url) else { return } }
        guard let id = hit?.captionID, let cue = transcript.captions.first(where: { $0.id == id }) else {
            highlight = nil
            return
        }
        if showsMarkedOnly && !cue.isBookmarked { showsMarkedOnly = false }
        highlight = CaptionHighlight(captionID: id)
    }

    // MARK: - Record organization

    var knownSubjects: [String] {
        RecordGrouping.subjects(sessions.map(\.subject) + [transcript.subject])
    }

    func rename(_ url: URL, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            errorMessage = "기록 이름을 비워 둘 수 없습니다."
            return
        }
        if isCurrentRecord(url) {
            transcript.title = title
            persist()
        } else {
            do { try TranscriptLibrary.update(url) { $0.title = title } }
            catch { errorMessage = "이름을 바꾸지 못했습니다: \(error.localizedDescription)" }
        }
        refreshLibrary()
    }

    func setSubject(_ url: URL, to subject: String?) {
        let subject = Transcript.normalizedSubject(subject)
        if isCurrentRecord(url) {
            transcript.subject = subject
            persist()
        } else {
            do { try TranscriptLibrary.update(url) { $0.subject = subject } }
            catch { errorMessage = "과목을 지정하지 못했습니다: \(error.localizedDescription)" }
        }
        refreshLibrary()
    }

    /// The subject of the open record, which new records inherit.
    func setCurrentSubject(_ subject: String?) {
        transcript.subject = Transcript.normalizedSubject(subject)
        schedulePersist()
        syncCurrentSession()
    }

    /// Moves a record to the Trash. The open record can only be removed while idle; a fresh
    /// record replaces it without writing the removed one back.
    func trashRecord(_ url: URL) {
        let isCurrent = isCurrentRecord(url)
        if isCurrent {
            guard !isLocked else {
                errorMessage = "기록 중에는 현재 기록을 삭제할 수 없습니다."
                return
            }
            persistTask?.cancel()
            persistTask = nil
            flushCaptionPause()
            player.stop()
        }
        let audio = isCurrent ? RecordAudio.files(of: transcript, record: url)
            : (try? TranscriptDisk.load(url)).map { RecordAudio.files(of: $0, record: url) } ?? []
        do {
            try trashItem(url)
        } catch {
            errorMessage = "휴지통으로 옮기지 못했습니다: \(error.localizedDescription)"
            return
        }
        // The record goes first; its audio follows so that Finder's "Put Back" restores both.
        var stranded: [String] = []
        for file in audio {
            do { try trashItem(file) } catch { stranded.append(file.lastPathComponent) }
        }
        if !stranded.isEmpty {
            errorMessage = "기록은 휴지통으로 옮겼지만 녹음 파일을 옮기지 못해 보관 폴더에 남겨 두었습니다: " + stranded.joined(separator: ", ")
        }
        if isCurrent {
            cloudTranslationConsent = false
            startBlankRecord()
        }
        status = audio.isEmpty ? "기록을 휴지통으로 옮겼습니다." : "기록과 녹음 파일을 휴지통으로 옮겼습니다."
        refreshLibrary()
    }

    // MARK: - Glossary

    private func saveGlossary() {
        guard let glossaryURL, !glossaryLoadFailed else { return }
        do { try GlossaryDisk.save(glossary, to: glossaryURL) }
        catch { errorMessage = "용어집을 저장하지 못했습니다: \(error.localizedDescription)" }
    }

    /// Merges a chosen CSV into the editor's draft; the saved glossary changes only when the
    /// editor is saved.
    func importGlossary(into draft: Glossary) -> Glossary? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return importGlossary(from: url, into: draft)
    }

    func importGlossary(from url: URL, into draft: Glossary) -> Glossary? {
        do {
            let entries = Glossary.parseCSV(try String(contentsOf: url, encoding: .utf8))
            guard !entries.isEmpty else {
                errorMessage = "가져올 용어를 찾지 못했습니다. 한 줄에 영어 용어,한국어,변형1|변형2 형식인지 확인해 주세요."
                return nil
            }
            status = "용어 \(entries.count)개를 가져왔습니다. 저장을 누르면 반영됩니다."
            return draft.merging(entries)
        } catch {
            errorMessage = "용어집을 읽지 못했습니다: \(error.localizedDescription)"
            return nil
        }
    }

    func exportGlossary(_ draft: Glossary) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "MeetingCaption-용어집.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportGlossary(draft, to: url)
    }

    func exportGlossary(_ draft: Glossary, to url: URL) {
        do {
            try draft.csv.write(to: url, atomically: true, encoding: .utf8)
            status = "용어집을 내보냈습니다: \(url.lastPathComponent)"
        } catch {
            errorMessage = "용어집을 내보내지 못했습니다: \(error.localizedDescription)"
        }
    }

    /// Called from the quit path after the user agreed to finish the meeting. An active
    /// recording is finalized rather than dropped, so its last confirmed sentences persist.
    @discardableResult
    func shutdown() async -> Bool {
        guard !isClosing else { return false }
        isClosing = true
        defer { isClosing = false }
        sessionTask?.cancel()
        if let switching = sessionTask { await switching.value }
        persistTask?.cancel()
        persistTask = nil
        if let stopping = stopTask {
            _ = await stopping.value
        } else if let starting = operation {
            starting.cancel()
            await starting.value
        } else if isRecording {
            do { try await engine?.finish() }
            catch { errorMessage = error.localizedDescription }
        } else {
            await engine?.cancel()
        }
        engineID = UUID()
        engine = nil
        await finishAudio(keep: true)
        player.stop()
        flushCaptionPause()
        isRecording = false
        isStarting = false
        importProgress = nil
        return persist()
    }

    // MARK: - Recognition results

    private func makeEngine() -> any MeetingSpeechEngine {
        let service = engineFactory()
        // A stopped engine can still deliver its last finalized result. Tag each engine so a
        // late packet from a previous session cannot land in the current transcript.
        let id = UUID()
        engineID = id
        service.onStatus = { [weak self] message in
            guard let self, self.engineID == id else { return }
            self.status = message
        }
        service.onPacket = { [weak self] packet in
            guard let self, self.engineID == id else { return }
            self.receive(packet)
        }
        service.onFailure = { [weak self] message in
            guard let self, self.engineID == id else { return }
            self.handleCaptureFailure(message)
        }
        engine = service
        return service
    }

    private func receive(_ packet: SpeechPacket) {
        if packet.isFinal {
            // Misrecognitions are corrected once, on the raw finalized words, before anything is
            // grouped, translated or saved; re-deliveries are corrected identically.
            let glossary = glossary
            let corrected = packet.captions.map { cue -> Caption in
                var cue = cue
                cue.text = glossary.corrected(cue.text)
                return cue
            }
            let newCues = corrected.filter { cue in
                guard let groupID = releasedCaptionSources.first(where: {
                    $0.value.contains { abs($0.start - cue.start) < 0.005 }
                })?.key, let sources = releasedCaptionSources[groupID] else { return true }
                var revised = CaptionPauseBuffer()
                revised.append(sources)
                revised.append([cue])
                releasedCaptionSources[groupID] = revised.captions
                transcript.mergeFinal(revised.groups(pause: .infinity))
                return false
            }
            if captionPauseSeconds > 0 {
                captionPauseBuffer.append(newCues)
                let groups = captionPauseBuffer.groups(pause: captionPauseSeconds)
                for group in groups.dropLast() {
                    releasedCaptionSources[group.id] = captionPauseBuffer.captions.filter {
                        $0.start >= group.start && $0.start <= group.end
                    }
                }
                // The growing sentence is replaced wholesale; a mark the user put on it carries
                // over to whichever regrouped sentence covers the same speech.
                let markedPending = transcript.captions
                    .filter { pendingCaptionIDs.contains($0.id) && $0.isBookmarked }
                    .map { ($0.start, $0.end) }
                transcript.captions.removeAll { pendingCaptionIDs.contains($0.id) }
                transcript.mergeFinal(groups)
                if !markedPending.isEmpty {
                    let regrouped = Set(groups.map(\.id))
                    for index in transcript.captions.indices where regrouped.contains(transcript.captions[index].id) {
                        let cue = transcript.captions[index]
                        if markedPending.contains(where: { cue.start <= $0.1 && cue.end >= $0.0 }) {
                            transcript.captions[index].isBookmarked = true
                        }
                    }
                }
                pendingCaptionIDs = Set(groups.suffix(1).map(\.id))
                isWaitingForCaptionPause = !pendingCaptionIDs.isEmpty
                captionPauseBuffer.keepLastGroup(pause: captionPauseSeconds)
                scheduleCaptionPause()
            } else {
                transcript.mergeFinal(newCues)
            }
            provisional = ""
            schedulePersist()
        } else {
            provisional = packet.text
            // A progressive result means the next phrase is still being recognized.
            cancelCaptionPause()
        }
    }

    private func cancelCaptionPause() {
        captionPauseRevision = UUID()
        captionPauseTask?.cancel()
        captionPauseTask = nil
    }

    private func flushCaptionPause() {
        cancelCaptionPause()
        if let id = pendingCaptionIDs.first, !captionPauseBuffer.captions.isEmpty {
            releasedCaptionSources[id] = captionPauseBuffer.captions
        }
        captionPauseBuffer.clear()
        pendingCaptionIDs.removeAll()
        isWaitingForCaptionPause = false
    }

    private func scheduleCaptionPause() {
        cancelCaptionPause()
        let revision = captionPauseRevision
        let wait = captionPauseSeconds
        let sleep = captionPauseSleep
        captionPauseTask = Task { [weak self] in
            do { try await sleep(wait) }
            catch { return }
            guard !Task.isCancelled, let self, self.captionPauseRevision == revision else { return }
            self.flushCaptionPause()
        }
    }

    private func handleCaptureFailure(_ message: String) {
        guard !isStopping else { return }
        errorMessage = message
        if isRecording || isStarting { stop() }
    }

    // MARK: - Translation

    func runInstalledTranslation() async {
        guard translationEnabled else {
            translationStatus = "한국어 번역 꺼짐"
            return
        }
        let language = Locale.Language(identifier: transcript.locale)
        guard language.languageCode?.identifier != "ko" else {
            translationStatus = "원문이 한국어입니다."
            return
        }
        if translationProvider.isCloud {
            await runCloudTranslation()
            return
        }
        let available = await LanguageAvailability().status(from: language, to: Locale.Language(identifier: "ko"))
        guard !Task.isCancelled else { return }
        guard available == .installed else {
            translationStatus = available == .unsupported
                ? "이 언어의 한국어 번역을 애플 번역에서 지원하지 않습니다."
                : "번역 모델 준비를 눌러 언어 모델을 설치해 주세요."
            return
        }
        let session = TranslationSession(installedSource: language, target: Locale.Language(identifier: "ko"))
        await runTranslation(session)
    }

    func runTranslation(_ session: TranslationSession) async {
        guard translationProvider == .apple else { return }
        let record = transcript.created
        let locale = transcript.locale
        do {
            try await session.prepareTranslation()
            try Task.checkCancellation()
            guard transcript.created == record, transcript.locale == locale,
                  translationEnabled, translationProvider == .apple else { return }
            await translatePending(provider: .apple) { text in
                try await session.translate(text).targetText
            }
        } catch {
            if !Task.isCancelled {
                translationStatus = "Apple 번역을 준비하지 못했습니다. 번역 모델 준비를 눌러 다시 시도해 주세요."
            }
        }
    }

    func hasTranslationKeys(for provider: CaptionTranslationProvider) -> Bool {
        provider.credentialFields.allSatisfy(storedTranslationFields.contains)
    }

    /// Saves every typed credential of `provider`; nothing is saved unless all typed values
    /// are valid, so a half-typed pair never replaces a working one.
    func saveTranslationKeys(for provider: CaptionTranslationProvider) {
        var valid: [(TranslationCredentialField, String)] = []
        for field in provider.credentialFields {
            let draft = translationKeyDrafts[field] ?? ""
            guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard let value = field.sanitized(draft) else {
                errorMessage = "\(field.label) 값을 공백 없이 한 줄로 정확히 입력해 주세요."
                return
            }
            valid.append((field, value))
        }
        guard !valid.isEmpty else { return }
        do {
            for (field, value) in valid {
                try translationKeyStores[field]?.saveAPIKey(value)
                storedTranslationFields.insert(field)
                translationKeyDrafts[field] = nil
            }
            translationLoopID = UUID()
            translationRetry += 1
        } catch { errorMessage = error.localizedDescription }
    }

    func removeTranslationKeys(for provider: CaptionTranslationProvider) {
        do {
            for field in provider.credentialFields {
                try translationKeyStores[field]?.removeAPIKey()
                storedTranslationFields.remove(field)
                translationKeyDrafts[field] = nil
            }
            translationLoopID = UUID()
            translationRetry += 1
        } catch { errorMessage = error.localizedDescription }
    }

    func runCloudTranslation() async {
        let provider = translationProvider
        guard translationEnabled, provider.isCloud else { return }
        guard Locale.Language(identifier: transcript.locale).languageCode?.identifier != "ko" else {
            translationStatus = "원문이 한국어입니다."
            return
        }
        guard cloudTranslationConsent else {
            translationStatus = "\(provider.vendor)로 원문 전송에 동의해야 번역을 시작합니다."
            return
        }
        var credentials: [String] = []
        for field in provider.credentialFields {
            guard let value = translationKeyStores[field]?.loadAPIKey(), field.sanitized(value) != nil else {
                translationStatus = "\(field.label) 항목을 저장해 주세요."
                return
            }
            credentials.append(value)
        }
        let locale = transcript.locale
        let translate = cloudTranslate
        await translatePending(provider: provider) { text in
            try await translate(provider, text, locale, credentials)
        }
    }

    private func translatePending(provider: CaptionTranslationProvider,
                                  translate: (String) async throws -> String) async {
        let locale = transcript.locale
        let record = transcript.created
        let loop = UUID()
        translationLoopID = loop
        do {
            while !Task.isCancelled, translationLoopID == loop,
                  translationEnabled, translationProvider == provider,
                  transcript.created == record, transcript.locale == locale,
                  !provider.isCloud || cloudTranslationConsent {
                // Oldest-first keeps the transcript's chronological order stable for the reader.
                guard let cue = nextTranslationCaption else {
                    try await Task.sleep(for: .milliseconds(300))
                    continue
                }
                translationStatus = "\(provider.vendor)로 한국어 번역 중입니다."
                func stillCurrent() -> Bool {
                    translationLoopID == loop && translationEnabled &&
                        translationProvider == provider && transcript.created == record &&
                        transcript.locale == locale &&
                        (!provider.isCloud || cloudTranslationConsent)
                }
                // Fixed glossary renderings go through placeholders; if the translator mangles
                // any placeholder the sentence is translated again without them.
                var response: String?
                if let protection = glossary.protect(cue.text) {
                    let protected = try await translate(protection.text)
                    try Task.checkCancellation()
                    guard stillCurrent() else { return }
                    response = protection.restore(protected)
                }
                if response == nil {
                    response = try await translate(cue.text)
                    try Task.checkCancellation()
                }
                guard stillCurrent(), let response else { return }
                if let index = transcript.captions.firstIndex(where: { $0.id == cue.id && $0.text == cue.text }) {
                    transcript.captions[index].koreanText = response
                    schedulePersist()
                }
                translationStatus = "\(provider.title) 번역 켜짐 · 확정된 문장을 시간순으로 번역합니다."
            }
        } catch {
            if !(error is CancellationError) && !Task.isCancelled && translationLoopID == loop {
                translationStatus = provider.isCloud
                    ? "\(provider.vendor) 번역 실패: \(error.localizedDescription) 자동 재시도하지 않습니다. 설정 확인 후 다시 시도해 주세요."
                    : "Apple 번역을 준비하지 못했습니다. 번역 모델 준비를 눌러 다시 시도해 주세요."
            }
        }
    }

    func translationPrepared() {
        translationRetry += 1
        UserDefaults.standard.set(true, forKey: "meetingTranslationInstalled")
    }

    // MARK: - Copy and export

    func copyBilingual() {
        guard !transcript.captions.isEmpty else {
            errorMessage = "복사할 확정된 자막이 아직 없습니다."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript.bilingualPlainText, forType: .string)
        status = "원문과 완료된 한국어 번역을 복사했습니다."
    }

    func exportTXT() { export(.txt) }
    func exportMarkedTXT() { export(.txt, markedOnly: true) }
    func exportSRT() { export(.srt) }

    private func export(_ format: TranscriptExportFormat, markedOnly: Bool = false) {
        persist()
        guard !transcript.captions.isEmpty else {
            errorMessage = "내보낼 확정된 자막이 아직 없습니다."
            return
        }
        guard !markedOnly || markedCount > 0 else {
            errorMessage = "중요 표시한 자막이 없습니다. ⌘D 또는 자막의 오른쪽 클릭 메뉴로 표시해 주세요."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.rawValue) ?? .plainText]
        panel.nameFieldStringValue = transcript.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-") + (markedOnly ? " 중요" : "") + "." + format.rawValue
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let collisions = TranscriptExport.files(for: transcript, to: url, format: format, markedOnly: markedOnly)
                .dropFirst().filter { FileManager.default.fileExists(atPath: $0.url.path) }
            if !collisions.isEmpty {
                let alert = NSAlert()
                alert.messageText = "기존 번역 파일도 덮어쓸까요?"
                alert.informativeText = collisions.map { $0.url.lastPathComponent }.joined(separator: "\n")
                alert.addButton(withTitle: "덮어쓰기")
                alert.addButton(withTitle: "취소")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            let written = try TranscriptExport.write(transcript, to: url, format: format, markedOnly: markedOnly,
                                                     replacingDerived: !collisions.isEmpty)
            status = "저장했습니다: " + written.map(\.lastPathComponent).joined(separator: ", ")
        } catch {
            errorMessage = "내보내지 못했습니다: \(error.localizedDescription)"
        }
    }

    // MARK: - Persistence

    @discardableResult
    func persist() -> Bool {
        guard let jsonURL else { return true }
        do {
            try TranscriptDisk.save(transcript, at: jsonURL, srt: false)
            lastPersistenceError = nil
            return true
        } catch {
            let message = "자막 저장에 실패했습니다. 전체 복사로 내용을 보관해 주세요.\n\(error.localizedDescription)"
            errorMessage = message
            lastPersistenceError = message
            return false
        }
    }

    private func schedulePersist() {
        // Throttle writes; a continuous stream must still flush once per second.
        guard persistTask == nil else { return }
        persistTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            persistTask = nil
            persist()
        }
    }
}
