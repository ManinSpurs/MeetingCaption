import CaptionCore
import Foundation
import Testing
@testable import MeetingCaption

// No live calls: every request below goes to a stubbed transport.

private func jsonObject(_ request: URLRequest) throws -> [String: Any] {
    let body = try #require(request.httpBody)
    return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
}

private func reply(_ request: URLRequest, status: Int, _ body: String) -> (Data, URLResponse) {
    (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
}

@Suite("Cloud translation clients")
struct CloudTranslationClientTests {
    static let deepLFree = "0f3c5c2e-1111-2222-3333-444455556666:fx"
    static let deepLPro = "0f3c5c2e-1111-2222-3333-444455556666"

    @Test func deepLUsesTheHostMatchingTheKeyAndTheDocumentedRequestShape() throws {
        let free = try DeepLTranslationClient.makeRequest("Hello.", sourceLocale: "en-US", key: Self.deepLFree)
        #expect(free.url?.absoluteString == "https://api-free.deepl.com/v2/translate")
        #expect(free.httpMethod == "POST")
        #expect(free.value(forHTTPHeaderField: "Authorization") == "DeepL-Auth-Key \(Self.deepLFree)")
        let body = try jsonObject(free)
        #expect(body["text"] as? [String] == ["Hello."])
        #expect(body["target_lang"] as? String == "KO")
        #expect(body["source_lang"] as? String == "EN")
        let pro = try DeepLTranslationClient.makeRequest("Hello.", sourceLocale: "en-US", key: Self.deepLPro)
        #expect(pro.url?.absoluteString == "https://api.deepl.com/v2/translate")
        // A recognizer locale DeepL has no source code for is auto-detected, not sent as "MUL".
        let multilingual = try DeepLTranslationClient.makeRequest("Hello.", sourceLocale: "mul_IN", key: Self.deepLFree)
        #expect(try jsonObject(multilingual)["source_lang"] == nil)
    }

    @Test func deepLResponsesAndFailuresMapToKoreanErrorsWithoutTheKey() async throws {
        let ok = #"{"translations":[{"detected_source_language":"EN","text":"안녕하세요."}]}"#
        #expect(try DeepLTranslationClient.parse(data: Data(ok.utf8), status: 200) == "안녕하세요.")
        let cases: [(Int, TranslationServiceFailure.Kind)] = [(403, .rejectedKey), (456, .quota), (429, .rateLimited), (500, .http(500))]
        for (status, kind) in cases {
            #expect(throws: TranslationServiceFailure(vendor: "DeepL", kind: kind)) {
                try DeepLTranslationClient.parse(data: Data("{\"message\":\"\(Self.deepLFree)\"}".utf8), status: status)
            }
        }
        #expect(throws: TranslationServiceFailure(vendor: "DeepL", kind: .invalidResponse)) {
            try DeepLTranslationClient.parse(data: Data(#"{"translations":[]}"#.utf8), status: 200)
        }
        // Live path with a stub transport: success, timeout, and a redirect to another URL.
        var client = DeepLTranslationClient(transport: { reply($0, status: 200, ok) })
        #expect(try await client.translate("Hi.", sourceLocale: "en-US", authKey: Self.deepLFree) == "안녕하세요.")
        client.transport = { _ in throw URLError(.timedOut) }
        await #expect(throws: TranslationServiceFailure(vendor: "DeepL", kind: .timeout)) {
            try await client.translate("Hi.", sourceLocale: "en-US", authKey: Self.deepLFree)
        }
        client.transport = { _ in
            (Data(ok.utf8), HTTPURLResponse(url: URL(string: "https://example.com/")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await #expect(throws: TranslationServiceFailure(vendor: "DeepL", kind: .invalidResponse)) {
            try await client.translate("Hi.", sourceLocale: "en-US", authKey: Self.deepLFree)
        }
        await #expect(throws: TranslationServiceFailure(vendor: "DeepL", kind: .invalidKey)) {
            try await client.translate("Hi.", sourceLocale: "en-US", authKey: "short key")
        }
        for kind in [TranslationServiceFailure.Kind.rejectedKey, .quota, .network] {
            #expect(!(TranslationServiceFailure(vendor: "DeepL", kind: kind).errorDescription ?? "").contains(Self.deepLFree))
        }
    }

    @Test func papagoSendsClientIDAndSecretHeadersAndParsesTheMessageResult() async throws {
        let request = try PapagoTranslationClient.makeRequest("Hello.", sourceLocale: "en-US",
                                                              clientID: "abcd1234", clientSecret: "secret-0123456789abcdefghij")
        #expect(request.url?.absoluteString == "https://papago.apigw.ntruss.com/nmt/v1/translation")
        #expect(request.value(forHTTPHeaderField: "X-NCP-APIGW-API-KEY-ID") == "abcd1234")
        #expect(request.value(forHTTPHeaderField: "X-NCP-APIGW-API-KEY") == "secret-0123456789abcdefghij")
        let body = try jsonObject(request)
        #expect(body["source"] as? String == "en")
        #expect(body["target"] as? String == "ko")
        #expect(body["text"] as? String == "Hello.")
        #expect(PapagoTranslationClient.source(for: "zh-Hant-TW") == "zh-TW")
        #expect(PapagoTranslationClient.source(for: "zh_CN") == "zh-CN")
        #expect(PapagoTranslationClient.source(for: "pt-BR") == "auto")

        let ok = #"{"message":{"result":{"srcLangType":"en","tarLangType":"ko","translatedText":"안녕하세요."}}}"#
        let client = PapagoTranslationClient(transport: { reply($0, status: 200, ok) })
        #expect(try await client.translate("Hello.", sourceLocale: "en-US", clientID: "abcd1234",
                                           clientSecret: "secret-0123456789abcdefghij") == "안녕하세요.")
        #expect(throws: TranslationServiceFailure(vendor: "Papago", kind: .rejectedKey)) {
            try PapagoTranslationClient.parse(data: Data(), status: 401)
        }
        #expect(throws: TranslationServiceFailure(vendor: "Papago", kind: .quota)) {
            try PapagoTranslationClient.parse(data: Data(), status: 429)
        }
        await #expect(throws: TranslationServiceFailure(vendor: "Papago", kind: .invalidKey)) {
            try await client.translate("Hello.", sourceLocale: "en-US", clientID: "abcd1234", clientSecret: "")
        }
    }

    @Test func everyKeyFieldHasItsOfficialKeyPage() {
        let pages = CaptionTranslationProvider.allCases.compactMap(\.keyPage).map(\.url.absoluteString)
            + MeetingAIProvider.allCases.compactMap(\.keyPage).map(\.url.absoluteString)
        #expect(pages == [
            "https://console.cloud.google.com/apis/credentials",
            "https://www.deepl.com/your-account/keys",
            "https://console.ncloud.com/",
            "https://platform.openai.com/api-keys",
            "https://aistudio.google.com/apikey",
            "https://platform.claude.com/settings/keys"
        ])
        #expect(CaptionTranslationProvider.allCases.filter(\.isCloud).allSatisfy { $0.keyPage?.hint.isEmpty == false })
        #expect(CaptionTranslationProvider.apple.keyPage == nil && MeetingAIProvider.apple.keyPage == nil)
    }
}

