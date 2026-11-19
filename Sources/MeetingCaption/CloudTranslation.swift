import Foundation
import Security

// MARK: - Provider vocabulary

extension CaptionTranslationProvider {
    /// Every provider except Apple sends caption text off the Mac and needs explicit consent.
    var isCloud: Bool { self != .apple }

    /// Short name for status lines and consent wording.
    var vendor: String {
        switch self {
        case .apple: "Apple"
        case .google: "Google"
        case .deepL: "DeepL"
        case .papago: "Papago"
        }
    }

    var credentialFields: [TranslationCredentialField] {
        switch self {
        case .apple: []
        case .google: [.googleKey]
        case .deepL: [.deepLKey]
        case .papago: [.papagoClientID, .papagoClientSecret]
        }
    }

    /// The provider's official page for creating or copying its key.
    var keyPage: ProviderKeyPage? {
        switch self {
        case .apple: nil
        case .google: ProviderKeyPage(
            url: URL(string: "https://console.cloud.google.com/apis/credentials")!,
            hint: "Cloud Translation API와 결제를 켠 프로젝트에서 ‘사용자 인증 정보 만들기 → API 키’로 만든 키를 복사하세요.")
        case .deepL: ProviderKeyPage(
            url: URL(string: "https://www.deepl.com/your-account/keys")!,
            hint: "DeepL API 계정의 ‘API 키’ 탭에서 키를 복사하세요. 무료(Free) 플랜 키는 끝이 :fx입니다.")
        case .papago: ProviderKeyPage(
            url: URL(string: "https://console.ncloud.com/")!,
            hint: "NAVER Cloud 콘솔 → AI Services → Papago Translation → APIs에서 Application을 등록(Text Translation 선택)하고 인증 정보의 Client ID와 Client Secret을 복사하세요.")
        }
    }

    var costNote: String {
        switch self {
        case .apple: "이 Mac에서 번역하며 비용이 들지 않습니다."
        case .google: "번역한 문자 수에 따라 Google Cloud 계정에 요금이 청구됩니다."
        case .deepL: "DeepL API Free는 월 무료 한도까지, Pro는 문자 수에 따라 DeepL 계정에 요금이 청구됩니다. Free 플랜에서는 보낸 텍스트가 DeepL 서비스 개선(학습)에 쓰일 수 있으니 민감한 내용은 보내지 마세요."
        case .papago: "번역한 문자 수에 따라 NAVER Cloud 계정에 요금이 청구됩니다."
        }
    }
}

struct ProviderKeyPage: Equatable {
    var url: URL
    /// One short line saying what to copy from the page.
    var hint: String
}

/// One secret a translation provider needs. Each is its own Keychain item; nothing about a
/// credential is ever written to UserDefaults, logs or files.
enum TranslationCredentialField: String, CaseIterable, Hashable, Sendable {
    case googleKey, deepLKey, papagoClientID, papagoClientSecret

    var label: String {
        switch self {
        case .googleKey: "Google Translation API 키"
        case .deepLKey: "DeepL API 인증 키"
        case .papagoClientID: "Papago Client ID"
        case .papagoClientSecret: "Papago Client Secret"
        }
    }

    /// Client IDs are short identifiers; real secrets are long.
    private var minimumLength: Int { self == .papagoClientID ? 4 : 20 }

    /// Single-token ASCII only, so a value can never break a header or reach a message.
    func sanitized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumLength, trimmed.count <= 200,
              trimmed.allSatisfy({ $0.isASCII && !$0.isWhitespace && !$0.isNewline }) else { return nil }
        return trimmed
    }

    /// Google keeps the item it has used since 1.3, so a saved key survives the update.
    var defaultStore: any MeetingAIKeyStoring {
        switch self {
        case .googleKey: GoogleTranslationKeyStore()
        case .deepLKey: KeychainSecretStore(service: "local.taeseoneo.MeetingCaption.deepl-translation", account: "auth-key")
        case .papagoClientID: KeychainSecretStore(service: "local.taeseoneo.MeetingCaption.papago-translation", account: "client-id")
        case .papagoClientSecret: KeychainSecretStore(service: "local.taeseoneo.MeetingCaption.papago-translation", account: "client-secret")
        }
    }
}

/// A generic-password Keychain item holding one secret.
struct KeychainSecretStore: MeetingAIKeyStoring {
    let service: String
    let account: String

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func loadAPIKey() -> String? {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func saveAPIKey(_ key: String) throws {
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(key.utf8)] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw MeetingAIKeychainError.saveFailed(update) }
        var attributes = query
        attributes[kSecValueData as String] = Data(key.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw MeetingAIKeychainError.saveFailed(status) }
    }

    func removeAPIKey() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MeetingAIKeychainError.deleteFailed(status)
        }
    }
}

