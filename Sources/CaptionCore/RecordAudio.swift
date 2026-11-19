import Foundation

/// One continuous audio file recorded during one start→stop recording session of a record.
///
/// Its first sample is caption time `start`: recognition for that session began at the
/// record's `nextStartTime`, and the writer lays the analyzer's frames (including silence for
/// capture gaps) at exactly the same positions, so `caption.start - start` is the file offset.
public struct AudioSegment: Codable, Equatable, Sendable {
    /// File name in the archive folder, next to the record's JSON.
    public var file: String
    /// Caption time of the file's first sample.
    public var start: Double
    /// Caption time from which this file no longer applies (its length, cut at the next
    /// session's start). nil while recording or after the app quit unexpectedly.
    public var end: Double?

    public init(file: String, start: Double, end: Double? = nil) {
        self.file = file
        self.start = start
        self.end = end
    }

    public var isFinished: Bool { end != nil }
}

public enum AudioTimeline {
    /// Caption times are recognizer times that can be fractions of a frame earlier than the
    /// rounded first frame of a segment.
    static let tolerance = 0.01

    /// The segment that holds caption time `time`, and the position within its file.
    public static func locate(_ time: Double, in segments: [AudioSegment]) -> (index: Int, offset: Double)? {
        guard time.isFinite else { return nil }
        for index in segments.indices.reversed() {
            let segment = segments[index]
            guard let end = segment.end, end > segment.start else { continue }
            if time >= segment.start - tolerance && time < end {
                return (index, max(0, time - segment.start))
            }
        }
        return nil
    }

    /// The caption being heard at `offset` seconds into segment `index`: the last caption of
    /// that segment that has started, so a pause in speech keeps the previous sentence lit.
    public static func caption(atOffset offset: Double, segment index: Int,
                               in segments: [AudioSegment], captions: [Caption]) -> Caption? {
        guard segments.indices.contains(index) else { return nil }
        let time = segments[index].start + offset
        return captions.last { cue in
            cue.start <= time + tolerance && locate(cue.start, in: segments)?.index == index
        }
    }

    /// A new recording session starts at `time`; earlier segments stop applying there, so
    /// captions of a later session (with or without audio) never map into older audio.
    public static func closeSegments(_ segments: inout [AudioSegment], at time: Double) {
        for index in segments.indices {
            if let end = segments[index].end { segments[index].end = min(end, max(segments[index].start, time)) }
        }
    }
}

public enum RecordAudio {
    public static let fileExtension = "m4a"

    /// Audio files sit next to their record; only the last path component of a stored name is
    /// honored so a record cannot point outside the archive folder. A name that would resolve
    /// to the folder itself or its parent ("", ".", "..") or a hidden file is rejected, so a
    /// link can only ever name a file directly inside the archive folder.
    public static func url(of segment: AudioSegment, record: URL) -> URL? {
        let name = (segment.file as NSString).lastPathComponent
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains(":") else { return nil }
        return record.deletingLastPathComponent().appendingPathComponent(name, isDirectory: false)
    }

    /// The record's audio files that exist on disk as regular files, in recording order.
    public static func files(of transcript: Transcript, record: URL) -> [URL] {
        (transcript.audio ?? []).compactMap { url(of: $0, record: record) }.filter(isRegularFile)
    }

    public static func isRegularFile(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeRegular
    }

    public static func bytes(of files: [URL]) -> Int64 {
        files.reduce(0) { total, url in
            total + ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    /// `meeting-<id>-audio-<n>.m4a`, unused by the record and on disk.
    public static func newSegmentFile(for transcript: Transcript, record: URL) -> String {
        let base = record.deletingPathExtension().lastPathComponent
        let used = Set((transcript.audio ?? []).map(\.file))
        var number = (transcript.audio?.count ?? 0) + 1
        while true {
            let name = "\(base)-audio-\(number).\(fileExtension)"
            let onDisk = FileManager.default.fileExists(atPath: record.deletingLastPathComponent().appendingPathComponent(name).path)
            if !used.contains(name) && !onDisk { return name }
            number += 1
        }
    }

    public struct Recovery: Equatable, Sendable {
        public var recovered = 0
        public var removed = 0
        public var changed: Bool { recovered + removed > 0 }
        public init(recovered: Int = 0, removed: Int = 0) {
            self.recovered = recovered
            self.removed = removed
        }
    }

    /// Settles segments left unfinished by an interrupted session. A file that can still be
    /// played keeps its link with the length `duration` reports; a missing or unplayable one
    /// is deleted and unlinked so the record never points at a broken file.
    public static func recover(_ transcript: inout Transcript, record: URL,
                               duration: (URL) -> Double?) -> Recovery {
        guard let original = transcript.audio, original.contains(where: { !$0.isFinished }) else { return Recovery() }
        var result = Recovery()
        var kept: [AudioSegment] = []
        for (index, segment) in original.enumerated() {
            guard !segment.isFinished else { kept.append(segment); continue }
            guard let file = url(of: segment, record: record) else {
                result.removed += 1
                continue
            }
            guard let length = duration(file), length > 0 else {
                if isRegularFile(file) { try? FileManager.default.removeItem(at: file) }
                result.removed += 1
                continue
            }
            result.recovered += 1
            // A later session (even one whose audio is lost) owns the captions from its start.
            let next = original.indices.contains(index + 1) ? original[index + 1].start : .infinity
            kept.append(AudioSegment(file: segment.file, start: segment.start,
                                     end: min(segment.start + length, max(segment.start, next))))
        }
        transcript.audio = kept.isEmpty ? nil : kept
        return result
    }
}