/// Empty in-memory stores for every translation credential, so a test model never reads the
/// login Keychain. Pass `includingGoogle: false` when the test supplies its own Google store.
func emptyTranslationKeyStores(includingGoogle: Bool = false) -> [TranslationCredentialField: any MeetingAIKeyStoring] {
    var stores: [TranslationCredentialField: any MeetingAIKeyStoring] = [:]
    for field in TranslationCredentialField.allCases where includingGoogle || field != .googleKey {
        stores[field] = TranslationKeySpy()
    }
    return stores
}

final class TranslationKeySpy: MeetingAIKeyStoring, @unchecked Sendable {
    var stored: String?
    init(_ key: String? = nil) { stored = key }
    func loadAPIKey() -> String? { stored }
    func saveAPIKey(_ key: String) throws { stored = key }
    func removeAPIKey() throws { stored = nil }
}

@Suite(.serialized)
@MainActor
struct CloudTranslationModelTests {
    @Test func deepLNeedsConsentUsesGlossaryAndFallsBackWithoutLosingText() async throws {
        var calls: [(CaptionTranslationProvider, String, [String])] = []
        try await withModel(provider: .deepL, translate: { provider, text, _, keys in
            calls.append((provider, text, keys))
            if text == "QXZ0Q is big." { return "QXZ0Q가 큽니다." }
            if text == "QXZ0Q is small." { return "작다." }
            return "번역: " + text
        }) { model, _ in
            model.glossary = Glossary(entries: [GlossaryEntry(term: "heap", korean: "힙")])
            model.transcript.captions = [Caption(start: 0, end: 1, text: "Heap is big."),
                                         Caption(start: 2, end: 3, text: "Heap is small.")]
            await model.runCloudTranslation()
            #expect(calls.isEmpty)
            #expect(model.translationStatus.contains("DeepL"))
            model.cloudTranslationConsent = true
            let work = Task { await model.runCloudTranslation() }
            for await transcript in model.$transcript.values where transcript.captions.last?.koreanText != nil { break }
            work.cancel()
            await work.value
            #expect(model.transcript.captions.map(\.koreanText) == ["힙이 큽니다.", "번역: Heap is small."])
            #expect(calls.map(\.1) == ["QXZ0Q is big.", "QXZ0Q is small.", "Heap is small."])
            #expect(calls.allSatisfy { $0.0 == .deepL && $0.2 == [CloudTranslationClientTests.deepLFree] })
        }
    }

