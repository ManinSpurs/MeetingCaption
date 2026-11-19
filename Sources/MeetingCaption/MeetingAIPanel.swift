import AppKit
import CaptionCore
import SwiftUI

/// AI panel shown beside the meeting transcript. All AI calls, consent and key handling
/// live in `MeetingAI`; this view owns only presentation state and tells the user what is
/// sent, what is not, and what the generated text is (a suggestion, never a quote).
struct MeetingAIPanel: View {
    @ObservedObject var ai: MeetingAI
    let transcript: CaptionCore.Transcript
    @StateObject private var ui = MeetingAIPanelState()
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            actionPicker
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let reason = cloudBlockedReason {
                        cloudNotice(reason)
                    }
                    if transcript.captions.isEmpty, needsTranscript(ui.action) {
                        emptyNotice
                    }
                    actionControls
                    if isRunningHere {
                        activeScopeLine
                    }
                    if let message = visibleError {
                        errorBanner(message)
                    }
                    resultSection
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(minWidth: 320, idealWidth: 360, maxWidth: .infinity,
               minHeight: 500, maxHeight: .infinity)
        .task { await ai.refreshAvailability() }
        .onChange(of: transcript.created) {
            // A new meeting record invalidates drafts written about the previous one.
            ui.startFreshSession()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Label("회의 AI", systemImage: "sparkles")
                .font(.headline)
                .labelStyle(.titleAndIcon)
            Spacer(minLength: 4)
            if ai.isBusy {
                ProgressView()
                    .controlSize(.small)
                Button("취소") { ai.cancel() }
                    .controlSize(.small)
                    .help("진행 중인 AI 요청을 취소합니다.")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var actionPicker: some View {
        Picker("AI 기능", selection: $ui.action) {
            ForEach(MeetingAIAction.allCases) { action in
                Text(tabTitle(action)).tag(action)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .labelsHidden()
        .accessibilityLabel("AI 기능 선택")
        .accessibilityValue(tabTitle(ui.action))
    }

    /// The panel's own tab wording. `MeetingAIAction.title` is the backend's vocabulary and
    /// is used for its status lines, so the two are kept separate on purpose.
    private func tabTitle(_ action: MeetingAIAction) -> String {
        switch action {
        case .reply: return "발언 도우미"
        case .summary: return "회의 요약"
        case .expressions: return "표현 교정"
        case .practice: return "복습 연습"
        }
    }

    // MARK: Per-action controls

    @ViewBuilder
    private var actionControls: some View {
        switch ui.action {
        case .reply:
            replyControls
        case .summary:
            summaryControls
        case .expressions:
            expressionControls
        case .practice:
            practiceControls
        }
    }

    private var replyControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("지금 한국어로 말하고 싶은 의도를 고르면 회의 흐름에 맞는 영어 표현 두 가지와 뜻을 만들어 줍니다.")
                .panelNote()
            Picker("의도", selection: $ui.intent) {
                ForEach(MeetingReplyIntent.allCases) { intent in
                    Text(intent.title).tag(intent)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel("발언 의도")

            TextField("덧붙일 의도 (선택, 한국어)", text: $ui.userIntent, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
                .accessibilityLabel("한국어 의도 입력")
                .help("비워 두면 고른 의도만으로 만듭니다.")

            Button {
                generate(.reply)
            } label: {
                Label("영어 발언 만들기", systemImage: "text.bubble")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.space, modifiers: [.command, .shift])
            .disabled(!canGenerate(.reply))
            .help("⌘⇧Space 로도 만들 수 있습니다. 답변을 자동으로 말하거나 회의 채팅에 전송하지 않습니다.")
        }
    }

    private var summaryControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("지금까지 확정된 자막을 요약하고 관련 원문을 함께 보여줍니다. 결정·할 일은 AI의 정리 초안이므로 원문과 비교해 확인하세요.")
                .panelNote()
            Button {
                generate(.summary)
            } label: {
                Label("회의 요약 만들기", systemImage: "list.bullet.rectangle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canGenerate(.summary))
        }
    }

    private var expressionControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("교정할 문장을 직접 입력하거나 회의 원문에서 골라 넣으세요. 원문 화자를 사용자로 가정하지 않으며, 교정은 입력한 문장에만 적용됩니다. 발음 평가는 하지 않습니다.")
                .panelNote()
            TextField("교정할 문장 (한국어 또는 영어)", text: $ui.expression, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
                .accessibilityLabel("교정할 문장 입력")

            HStack(spacing: 8) {
                Menu("회의 원문에서 고르기") {
                    if transcript.captions.isEmpty {
                        Text("확정된 문장이 없습니다")
                    } else {
                        ForEach(transcript.captions.suffix(12)) { caption in
                            Button(excerptTitle(caption.text)) { ui.expression = caption.text }
                        }
                    }
                }
                .disabled(transcript.captions.isEmpty || ai.isBusy)
                .accessibilityLabel("회의 원문에서 문장 고르기")
                if !ui.expression.isEmpty {
                    Button("입력 지우기") { ui.expression = "" }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .disabled(ai.isBusy)
                }
                Spacer(minLength: 0)
            }

            Button {
                generate(.expressions)
            } label: {
                Label("표현 교정 받기", systemImage: "character.book.closed")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canGenerate(.expressions))
        }
    }

    private var practiceControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("회의 자막을 바탕으로 영어 말하기·쓰기 문제와 예시 답안을 만듭니다. 상황과 설명은 AI가 구성한 연습 예시이며 실제 회의 사실의 요약이 아닙니다. 채점은 하지 않습니다.")
                .panelNote()
            Button {
                generate(.practice)
            } label: {
                Label("연습 문제 만들기", systemImage: "figure.mind.and.body")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canGenerate(.practice))
        }
    }

    // MARK: Notices

    private var emptyNotice: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("아직 확정된 회의 문장이 없습니다", systemImage: "text.bubble")
                .font(.callout.weight(.medium))
            Text("기록을 시작해 문장이 쌓이면 발언 도우미·요약·연습을 만들 수 있습니다. 표현 교정은 문장을 직접 입력하면 바로 쓸 수 있습니다.")
                .panelNote()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private func cloudNotice(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(ai.provider.vendor)로 보내기 전에 설정이 필요합니다", systemImage: "lock.fill")
                .font(.callout.weight(.medium))
            Text(reason)
                .panelNote()
            Button("AI 설정 열기") { SettingsNavigation.shared.show(.ai, using: openSettings) }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    /// The global scope only describes the request in flight; a finished result carries its
    /// own recorded scope, shown next to that result instead of here.
    @ViewBuilder
    private var activeScopeLine: some View {
        if !ai.scopeDescription.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "scope")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(ai.scopeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("처리 범위: \(ai.scopeDescription)")
        }
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("AI 요청을 마치지 못했습니다", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if ui.lastRequest != nil, canGenerate(ui.action) {
                    Button("다시 시도") { run(ui.currentRequest()) }
                        .controlSize(.small)
                }
                Button("닫기") { ui.dismissedError = ai.errorMessage }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Result

    /// True while a request this panel started — or one started while it had no record,
    /// such as the menu shortcut — is still running for the visible tab.
    private var isRunningHere: Bool {
        guard ai.isBusy else { return false }
        guard let running = ui.lastRequest?.action else { return true }
        return running == ui.action
    }

    @ViewBuilder
    private var resultSection: some View {
        let text = (ai.results[ui.action] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if isRunningHere {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(ai.status.isEmpty ? "AI가 응답을 만드는 중입니다…" : ai.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        } else if !text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("\(tabTitle(ui.action)) 결과")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button {
                        copyToPasteboard(text)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("결과를 클립보드로 복사합니다. 어디에도 자동으로 보내지 않습니다.")
                    .accessibilityLabel("\(tabTitle(ui.action)) 결과 복사")
                }
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("\(tabTitle(ui.action)) AI 결과 텍스트")
                    .accessibilityValue(text)
                scopeCaption
                Text(disclaimer(for: ui.action))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if !ai.isBusy {
            Text("아직 결과가 없습니다. 위 버튼을 눌렀을 때만 요청합니다.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    /// The scope recorded when this tab's result was generated, so it stays honest after
    /// the user edits the input or the transcript grows.
    @ViewBuilder
    private var scopeCaption: some View {
        let action = ui.action
        let scope = (ai.resultScopes[action] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !scope.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "scope")
                    .font(.caption2)
                Text(scope + dateSuffix(ai.generatedDates[action]))
                    .font(.caption2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("결과 생성 범위: \(scope)")
        }
    }

    private func dateSuffix(_ date: Date?) -> String {
        guard let date else { return "" }
        return " · \(date.formatted(date: .omitted, time: .shortened)) 생성"
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(ai.status.isEmpty ? "대기 중" : ai.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 4)
            Button {
                SettingsNavigation.shared.show(.ai, using: openSettings)
            } label: {
                Text(ai.provider == .apple ? "Apple 기기 내" : "\(ai.provider.vendor) API")
                    .font(.caption2)
                    .lineLimit(1)
            }
            .buttonStyle(.borderless)
            .help(providerHelp + " · 눌러서 AI 설정 열기")
            .accessibilityLabel(providerHelp)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private var providerHelp: String {
        switch ai.provider {
        case .apple: return "제공자: Apple 기기 내 처리 · \(ai.localAvailability)"
        case .openAI, .gemini, .claude:
            return "제공자: \(ai.provider.vendor) API · \(ai.cloudConsent ? "전송 동의 켜짐" : "전송 동의 꺼짐") · \(ai.hasAPIKey ? "키 저장됨" : "키 없음")"
        }
    }

    // MARK: Logic

    private var visibleError: String? {
        guard let message = ai.errorMessage, message != ui.dismissedError else { return nil }
        return message
    }

    /// Cloud work needs an explicit consent and a stored key; the backend refuses too.
    private var cloudBlockedReason: String? {
        guard ai.provider.isCloud else { return nil }
        let vendor = ai.provider.vendor
        if !ai.cloudConsent {
            return "동의가 꺼져 있어 \(vendor)로 아무것도 전송하지 않습니다. 자동으로 다른 제공자로 바뀌지도 않습니다."
        }
        if !ai.hasAPIKey {
            return "저장된 \(vendor) API 키가 없습니다. 키를 저장해야 요청할 수 있습니다."
        }
        return nil
    }

    /// Correction works on a phrase the user types, so an empty transcript never blocks it.
    private func needsTranscript(_ action: MeetingAIAction) -> Bool {
        switch action {
        case .reply, .summary, .practice: return true
        case .expressions: return false
        }
    }

    private func canGenerate(_ action: MeetingAIAction) -> Bool {
        guard !ai.isBusy, cloudBlockedReason == nil else { return false }
        switch action {
        case .reply, .summary, .practice:
            return !transcript.captions.isEmpty
        case .expressions:
            return !ui.expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func generate(_ action: MeetingAIAction) {
        ui.action = action
        run(ui.currentRequest())
    }

    private func run(_ request: MeetingAIPanelState.Request) {
        guard canGenerate(request.action) else { return }
        ui.action = request.action
        ui.lastRequest = request
        ui.dismissedError = nil
        ai.generate(
            action: request.action,
            transcript: transcript,
            intent: request.intent,
            userIntent: request.userIntent.trimmingCharacters(in: .whitespacesAndNewlines),
            selectedExpression: request.expression.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func excerptTitle(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 42 ? String(flat.prefix(42)) + "…" : flat
    }

    private func disclaimer(for action: MeetingAIAction) -> String {
        switch action {
        case .reply:
            return "AI가 만든 제안이며 회의 참석자의 실제 발언 인용이 아닙니다. 답변을 자동으로 말하거나 회의 채팅에 전송하지 않습니다. 말하기 전에 상황과 표현이 맞는지 확인하세요."
        case .summary:
            return "AI 요약은 원문을 대신하지 않습니다. 결정과 수치는 원문에서 다시 확인하세요."
        case .expressions:
            return "교정 결과는 제안입니다. 발음을 채점하거나 보장하지 않으며, 원문 화자의 말로 인용하지 마세요."
        case .practice:
            return "상황·답안·설명은 연습용 AI 예시이며 참석자의 실제 발언 인용이나 회의 사실 확인이 아닙니다. 직접 말해 본 뒤 참고하세요."
        }
    }
}

/// Presentation-only state for the panel. Held in an observable object because this
/// toolchain ships no SwiftUI macro plugin, so `@State` cannot expand.
@MainActor
final class MeetingAIPanelState: ObservableObject {
    struct Request {
        var action: MeetingAIAction
        var intent: MeetingReplyIntent
        var userIntent: String
        var expression: String
    }

    @Published var action: MeetingAIAction = .reply
    @Published var intent: MeetingReplyIntent = .clarify
    @Published var userIntent = ""
    @Published var expression = ""
    @Published var dismissedError: String?
    @Published var lastRequest: Request?

    func currentRequest() -> Request {
        Request(action: action, intent: intent, userIntent: userIntent, expression: expression)
    }

    func startFreshSession() {
        userIntent = ""
        expression = ""
        dismissedError = nil
        lastRequest = nil
    }
}

/// Keeps explanatory copy readable inside the narrow panel column.
struct MeetingAIPanelNote: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    func panelNote() -> some View { modifier(MeetingAIPanelNote()) }
}
