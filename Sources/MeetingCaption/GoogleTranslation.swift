import Foundation
import Security

enum CaptionTranslationProvider: String, CaseIterable, Identifiable {
    case apple, google, deepL, papago
    var id: String { rawValue }
    var title: String {
        switch self {
        case .apple: "Apple"
        case .google: "Google Cloud Translation"
        case .deepL: "DeepL API"
        case .papago: "Papago (NAVER Cloud)"
        }
    }
}

struct GoogleTranslationKeyStore: MeetingAIKeyStoring {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.taeseoneo.MeetingCaption.google-translation",
         kSecAttrAccount as String: "translation-api-key"]
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
        var attributes = query
        attributes[kSecValueData as String] = Data(key.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(key.utf8)] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw MeetingAIKeychainError.saveFailed(update) }
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

final class GoogleNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct GoogleTranslationClient {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)
    private let transport: Transport

    init(transport: @escaping Transport = { request in
        let session = URLSession(configuration: .ephemeral, delegate: GoogleNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await session.data(for: request)
    }) {
        self.transport = transport
    }

    enum Failure: LocalizedError {
        case invalidKey, invalidResponse, forbidden, quota, http(Int), network, timeout
        var errorDescription: String? {
            switch self {
            case .invalidKey: "Google API 키 형식을 확인해 주세요."
            case .invalidResponse: "Google 번역 응답을 읽지 못했습니다."
            case .forbidden: "Google 번역 접근이 거절됐습니다. API 활성화·키 제한·결제(billing) 설정을 확인해 주세요."
            case .quota: "Google 번역 할당량(quota)을 초과했습니다. 사용량과 한도를 확인해 주세요."
            case .http(let status): "Google 번역 요청 실패(HTTP \(status))."
            case .network: "Google 번역 서버에 연결하지 못했습니다. 네트워크를 확인해 주세요."
            case .timeout: "Google 번역 응답 시간이 초과됐습니다."
            }
        }
    }

    func translate(_ text: String, sourceLocale: String, apiKey: String) async throws -> String {
        guard let key = MeetingAIKeyFormat.sanitized(apiKey) else { throw Failure.invalidKey }
        var request = URLRequest(url: URL(string: "https://translation.googleapis.com/language/translate/v2")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(key, forHTTPHeaderField: "X-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let source = sourceLocale.replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map(String.init) ?? ""
        var body = ["q": text, "target": "ko", "format": "text"]
        if !source.isEmpty { body["source"] = source }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw Failure.timeout
        } catch {
            throw Failure.network
        }
        guard let http = response as? HTTPURLResponse, http.url == request.url else { throw Failure.invalidResponse }
        switch http.statusCode {
        case 200...299: break
        case 403: throw Failure.forbidden
        case 429: throw Failure.quota
        default: throw Failure.http(http.statusCode)
        }
        struct Reply: Decodable {
            struct Payload: Decodable {
                struct Translation: Decodable { let translatedText: String }
                let translations: [Translation]
            }
            let data: Payload
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data),
              let translation = reply.data.translations.first,
              !translation.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.invalidResponse }
        return translation.translatedText
    }
}