    @Test func revokedConsentDiscardsALatePapagoResult() async throws {
        let gate = PapagoGate()
        try await withModel(provider: .papago, translate: { _, _, _, keys in
            #expect(keys == ["abcd1234", "secret-0123456789abcdefghij"])
            return await gate.respond()
        }) { model, _ in
            model.transcript.captions = [Caption(start: 0, end: 1, text: "One."), Caption(start: 2, end: 3, text: "Two.")]
            model.cloudTranslationConsent = true
            let work = Task { await model.runCloudTranslation() }
            for await _ in gate.started { break }
            model.cloudTranslationConsent = false
            gate.release()
            await work.value
            #expect(gate.calls == 1)
            #expect(model.transcript.captions.allSatisfy { $0.koreanText == nil })
        }
    }

    @Test func consentIsPerProviderAndPerRecord() async throws {
        try await withModel(provider: .deepL, translate: { _, _, _, _ in "번역" }) { model, _ in
            model.cloudTranslationConsent = true
            model.translationProvider = .papago
            #expect(!model.cloudTranslationConsent)
            model.cloudTranslationConsent = true
            model.newSession()
            #expect(!model.cloudTranslationConsent)
        }
    }

    @Test func papagoNeedsBothCredentialsAndKeysStayInTheKeychainOnly() async throws {
        var calls = 0
        try await withModel(provider: .papago, stores: [.papagoClientID: TranslationKeySpy(), .papagoClientSecret: TranslationKeySpy()],
                            translate: { _, _, _, _ in calls += 1; return "번역" }) { model, stores in
            model.transcript.captions = [Caption(start: 0, end: 1, text: "One.")]
            model.cloudTranslationConsent = true
            await model.runCloudTranslation()
            #expect(calls == 0)
            #expect(!model.hasTranslationKeys(for: .papago))

            model.translationKeyDrafts[.papagoClientID] = "abcd1234"
            model.translationKeyDrafts[.papagoClientSecret] = "has space in secret value"
            model.saveTranslationKeys(for: .papago)
            #expect(model.errorMessage?.contains("Papago Client Secret") == true)
            #expect(stores[.papagoClientID]?.loadAPIKey() == nil)

            model.translationKeyDrafts[.papagoClientSecret] = "secret-0123456789abcdefghij"
            model.saveTranslationKeys(for: .papago)
            #expect(model.hasTranslationKeys(for: .papago))
            #expect(model.translationKeyDrafts.isEmpty)
            #expect(stores[.papagoClientSecret]?.loadAPIKey() == "secret-0123456789abcdefghij")
            let defaults = UserDefaults.standard.dictionaryRepresentation().values.map { "\($0)" }.joined()
            #expect(!defaults.contains("secret-0123456789abcdefghij"))

            model.removeTranslationKeys(for: .papago)
            #expect(!model.hasTranslationKeys(for: .papago))
            #expect(stores[.papagoClientID]?.loadAPIKey() == nil)
        }
    }

