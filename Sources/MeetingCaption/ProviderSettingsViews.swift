import AppKit
import SwiftUI

// Self-contained provider settings sections. Each takes only its model, so it can move into a
// separate Settings window unchanged.

/// "키 발급 페이지 열기" plus one line saying what to copy there.
struct KeyPageShortcut: View {
    var page: ProviderKeyPage

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                NSWorkspace.shared.open(page.url)
            } label: {
                Label("키 발급 페이지 열기", systemImage: "arrow.up.forward.square")
            }
            .buttonStyle(.link)
            .font(.caption)
            .help(page.url.absoluteString)
            Text(page.hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Translation

/// Key fields, key page, cost note and per-record consent for one cloud translation provider.
struct CloudTranslationSettingsSection: View {
    @ObservedObject var model: MeetingModel
    let provider: CaptionTranslationProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(provider.credentialFields, id: \.self) { field in
                SecureField(field.label, text: draft(field))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("\(field.label) 입력")
            }
            if let page = provider.keyPage { KeyPageShortcut(page: page) }
            HStack {
                Button(model.hasTranslationKeys(for: provider) ? "키 교체" : "키 저장") {
                    model.saveTranslationKeys(for: provider)
                }
                .disabled(provider.credentialFields.allSatisfy { (model.translationKeyDrafts[$0] ?? "").isEmpty })
                if provider.credentialFields.contains(where: model.storedTranslationFields.contains) {
                    Button("키 삭제") { model.removeTranslationKeys(for: provider) }
                }
            }
            Text(model.hasTranslationKeys(for: provider)
                 ? "\(provider.vendor) 인증 정보 저장됨 · 이 Mac의 키체인"
                 : "인증 정보를 입력해 저장하세요. 키는 이 Mac의 키체인에만 보관됩니다.")
                .sidebarNote()
            Toggle("\(provider.vendor) 원문 전송·사용료에 동의", isOn: $model.cloudTranslationConsent)
                .toggleStyle(.checkbox)
            Text("동의하면 현재 기록의 미번역 확정 자막과 이후 확정되는 원문 텍스트를 \(provider.vendor)로 전송합니다. 녹음 파일은 보내지 않습니다. \(provider.costNote) 동의는 이 기록에만 적용되며 다른 기록을 열거나 새 기록을 시작하면 다시 꺼집니다. Apple 번역으로 자동 전환하지 않습니다.")
                .sidebarNote()
            Button("\(provider.vendor) 번역 다시 시도") { model.translationRetry += 1 }
                .disabled(!model.translationEnabled || !model.cloudTranslationConsent || !model.hasTranslationKeys(for: provider))
        }
    }

    private func draft(_ field: TranslationCredentialField) -> Binding<String> {
        Binding(get: { model.translationKeyDrafts[field] ?? "" },
                set: { model.translationKeyDrafts[field] = $0 })
    }
}

struct GoogleTranslationSettingsSection: View {
    @ObservedObject var model: MeetingModel
    var body: some View { CloudTranslationSettingsSection(model: model, provider: .google) }
}

struct DeepLTranslationSettingsSection: View {
    @ObservedObject var model: MeetingModel
    var body: some View { CloudTranslationSettingsSection(model: model, provider: .deepL) }
}

struct PapagoTranslationSettingsSection: View {
    @ObservedObject var model: MeetingModel
    var body: some View { CloudTranslationSettingsSection(model: model, provider: .papago) }
}

// MARK: - AI

/// API key, key page, cost note and send consent for one cloud AI provider.
struct CloudAISettingsSection: View {
    @ObservedObject var ai: MeetingAI
    let provider: MeetingAIProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(provider.vendor) API 키와 전송 동의")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                SecureField("\(provider.vendor) API 키", text: $ai.apiKeyDraft)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("\(provider.vendor) API 키 입력")
                Button(ai.hasAPIKey ? "키 교체" : "키 저장") { ai.saveAPIKey() }
                    .disabled(ai.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ai.isBusy)
            }
            if let page = provider.keyPage { KeyPageShortcut(page: page) }

            HStack(spacing: 8) {
                if ai.hasAPIKey {
                    Label("키 저장됨", systemImage: "checkmark.seal")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("키 삭제") { ai.removeAPIKey() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .disabled(ai.isBusy)
                        .accessibilityLabel("저장된 \(provider.vendor) API 키 삭제")
                } else {
                    Text("저장된 키가 없습니다.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            Text(provider.costNote)
                .panelNote()

            Toggle("\(provider.vendor)로 회의 원문과 입력한 문장을 전송하는 데 동의합니다. API 사용료가 발생합니다.",
                   isOn: $ai.cloudConsent)
                .toggleStyle(.checkbox)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("\(provider.vendor) 전송 동의. 요약은 전체 기록, 발언 추천과 복습은 최근 대화, 표현 교정은 입력한 문장과 관련 원문을 전송합니다. 화면에 보이는 영역만 보내는 것이 아니며 API 사용료가 발생합니다.")

            Text("회의 요약은 전체 기록을 여러 구간으로 나눠 전송합니다. 발언 추천은 최근 대화, 표현 교정은 입력한 문장과 관련 원문, 복습은 최근 원문을 전송합니다. 화면에 보이는 스크롤 영역만 보내는 것이 아닙니다.")
                .panelNote()
            Text("동의를 켜지 않으면 \(provider.vendor)로 전송하지 않고 요청도 만들지 않으며, Apple 기기 내 처리로 자동 전환하지 않습니다. 제공자를 바꾸면 동의를 다시 받아야 합니다.")
                .panelNote()
        }
    }
}

struct OpenAISettingsSection: View {
    @ObservedObject var ai: MeetingAI
    var body: some View { CloudAISettingsSection(ai: ai, provider: .openAI) }
}

struct GeminiSettingsSection: View {
    @ObservedObject var ai: MeetingAI
    var body: some View { CloudAISettingsSection(ai: ai, provider: .gemini) }
}

struct ClaudeSettingsSection: View {
    @ObservedObject var ai: MeetingAI
    var body: some View { CloudAISettingsSection(ai: ai, provider: .claude) }
}
