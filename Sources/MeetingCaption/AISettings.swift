import Foundation
import Security

/// Key storage is abstracted so tests never touch the host keychain and so the rest of the app
/// can only ever ask "is a key present" without handling the secret itself.
protocol MeetingAIKeyStoring {
    func loadAPIKey() -> String?
    func saveAPIKey(_ key: String) throws
    func removeAPIKey() throws
}

enum MeetingAIKeychainError: LocalizedError {
    case saveFailed(OSStatus)
    case deleteFailed(OSStatus)
    var errorDescription: String? {
        switch self {
        case .saveFailed(let status): "API 키를 키체인에 저장하지 못했습니다(\(status)). 키체인 접근 권한을 확인해 주세요."
        case .deleteFailed(let status): "키체인에서 API 키를 삭제하지 못했습니다(\(status))."
        }
    }
}

/// Only the generic-password item holds the secret; the rest of the AI settings stay in
/// UserDefaults because they are not sensitive.
struct KeychainMeetingAIKeyStore: MeetingAIKeyStoring {
    let service = "local.taeseoneo.MeetingCaption.openai"
    let account = "chat-completions-key"

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func loadAPIKey() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func saveAPIKey(_ key: String) throws {
        SecItemDelete(baseQuery as CFDictionary)
        var attributes = baseQuery
        attributes[kSecValueData as String] = Data(key.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw MeetingAIKeychainError.saveFailed(status) }
    }

    func removeAPIKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MeetingAIKeychainError.deleteFailed(status)
        }
    }
}

enum MeetingAIKeyFormat {
    /// Keys are single-token ASCII secrets; anything with whitespace or line breaks is rejected
    /// before it can reach a request header or an error message.
    static func sanitized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20, trimmed.count <= 200,
              trimmed.allSatisfy({ $0.isASCII && !$0.isWhitespace && !$0.isNewline }) else { return nil }
        return trimmed
    }
}
