import Foundation

public enum TranscriptExportFormat: String, Sendable {
    case txt, srt
}

public struct TranscriptExportFile: Equatable, Sendable {
    public let url: URL
    public let text: String
    public init(url: URL, text: String) {
        self.url = url
        self.text = text
    }
}

public enum TranscriptExportError: LocalizedError {
    case sidecarsExist([URL])
    public var errorDescription: String? {
        switch self {
        case .sidecarsExist(let urls): return "기존 번역 파일을 덮어쓰려면 확인이 필요합니다: " + urls.map(\.lastPathComponent).joined(separator: ", ")
        }
    }
}

public enum TranscriptExport {
    /// The chosen file always keeps the original language; Korean and bilingual files are
    /// added beside it once at least one translation exists, so no text is lost.
    /// TXT marks important captions with ★; a marked-only export contains just those captions,
    /// so it needs no marker. SRT stays a clean subtitle file.
    public static func files(for transcript: Transcript, to chosenURL: URL, format: TranscriptExportFormat,
                             markedOnly: Bool = false) -> [TranscriptExportFile] {
        let transcript = markedOnly ? transcript.bookmarkedOnly : transcript
        let url = chosenURL.pathExtension.lowercased() == format.rawValue
            ? chosenURL
            : chosenURL.appendingPathExtension(format.rawValue)
        let stem = url.deletingPathExtension()
        let korean = transcript.koreanTranscript
        var files = [TranscriptExportFile(url: url, text: format == .srt ? transcript.srt
            : (markedOnly ? transcript.plainText : transcript.markedPlainText))]
        guard transcript.hasTranslations else { return files }
        if format == .srt {
            files.append(TranscriptExportFile(url: stem.appendingPathExtension("ko.srt"), text: korean.srt))
            files.append(TranscriptExportFile(url: stem.appendingPathExtension("bilingual.srt"), text: transcript.bilingualSRT))
        } else {
            files.append(TranscriptExportFile(url: stem.appendingPathExtension("ko.txt"),
                                              text: markedOnly ? korean.plainText : korean.markedPlainText))
            files.append(TranscriptExportFile(url: stem.appendingPathExtension("bilingual.txt"),
                                              text: markedOnly ? transcript.bilingualPlainText : transcript.markedBilingualPlainText))
        }
        return files
    }

    @discardableResult
    public static func write(_ transcript: Transcript, to chosenURL: URL, format: TranscriptExportFormat,
                             markedOnly: Bool = false, replacingDerived: Bool = false) throws -> [URL] {
        let files = files(for: transcript, to: chosenURL, format: format, markedOnly: markedOnly)
        let existing = files.dropFirst().map(\.url).filter { FileManager.default.fileExists(atPath: $0.path) }
        if !replacingDerived, !existing.isEmpty { throw TranscriptExportError.sidecarsExist(existing) }
        for file in files {
            try file.text.write(to: file.url, atomically: true, encoding: .utf8)
        }
        return files.map(\.url)
    }
}

