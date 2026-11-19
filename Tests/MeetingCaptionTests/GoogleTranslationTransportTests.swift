import Foundation
import Testing
@testable import MeetingCaption

struct GoogleTranslationTransportTests {
    @Test func redirectNeverForwardsTheAuthenticatedRequest() {
        let url = URL(string: "https://translation.googleapis.com/language/translate/v2")!
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: url)
        let response = HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: nil)!
        var forwarded = URLRequest(url: URL(string: "https://example.invalid/steal")!)
        forwarded.setValue("secret-api-key", forHTTPHeaderField: "X-goog-api-key")
        var called = false
        GoogleNoRedirect().urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: forwarded) {
            called = true
            #expect($0 == nil)
        }
        #expect(called)
    }

    @Test func timeoutDoesNotEchoTransportSecrets() async throws {
        let secret = "private-key-in-error-message"
        let client = GoogleTranslationClient { _ in
            throw URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: secret])
        }
        do {
            _ = try await client.translate("private meeting", sourceLocale: "en", apiKey: "google-test-key-no-network-12345")
            Issue.record("Expected a timeout.")
        } catch {
            #expect(!error.localizedDescription.contains(secret))
            #expect(error.localizedDescription.contains("초과"))
        }
    }
}
