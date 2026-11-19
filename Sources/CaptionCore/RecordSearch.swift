import Foundation

public struct RecordSearchHit: Equatable, Sendable, Identifiable {
    public enum Field: String, Sendable { case title, original, translation }
    /// nil for a title match: opening it restores the record without a caption to highlight.
    public let captionID: UUID?
    public let field: Field
    /// The snippet split around the first match so the UI can emphasize it.
    public let before: String
    public let match: String
    public let after: String
    public var id: String { "\(captionID?.uuidString ?? "title")|\(field.rawValue)" }
    public var snippet: String { before + match + after }
}

public struct RecordSearchResult: Equatable, Sendable, Identifiable {
    public let url: URL
    public let title: String
    public let subject: String?
    public let date: Date
    public let hits: [RecordSearchHit]
    /// Every matching field, including those beyond the displayed hits.
    public let matchCount: Int
    public var id: String { url.path }
}

public enum RecordSearch {
    public static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    public static func normalizedQuery(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Matches the title, then each caption's original and translated text in time order.
    public static func result(for query: String, in transcript: Transcript, url: URL,
                              maxHits: Int = 3) -> RecordSearchResult? {
        guard let query = normalizedQuery(query) else { return nil }
        var hits: [RecordSearchHit] = []
        var count = 0
        func consider(_ text: String, field: RecordSearchHit.Field, caption: UUID?) {
            guard let range = text.range(of: query, options: options) else { return }
            count += 1
            if hits.count < maxHits { hits.append(hit(text, range: range, field: field, caption: caption)) }
        }
        consider(transcript.title, field: .title, caption: nil)
        for cue in transcript.captions {
            consider(cue.text, field: .original, caption: cue.id)
            if let korean = cue.koreanText { consider(korean, field: .translation, caption: cue.id) }
        }
        guard count > 0 else { return nil }
        return RecordSearchResult(url: url, title: transcript.title, subject: Transcript.normalizedSubject(transcript.subject),
                                  date: transcript.created, hits: hits, matchCount: count)
    }

    public static func search(_ query: String, in records: [(url: URL, transcript: Transcript)],
                              maxHits: Int = 3) -> [RecordSearchResult] {
        records.compactMap { result(for: query, in: $0.transcript, url: $0.url, maxHits: maxHits) }
            .sorted { $0.date > $1.date }
    }

    private static func hit(_ text: String, range: Range<String.Index>, field: RecordSearchHit.Field,
                            caption: UUID?, radius: Int = 32) -> RecordSearchHit {
        let start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        func flat(_ part: Substring) -> String {
            part.replacingOccurrences(of: "\n", with: " ")
        }
        return RecordSearchHit(
            captionID: caption, field: field,
            before: (start > text.startIndex ? "…" : "") + flat(text[start..<range.lowerBound]),
            match: flat(text[range]),
            after: flat(text[range.upperBound..<end]) + (end < text.endIndex ? "…" : "")
        )
    }
}
