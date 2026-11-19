import Foundation

public struct Caption: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var text: String
    public var koreanText: String?
    /// Optional so records from 1.0–1.4 decode unchanged and an unmarked caption writes no key,
    /// which keeps 1.5 files readable by older builds that ignore unknown keys.
    public var bookmarked: Bool?

    public var isBookmarked: Bool {
        get { bookmarked == true }
        set { bookmarked = newValue ? true : nil }
    }

    public init(start: Double, end: Double, text: String, id: UUID = UUID(), koreanText: String? = nil) {
        self.id = id
        self.start = max(0, start.isFinite ? start : 0)
        self.end = max(self.start + 0.001, end.isFinite ? end : self.start + 0.001)
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.koreanText = koreanText
    }
}

public struct Transcript: Codable, Sendable {
    public var version = 1
    public var title: String
    public var locale: String
    public var source: String
    public var created = Date()
    public var captions: [Caption] = []
    /// Course/subject (과목). Optional and omitted when unset, like `Caption.bookmarked`.
    public var subject: String?
    /// Recorded audio, one entry per recording session. Optional and omitted when there is no
    /// audio, so older builds (which ignore unknown keys) read the record unchanged.
    public var audio: [AudioSegment]?
    public init(title: String, locale: String, source: String) {
        self.title = title
        self.locale = locale
        self.source = source
    }

    public var koreanTranscript: Transcript {
        var translated = self
        translated.locale = "ko-KR"
        translated.captions = captions.compactMap { cue in
            guard let text = cue.koreanText, !text.isEmpty else { return nil }
            var korean = Caption(start: cue.start, end: cue.end, text: text, id: cue.id)
            korean.bookmarked = cue.bookmarked
            return korean
        }
        return translated
    }

    /// Only the captions the user marked as important, in time order.
    public var bookmarkedOnly: Transcript {
        var marked = self
        marked.captions = captions.filter(\.isBookmarked)
        return marked
    }

    /// A trimmed subject, or nil when it is blank; blank subjects belong to "미분류".
    public static func normalizedSubject(_ subject: String?) -> String? {
        let trimmed = subject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    public var plainText: String { captions.map(\.text).joined(separator: "\n") }
    public var srt: String {
        captions.enumerated().map { index, cue in
            "\(index + 1)\n\(Self.timestamp(cue.start)) --> \(Self.timestamp(cue.end))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    public static func timestamp(_ time: Double) -> String {
        let ms = Int((max(0, time.isFinite ? time : 0) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000,
                      ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    public static func parseSRT(_ text: String) throws -> [Caption] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        if normalized.isEmpty { return [] }
        let blocks = normalized.components(separatedBy: "\n\n")
        var cues: [Caption] = []
        for block in blocks where !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let lines = block.components(separatedBy: "\n")
            guard let i = lines.firstIndex(where: { $0.contains("-->") }), i + 1 < lines.count else {
                throw FormatError.invalidSRT
            }
            let pair = lines[i].components(separatedBy: "-->")
            guard pair.count == 2, let start = seconds(pair[0]), let end = seconds(pair[1]), end > start else {
                throw FormatError.invalidSRT
            }
            cues.append(Caption(start: start, end: end, text: lines[(i + 1)...].joined(separator: "\n")))
        }
        return cues.sorted { $0.start < $1.start }
    }

    private static func seconds(_ value: String) -> Double? {
        let fields = value.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".").components(separatedBy: ":")
        guard fields.count == 3, let h = Double(fields[0]), let m = Double(fields[1]),
              let s = Double(fields[2]), h >= 0, m >= 0, m < 60, s >= 0, s < 60 else { return nil }
        return h * 3600 + m * 60 + s
    }

    public enum FormatError: LocalizedError {
        case invalidSRT
        public var errorDescription: String? { "SRT 시간 또는 자막 형식을 확인해 주세요." }
    }
}

public enum TranscriptDisk {
    public static func save(_ transcript: Transcript, at url: URL, srt: Bool) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(transcript).write(to: url, options: .atomic)
        if srt {
            try transcript.srt.write(to: url.deletingPathExtension().appendingPathExtension("srt"), atomically: true, encoding: .utf8)
        }
    }
    public static func load(_ url: URL) throws -> Transcript {
        let result = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: url))
        guard result.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }
}