    private func withModel(provider: CaptionTranslationProvider,
                           stores: [TranslationCredentialField: TranslationKeySpy]? = nil,
                           translate: @escaping (CaptionTranslationProvider, String, String, [String]) async throws -> String,
                           body: (MeetingModel, [TranslationCredentialField: TranslationKeySpy]) async throws -> Void) async throws {
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
        let spies = stores ?? [
            .googleKey: TranslationKeySpy(),
            .deepLKey: TranslationKeySpy(CloudTranslationClientTests.deepLFree),
            .papagoClientID: TranslationKeySpy("abcd1234"),
            .papagoClientSecret: TranslationKeySpy("secret-0123456789abcdefghij")
        ]
        var all = spies
        for field in TranslationCredentialField.allCases where all[field] == nil { all[field] = TranslationKeySpy() }
        let model = MeetingModel(library: directory, googleKeyStore: all[.googleKey]!,
                                 translationKeyStores: all.mapValues { $0 as any MeetingAIKeyStoring },
                                 cloudTranslate: translate)
        model.localeID = "en-US"
        model.translationProvider = provider
        try await body(model, all)
        _ = await model.shutdown()
    }
}

@MainActor
private final class PapagoGate {
    let started: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private var pending: CheckedContinuation<String, Never>?
    private(set) var calls = 0
    init() { (started, signal) = AsyncStream<Void>.makeStream() }
    func respond() async -> String {
        calls += 1
        return await withCheckedContinuation {
            pending = $0
            signal.yield(())
            signal.finish()
        }
    }
    func release() { pending?.resume(returning: "늦은 결과"); pending = nil }
}

// MARK: - AI providers

private let aiStep = MeetingAIRequest(action: .summary, instructions: "Answer in Korean.", prompt: "<<captions>>",
                                      maxResponseTokens: 1_000, maxOutputCharacters: 2_000, timeout: 60,
                                      reasoningEffort: "minimal")

@Suite("Cloud AI responders")
struct CloudAIResponderTests {
    static let geminiKey = "AIzaSyTest0123456789abcdefghijklmnopq"
    static let claudeKey = "sk-ant-api03-test0123456789abcdefghij"

