import Foundation

public struct GlossaryEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    /// The correct English term, as it should appear in the original text.
    public var term: String
    /// Fixed Korean rendering; empty means "translate normally".
    public var korean: String
    /// Misrecognitions corrected to `term` in finalized original text.
    public var variants: [String]

    public init(id: UUID = UUID(), term: String, korean: String = "", variants: [String] = []) {
        self.id = id
        self.term = term
        self.korean = korean
        self.variants = variants
    }

    enum CodingKeys: String, CodingKey { case id, term, korean, variants }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        term = try values.decodeIfPresent(String.self, forKey: .term) ?? ""
        korean = try values.decodeIfPresent(String.self, forKey: .korean) ?? ""
        variants = try values.decodeIfPresent([String].self, forKey: .variants) ?? []
    }

    var cleanTerm: String { term.trimmingCharacters(in: .whitespacesAndNewlines) }
    var cleanKorean: String { korean.trimmingCharacters(in: .whitespacesAndNewlines) }
    var cleanVariants: [String] {
        variants.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.compare(cleanTerm, options: .caseInsensitive) != .orderedSame }
    }

    /// Variants as one comma-separated field for editing.
    public var variantsText: String {
        get { variants.joined(separator: ", ") }
        set { variants = newValue.split(whereSeparator: { $0 == "," || $0 == "|" || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    }
}

/// The Korean translation with each fixed term replaced by a placeholder. `restore` swaps the
/// placeholders back for the fixed renderings, or returns nil when the translator did not keep
/// every placeholder exactly once, in which case the caller translates the sentence normally.
public struct GlossaryProtection: Equatable, Sendable {
    public let text: String
    public let renderings: [String]

    static let marker = "QXZ"
    static func token(_ index: Int) -> String { "\(marker)\(index)Q" }

    public func restore(_ translated: String) -> String? {
        var result = translated
        for (index, rendering) in renderings.enumerated() {
            let token = Self.token(index)
            guard let range = result.range(of: token),
                  result.range(of: token, range: range.upperBound..<result.endIndex) == nil else { return nil }
            let (particleEnd, particle) = Self.particle(in: result, after: range.upperBound, rendering: rendering)
            result.replaceSubrange(range.lowerBound..<particleEnd, with: rendering + particle)
        }
        guard result.range(of: Self.marker, options: .caseInsensitive) == nil,
              !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return result
    }

    /// The translator chose a Korean particle for the placeholder's sound; re-pick it for the
    /// rendering's final consonant. Pairs are (after a consonant, after a vowel).
    private static let particles: [(String, String)] = [("으로", "로"), ("을", "를"), ("은", "는"), ("이", "가"), ("과", "와")]

    private static func particle(in text: String, after index: String.Index, rendering: String) -> (String.Index, String) {
        guard let last = rendering.unicodeScalars.last, (0xAC00...0xD7A3).contains(last.value) else { return (index, "") }
        let batchim = (last.value - 0xAC00) % 28
        let rest = text[index...]
        for (consonant, vowel) in particles {
            for form in [consonant, vowel] where rest.hasPrefix(form) {
                let end = text.index(index, offsetBy: form.count)
                if end < text.endIndex, let next = text[end].unicodeScalars.first, (0xAC00...0xD7A3).contains(next.value) { continue }
                let useVowelForm = consonant == "으로" ? (batchim == 0 || batchim == 8) : batchim == 0
                return (end, useVowelForm ? vowel : consonant)
            }
        }
        return (index, "")
    }
}

public struct Glossary: Codable, Equatable, Sendable {
    public var entries: [GlossaryEntry]

    public init(entries: [GlossaryEntry] = []) { self.entries = entries }

    public var isEmpty: Bool { entries.allSatisfy { $0.cleanTerm.isEmpty } }

    /// Replaces whole-word, case-insensitive misrecognitions with their terms. Longer variants
    /// win over shorter ones that overlap them.
    public func corrected(_ text: String) -> String {
        var needles: [(String, String)] = []
        for entry in entries where !entry.cleanTerm.isEmpty {
            for variant in entry.cleanVariants { needles.append((variant, entry.cleanTerm)) }
        }
        let found = Self.matches(needles.map(\.0), in: text)
        guard !found.isEmpty else { return text }
        var result = text
        for (range, needle) in found.reversed() { result.replaceSubrange(range, with: needles[needle].1) }
        return result
    }

    /// Placeholders for every term with a fixed rendering, or nil when none occurs (or the
    /// sentence already contains the placeholder marker, which would make restoring ambiguous).
    public func protect(_ source: String) -> GlossaryProtection? {
        let fixed = entries.filter { !$0.cleanTerm.isEmpty && !$0.cleanKorean.isEmpty }
        let found = Self.matches(fixed.map(\.cleanTerm), in: source)
        guard !found.isEmpty, source.range(of: GlossaryProtection.marker, options: .caseInsensitive) == nil else { return nil }
        var text = source
        var renderings: [String] = []
        for (offset, (range, needle)) in found.enumerated().reversed() {
            text.replaceSubrange(range, with: GlossaryProtection.token(offset))
            renderings.append(fixed[needle].cleanKorean)
        }
        return GlossaryProtection(text: text, renderings: renderings.reversed())
    }

    /// Non-overlapping whole-word, case-insensitive matches in text order; the index refers to
    /// `needles`. Longer needles are claimed first.
    static func matches(_ needles: [String], in text: String) -> [(Range<String.Index>, Int)] {
        var taken: [(Range<String.Index>, Int)] = []
        let order = needles.indices.filter { !needles[$0].isEmpty }.sorted { needles[$0].count > needles[$1].count }
        for needle in order {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let range = text.range(of: needles[needle], options: .caseInsensitive, range: searchStart..<text.endIndex) {
                searchStart = range.upperBound
                guard isBoundary(text, before: range.lowerBound), isBoundary(text, after: range.upperBound),
                      !taken.contains(where: { $0.0.overlaps(range) }) else { continue }
                taken.append((range, needle))
            }
        }
        return taken.sorted { $0.0.lowerBound < $1.0.lowerBound }
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// Symbols that join word parts into one token ("Big-O", "ASP.NET", "TCP/IP", "R&D"): a
    /// match next to one is only a fragment when the token continues past it.
    private static let joiners: Set<Character> = ["-", "‐", "–", ".", "/", "&", "\\"]
    /// Symbols that belong to a token they touch: "C++", "C#", ".NET", "@user", "$PATH".
    private static let suffixSymbols: Set<Character> = ["+", "#"]
    private static let prefixSymbols: Set<Character> = [".", "#", "@", "$"]

    private static func isBoundary(_ text: String, before index: String.Index) -> Bool {
        guard index > text.startIndex else { return true }
        let previous = text.index(before: index)
        let character = text[previous]
        if isWordCharacter(character) || prefixSymbols.contains(character) { return false }
        guard joiners.contains(character), previous > text.startIndex else { return true }
        return !isWordCharacter(text[text.index(before: previous)])
    }

    private static func isBoundary(_ text: String, after index: String.Index) -> Bool {
        guard index < text.endIndex else { return true }
        let character = text[index]
        if isWordCharacter(character) || suffixSymbols.contains(character) { return false }
        let next = text.index(after: index)
        guard joiners.contains(character), next < text.endIndex else { return true }
        return !isWordCharacter(text[next])
    }

    // MARK: - Text exchange

    /// CSV with a header: term,korean,variants — variants separated by "|".
    public var csv: String {
        func field(_ value: String) -> String {
            value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
                ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
        }
        let rows = entries.filter { !$0.cleanTerm.isEmpty }.map {
            [field($0.cleanTerm), field($0.cleanKorean), field($0.cleanVariants.joined(separator: "|"))].joined(separator: ",")
        }
        return (["term,korean,variants"] + rows).joined(separator: "\n") + "\n"
    }

    /// Reads CSV (or a plain list of terms, one per line). A header row is skipped.
    public static func parseCSV(_ text: String) -> [GlossaryEntry] {
        var rows = csvRows(text)
        if let first = rows.first?.first?.trimmingCharacters(in: .whitespaces).lowercased(),
           ["term", "용어", "english", "영어"].contains(first) {
            rows.removeFirst()
        }
        return rows.compactMap { row in
            let term = row[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { return nil }
            var entry = GlossaryEntry(term: term, korean: row.count > 1 ? row[1].trimmingCharacters(in: .whitespacesAndNewlines) : "")
            if row.count > 2 { entry.variantsText = row[2...].joined(separator: "|") }
            return entry
        }
    }

    /// Imported entries replace existing ones with the same term (case-insensitive); the rest
    /// are appended, keeping existing entry identities.
    public func merging(_ imported: [GlossaryEntry]) -> Glossary {
        var result = self
        for entry in imported {
            if let index = result.entries.firstIndex(where: { $0.cleanTerm.compare(entry.cleanTerm, options: .caseInsensitive) == .orderedSame }) {
                var updated = entry
                updated.id = result.entries[index].id
                result.entries[index] = updated
            } else {
                result.entries.append(entry)
            }
        }
        return result
    }

    private static func csvRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var characters = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if characters.hasPrefix("\u{FEFF}") { characters.removeFirst() }
        var iterator = Array(characters).makeIterator()
        var pending: Character? = nil
        func endRow() {
            row.append(field)
            field = ""
            if row.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) { rows.append(row) }
            row = []
        }
        while let character = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                    } else { quoted = false }
                } else { field.append(character) }
            } else if character == "\"" && field.isEmpty {
                quoted = true
            } else if character == "," {
                row.append(field)
                field = ""
            } else if character == "\n" {
                endRow()
            } else {
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}

public enum GlossaryDisk {
    /// A missing file is an empty glossary; an unreadable one is an error so it is never
    /// silently overwritten.
    public static func load(_ url: URL) throws -> Glossary {
        guard FileManager.default.fileExists(atPath: url.path) else { return Glossary() }
        return try JSONDecoder().decode(Glossary.self, from: Data(contentsOf: url))
    }

    public static func save(_ glossary: Glossary, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(glossary).write(to: url, options: .atomic)
    }
}
