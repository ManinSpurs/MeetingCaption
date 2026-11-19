import Foundation
import CaptionCore

/// Searches every saved record off the main actor. Decoded records are cached by file
/// modification date, so repeated keystrokes over a large archive only re-read changed files.
actor RecordSearchService {
    private var cache: [URL: (modified: Date, transcript: Transcript)] = [:]

    func search(_ query: String, in directory: URL) -> [RecordSearchResult] {
        guard RecordSearch.normalizedQuery(query) != nil else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var records: [(url: URL, transcript: Transcript)] = []
        var seen: Set<URL> = []
        for url in urls where url.pathExtension.lowercased() == "json" {
            if Task.isCancelled { return [] }
            seen.insert(url)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if let cached = cache[url], cached.modified == modified {
                records.append((url, cached.transcript))
            } else if let transcript = try? TranscriptDisk.load(url) {
                cache[url] = (modified, transcript)
                records.append((url, transcript))
            } else {
                cache[url] = nil
            }
        }
        cache = cache.filter { seen.contains($0.key) }
        if Task.isCancelled { return [] }
        return RecordSearch.search(query, in: records.filter { !$0.transcript.captions.isEmpty })
    }
}
