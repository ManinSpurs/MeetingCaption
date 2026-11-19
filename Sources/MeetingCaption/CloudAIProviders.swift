import Foundation

extension MeetingAIProvider {
    var isCloud: Bool { self != .apple }

    var vendor: String {
        switch self {
        case .apple: "Apple"
        case .openAI: "OpenAI"
        case .gemini: "Gemini"
        case .claude: "Claude"
        }
    }

    /// The provider's official page for creating an API key.
    var keyPage: ProviderKeyPage? {
        switch self {
        case .apple: nil
        case .openAI: ProviderKeyPage(
            url: URL(string: "https://platform.openai.com/api-keys")!,
            hint: "‘Create new secret key’로 만든 sk-로 시작하는 키를 복사하세요. 키는 만들 때 한 번만 보입니다.")
        case .gemini: ProviderKeyPage(
            url: URL(string: "https://aistudio.google.com/apikey")!,
            hint: "Google AI Studio의 ‘API 키 만들기(Create API key)’로 만든 키를 복사하세요.")
        case .claude: ProviderKeyPage(
            url: URL(string: "https://platform.claude.com/settings/keys")!,
            hint: "Claude Console의 ‘Create Key’에서 Workspace를 하나 지정해 만든 sk-ant-로 시작하는 키를 복사하세요. 키는 만들 때 한 번만 보입니다.")
        }
    }

    var costNote: String {
        switch self {
        case .apple: "이 Mac에서 처리하며 비용이 들지 않습니다."
        case .openAI: "ChatGPT Plus·Pro 구독과는 별개입니다. OpenAI API 키는 사용한 만큼 API 요금이 청구되며, 키는 이 Mac의 키체인에만 저장됩니다."
        case .gemini: "Gemini 앱·Google One 구독과는 별개입니다. Gemini API는 무료 등급 한도 안에서는 무료이며, 결제를 켠 프로젝트는 사용한 만큼 요금이 청구됩니다. 무료 등급에서는 보낸 내용과 응답이 Google 제품 개선에 쓰이고 사람이 검토할 수 있으니 민감한 내용은 보내지 마세요. 키는 이 Mac의 키체인에만 저장됩니다."
        case .claude: "Claude.ai 구독과는 별개입니다. Claude API 키는 사용한 만큼 API 요금이 청구되며, 키는 이 Mac의 키체인에만 저장됩니다."
        }
    }

    var defaultKeyStore: MeetingAIKeyStoring {
        switch self {
        case .apple, .openAI: KeychainMeetingAIKeyStore()
        case .gemini: KeychainSecretStore(service: "local.taeseoneo.MeetingCaption.gemini", account: "api-key")
        case .claude: KeychainSecretStore(service: "local.taeseoneo.MeetingCaption.claude", account: "api-key")
        }
    }
}

/// Shared request plumbing for the Gemini and Claude responders: fixed endpoints, no
/// redirects, sanitized Korean errors that never carry the key.
enum CloudAIHTTP {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    static let live: Transport = { try await OpenAIChatCompletionsResponder.defaultSession.data(for: $0) }

