import AppKit
import CaptionCore
import SwiftUI

/// Panes of the Settings window. Every configuration control lives in exactly one of them.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, translation, ai, glossary, update, privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "일반"
        case .translation: return "번역"
        case .ai: return "AI"
        case .glossary: return "용어집"
        case .update: return "업데이트"
        case .privacy: return "개인정보"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .translation: return "character.bubble"
        case .ai: return "sparkles"
        case .glossary: return "text.book.closed"
        case .update: return "arrow.triangle.2.circlepath"
        case .privacy: return "hand.raised"
        }
    }

    var height: CGFloat {
        switch self {
        case .general: return 560
        case .translation, .ai: return 620
        case .glossary: return 300
        case .update: return 360
        case .privacy: return 380
        }
    }
}

/// Which pane the Settings window shows. The main window sets it before opening Settings, so
/// "AI 설정 열기" lands on the AI pane.
@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var pane: SettingsPane = .general

    func show(_ pane: SettingsPane, using open: OpenSettingsAction) {
        self.pane = pane
        open()
    }
}

/// What the main window must tell the user about translation without opening Settings.
enum TranslationNotice: Equatable {
    case none
    /// A cloud provider is chosen but sending this record's text was not agreed to.
    case needsConsent
    case needsKeys
    /// A failure or setup step reported by the model, shown verbatim with a retry.
    case problem(String)

    private static let problemMarkers = ["실패", "준비하지 못했습니다", "준비를 눌러", "지원하지 않습니다"]

    static func current(enabled: Bool, provider: CaptionTranslationProvider, consent: Bool, hasKeys: Bool,
                        sourceIsKorean: Bool, hasPending: Bool, isLocked: Bool, status: String) -> TranslationNotice {
        guard enabled, !sourceIsKorean else { return .none }
        if provider.isCloud {
            guard isLocked || hasPending else { return .none }
            if !consent { return .needsConsent }
            if !hasKeys { return .needsKeys }
        }
        let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
        if problemMarkers.contains(where: trimmed.contains) { return .problem(trimmed) }
        return .none
    }
}

extension MeetingViewState {
    /// Korean source needs no translation.
    static func canTranslate(localeID: String) -> Bool {
        Locale.Language(identifier: localeID).languageCode?.identifier != "ko"
    }

    /// Preparing a model needs a `TranslationSession`, which only the main window's
    /// `.translationTask` can run; Settings and the main window both ask through here.
    func prepareTranslationModel(for model: MeetingModel) {
        guard model.translationEnabled, model.translationProvider == .apple,
              Self.canTranslate(localeID: model.localeID) else { return }
        prepareTranslation(source: Locale.Language(identifier: model.localeID))
    }
}

/// The Settings window. It edits the same model objects as the main window.
struct MeetingSettingsView: View {
    @ObservedObject var model: MeetingModel
    @ObservedObject var ai: MeetingAI
    @ObservedObject var ui: MeetingViewState
    @ObservedObject private var navigation = SettingsNavigation.shared

    var body: some View {
        TabView(selection: $navigation.pane) {
            ForEach(SettingsPane.allCases) { pane in
                paneView(pane)
                    .tabItem { Label(pane.title, systemImage: pane.symbol) }
                    .tag(pane)
            }
        }
        .frame(width: 600, height: navigation.pane.height)
    }

    @ViewBuilder
    private func paneView(_ pane: SettingsPane) -> some View {
        switch pane {
        case .general: GeneralSettingsPane(model: model)
        case .translation: TranslationSettingsPane(model: model, ui: ui)
        case .ai: AISettingsPane(ai: ai)
        case .glossary:
            Form { Section("전공 용어집") { GlossarySidebarSection(model: model) } }
                .formStyle(.grouped)
        case .update:
            Form { Section { UpdateSettingsSection(updater: AppUpdater.shared) } }
                .formStyle(.grouped)
        case .privacy: PrivacySettingsPane()
        }
    }
}

private struct GeneralSettingsPane: View {
    @ObservedObject var model: MeetingModel
    @AppStorage("captionFontSize") private var captionFontSize = 15.0

