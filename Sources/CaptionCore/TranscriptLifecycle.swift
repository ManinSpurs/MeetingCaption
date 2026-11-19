import Foundation

extension Transcript {
    /// Merges recognizer results that may arrive out of order or repeat the same cue.
    /// A cue's identity and finished Korean translation survive a re-delivery of the
    /// same text; changed text drops the stale translation instead of showing a mismatch.
    public mutating func mergeFinal(_ cues: [Caption]) {
        for cue in cues where !cue.text.isEmpty {
            if let index = captions.firstIndex(where: { abs($0.start - cue.start) < 0.005 }) {
                let existing = captions[index]
                var merged = cue
                merged.id = existing.id
                if merged.koreanText == nil, existing.text == merged.text {
                    merged.koreanText = existing.koreanText
                }
                // A mark is the user's choice, so it survives revised or grown text.
                if merged.bookmarked == nil { merged.bookmarked = existing.bookmarked }
                captions[index] = merged
            } else {
                captions.append(cue)
            }
        }
        captions.sort { $0.start < $1.start }
    }

    /// Live recognition continues after the last confirmed cue, never overlapping it.
    public var nextStartTime: Double {
        captions.map(\.end).max() ?? 0
    }

    public var hasTranslations: Bool {
        captions.contains { !($0.koreanText ?? "").isEmpty }
    }

    /// Translation must follow speech order: the oldest untranslated cue comes first, so a
    /// complete meeting reads chronologically instead of newest-first.
    public var firstUntranslated: Caption? {
        captions.first { $0.koreanText == nil && !$0.text.isEmpty }
    }

    public var bilingualPlainText: String {
        captions.map { cue in
            guard let korean = cue.koreanText, !korean.isEmpty else { return cue.text }
            return cue.text + "\n" + korean
        }.joined(separator: "\n\n")
    }

    public static let bookmarkPrefix = "★ "

    /// Plain text with important captions prefixed by ★, for the full TXT export.
    public var markedPlainText: String {
        captions.map { ($0.isBookmarked ? Self.bookmarkPrefix : "") + $0.text }.joined(separator: "\n")
    }

    public var markedBilingualPlainText: String {
        captions.map { cue in
            let original = (cue.isBookmarked ? Self.bookmarkPrefix : "") + cue.text
            guard let korean = cue.koreanText, !korean.isEmpty else { return original }
            return original + "\n" + korean
        }.joined(separator: "\n\n")
    }

    public var bilingualSRT: String {
        captions.enumerated().map { index, cue in
            var text = cue.text
            if let korean = cue.koreanText, !korean.isEmpty { text += "\n" + korean }
            return "\(index + 1)\n\(Self.timestamp(cue.start)) --> \(Self.timestamp(cue.end))\n\(text)\n"
        }.joined(separator: "\n")
    }
}

public struct TranscriptEntry: Sendable, Equatable {
    public var url: URL
    public var title: String
    public var date: Date
    public var count: Int
    public var subject: String?
    public var bookmarkCount: Int
    /// The record's audio files present on disk, and their total size.
    public var audioFiles: [URL]
    public var audioBytes: Int64
    public init(url: URL, title: String, date: Date, count: Int, subject: String? = nil, bookmarkCount: Int = 0,
                audioFiles: [URL] = [], audioBytes: Int64 = 0) {
        self.url = url
        self.title = title
        self.date = date
        self.count = count
        self.subject = Transcript.normalizedSubject(subject)
        self.bookmarkCount = bookmarkCount
        self.audioFiles = audioFiles
        self.audioBytes = audioBytes
    }
}

public struct RecordGroup<Item> {
    /// nil is the "미분류" (unclassified) group.
    public var subject: String?
    public var items: [Item]
    public var id: String { subject.map { "subject:" + $0.lowercased() } ?? "unclassified" }
}

public enum RecordGrouping {
    /// Groups by subject, case-insensitively, keeping each group's item order. Named subjects
    /// sort in Finder order and the unclassified group always comes last.
    public static func grouped<Item>(_ items: [Item], subject: (Item) -> String?) -> [RecordGroup<Item>] {
        var groups: [RecordGroup<Item>] = []
        var index: [String: Int] = [:]
        for item in items {
            let name = Transcript.normalizedSubject(subject(item))
            let key = name?.lowercased() ?? ""
            if let position = index[key] {
                groups[position].items.append(item)
            } else {
                index[key] = groups.count
                groups.append(RecordGroup(subject: name, items: [item]))
            }
        }
        return groups.sorted { lhs, rhs in
            switch (lhs.subject, rhs.subject) {
            case (nil, _): return false
            case (_, nil): return true
            case let (l?, r?): return l.localizedStandardCompare(r) == .orderedAscending
            }
        }
    }

    /// Distinct subjects already in use, for suggestions.
    public static func subjects(_ subjects: [String?]) -> [String] {
        grouped(subjects) { $0 }.compactMap(\.subject)
    }
}

public enum TranscriptLibrary {
    /// Readable records only: unreadable or empty files never appear in history. A record
    /// with recorded audio is listed even without captions, so its audio is never hidden.
    public static func entries(in directory: URL) -> [TranscriptEntry] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url -> TranscriptEntry? in
                guard let transcript = try? TranscriptDisk.load(url) else { return nil }
                let audio = RecordAudio.files(of: transcript, record: url)
                guard !transcript.captions.isEmpty || !audio.isEmpty else { return nil }
                return TranscriptEntry(url: url, title: transcript.title, date: transcript.created,
                                       count: transcript.captions.count, subject: transcript.subject,
                                       bookmarkCount: transcript.captions.filter(\.isBookmarked).count,
                                       audioFiles: audio, audioBytes: RecordAudio.bytes(of: audio))
            }
            .sorted { $0.date > $1.date }
    }

    /// Rewrites one saved record in place (atomically); used for renaming or re-filing a
    /// record that is not the one open in memory.
    public static func update(_ url: URL, _ change: (inout Transcript) -> Void) throws {
        var transcript = try TranscriptDisk.load(url)
        change(&transcript)
        try TranscriptDisk.save(transcript, at: url, srt: false)
    }

    public static func newSessionURL(in directory: URL) -> URL {
        directory.appendingPathComponent("meeting-\(UUID().uuidString).json")
    }
}
