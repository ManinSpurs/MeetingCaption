import AppKit
import CaptionCore
import SwiftUI
import Translation

/// Main meeting window. Every value comes from `MeetingModel`; the view only owns
/// presentation state (translation configuration, auto-scroll) and never invents
/// caption content.
struct MeetingView: View {
    @ObservedObject var model: MeetingModel
    @ObservedObject var captions: MeetingCaptionPanelController
    @ObservedObject var ai: MeetingAI
    @ObservedObject var ui: MeetingViewState
    @Environment(\.openSettings) private var openSettings
    @AppStorage("captionFontSize") private var captionFontSize = 15.0

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 252, ideal: 276, max: 330)
        } detail: {
            workspace
                .toolbar { meetingToolbar }
        }
        .frame(minWidth: ui.showAssistant ? 1040 : 880, minHeight: 600)
        .task(id: model.translationTaskID) { await model.runInstalledTranslation() }
        .onChange(of: model.translationEnabled) {
            if !model.translationEnabled { ui.translationConfiguration = nil }
        }
        .onChange(of: model.translationProvider) { ui.translationConfiguration = nil }
        .onChange(of: model.transcript.locale) {
            // A prepared session is bound to one language pair; dropping it keeps the
            // status honest instead of letting the previous pair keep translating.
            ui.translationConfiguration = nil
        }
        .translationTask(ui.translationConfiguration) { session in
            do {
                try await session.prepareTranslation()
                model.translationPrepared()
            } catch {
                guard !Task.isCancelled else { return }
                model.translationStatus = "번역 언어 모델을 준비하지 못했습니다: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Sidebar

    private var workspace: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                detail
                    .frame(width: max(0, geometry.size.width - (ui.showAssistant ? 361 : 0)),
                           height: geometry.size.height)
                if ui.showAssistant {
                    Divider()
                    MeetingAIPanel(ai: ai, transcript: model.transcript)
                        .frame(width: 360, height: geometry.size.height)
                }
            }
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sidebarSection("과목") {
                    CurrentSubjectField(model: model)
                }

                sidebarSection("기록") {
                    RecordsSidebarList(model: model)
                    HStack(spacing: 12) {
                        Button("새로 고침") { model.refreshLibrary() }
                            .disabled(model.isLocked)
                        Button {
                            NSWorkspace.shared.open(model.library)
                        } label: {
                            Label("보관 폴더 열기", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                        .help(model.library.path(percentEncoded: false))
                        Spacer(minLength: 0)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sidebarSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: Detail

    private var detail: some View {
        VStack(spacing: 0) {
            transcriptHeader
            Divider()
            if let message = model.errorMessage {
                errorBanner(message)
                Divider()
            }
            if translationNotice != .none {
                translationBanner
                Divider()
            }
            Group {
                if isEmpty {
                    emptyState
                } else if model.showsMarkedOnly && model.markedCount == 0 {
                    ContentUnavailableView {
                        Label("중요 표시한 자막이 없습니다", systemImage: "star")
                    } description: {
                        Text("⌘D로 최신 자막을, 자막을 오른쪽 클릭해 원하는 자막을 중요 표시할 수 있습니다.")
                    } actions: {
                        Button("전체 자막 보기") { model.showsMarkedOnly = false }
                    }
                } else {
                    MeetingTranscriptText(
                        captions: model.showsMarkedOnly ? model.transcript.captions.filter(\.isBookmarked) : model.transcript.captions,
                        provisional: model.showsMarkedOnly ? "" : model.provisional,
                        showsTranslation: showsTranslation,
                        autoScroll: ui.autoScroll,
                        record: model.transcript.created,
                        fontSize: min(36, max(12, captionFontSize)),
                        highlight: model.highlight,
                        playable: model.playableCaptionIDs,
                        playing: model.hasPlayableAudio && !model.isLocked ? model.playingCaptionID : nil,
                        onToggleMark: { id in model.toggleMark(id) },
                        onPlay: { id in model.play(from: id) }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.hasPlayableAudio && !model.isLocked {
                Divider()
                AudioPlaybackBar(player: model.player)
            }
            Divider()
            footer
        }
    }

    private var transcriptHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(recordTitle)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(recordSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { captionFontSize = max(12, captionFontSize - 1) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("자막 작게 보기")
            Button { captionFontSize = min(36, captionFontSize + 1) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("자막 크게 보기")
            Button {
                model.toggleMarkOnNewest()
            } label: {
                Image(systemName: model.transcript.captions.last?.isBookmarked == true ? "star.fill" : "star")
            }
            .disabled(model.transcript.captions.isEmpty)
            .help("최신 자막 중요 표시 (⌘D). 다른 자막은 오른쪽 클릭으로 표시합니다.")
            Toggle(isOn: $model.showsMarkedOnly) {
                Label("중요만 \(model.markedCount)", systemImage: "line.3.horizontal.decrease.circle")
            }
            .toggleStyle(.button)
            .help("중요 표시한 자막만 봅니다.")
            if model.hasPlayableAudio {
                Image(systemName: "waveform")
                    .foregroundStyle(.secondary)
                    .help("이 기록에는 녹음이 있습니다. 자막의 ▶ 또는 오른쪽 클릭 ‘여기부터 듣기’로 들을 수 있습니다.")
            }
            Text("\(model.transcript.captions.count)문장")
                .font(.caption)
                .monospacedDigit()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
            if model.isLocked {
                Button {
                    model.stop()
                } label: {
                    Label(stopLabel, systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(model.isStopping || model.isSwitchingSession)
                .help("회의 기록을 마치고 확정된 문장을 저장합니다.")
            } else {
                Button {
                    model.start()
                } label: {
                    Label("기록 시작", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .help("선택한 입력과 언어로 회의 기록을 시작합니다.")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isLocked {
            ContentUnavailableView {
                Label("듣고 있습니다", systemImage: "waveform")
            } description: {
                Text("\(displayName(for: model.transcript.locale)) 음성을 기다리는 중입니다. 첫 문장이 확정되면 여기에 쌓입니다.\n소리가 나지 않는다면 입력이 \(inputTitle(for: model.transcript.source))(으)로 맞는지, 권한이 허용되었는지 확인해 주세요.")
            }
        } else {
            ContentUnavailableView {
                Label("회의 기록이 비어 있습니다", systemImage: "waveform")
            } description: {
                Text("시작을 누르면 선택한 입력과 언어로 회의를 받아씁니다. 확정된 문장은 아래에 계속 쌓이고, 인식 중인 문장은 흐리게 표시됩니다. 쌓인 텍스트는 이어서 선택하거나 전체 선택해 복사할 수 있습니다.")
            } actions: {
                EmptyView()
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("확인") { model.errorMessage = nil }
                .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
    }

    private var translationNotice: TranslationNotice {
        TranslationNotice.current(
            enabled: model.translationEnabled, provider: model.translationProvider,
            consent: model.cloudTranslationConsent,
            hasKeys: model.hasTranslationKeys(for: model.translationProvider),
            sourceIsKorean: !MeetingViewState.canTranslate(localeID: model.transcript.locale),
            hasPending: model.nextTranslationCaption != nil, isLocked: model.isLocked,
            status: model.translationStatus)
    }

    /// Answers the per-record send consent and shows translation failures where the user
    /// is working; everything else about translation is configured in Settings.
    private var translationBanner: some View {
        let provider = model.translationProvider
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "character.bubble")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                switch translationNotice {
                case .needsConsent:
                    Text("\(provider.vendor) 번역: 이 기록의 원문을 \(provider.vendor)로 전송하는 데 동의해야 번역을 시작합니다. 사용료가 발생할 수 있으며 Apple 번역으로 자동 전환하지 않습니다.")
                    Toggle("\(provider.vendor) 원문 전송·사용료에 동의", isOn: $model.cloudTranslationConsent)
                        .toggleStyle(.checkbox)
                case .needsKeys:
                    Text("\(provider.title) 인증 정보를 저장해야 번역할 수 있습니다.")
                case .problem(let message):
                    Text(message).textSelection(.enabled)
                case .none:
                    EmptyView()
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if case .problem = translationNotice {
                Button(provider == .apple ? "번역 모델 준비" : "다시 시도") {
                    if provider == .apple { ui.prepareTranslationModel(for: model) } else { model.translationRetry += 1 }
                }
                .controlSize(.small)
            }
            Button("번역 설정…") { SettingsNavigation.shared.show(.translation, using: openSettings) }
                .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
    }

    private var translationChip: String {
        guard model.translationEnabled else { return "번역 꺼짐" }
        let title = model.translationProvider.title
        switch translationNotice {
        case .needsConsent: return "번역 · \(title) · 동의 필요"
        case .needsKeys: return "번역 · \(title) · 키 필요"
        case .problem: return "번역 · \(title) · 확인 필요"
        case .none: return "번역 · \(title)"
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if model.isStarting || model.isStopping {
                ProgressView().controlSize(.small)
            } else {
                stateDot
            }
            Text(stateHeadline)
                .font(.caption.weight(.medium))
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if model.isWaitingForCaptionPause {
                Text("이어지는 발언을 기다리는 중…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let url = model.recentlySavedURL {
                Button("저장됨 · 폴더 열기") {
                    model.reveal(url)
                }
                .font(.caption)
            }
            Spacer(minLength: 8)
            Button {
                SettingsNavigation.shared.show(.general, using: openSettings)
            } label: {
                Label("\(displayName(for: model.localeID)) · \(model.source.title)" + (model.recordsAudio ? " · 녹음" : ""),
                      systemImage: model.source == .system ? "speaker.wave.2" : "mic")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .help("입력과 인식 언어 설정 열기")
            Button {
                SettingsNavigation.shared.show(.translation, using: openSettings)
            } label: {
                Text(translationChip)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .help("번역 설정 열기")
            Toggle("자동 스크롤", isOn: $ui.autoScroll)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("새 문장이 오면 위쪽 최신 자막을 따라갑니다. 텍스트를 선택해 둔 동안에는 움직이지 않습니다.")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var meetingToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                ui.showAssistant.toggle()
            } label: {
                Label(ui.showAssistant ? "AI 도우미 닫기" : "AI 도우미", systemImage: "sparkles")
            }
            .keyboardShortcut("j", modifiers: [.command, .shift])
            Button {
                model.saveAndStartNewSession()
            } label: {
                Label("저장하고 새 기록 시작", systemImage: "plus")
            }
            .disabled(model.isStarting || model.isStopping || model.isSwitchingSession)
            .help("마지막 문장까지 저장한 뒤 같은 입력과 언어로 새 기록을 시작합니다. 전환 중에는 잠시 인식이 끊깁니다.")
            Button {
                model.copyBilingual()
            } label: {
                Label("복사", systemImage: "doc.on.doc")
            }
            .disabled(model.transcript.captions.isEmpty)
            .help("확정된 원문과 번역을 함께 복사합니다.")
            Menu {
                Button("TXT로 내보내기…") { model.exportTXT() }
                Button("중요 표시만 TXT로 내보내기…") { model.exportMarkedTXT() }
                    .disabled(model.markedCount == 0)
                Button("SRT로 내보내기…") { model.exportSRT() }
            } label: {
                Label("내보내기", systemImage: "square.and.arrow.up")
            }
            .disabled(model.transcript.captions.isEmpty)
            .help("회의 기록을 TXT 또는 SRT 파일로 저장합니다.")
            Button {
                captions.toggle()
            } label: {
                Label(captions.isVisible ? "자막 창 닫기" : "떠 있는 자막 창",
                      systemImage: captions.isVisible ? "pip.exit" : "pip")
            }
            .help("항상 위에 표시되는 작은 자막 창을 엽니다. 화면 공유에도 그대로 보입니다.")
            Button {
                SettingsNavigation.shared.show(.general, using: openSettings)
            } label: {
                Label("설정", systemImage: "gearshape")
            }
            .help("설정 (⌘,)")
        }
    }

    // MARK: Derived state

    private var isEmpty: Bool {
        model.transcript.captions.isEmpty && model.provisional.isEmpty
    }

    private var showsTranslation: Bool {
        model.transcript.captions.contains { !($0.koreanText ?? "").isEmpty }
    }

    private var recordTitle: String {
        model.transcript.title.isEmpty ? "새 회의" : model.transcript.title
    }

    private var recordSubtitle: String {
        // The title already carries the input and start time for a fresh record, so this
        // line only adds what the title cannot show: the language the words were heard in.
        let language = displayName(for: model.transcript.locale)
        let input = inputTitle(for: model.transcript.source)
        let bilingual = showsTranslation
        return bilingual ? "\(language) · \(input) · 한국어 번역" : "\(language) · \(input)"
    }

    /// Starting can still be cancelled, so the primary button stays useful during setup.
    private var stopLabel: String {
        if model.isStopping { return "저장 중" }
        if model.isStarting { return "시작 취소" }
        return "중지"
    }

    private var stateHeadline: String {
        if model.isStopping { return "저장 중" }
        if model.isStarting { return "준비 중" }
        if model.isRecording { return "기록 중" }
        return "대기 중"
    }

    private var stateDot: some View {
        Circle()
            .fill(model.isRecording ? Color.red : (model.isLocked ? Color.orange : Color.secondary))
            .frame(width: 7, height: 7)
            .padding(.top, 5)
    }

    private func displayName(for identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    private func inputTitle(for raw: String) -> String {
        MeetingInput(rawValue: raw)?.title ?? raw
    }
}

/// Window-local presentation state. Held in an observable object because this toolchain
/// ships no SwiftUI macro plugin, so `@State` cannot expand; behaviour is the same.
@MainActor
final class MeetingViewState: ObservableObject {
    @Published var translationConfiguration: TranslationSession.Configuration?
    @Published var autoScroll = true
    @Published var showAssistant = true

    func prepareTranslation(source: Locale.Language) {
        if translationConfiguration?.source != source {
            translationConfiguration = TranslationSession.Configuration(source: source, target: Locale.Language(identifier: "ko"))
        }
        translationConfiguration?.invalidate()
    }
}

/// Keeps sidebar explanatory text wrapping inside the narrow column.
private struct SidebarNote: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    func sidebarNote() -> some View { modifier(SidebarNote()) }
}

/// One native text document keeps selections continuous across caption boundaries.
struct MeetingTranscriptText: NSViewRepresentable {
    var captions: [Caption]
    var provisional: String
    var showsTranslation: Bool
    var autoScroll: Bool
    /// Identifies the open record (`Transcript.created`); a change means a different record.
    var record: Date? = nil
    var fontSize: Double = 15
    var highlight: CaptionHighlight? = nil
    /// Captions that have recorded audio to play from, and the one being played.
    var playable: Set<UUID> = []
    var playing: UUID? = nil
    var onToggleMark: (UUID) -> Void = { _ in }
    var onPlay: (UUID) -> Void = { _ in }

    static let captionKey = NSAttributedString.Key("MeetingCaptionID")
    static let markScheme = "meetingcaption-mark"
    static let playLabel = "여기부터 듣기"

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let text = TranscriptTextView(frame: .zero)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = true
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        text.isAutomaticLinkDetectionEnabled = false
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 20, height: 14)
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.setAccessibilityLabel("회의 자막 전체 텍스트")
        text.linkTextAttributes = [.foregroundColor: NSColor.systemOrange, .cursor: NSCursor.pointingHand]
        text.delegate = context.coordinator
        scroll.documentView = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        updateText(text, coordinator: context.coordinator)
    }

    func updateText(_ text: NSTextView, coordinator: Coordinator) {
        coordinator.captions = captions
        coordinator.onToggleMark = onToggleMark
        coordinator.playable = playable
        coordinator.onPlay = onPlay
        defer {
            if let text = text as? TranscriptTextView {
                text.updatePlayMarkers(playable, playing: playing, fontSize: fontSize, onPlay: onPlay)
            }
            scrollToHighlight(text, coordinator: coordinator)
            followPlayback(text, coordinator: coordinator)
        }
        let document = document()
        guard !(coordinator.lastDocument?.isEqual(to: document) ?? false) else { return }
        // TextKit mutates storage while a drag is selecting; overwriting then drops the selection.
        if NSEvent.pressedMouseButtons & 1 != 0, text.window?.firstResponder === text { return }
        coordinator.lastDocument = NSAttributedString(attributedString: document)

        let old = text.string as NSString
        let oldSelection = text.selectedRange()
        let selectedAll = old.length > 0 && oldSelection == NSRange(location: 0, length: old.length)
        let selected = oldSelection.length > 0 && NSMaxRange(oldSelection) <= old.length
            ? old.substring(with: oldSelection) : nil
        let changedText = text.string != document.string
        text.textStorage?.setAttributedString(document)

        let new = document.string as NSString
        var restored = selectedAll ? NSRange(location: 0, length: new.length) : NSRange(
            location: min(oldSelection.location, new.length),
            length: min(oldSelection.length, max(0, new.length - min(oldSelection.location, new.length)))
        )
        if !selectedAll, let selected, !selected.isEmpty {
            if NSMaxRange(restored) > new.length || new.substring(with: restored) != selected {
                let match = new.range(of: selected)
                if match.location != NSNotFound { restored = match }
            }
        }
        text.setSelectedRange(restored)
        let newest = NewestContent(captions: captions, provisional: provisional, showsTranslation: showsTranslation)
        let newestAdvanced = newest.advances(from: coordinator.lastNewest)
        coordinator.lastNewest = newest
        // Another record always starts at its newest caption, even if that caption is older
        // in time than the one the previous record was scrolled to.
        let recordChanged = coordinator.lastRecord != record
        coordinator.lastRecord = record
        if changedText && (newestAdvanced || recordChanged) && autoScroll && oldSelection.length == 0 {
            text.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
    }

    /// What the top of the transcript shows. Auto-scroll follows only new or growing speech, so
    /// marks, playback and highlights on older captions never move the reading position.
    struct NewestContent: Equatable {
        var id: UUID?
        var start: Double?
        var text: String?
        var translation: String?
        var provisional: String

        init(captions: [Caption], provisional: String, showsTranslation: Bool) {
            let newest = captions.last
            id = newest?.id
            start = newest?.start
            text = newest?.text
            translation = showsTranslation ? newest?.koreanText : nil
            self.provisional = provisional
        }

        func advances(from old: NewestContent?) -> Bool {
            guard let old else { return true }
            if provisional != old.provisional && !provisional.isEmpty { return true }
            if id == old.id { return text != old.text || translation != old.translation }
            // A different top caption: newer speech, not an older one surfacing after an unmark.
            guard let start else { return false }
            return start >= (old.start ?? -.infinity)
        }
    }

    /// Scrolls once per highlight request; later caption updates leave the reader's position alone.
    private func scrollToHighlight(_ text: NSTextView, coordinator: Coordinator) {
        guard let highlight, coordinator.scrolledHighlight != highlight.revision,
              let range = Self.range(of: highlight.captionID, in: text.attributedString()) else { return }
        coordinator.scrolledHighlight = highlight.revision
        text.scrollRangeToVisible(range)
        if text.window != nil { text.showFindIndicator(for: range) }
    }

    /// Keeps the caption being played in view when auto-scroll is on, unless the reader has
    /// selected text.
    private func followPlayback(_ text: NSTextView, coordinator: Coordinator) {
        guard coordinator.followedPlaying != playing else { return }
        coordinator.followedPlaying = playing
        guard autoScroll, let playing, text.selectedRange().length == 0,
              let range = Self.range(of: playing, in: text.attributedString()) else { return }
        text.scrollRangeToVisible(range)
    }

    static func range(of id: UUID, in document: NSAttributedString) -> NSRange? {
        var found: NSRange?
        document.enumerateAttribute(captionKey, in: NSRange(location: 0, length: document.length)) { value, range, _ in
            guard value as? String == id.uuidString else { return }
            found = found.map { NSUnionRange($0, range) } ?? range
        }
        return found
    }

    private func document() -> NSAttributedString {
        let document = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 8
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        if !provisional.isEmpty {
            var tagStyle = base
            tagStyle[.font] = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
            tagStyle[.foregroundColor] = NSColor.tertiaryLabelColor
            var pendingStyle = base
            pendingStyle[.foregroundColor] = NSColor.secondaryLabelColor
            pendingStyle[.obliqueness] = 0.12
            document.append(NSAttributedString(string: "인식 중  ", attributes: tagStyle))
            document.append(NSAttributedString(string: provisional + "\n", attributes: pendingStyle))
        }
        for cue in captions.reversed() {
            let start = document.length
            var cueBase = base
            if cue.isBookmarked {
                cueBase[.backgroundColor] = NSColor.systemYellow.withAlphaComponent(0.16)
            }
            if playing == cue.id {
                cueBase[.backgroundColor] = NSColor.controlAccentColor.withAlphaComponent(0.22)
            }
            if highlight?.captionID == cue.id {
                cueBase[.backgroundColor] = NSColor.findHighlightColor.withAlphaComponent(0.45)
            }
            if cue.isBookmarked {
                var markStyle = cueBase
                markStyle[.font] = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
                markStyle[.link] = URL(string: "\(Self.markScheme):\(cue.id.uuidString)")
                markStyle[.toolTip] = "중요 표시 해제"
                document.append(NSAttributedString(string: Transcript.bookmarkPrefix, attributes: markStyle))
            }
            var timeStyle = cueBase
            timeStyle[.font] = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            timeStyle[.foregroundColor] = cue.isBookmarked ? NSColor.systemOrange : NSColor.tertiaryLabelColor
            document.append(NSAttributedString(
                string: Transcript.timestamp(cue.start).replacingOccurrences(of: ",", with: ".") + "  ",
                attributes: timeStyle
            ))
            document.append(NSAttributedString(string: cue.text + "\n", attributes: cueBase))
            if showsTranslation, let korean = cue.koreanText?.trimmingCharacters(in: .whitespacesAndNewlines), !korean.isEmpty {
                var translatedStyle = cueBase
                translatedStyle[.foregroundColor] = NSColor.secondaryLabelColor
                document.append(NSAttributedString(string: korean + "\n", attributes: translatedStyle))
            }
            document.addAttribute(Self.captionKey, value: cue.id.uuidString,
                                  range: NSRange(location: start, length: document.length - start))
        }
        return document
    }

    /// Owns the text view's delegate callbacks: clicking ★ unmarks, and the context menu marks
    /// or unmarks the caption under the pointer.
    final class Coordinator: NSObject, NSTextViewDelegate {
        var lastDocument: NSAttributedString?
        var lastNewest: NewestContent?
        var lastRecord: Date?
        var scrolledHighlight: UUID?
        var followedPlaying: UUID?
        var captions: [Caption] = []
        var playable: Set<UUID> = []
        var onToggleMark: (UUID) -> Void = { _ in }
        var onPlay: (UUID) -> Void = { _ in }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL, let scheme = url.scheme,
                  let id = UUID(uuidString: url.absoluteString.replacingOccurrences(of: "\(scheme):", with: "")) else { return false }
            switch scheme {
            case MeetingTranscriptText.markScheme: onToggleMark(id)
            default: return false
            }
            return true
        }

        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            guard let id = captionID(in: view, at: charIndex),
                  let cue = captions.first(where: { $0.id == id }) else { return menu }
            let item = NSMenuItem(title: cue.isBookmarked ? "중요 표시 해제" : "중요 표시",
                                  action: #selector(toggleFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            menu.insertItem(item, at: 0)
            var next = 1
            if playable.contains(id) {
                let play = NSMenuItem(title: MeetingTranscriptText.playLabel, action: #selector(playFromMenu(_:)), keyEquivalent: "")
                play.target = self
                play.representedObject = id
                menu.insertItem(play, at: next)
                next += 1
            }
            menu.insertItem(.separator(), at: next)
            return menu
        }

        @objc func playFromMenu(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID else { return }
            onPlay(id)
        }

        func captionID(in view: NSTextView, at charIndex: Int) -> UUID? {
            let length = view.textStorage?.length ?? 0
            guard length > 0 else { return nil }
            let index = min(max(0, charIndex), length - 1)
            return (view.textStorage?.attribute(MeetingTranscriptText.captionKey, at: index, effectiveRange: nil) as? String)
                .flatMap(UUID.init(uuidString:))
        }

        @objc func toggleFromMenu(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID else { return }
            onToggleMark(id)
        }
    }
}

/// Small always-on-top caption window content. Two lines only: the latest finalized
/// English cue and its translation, plus the in-progress sentence in a thinner weight.
struct MeetingFloatingCaption: View {
    @ObservedObject var model: MeetingModel
    @AppStorage("captionFontSize") private var captionFontSize = 15.0

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.isRecording ? Color.red : (model.isLocked ? Color.orange : Color.secondary))
                    .frame(width: 6, height: 6)
                Text(headline)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                if model.isLocked {
                    Button("중지") { model.stop() }
                        .controlSize(.mini)
                        .disabled(model.isStopping)
                }
            }
            Spacer(minLength: 0)
            Text(primaryEnglish)
                .font(.system(size: min(36, max(12, captionFontSize)) + 2, weight: .semibold))
                .textSelection(.enabled)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if let translated {
                Text(translated)
                    .font(.system(size: min(36, max(12, captionFontSize)) + 2))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsProvisionalSeparately {
                Text(model.provisional)
                    .font(.system(size: 12))
                    .italic()
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private var lastFinal: Caption? { model.transcript.captions.last }

    private var primaryEnglish: String {
        if let lastFinal, !lastFinal.text.isEmpty { return lastFinal.text }
        if !model.provisional.isEmpty { return model.provisional }
        return model.isLocked ? "듣는 중…" : "회의를 시작하면 최신 문장이 여기에 표시됩니다."
    }

    private var translated: String? {
        guard let lastFinal, let korean = lastFinal.koreanText, !korean.isEmpty else { return nil }
        return korean
    }

    private var showsProvisionalSeparately: Bool {
        lastFinal != nil && !model.provisional.isEmpty
    }

    private var headline: String {
        if model.isStopping { return "저장 중" }
        if model.isStarting { return "준비 중" }
        if model.isRecording { return "기록 중" }
        return "대기 중"
    }
}