// MARK: - Dispatch

enum CloudTranslators {
    /// `credentials` are the provider's `credentialFields` values, in order.
    static func translate(provider: CaptionTranslationProvider, text: String, sourceLocale: String,
                          credentials: [String]) async throws -> String {
        switch provider {
        case .apple:
            throw TranslationServiceFailure(vendor: "Apple", kind: .invalidResponse)
        case .google:
            return try await GoogleTranslationClient().translate(text, sourceLocale: sourceLocale, apiKey: credentials.first ?? "")
        case .deepL:
            return try await DeepLTranslationClient().translate(text, sourceLocale: sourceLocale, authKey: credentials.first ?? "")
        case .papago:
            return try await PapagoTranslationClient().translate(text, sourceLocale: sourceLocale,
                                                                 clientID: credentials.first ?? "",
                                                                 clientSecret: credentials.dropFirst().first ?? "")
        }
    }

    /// "en-US" → "en".
    static func languageCode(_ locale: String) -> String {
        locale.replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map { $0.lowercased() } ?? ""
    }
}

/// Korean, fixed-wording failures: server text is never shown, so a key cannot leak through it.
struct TranslationServiceFailure: LocalizedError, Equatable {
    enum Kind: Equatable { case invalidKey, invalidResponse, rejectedKey, forbidden, quota, rateLimited, http(Int), network, timeout }
    var vendor: String
    var kind: Kind

    var errorDescription: String? {
        switch kind {
        case .invalidKey: "\(vendor) 인증 정보 형식을 확인해 주세요."
        case .invalidResponse: "\(vendor) 번역 응답을 읽지 못했습니다."
        case .rejectedKey: "\(vendor)에서 인증 정보를 거절했습니다. 키를 다시 확인해 저장해 주세요."
        case .forbidden: "\(vendor) 번역 접근이 거절됐습니다. 계정의 API 사용 설정과 키 종류를 확인해 주세요."
        case .quota: "\(vendor) 번역 사용 한도를 초과했습니다. 계정의 사용량과 요금제를 확인해 주세요."
        case .rateLimited: "\(vendor) 번역 요청이 너무 많습니다. 잠시 후 다시 시도해 주세요."
        case .http(let status): "\(vendor) 번역 요청 실패(HTTP \(status))."
        case .network: "\(vendor) 번역 서버에 연결하지 못했습니다. 네트워크를 확인해 주세요."
        case .timeout: "\(vendor) 번역 응답 시간이 초과됐습니다."
        }
    }
}

enum TranslationHTTP {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    /// Ephemeral session that never follows a redirect, so the credential headers cannot be
    /// carried to another host.
    static let live: Transport = { request in
        let session = URLSession(configuration: .ephemeral, delegate: GoogleNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await session.data(for: request)
    }

    /// Sends and returns the body with its status; only a response for the request's own URL counts.
    static func send(_ request: URLRequest, vendor: String, transport: Transport) async throws -> (Data, Int) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw TranslationServiceFailure(vendor: vendor, kind: .timeout)
        } catch {
            throw TranslationServiceFailure(vendor: vendor, kind: .network)
        }
        guard let http = response as? HTTPURLResponse, http.url == request.url else {
            throw TranslationServiceFailure(vendor: vendor, kind: .invalidResponse)
        }
        return (data, http.statusCode)
    }

    static func nonEmpty(_ text: String?, vendor: String) throws -> String {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationServiceFailure(vendor: vendor, kind: .invalidResponse)
        }
        return text
    }
}

// MARK: - DeepL

/// DeepL API v2 `/translate` (developers.deepl.com). Free-plan keys end in ":fx" and must use
/// the api-free host; every other key uses the Pro host.
struct DeepLTranslationClient {
    static let freeEndpoint = URL(string: "https://api-free.deepl.com/v2/translate")!
    static let proEndpoint = URL(string: "https://api.deepl.com/v2/translate")!
    /// Source languages DeepL accepts as `source_lang`; anything else (e.g. the recognizer's
    /// multilingual "mul") is left out so DeepL detects the language instead of rejecting it.
    static let sources: Set<String> = [
        "AR", "BG", "CS", "DA", "DE", "EL", "EN", "ES", "ET", "FI", "FR", "HU", "ID", "IT", "JA", "KO",
        "LT", "LV", "NB", "NL", "PL", "PT", "RO", "RU", "SK", "SL", "SV", "TR", "UK", "ZH"
    ]
    var transport: TranslationHTTP.Transport = TranslationHTTP.live

    static func endpoint(for key: String) -> URL { key.hasSuffix(":fx") ? freeEndpoint : proEndpoint }

