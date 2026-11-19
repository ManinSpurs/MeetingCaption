import Foundation
import Testing
@testable import MeetingCaption

struct GoogleTranslationTests {
    private let key = "abcdefghijklmnopqrstuvwxyz"
    private let url = URL(string: "https://translation.googleapis.com/language/translate/v2")!

    @Test func requestAndResponse() async throws {
        let client = GoogleTranslationClient { request in
            #expect(request.url == url)
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "X-goog-api-key") == key)
            let body = try #require(request.httpBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
            #expect(json == ["q": "hello", "source": "en", "target": "ko", "format": "text"])
            return (Data(#"{"data":{"translations":[{"translatedText":"안녕"}]}}"#.utf8),
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(try await client.translate("hello", sourceLocale: "en-US", apiKey: key) == "안녕")
    }

    @Test(arguments: [403, 429, 302, 200])
    func errorsAreSanitized(status: Int) async throws {
        let client = GoogleTranslationClient { _ in
            (Data("secret response".utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        do {
            _ = try await client.translate("private text", sourceLocale: "en", apiKey: key)
            Issue.record("Expected failure")
        } catch {
            let message = error.localizedDescription
            #expect(!message.contains(key))
            #expect(!message.contains("private text"))
            if status == 403 { #expect(message.contains("billing")) }
            if status == 429 { #expect(message.contains("quota")) }
        }
    }

    @Test func cancellationPropagates() async throws {
        let client = GoogleTranslationClient { _ in throw CancellationError() }
        do {
            _ = try await client.translate("hello", sourceLocale: "en", apiKey: key)
            Issue.record("Expected cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