    static func send(_ request: URLRequest, host: String, key: String, transport: Transport) async throws -> (Data, Int) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch let error as URLError {
            if error.code == .cancelled { throw MeetingAIError.cancelled }
            throw MeetingAIError.network(describe(error, host: host))
        } catch {
            if error is CancellationError { throw MeetingAIError.cancelled }
            throw MeetingAIError.network(sanitize(error.localizedDescription, key: key))
        }
        guard let http = response as? HTTPURLResponse, !(300...399).contains(http.statusCode),
              http.url?.absoluteString == request.url?.absoluteString else {
            throw MeetingAIError.network("요청이 다른 주소로 전환되어 중단했습니다. 네트워크 프록시를 확인해 주세요.")
        }
        return (data, http.statusCode)
    }

    static func failure(status: Int, detail: String?, vendor: String, key: String) -> MeetingAIError {
        let sanitized = sanitize(detail ?? "", key: key)
        return .http(status: status, message: sanitized.isEmpty ? hint(for: status, vendor: vendor) : sanitized)
    }

    static func hint(for status: Int, vendor: String) -> String {
        switch status {
        case 400: "\(vendor)가 요청을 거부했습니다. 키 종류와 계정 설정을 확인해 주세요."
        case 401: "\(vendor) API 키가 거부되었습니다. AI 설정에서 키를 다시 저장해 주세요."
        case 403: "이 \(vendor) API 키로는 모델을 사용할 수 없습니다. 계정 권한·결제 설정을 확인해 주세요."
        case 404: "요청한 \(vendor) 모델을 사용할 수 없습니다. 앱 업데이트가 필요할 수 있습니다."
        case 429: "\(vendor) 요청 한도에 걸렸습니다. 잠시 후 다시 시도해 주세요."
        case 500...599: "\(vendor) 서버 오류입니다. 잠시 후 다시 시도해 주세요."
        default: "\(vendor) 요청이 거부되었습니다. 설정과 네트워크를 확인해 주세요."
        }
    }

    static func describe(_ error: URLError, host: String) -> String {
        switch error.code {
        case .notConnectedToInternet: "인터넷 연결이 없습니다."
        case .cannotFindHost, .cannotConnectToHost: "\(host)에 연결할 수 없습니다. 네트워크나 방화벽을 확인해 주세요."
        case .timedOut: "연결 시간이 초과되었습니다."
        case .secureConnectionFailed, .serverCertificateUntrusted: "보안 연결을 맺지 못했습니다. 네트워크 프록시를 확인해 주세요."
        case .networkConnectionLost: "연결이 끊겼습니다."
        default: "네트워크 오류(\(error.code.rawValue))."
        }
    }

    /// Server text is untrusted: the exact key is removed first, then anything key-like.
    static func sanitize(_ text: String, key: String) -> String {
        let withoutKey = key.isEmpty ? text : text.replacingOccurrences(of: key, with: "[redacted]")
        return OpenAIChatCompletionsResponder.sanitize(withoutKey)
    }

    static let refused = MeetingAIError.http(status: 0, message: "모델이 이 요청을 거부했습니다. 표현을 바꿔 다시 시도해 주세요.")
    static let truncated = MeetingAIError.http(status: 0, message: "출력 한도에 걸려 빈 응답이 왔습니다. 다시 시도해 주세요.")
}

// MARK: - Gemini

/// Gemini API `models/{model}:generateContent` (ai.google.dev), key in `x-goog-api-key`.
struct GeminiResponder: MeetingAITextResponding {
    static let model = "gemini-4-hydrogen"
    static let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
    /// Thinking counts toward the output limit; the lowest Gemini 4 level plus headroom keeps
    /// short answers from being starved.
    static let thinkingLevel = "low"
    static let thinkingHeadroom = 2_048

    let apiKey: String
    var transport: CloudAIHTTP.Transport = CloudAIHTTP.live

    struct Body: Encodable, Equatable {
        struct Part: Encodable, Equatable { var text: String }
        struct Content: Encodable, Equatable { var role: String?; var parts: [Part] }
        struct ThinkingConfig: Encodable, Equatable { var thinkingLevel: String }
        struct GenerationConfig: Encodable, Equatable { var maxOutputTokens: Int; var thinkingConfig: ThinkingConfig }
        var systemInstruction: Content
        var contents: [Content]
        var generationConfig: GenerationConfig
    }