    static func makeRequest(_ text: String, sourceLocale: String, key: String) throws -> URLRequest {
        var request = URLRequest(url: endpoint(for: key))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("DeepL-Auth-Key \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["text": [text], "target_lang": "KO"]
        let source = CloudTranslators.languageCode(sourceLocale).uppercased()
        if sources.contains(source) { body["source_lang"] = source }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func parse(data: Data, status: Int) throws -> String {
        let vendor = "DeepL"
        switch status {
        case 200...299: break
        case 401, 403: throw TranslationServiceFailure(vendor: vendor, kind: .rejectedKey)
        case 429: throw TranslationServiceFailure(vendor: vendor, kind: .rateLimited)
        case 456: throw TranslationServiceFailure(vendor: vendor, kind: .quota)
        default: throw TranslationServiceFailure(vendor: vendor, kind: .http(status))
        }
        struct Reply: Decodable {
            struct Translation: Decodable { let text: String }
            let translations: [Translation]
        }
        let reply = try? JSONDecoder().decode(Reply.self, from: data)
        return try TranslationHTTP.nonEmpty(reply?.translations.first?.text, vendor: vendor)
    }

    func translate(_ text: String, sourceLocale: String, authKey: String) async throws -> String {
        guard let key = TranslationCredentialField.deepLKey.sanitized(authKey) else {
            throw TranslationServiceFailure(vendor: "DeepL", kind: .invalidKey)
        }
        let request = try Self.makeRequest(text, sourceLocale: sourceLocale, key: key)
        let (data, status) = try await TranslationHTTP.send(request, vendor: "DeepL", transport: transport)
        return try Self.parse(data: data, status: status)
    }
}

// MARK: - Papago

/// NAVER Cloud Papago Translation `/nmt/v1/translation` (api.ncloud-docs.com), authenticated
/// with the application's Client ID and Client Secret headers.
struct PapagoTranslationClient {
    static let endpoint = URL(string: "https://papago.apigw.ntruss.com/nmt/v1/translation")!
    /// Source languages the text API translates into Korean; others are auto-detected.
    static let sources: Set<String> = ["en", "ja", "zh-CN", "zh-TW", "vi", "th", "id", "fr", "es", "ru", "de", "it"]
    var transport: TranslationHTTP.Transport = TranslationHTTP.live

    static func source(for locale: String) -> String {
        let normalized = locale.replacingOccurrences(of: "_", with: "-")
        if sources.contains(normalized) { return normalized }
        if normalized.lowercased().hasPrefix("zh") {
            return normalized.contains("Hant") || normalized.hasSuffix("TW") || normalized.hasSuffix("HK") ? "zh-TW" : "zh-CN"
        }
        let code = CloudTranslators.languageCode(locale)
        return sources.contains(code) ? code : "auto"
    }

    static func makeRequest(_ text: String, sourceLocale: String, clientID: String, clientSecret: String) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(clientID, forHTTPHeaderField: "X-NCP-APIGW-API-KEY-ID")
        request.setValue(clientSecret, forHTTPHeaderField: "X-NCP-APIGW-API-KEY")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "source": source(for: sourceLocale), "target": "ko", "text": text
        ])
        return request
    }

    static func parse(data: Data, status: Int) throws -> String {
        let vendor = "Papago"
        switch status {
        case 200...299: break
        case 401: throw TranslationServiceFailure(vendor: vendor, kind: .rejectedKey)
        case 403: throw TranslationServiceFailure(vendor: vendor, kind: .forbidden)
        // NAVER Cloud answers 429 both for an exhausted quota and for an application that
        // has not selected the Papago Translation API.
        case 429: throw TranslationServiceFailure(vendor: vendor, kind: .quota)
        default: throw TranslationServiceFailure(vendor: vendor, kind: .http(status))
        }
        struct Reply: Decodable {
            struct Message: Decodable {
                struct Result: Decodable { let translatedText: String }
                let result: Result
            }
            let message: Message
        }
        let reply = try? JSONDecoder().decode(Reply.self, from: data)
        return try TranslationHTTP.nonEmpty(reply?.message.result.translatedText, vendor: vendor)
    }

    func translate(_ text: String, sourceLocale: String, clientID: String, clientSecret: String) async throws -> String {
        guard let id = TranslationCredentialField.papagoClientID.sanitized(clientID),
              let secret = TranslationCredentialField.papagoClientSecret.sanitized(clientSecret) else {
            throw TranslationServiceFailure(vendor: "Papago", kind: .invalidKey)
        }
        let request = try Self.makeRequest(text, sourceLocale: sourceLocale, clientID: id, clientSecret: secret)
        let (data, status) = try await TranslationHTTP.send(request, vendor: "Papago", transport: transport)
        return try Self.parse(data: data, status: status)
    }
}