    @Test func geminiRequestFollowsGenerateContent() throws {
        let request = try GeminiResponder.makeRequest(for: aiStep, key: Self.geminiKey)
        #expect(request.url?.absoluteString
                == "https://generativelanguage.googleapis.com/v1beta/models/gemini-4-hydrogen:generateContent")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == Self.geminiKey)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(!(request.url?.absoluteString.contains(Self.geminiKey) ?? true))
        let body = try jsonObject(request)
        let system = try #require(body["systemInstruction"] as? [String: Any])
        #expect((system["parts"] as? [[String: String]])?.first?["text"] == "Answer in Korean.")
        let contents = try #require(body["contents"] as? [[String: Any]])
        #expect(contents.first?["role"] as? String == "user")
        #expect((contents.first?["parts"] as? [[String: String]])?.first?["text"] == "<<captions>>")
        let config = try #require(body["generationConfig"] as? [String: Any])
        #expect(config["maxOutputTokens"] as? Int == 1_000 + GeminiResponder.thinkingHeadroom)
        #expect((config["thinkingConfig"] as? [String: String])?["thinkingLevel"] == "low")
        #expect(config["temperature"] == nil)
    }

    @Test func geminiResponsesAndErrors() async throws {
        let answer = #"{"candidates":[{"content":{"parts":[{"text":"생각","thought":true},{"text":"요약입니다."}]},"finishReason":"STOP"}]}"#
        #expect(try GeminiResponder.parse(data: Data(answer.utf8), status: 200, key: Self.geminiKey) == "요약입니다.")
        #expect(throws: CloudAIHTTP.truncated) {
            try GeminiResponder.parse(data: Data(#"{"candidates":[{"content":{"parts":[]},"finishReason":"MAX_TOKENS"}]}"#.utf8),
                                      status: 200, key: Self.geminiKey)
        }
        #expect(throws: CloudAIHTTP.refused) {
            try GeminiResponder.parse(data: Data(#"{"promptFeedback":{"blockReason":"SAFETY"}}"#.utf8), status: 200, key: Self.geminiKey)
        }
        let echoed = #"{"error":{"code":400,"message":"API key not valid: \#(Self.geminiKey)","status":"INVALID_ARGUMENT"}}"#
        do {
            _ = try GeminiResponder.parse(data: Data(echoed.utf8), status: 400, key: Self.geminiKey)
            Issue.record("expected failure")
        } catch let error as MeetingAIError {
            let text = error.localizedDescription
            #expect(!text.contains(Self.geminiKey))
            #expect(text.contains("HTTP 400"))
        }
        let responder = GeminiResponder(apiKey: Self.geminiKey) { _ in throw URLError(.cannotFindHost) }
        await #expect(throws: MeetingAIError.network("generativelanguage.googleapis.com에 연결할 수 없습니다. 네트워크나 방화벽을 확인해 주세요.")) {
            try await responder.respond(to: aiStep)
        }
        let live = GeminiResponder(apiKey: Self.geminiKey) { reply($0, status: 200, answer) }
        #expect(try await live.respond(to: aiStep) == "요약입니다.")
    }

    @Test func claudeRequestFollowsTheMessagesAPI() throws {
        let request = try ClaudeResponder.makeRequest(for: aiStep, key: Self.claudeKey)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.claudeKey)")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        let body = try jsonObject(request)
        #expect(body["model"] as? String == "claude-haiku-5-5")
        #expect(body["max_tokens"] as? Int == 1_000)
        #expect(body["system"] as? String == "Answer in Korean.")
        #expect((body["messages"] as? [[String: String]]) == [["role": "user", "content": "<<captions>>"]])
        #expect((body["thinking"] as? [String: String])?["type"] == "disabled")
        #expect((body["output_config"] as? [String: String])?["effort"] == "low")
        #expect(body["temperature"] == nil)
    }

    @Test func claudeResponsesAndErrors() async throws {
        let answer = #"{"type":"message","content":[{"type":"text","text":"요약"},{"type":"text","text":"입니다."}],"stop_reason":"end_turn"}"#
        #expect(try ClaudeResponder.parse(data: Data(answer.utf8), status: 200, key: Self.claudeKey) == "요약입니다.")
        #expect(throws: CloudAIHTTP.refused) {
            try ClaudeResponder.parse(data: Data(#"{"content":[],"stop_reason":"refusal"}"#.utf8), status: 200, key: Self.claudeKey)
        }
        #expect(throws: CloudAIHTTP.truncated) {
            try ClaudeResponder.parse(data: Data(#"{"content":[],"stop_reason":"max_tokens"}"#.utf8), status: 200, key: Self.claudeKey)
        }
        #expect(throws: MeetingAIError.http(status: 401, message: "Claude API 키가 거부되었습니다. AI 설정에서 키를 다시 저장해 주세요.")) {
            try ClaudeResponder.parse(data: Data(), status: 401, key: Self.claudeKey)
        }
        let unscoped = #"{"type":"error","error":{"type":"invalid_request_error","message":"Requests with this key must include the anthropic-workspace-id header."}}"#
        #expect(throws: ClaudeResponder.workspaceRequired) {
            try ClaudeResponder.parse(data: Data(unscoped.utf8), status: 400, key: Self.claudeKey)
        }
        let echoed = #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key \#(Self.claudeKey)"}}"#
        do {
            _ = try ClaudeResponder.parse(data: Data(echoed.utf8), status: 401, key: Self.claudeKey)
        } catch {
            #expect(!error.localizedDescription.contains(Self.claudeKey))
        }
        let redirected = ClaudeResponder(apiKey: Self.claudeKey) { _ in
            (Data(answer.utf8), HTTPURLResponse(url: URL(string: "https://evil.example/")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await #expect(throws: MeetingAIError.network("요청이 다른 주소로 전환되어 중단했습니다. 네트워크 프록시를 확인해 주세요.")) {
            try await redirected.respond(to: aiStep)
        }
    }
}

@MainActor
@Suite("Cloud AI selection")
struct CloudAISelectionTests {
    @Test func geminiAndClaudeNeedTheirOwnKeyAndFreshConsent() async throws {
        let preferences = AIStubPreferences()
        let openAIKeys = AIStubKeyStore(key: "sk-test-0123456789abcdefghij")
        let geminiKeys = AIStubKeyStore()
        let claudeKeys = AIStubKeyStore(key: CloudAIResponderTests.claudeKey)
        let gemini = AIStubResponder { _ in AIStubReplies.correction }
        let claude = AIStubResponder { _ in AIStubReplies.correction }
        let openAI = AIStubResponder { _ in AIStubReplies.correction }
        var factoryKeys: [String] = []
        let ai = MeetingAI(preferences: preferences, keyStore: openAIKeys,
                           localResponder: AIStubResponder(), remoteFactory: { _ in openAI },
                           geminiKeyStore: geminiKeys, geminiFactory: { _ in gemini },
                           claudeKeyStore: claudeKeys, claudeFactory: { key in
                               MainActor.assumeIsolated { factoryKeys.append(key) }
                               return claude
                           },
                           availability: { .available })
        let transcript = Transcript(title: "T", locale: "en-US", source: "system")

        ai.provider = .openAI
        ai.cloudConsent = true
        ai.provider = .gemini
        #expect(!ai.cloudConsent)
        #expect(!ai.hasAPIKey)
        await ai.generateAndWait(action: .expressions, transcript: transcript, selectedExpression: "I need more two weeks.")
        #expect(ai.errorMessage == MeetingAIError.cloudConsentRequired.localizedDescription)
        ai.cloudConsent = true
        await ai.generateAndWait(action: .expressions, transcript: transcript, selectedExpression: "I need more two weeks.")
        #expect(ai.errorMessage == MeetingAIError.missingAPIKey.localizedDescription)
        ai.apiKeyDraft = CloudAIResponderTests.geminiKey
        ai.saveAPIKey()
        #expect(geminiKeys.loadAPIKey() == CloudAIResponderTests.geminiKey)
        #expect(openAIKeys.loadAPIKey() == "sk-test-0123456789abcdefghij")
        await ai.generateAndWait(action: .expressions, transcript: transcript, selectedExpression: "I need more two weeks.")
        #expect(gemini.requests.count == 1)
        #expect(ai.errorMessage == nil)

        ai.provider = .claude
        #expect(ai.hasAPIKey)
        #expect(!ai.cloudConsent)
        ai.cloudConsent = true
        await ai.generateAndWait(action: .expressions, transcript: transcript, selectedExpression: "I need more two weeks.")
        #expect(claude.requests.count == 1)
        #expect(factoryKeys == [CloudAIResponderTests.claudeKey])
        #expect(openAI.requests.isEmpty)
        #expect(preferences.provider == .claude)
    }
}