    var body: some View {
        Form {
            Section("입력") {
                Picker("오디오", selection: $model.source) {
                    ForEach(MeetingInput.allCases) { input in
                        Label(input.title, systemImage: input == .system ? "speaker.wave.2" : "mic").tag(input)
                    }
                }
                .disabled(model.isLocked)
                Picker("인식 언어", selection: $model.localeID) {
                    ForEach(localeOptions, id: \.identifier) { locale in
                        Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                            .tag(locale.identifier)
                    }
                }
                .disabled(model.isLocked)
                Text(model.isLocked
                     ? "기록 중에는 입력과 언어를 바꿀 수 없습니다. 기록을 중지한 뒤 바꿔 주세요."
                     : "바꾼 설정은 다음 기록부터 적용됩니다. 이미 저장한 회의는 기록 당시의 입력과 언어로 남습니다.")
                    .sidebarNote()
            }
            Section("음성 녹음") {
                Toggle("음성도 함께 녹음", isOn: $model.recordsAudio)
                    .disabled(model.isLocked)
                    .help("인식하는 소리를 기록과 함께 보관 폴더에 저장해, 자막을 눌러 그 부분부터 다시 들을 수 있습니다.")
                Text("켜면 인식하는 소리(\(model.source.title))를 기록 옆에 압축 오디오(.m4a)로 저장합니다. 강의나 회의를 녹음해도 되는지 먼저 확인해 주세요. 녹음 파일은 1시간에 약 15MB의 디스크 공간을 차지합니다. 다음 기록 시작부터 적용되며, 녹음 파일은 이 Mac에만 보관합니다.")
                    .sidebarNote()
            }
            Section("자막") {
                Picker("문장 합치기 대기", selection: $model.captionPauseSeconds) {
                    Text("끄기 · 바로 번역").tag(0.0)
                    Text("1초").tag(1.0)
                    Text("2초 · 기본").tag(2.0)
                    Text("3초").tag(3.0)
                    Text("5초").tag(5.0)
                }
                Text("짧은 쉼 뒤 이어지는 발언을 합친 후 번역합니다. 원문은 바로 표시·저장됩니다. 음성인식 결과의 시간과 갱신을 기준으로 기다리므로 실제 무음과 차이가 있을 수 있습니다. 중지할 때는 대기 중인 문장을 확정합니다.")
                    .sidebarNote()
                Stepper(value: $captionFontSize, in: 12...36) {
                    LabeledContent("자막 글자 크기", value: "\(Int(min(36, max(12, captionFontSize))))pt")
                }
            }
            Section("보관 폴더") {
                LabeledContent("위치") {
                    Text(model.library.path(percentEncoded: false))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var localeOptions: [Locale] {
        var options = model.locales
        if !options.contains(where: { $0.identifier == model.localeID }) {
            options.append(Locale(identifier: model.localeID))
        }
        return options
    }
}

private struct TranslationSettingsPane: View {
    @ObservedObject var model: MeetingModel
    @ObservedObject var ui: MeetingViewState

    var body: some View {
        Form {
            Section("한국어 번역") {
                Toggle("한국어 번역", isOn: $model.translationEnabled)
                Picker("번역 제공자", selection: $model.translationProvider) {
                    ForEach(CaptionTranslationProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                Text("제공자를 바꿔도 완료된 번역은 유지하며, 아직 번역되지 않은 문장부터 새 제공자를 사용합니다.")
                    .sidebarNote()
                Text(explanation).sidebarNote()
            }
            Section("\(model.translationProvider.title) 설정") {
                switch model.translationProvider {
                case .google: GoogleTranslationSettingsSection(model: model)
                case .deepL: DeepLTranslationSettingsSection(model: model)
                case .papago: PapagoTranslationSettingsSection(model: model)
                case .apple:
                    Button(model.translationRetry > 0 ? "번역 모델 다시 시도" : "번역 모델 준비") {
                        ui.prepareTranslationModel(for: model)
                    }
                    .disabled(!model.translationEnabled || !MeetingViewState.canTranslate(localeID: model.localeID))
                }
            }
        }
        .formStyle(.grouped)
    }

    private var explanation: String {
        let status = model.translationStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        if !status.isEmpty { return status }
        if !model.translationEnabled { return "번역을 켜면 확정된 문장에 한국어 번역을 함께 보관합니다. 이미 번역된 문장은 계속 표시됩니다." }
        return "번역 모델을 준비하면 확정된 문장부터 한국어 번역이 붙습니다."
    }
}

private struct AISettingsPane: View {
    @ObservedObject var ai: MeetingAI

    var body: some View {
        Form {
            Section("AI 도우미") { MeetingAISettingsView(ai: ai) }
        }
        .formStyle(.grouped)
        .task { await ai.refreshAvailability() }
    }
}

private struct PrivacySettingsPane: View {
    var body: some View {
        Form {
            Section("개인정보") {
                Text("음성 인식은 이 Mac의 Apple 음성 인식으로 처리되며 회의 오디오를 별도 서버로 보내지 않습니다. 컴퓨터 소리를 받으려면 ‘화면 및 시스템 오디오 녹음’ 권한이, 마이크를 쓰려면 ‘마이크’ 권한이 필요합니다. 일부 앱은 시스템 오디오 캡처를 막습니다. 기록은 이 Mac의 보관 폴더에만 저장됩니다. 번역과 AI는 기본으로 이 Mac의 Apple 기능을 쓰며, 외부 제공자(Google·DeepL·Papago·OpenAI·Gemini·Claude)는 직접 고르고 전송에 동의한 경우에만 자막 텍스트를 보냅니다. 녹음 파일은 어디로도 보내지 않습니다.")
                    .sidebarNote()
                Text("떠 있는 자막 창은 일반 창과 똑같이 화면 공유에 보입니다. 화면에서 숨기는 기능이 아닙니다.")
                    .sidebarNote()
                Button("개인정보 보호 설정 열기") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Provider, availability, key and consent settings for the AI panel. Consent stays off
/// until the user switches it on.
struct MeetingAISettingsView: View {
    @ObservedObject var ai: MeetingAI

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("AI 제공자", selection: $ai.provider) {
                ForEach(MeetingAIProvider.allCases) { provider in
                    Text(panelProviderTitle(provider)).tag(provider)
                }
            }
            .pickerStyle(.radioGroup)
            .accessibilityLabel("AI 제공자 선택")

            appleSection
            switch ai.provider {
            case .apple: EmptyView()
            case .openAI:
                Divider()
                OpenAISettingsSection(ai: ai)
            case .gemini:
                Divider()
                GeminiSettingsSection(ai: ai)
            case .claude:
                Divider()
                ClaudeSettingsSection(ai: ai)
            }
        }
    }

    private var appleSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Apple 기기 내 처리 · \(ai.localAvailability)")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text("Apple Intelligence가 꺼져 있으면 시스템 설정 > Apple Intelligence 및 Siri에서 켜야 합니다. 켜져 있어도 이 Mac이나 언어 조합에 따라 쓸 수 없을 수 있으며, 그때는 이 옵션이 동작하지 않습니다.")
                .panelNote()
            Button("사용 가능 여부 다시 확인") {
                Task { await ai.refreshAvailability() }
            }
            .controlSize(.small)
            .disabled(ai.isBusy)
        }
    }
}

/// The provider wording must say which side does the work, because the backend's `title`
/// is used verbatim in status lines.
private func panelProviderTitle(_ provider: MeetingAIProvider) -> String {
    switch provider {
    case .apple: return "Apple 기기 내 처리"
    case .openAI: return "OpenAI (API)"
    case .gemini: return "Google Gemini (API)"
    case .claude: return "Anthropic Claude (API)"
    }
}

/// App-menu item "설정…" (⌘,).
struct OpenSettingsCommand: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("설정…") { openSettings() }
            .keyboardShortcut(",", modifiers: [.command])
    }
}