    struct Reply: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable { var text: String?; var thought: Bool? }
                var parts: [Part]?
            }
            var content: Content?
            var finishReason: String?
        }
        struct Feedback: Decodable { var blockReason: String? }
        struct Failure: Decodable { var message: String? }
        var candidates: [Candidate]?
        var promptFeedback: Feedback?
        var error: Failure?
    }

    static func makeRequest(for request: MeetingAIRequest, key: String) throws -> URLRequest {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.timeoutInterval = request.timeout
        urlRequest.httpBody = try JSONEncoder().encode(Body(
            systemInstruction: .init(role: nil, parts: [.init(text: request.instructions)]),
            contents: [.init(role: "user", parts: [.init(text: request.prompt)])],
            generationConfig: .init(maxOutputTokens: request.maxResponseTokens + thinkingHeadroom,
                                    thinkingConfig: .init(thinkingLevel: thinkingLevel))))
        return urlRequest
    }

    static func parse(data: Data, status: Int, key: String) throws -> String {
        let reply = try? JSONDecoder().decode(Reply.self, from: data)
        guard status == 200 else {
            throw CloudAIHTTP.failure(status: status, detail: reply?.error?.message, vendor: "Gemini", key: key)
        }
        if reply?.promptFeedback?.blockReason != nil { throw CloudAIHTTP.refused }
        guard let candidate = reply?.candidates?.first else { throw MeetingAIError.emptyResponse }
        let text = (candidate.content?.parts ?? []).filter { $0.thought != true }.compactMap(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            switch candidate.finishReason {
            case "MAX_TOKENS": throw CloudAIHTTP.truncated
            case "SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "RECITATION": throw CloudAIHTTP.refused
            default: throw MeetingAIError.emptyResponse
            }
        }
        return text
    }

    func respond(to request: MeetingAIRequest) async throws -> String {
        guard let key = MeetingAIKeyFormat.sanitized(apiKey) else { throw MeetingAIError.missingAPIKey }
        let urlRequest = try Self.makeRequest(for: request, key: key)
        let (data, status) = try await CloudAIHTTP.send(urlRequest, host: "generativelanguage.googleapis.com",
                                                         key: key, transport: transport)
        return try Self.parse(data: data, status: status, key: key)
    }
}

// MARK: - Claude

/// Claude Messages API (platform.claude.com/docs), key as a bearer token.
struct ClaudeResponder: MeetingAITextResponding {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let model = "claude-haiku-5-5"
    static let apiVersion = "2026-10-21"
    static let workspaceRequired = MeetingAIError.http(
        status: 400,
        message: "이 Claude API 키에는 Workspace가 지정되어 있지 않아 요청이 거부되었습니다. Claude Console에서 Workspace를 지정해 키를 새로 만들어 저장해 주세요.")

    let apiKey: String
    var transport: CloudAIHTTP.Transport = CloudAIHTTP.live

    /// Short answers with no up-front thinking: thinking would count toward `max_tokens`.
    /// `temperature` is absent because API version 2026-10-21 rejects it.
    struct Body: Encodable, Equatable {
        struct Message: Encodable, Equatable { var role: String; var content: String }
        struct Thinking: Encodable, Equatable { var type: String }
        struct OutputConfig: Encodable, Equatable { var effort: String }
        var model: String
        var max_tokens: Int
        var system: String
        var messages: [Message]
        var thinking: Thinking
        var output_config: OutputConfig
    }

    struct Reply: Decodable {
        struct Block: Decodable { var type: String; var text: String? }
        struct Failure: Decodable { var message: String? }
        var content: [Block]?
        var stop_reason: String?
        var error: Failure?
    }

    static func makeRequest(for request: MeetingAIRequest, key: String) throws -> URLRequest {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.timeoutInterval = request.timeout
        urlRequest.httpBody = try JSONEncoder().encode(Body(
            model: model,
            max_tokens: request.maxResponseTokens,
            system: request.instructions,
            messages: [.init(role: "user", content: request.prompt)],
            thinking: .init(type: "disabled"),
            output_config: .init(effort: "low")))
        return urlRequest
    }

    static func parse(data: Data, status: Int, key: String) throws -> String {
        let reply = try? JSONDecoder().decode(Reply.self, from: data)
        guard status == 200 else {
            // A key created without a workspace is rejected on every request; the server text
            // names a header, which the sanitizer would mask into an unreadable message.
            if status == 400, reply?.error?.message?.lowercased().contains("workspace") == true {
                throw workspaceRequired
            }
            throw CloudAIHTTP.failure(status: status, detail: reply?.error?.message, vendor: "Claude", key: key)
        }
        if reply?.stop_reason == "refusal" { throw CloudAIHTTP.refused }
        let text = (reply?.content ?? []).filter { $0.type == "text" }.compactMap(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw reply?.stop_reason == "max_tokens" ? CloudAIHTTP.truncated : MeetingAIError.emptyResponse
        }
        return text
    }

    func respond(to request: MeetingAIRequest) async throws -> String {
        guard let key = MeetingAIKeyFormat.sanitized(apiKey) else { throw MeetingAIError.missingAPIKey }
        let urlRequest = try Self.makeRequest(for: request, key: key)
        let (data, status) = try await CloudAIHTTP.send(urlRequest, host: "api.anthropic.com", key: key, transport: transport)
        return try Self.parse(data: data, status: status, key: key)
    }
}
