import Foundation

/// One caption rendered for a model prompt. Untrusted speech always lives behind a timestamp
/// prefix, so a caption can never start a line of its own and imitate prompt structure.
public struct MeetingAIQuote: Sendable, Equatable {
    public var stamp: String
    public var text: String
    /// Index of the source caption in the transcript, so coverage can be asserted exactly.
    public var cueIndex: Int
    /// 1-based fragment number when one caption was split across parts; nil when whole.
    public var fragment: Int?
    public var fragmentCount: Int?

    public init(stamp: String, text: String, cueIndex: Int = 0, fragment: Int? = nil,
                fragmentCount: Int? = nil) {
        self.stamp = stamp
        self.text = text
        self.cueIndex = cueIndex
        self.fragment = fragment
        self.fragmentCount = fragmentCount
    }

    /// Caption text is presented as speech, never as a judgement about what it says.
    public var rendered: String {
        guard let fragment, let fragmentCount else { return "[\(stamp)] \(text)" }
        return "[\(stamp)] (fragment \(fragment)/\(fragmentCount)) \(text)"
    }
}

/// Deterministic output checks that a model's own rules cannot guarantee, applied before a result
/// is shown. They never rewrite content: they detect a shape violation and report it, so the user
/// sees an honest error instead of a confidently wrong answer.
public enum MeetingAIOutputCheck {
    /// `교정:` must hold an English corrected phrase. A Korean "correction" is not a correction,
    /// because the user gave an English phrase. Decided by script alone, never by wording.
    public static func correctedPhraseIsEnglish(_ text: String) -> Bool {
        guard let line = labelledLine("교정", in: text), !line.isEmpty else { return false }
        return MeetingAIScript.isEnglish(line)
    }

    public static func labelledLine(_ label: String, in text: String) -> String? {
        for rawLine in text.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(label) else { continue }
            let rest = trimmed.dropFirst(label.count)
            let value = rest.drop(while: { $0 == ":" || $0 == "：" || $0 == " " })
            return String(value).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

/// Script classification only: which writing system a line uses. It never claims anything about
/// meaning, so it can decide "this practice answer is not English" without judging correctness.
public enum MeetingAIScript {
    /// Latin letters present and no Hangul at all.
    public static func isEnglish(_ text: String) -> Bool {
        var latin = 0
        for scalar in text.unicodeScalars {
            if isHangul(scalar) { return false }
            if CharacterSet.letters.contains(scalar) { latin += 1 }
        }
        return latin > 0
    }

    static func isHangul(_ scalar: Unicode.Scalar) -> Bool {
        (0xAC00...0xD7A3).contains(scalar.value)
            || (0x1100...0x11FF).contains(scalar.value)
            || (0x3130...0x318F).contains(scalar.value)
    }
}

/// Structural review of a practice drill: three numbered blocks, each with 상황 / 질문 / 예시 답변 /
/// 설명, English question and answer, Korean situation and explanation. Only shape and script are
/// checked, so a drill whose answers came back in Korean is reported instead of shown as complete.
public enum MeetingAIPracticeCheck {
    public struct Block: Sendable, Equatable {
        public var situation: String
        public var question: String
        public var answer: String
        public var note: String

        public init(situation: String = "", question: String = "", answer: String = "", note: String = "") {
            self.situation = situation
            self.question = question
            self.answer = answer
            self.note = note
        }
    }

    public static let situationLabel = "상황"
    public static let questionLabel = "질문"
    public static let answerLabel = "예시 답변"
    public static let noteLabel = "설명"
    public static let blockCount = 3

    public static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let value = labelledValue(situationLabel, in: line) {
                blocks.append(Block(situation: value))
            } else if let value = labelledValue(questionLabel, in: line) {
                if blocks.isEmpty { blocks.append(Block()) }
                blocks[blocks.count - 1].question = value
            } else if let value = labelledValue(answerLabel, in: line) {
                if blocks.isEmpty { blocks.append(Block()) }
                blocks[blocks.count - 1].answer = value
            } else if let value = labelledValue(noteLabel, in: line) {
                if blocks.isEmpty { blocks.append(Block()) }
                blocks[blocks.count - 1].note = value
            }
        }
        return blocks
    }

    /// The three `질문` / `예시 답변` pairs of the English-only stage, in order.
    public static func parseEnglishPairs(_ text: String) -> [(question: String, answer: String)]? {
        var questions: [String] = []
        var answers: [String] = []
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let value = labelledValue(questionLabel, in: line) {
                questions.append(value)
            } else if let value = labelledValue(answerLabel, in: line) {
                answers.append(value)
            }
        }
        guard questions.count == blockCount, answers.count == blockCount else { return nil }
        return (0..<blockCount).map { (questions[$0], answers[$0]) }
    }

    /// Three situations arrived, but at least one question or answer is missing or not English.
    public static func needsEnglishAnswers(_ blocks: [Block]) -> Bool {
        guard blocks.count == blockCount, blocks.allSatisfy({ !$0.situation.isEmpty }) else { return false }
        return blocks.contains { !MeetingAIScript.isEnglish($0.question) || !MeetingAIScript.isEnglish($0.answer) }
    }

    public static func isComplete(_ blocks: [Block]) -> Bool {
        guard blocks.count == blockCount else { return false }
        return blocks.allSatisfy { block in
            !block.situation.isEmpty && !block.question.isEmpty && !block.answer.isEmpty && !block.note.isEmpty
                && MeetingAIScript.isEnglish(block.question) && MeetingAIScript.isEnglish(block.answer)
        }
    }

    public static func assemble(_ blocks: [Block]) -> String {
        blocks.enumerated().map { index, block in
            "\(situationLabel) \(index + 1): \(block.situation)\n"
                + "\(questionLabel): \(block.question)\n"
                + "\(answerLabel): \(block.answer)\n"
                + "\(noteLabel): \(block.note)"
        }.joined(separator: "\n\n")
    }

    /// Reads an optionally numbered or bulleted label line: "상황 2:", "- 질문:", "1) 설명:".
    static func labelledValue(_ label: String, in line: String) -> String? {
        var rest = Substring(line)
        while let first = rest.first, first.isNumber || "-•*·.[]()".contains(first) {
            rest = rest.dropFirst()
        }
        rest = rest.drop(while: { $0 == " " })
        guard rest.hasPrefix(label) else { return nil }
        var after = rest.dropFirst(label.count).drop(while: { $0 == " " })
        while let first = after.first, first.isNumber || first == "." || first == ")" {
            after = after.dropFirst()
        }
        after = after.drop(while: { $0 == " " })
        guard let first = after.first, first == ":" || first == "：" else { return nil }
        return String(after.dropFirst()).trimmingCharacters(in: .whitespaces)
    }
}

/// A bounded, chronologically ordered excerpt of a transcript plus the human-readable scope of
/// that excerpt. The scope is shown in the UI, so a request never hides how much meeting it saw.
public struct MeetingAIContext: Sendable, Equatable {
    public var scope: String
    public var quotes: [MeetingAIQuote]
    public var coveredCues: Int
    public var totalCues: Int
    public var droppedCues: Int
    public var partIndex: Int?
    public var partCount: Int?

    public init(scope: String, quotes: [MeetingAIQuote], coveredCues: Int, totalCues: Int,
                droppedCues: Int = 0, partIndex: Int? = nil, partCount: Int? = nil) {
        self.scope = scope
        self.quotes = quotes
        self.coveredCues = coveredCues
        self.totalCues = totalCues
        self.droppedCues = droppedCues
        self.partIndex = partIndex
        self.partCount = partCount
    }

    public var isEmpty: Bool { quotes.isEmpty }
    public var renderedQuotes: String { quotes.map(\.rendered).joined(separator: "\n") }
    public var isPartial: Bool { coveredCues < totalCues || droppedCues > 0 }

    public static let empty = MeetingAIContext(scope: "자막 없음", quotes: [], coveredCues: 0, totalCues: 0)
}

/// Pure, deterministic context builders. They are the unit under test for question "how much of
/// the meeting did this request see", independent of any model provider.
public enum MeetingAIContextBuilder {
    /// A single quote line stays short enough that one very long caption cannot dominate the budget.
    public static let quoteCharacterLimit = 400
    static let reservedMarkers = ["<<<", ">>>"]

    /// Recent dialogue for a fast in-meeting request: newest `maxQuotes` captions that fit the
    /// character budget, still in chronological order.
    public static func recent(_ transcript: Transcript, maxQuotes: Int = 24, maxCharacters: Int = 2_600) -> MeetingAIContext {
        let cues = transcript.captions.filter { !$0.text.isEmpty }
        guard !cues.isEmpty else { return .empty }
        let limit = max(1, maxQuotes)
        var picked: [MeetingAIQuote] = []
        var used = 0
        for (index, cue) in cues.enumerated().reversed() {
            guard picked.count < limit else { break }
            let quote = MeetingAIQuote(stamp: stamp(cue.start), text: bounded(cue.text), cueIndex: index)
            guard !quote.text.isEmpty else { continue }
            if !picked.isEmpty, used + quote.rendered.count + 1 > maxCharacters { break }
            picked.append(quote)
            used += quote.rendered.count + 1
        }
        picked.reverse()
        let scope = scopeText(prefix: nil, first: picked.first?.stamp, last: picked.last?.stamp,
                              covered: picked.count, total: cues.count, dropped: 0, part: nil)
        return MeetingAIContext(scope: scope, quotes: picked, coveredCues: picked.count, totalCues: cues.count)
    }

    /// Context centred on a phrase the user selected. Falls back to recent dialogue when the
    /// phrase is not in the transcript, and says so in the visible scope.
    public static func focused(_ transcript: Transcript, phrase: String,
                               maxQuotes: Int = 16, maxCharacters: Int = 2_000) -> MeetingAIContext {
        let cues = transcript.captions.filter { !$0.text.isEmpty }
        guard !cues.isEmpty else { return .empty }
        let needle = phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else {
            let context = recent(transcript, maxQuotes: maxQuotes, maxCharacters: maxCharacters)
            return MeetingAIContext(scope: context.scope + " · 선택한 표현 없음", quotes: context.quotes,
                                    coveredCues: context.coveredCues, totalCues: context.totalCues)
        }
        guard let anchor = cues.lastIndex(where: { $0.text.lowercased().contains(needle) }) else {
            let context = recent(transcript, maxQuotes: maxQuotes, maxCharacters: maxCharacters)
            return MeetingAIContext(scope: "선택한 표현을 자막에서 찾지 못해 최근 자막을 사용 · " + context.scope,
                                    quotes: context.quotes, coveredCues: context.coveredCues, totalCues: context.totalCues)
        }
        let limit = max(1, maxQuotes)
        let half = max(1, limit / 2)
        var lower = max(0, anchor - half)
        var upper = min(cues.count - 1, anchor + half)
        func rendered(_ range: ClosedRange<Int>) -> [MeetingAIQuote] {
            range.map {
                MeetingAIQuote(stamp: stamp(cues[$0].start), text: bounded(cues[$0].text), cueIndex: $0)
            }
        }
        var quotes = rendered(lower...upper)
        var size = quotes.reduce(0) { $0 + $1.rendered.count + 1 }
        // Trim the farthest lines first, never the anchor itself.
        while size > maxCharacters, upper > lower {
            let dropLower = (anchor - lower) >= (upper - anchor) && lower < anchor
            if dropLower { lower += 1 } else { upper -= 1 }
            quotes = rendered(lower...upper)
            size = quotes.reduce(0) { $0 + $1.rendered.count + 1 }
        }
        let scope = scopeText(prefix: "선택한 표현 주변", first: quotes.first?.stamp, last: quotes.last?.stamp,
                              covered: quotes.count, total: cues.count, dropped: 0, part: nil)
        return MeetingAIContext(scope: scope, quotes: quotes, coveredCues: quotes.count, totalCues: cues.count)
    }

    /// Chronological source parts for a whole-meeting request. Every caption of the meeting is
    /// covered exactly once, in order, with no destructive cap: `maxParts` is only a grouping
    /// target, so a long meeting simply yields more parts. A single caption longer than the part
    /// budget is split by its own text and each fragment keeps the caption's stamp and an explicit
    /// fragment marker, so no source text is silently lost.
    public static func chronologicalParts(_ transcript: Transcript, maxParts: Int = 8,
                                          maxCharactersPerPart: Int = 4_000,
                                          minCharactersPerPart: Int = 1_200) -> [MeetingAIContext] {
        let cues = transcript.captions
        guard cues.contains(where: { !$0.text.isEmpty }) else { return [] }
        let groupTarget = max(1, maxParts)
        let partCap = max(400, maxCharactersPerPart)
        let floorCap = max(200, min(minCharactersPerPart, partCap))

        // 1. Split overly long captions by their own text; every fragment keeps the stamp.
        var units: [MeetingAIQuote] = []
        for (index, cue) in cues.enumerated() where !cue.text.isEmpty {
            let normalized = normalize(cue.text)
            guard !normalized.isEmpty else { continue }
            // Leave room for the "[mm:ss] (fragment n/m) " prefix inside the part budget.
            let bodyBudget = max(80, partCap - 60)
            let pieces = split(normalized, budget: bodyBudget)
            for (offset, piece) in pieces.enumerated() {
                units.append(MeetingAIQuote(stamp: stamp(cue.start), text: piece, cueIndex: index,
                                            fragment: pieces.count > 1 ? offset + 1 : nil,
                                            fragmentCount: pieces.count > 1 ? pieces.count : nil))
            }
        }
        guard !units.isEmpty else { return [] }

        // 2. Aim for about `groupTarget` parts, but never shrink below the floor and never grow
        //    past the per-request cap: the number of parts follows the meeting, not a hard limit.
        let totalCharacters = units.reduce(0) { $0 + $1.rendered.count + 1 }
        let even = totalCharacters / groupTarget + 1
        let budget = min(partCap, max(floorCap, even))

        var groups: [[MeetingAIQuote]] = []
        var current: [MeetingAIQuote] = []
        var used = 0
        for unit in units {
            let size = unit.rendered.count + 1
            if !current.isEmpty, used + size > budget {
                groups.append(current)
                current = []
                used = 0
            }
            current.append(unit)
            used += size
        }
        if !current.isEmpty { groups.append(current) }

        // 3. Coverage is cumulative and exact: `coveredCues` counts distinct source captions seen
        //    up to and including this part, so the last part must equal the meeting's cue count.
        var coveredSources: Set<Int> = []
        let totalSources = cues.filter { !$0.text.isEmpty }.count
        return groups.enumerated().map { index, group in
            coveredSources.formUnion(group.map(\.cueIndex))
            let single = groups.count == 1
            let scope = scopeText(prefix: single ? nil : "구간 \(index + 1)/\(groups.count)",
                                  first: group.first?.stamp, last: group.last?.stamp,
                                  covered: coveredSources.count, total: totalSources, dropped: 0,
                                  part: single ? nil : (index + 1, groups.count))
            return MeetingAIContext(scope: scope, quotes: group, coveredCues: coveredSources.count,
                                    totalCues: totalSources, droppedCues: 0,
                                    partIndex: index + 1, partCount: groups.count)
        }
    }

    /// Splits normalized text into slices no longer than `budget`, preferring a space near the cut.
    public static func split(_ text: String, budget: Int) -> [String] {
        guard budget > 0 else { return [text] }
        guard text.count > budget else { return [text] }
        var pieces: [String] = []
        var remaining = Substring(text)
        while remaining.count > budget {
            let hard = remaining.index(remaining.startIndex, offsetBy: budget)
            let window = remaining[remaining.startIndex..<hard]
            let cut = window.lastIndex(of: " ").map { remaining.index(after: $0) } ?? hard
            pieces.append(String(remaining[remaining.startIndex..<cut]).trimmingCharacters(in: .whitespaces))
            remaining = remaining[cut...]
        }
        let tail = String(remaining).trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { pieces.append(tail) }
        return pieces.filter { !$0.isEmpty }
    }

    /// Renders a caption as one prompt-safe line: whitespace collapsed and prompt fence markers
    /// defused. Length is bounded separately by callers, so a whole-meeting summary can split a
    /// long caption instead of losing its tail here.
    public static func normalize(_ text: String) -> String {
        let cleaned = text.unicodeScalars
            .map { scalar -> Character in
                scalar.properties.generalCategory == .control ? " " : Character(scalar)
            }
        var collapsed = String(cleaned)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        for marker in reservedMarkers {
            collapsed = collapsed.replacingOccurrences(of: marker,
                                                       with: marker.replacingOccurrences(of: "<", with: "‹")
                                                           .replacingOccurrences(of: ">", with: "›"))
        }
        return collapsed
    }

    /// A single quote line for recent/focused context stays short so one caption cannot dominate
    /// a small budget; truncation here is visible in the scope-independent tail marker.
    public static func bounded(_ text: String) -> String {
        let normalized = normalize(text)
        guard normalized.count > quoteCharacterLimit else { return normalized }
        return String(normalized.prefix(quoteCharacterLimit)) + "…"
    }

    public static func stamp(_ time: Double) -> String {
        let seconds = Int(max(0, time.isFinite ? time : 0))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    static func scopeText(prefix: String?, first: String?, last: String?, covered: Int, total: Int,
                          dropped: Int, part: (Int, Int)?) -> String {
        var pieces: [String] = []
        if let prefix { pieces.append(prefix) }
        if part == nil, covered == total, dropped == 0 {
            pieces.append("전체 자막 \(total)개")
        } else if covered == 0 {
            pieces.append("자막 없음")
        } else {
            pieces.append("자막 \(covered)/\(total)개")
        }
        if let first, let last {
            pieces.append(first == last ? "(\(first))" : "(\(first)–\(last))")
        }
        if part == nil, covered < total {
            pieces.append("전체 \(total)개 중 최근 부분")
        }
        if dropped > 0 {
            pieces.append("뒷부분 자막 \(dropped)개 제외")
        }
        return pieces.joined(separator: " · ")
    }
}

/// The shape of a summary: three headings. Bullets under the first are free; bullets under the
/// other two are claims the app backs with the caption they cite.
public enum MeetingSummaryTemplate: String, CaseIterable, Identifiable, Sendable {
    case meeting, lecture

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .meeting: "회의록"
        case .lecture: "강의 노트"
        }
    }

    /// What the record is called in status and scope lines.
    public var subject: String {
        switch self {
        case .meeting: "회의"
        case .lecture: "강의"
        }
    }

    public var pointsHeading: String {
        switch self {
        case .meeting: "핵심 내용"
        case .lecture: "핵심 개념"
        }
    }

    public var discussionHeading: String {
        switch self {
        case .meeting: "결정 논의(원문 확인)"
        case .lecture: "내용 정리(원문 확인)"
        }
    }

    public var candidateHeading: String {
        switch self {
        case .meeting: "할 일 후보(원문 확인)"
        case .lecture: "시험·과제 언급(원문 확인)"
        }
    }

    var interpretedSections: String {
        switch self {
        case .meeting: "결정과 할 일은"
        case .lecture: "내용 정리와 시험·과제 언급은"
        }
    }
}

/// Resolves summary claim lines against the captions that were actually sent. It decides nothing
/// about meaning: a claim keeps its model wording, and the app only appends the original caption
/// text of the timestamp the claim cites, or moves the claim to a confirmation-needed list when the
/// cited timestamp is not in the sent source. A decision or task stays a model interpretation.
public enum MeetingAISourceResolution {
    public struct Summary: Sendable, Equatable {
        public var text: String
        public var resolvedLines: Int
        public var unresolvedLines: Int
        public init(text: String, resolvedLines: Int, unresolvedLines: Int) {
            self.text = text
            self.resolvedLines = resolvedLines
            self.unresolvedLines = unresolvedLines
        }
        public var isFullyResolved: Bool { unresolvedLines == 0 }
    }

    /// Shown above every summary so a reader cannot mistake the draft for a verified record.
    public static func prelude(for template: MeetingSummaryTemplate) -> String {
        """
        모델이 생성한 초안입니다. \(template.interpretedSections) 자막을 바탕으로 한 모델의 해석이며, 앱이 참·거짓을 \
        판정한 것이 아닙니다. "↳ 자막 원문" 줄은 앱이 이 요청에 실제로 전달한 자막에서 그대로 옮긴 \
        인용입니다(정규화로 줄바꿈·공백이 바뀌었고, 길면 생략 표시가 붙습니다).
        """
    }

    public static let prelude = prelude(for: .meeting)
    public static let unresolvedHeading = "확인 필요 · 자막 근거 미확인"
    public static let discussionHeading = MeetingSummaryTemplate.meeting.discussionHeading
    public static let candidateHeading = MeetingSummaryTemplate.meeting.candidateHeading
    public static let pointsHeading = MeetingSummaryTemplate.meeting.pointsHeading
    /// The marker the prompt asks for when a section has nothing in it. It asserts no fact, so it
    /// is kept in place instead of being treated as a claim that needs source confirmation.
    public static let emptySectionMarker = "자막에 명시된 내용 없음"
    static let excerptArrow = "↳ 자막 원문: "
    static let excerptLimit = 160

    /// Collects every caption that shares a timestamp instead of keeping only the first, so a
    /// second of the meeting that carries two utterances is fully available for quotation.
    public static func sourceMap(_ quotes: [MeetingAIQuote]) -> [String: [String]] {
        var map: [String: [String]] = [:]
        for quote in quotes {
            let text = quote.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if map[quote.stamp]?.contains(text) == true { continue }
            map[quote.stamp, default: []].append(text)
        }
        return map
    }

    enum Section { case points, discussion, candidates, unresolved }

    /// Rewrites only the citation part of decision and action lines. Any evidence line the model
    /// wrote is discarded and rebuilt from `sources`, so the result is idempotent and never carries
    /// a quote that was not in the request.
    public static func resolve(_ summary: String, sources: [String: [String]],
                               template: MeetingSummaryTemplate = .meeting) -> Summary {
        var output: [String] = []
        var unresolved: [String] = []
        var current: Section = .points
        var resolved = 0
        var lastHeading: Section?

        for rawLine in summary.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let heading = section(for: line, template: template) {
                current = heading
                guard lastHeading != heading else { continue }
                lastHeading = heading
                if heading == .unresolved { continue }
                output.append(name(of: heading, template: template))
                continue
            }
            if isModelEvidenceLine(line) { continue }
            if current == .unresolved {
                // Carried forward unchanged: a claim that could not be resolved stays visible as a
                // claim needing confirmation instead of being deleted or promoted to a fact.
                unresolved.append(hasBullet(line) ? line : "- " + line)
                continue
            }
            guard current == .discussion || current == .candidates else {
                output.append(line)
                continue
            }
            if line.contains(emptySectionMarker) {
                output.append(line)
                continue
            }
            let citations = MeetingAISourceResolution.stamps(in: line)
            let excerpts = citations.flatMap { stamp in
                (sources[stamp] ?? []).map { (stamp, $0) }
            }
            guard !excerpts.isEmpty else {
                unresolved.append(hasBullet(line) ? line : "- " + line)
                continue
            }
            resolved += 1
            output.append(line)
            for (stamp, text) in excerpts {
                output.append("    " + excerptArrow + stamp + " " + excerpt(text))
            }
        }

        if !unresolved.isEmpty {
            output.append("")
            output.append(unresolvedHeading)
            output.append(contentsOf: unresolved)
        }
        return Summary(text: output.joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       resolvedLines: resolved, unresolvedLines: unresolved.count)
    }

    /// A caption excerpt stays one line and says so when it was shortened. Length bounds are the
    /// app's, so a very long caption cannot flood the result.
    static func excerpt(_ text: String) -> String {
        let normalized = MeetingAIContextBuilder.normalize(text)
        if normalized.count <= excerptLimit { return normalized }
        return String(normalized.prefix(excerptLimit)) + " …(생략)"
    }

    /// Model-written evidence lines: `↳`, `→` or an explicit "자막 원문" prefix. They are never
    /// trusted, because the model can restate a caption from memory instead of quoting it.
    static func isModelEvidenceLine(_ line: String) -> Bool {
        line.hasPrefix("↳") || line.hasPrefix("→") || line.hasPrefix("▸")
            || line.hasPrefix("자막 원문") || line.hasPrefix("자막:")
    }

    static func hasBullet(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        return "-•*·".contains(first) || first.isNumber
    }

    /// Lenient heading match, including the legacy labels the model still produces.
    static func section(for line: String, template: MeetingSummaryTemplate = .meeting) -> Section? {
        let cleaned = line.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "#*• -:·[]_"))
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, cleaned.count <= 40 else { return nil }
        let bare = cleaned.replacingOccurrences(of: " ", with: "")
        if template == .lecture {
            if ["핵심개념", "주요개념", "개념", "keyconcepts", "concepts"].contains(bare) { return .points }
            if ["내용정리(원문확인)", "내용정리", "강의내용", "주요내용", "lecturenotes", "notes"].contains(bare) {
                return .discussion
            }
            if ["시험·과제언급(원문확인)", "시험·과제언급", "시험과제언급", "시험·과제", "시험과제", "시험", "과제",
                "examsandassignments", "exams", "assignments"].contains(bare) { return .candidates }
        }
        if ["decisions", "decision", "결정논의(원문확인)", "확정된결정", "결정", "결정사항"].contains(bare) {
            return .discussion
        }
        if ["actionitems", "actionitem", "actions", "actionpoints", "할일후보(원문확인)",
            "할일", "할일목록", "액션아이템", "후속조치", "담당업무"].contains(bare) { return .candidates }
        if ["keypoints", "keypoint", "summary", "핵심내용", "핵심", "요약"].contains(bare) { return .points }
        if ["확인필요·자막근거미확인", "확인필요", "자막근거미확인"].contains(bare) { return .unresolved }
        return nil
    }

    static func name(of section: Section, template: MeetingSummaryTemplate = .meeting) -> String {
        switch section {
        case .points: template.pointsHeading
        case .discussion: template.discussionHeading
        case .candidates: template.candidateHeading
        case .unresolved: unresolvedHeading
        }
    }

    /// A place in a summary that names a caption time.
    public struct StampLink: Equatable, Sendable {
        public var range: Range<String.Index>
        public var stamp: String
    }

    private static let linkPattern = try! NSRegularExpression(
        pattern: "[\\[(](\\d{2,}:\\d{2})[\\])]|" + NSRegularExpression.escapedPattern(for: excerptArrow) + "(\\d{2,}:\\d{2})")

    /// Every caption time a summary shows: a cited `(mm:ss)` / `[mm:ss]` label, and the time on
    /// an app-written "↳ 자막 원문" line. The range covers what the reader would click.
    public static func stampLinks(in text: String) -> [StampLink] {
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        return linkPattern.matches(in: text, range: whole).compactMap { match in
            if let stamp = Range(match.range(at: 1), in: text), let label = Range(match.range, in: text) {
                return StampLink(range: label, stamp: String(text[stamp]))
            }
            guard let stamp = Range(match.range(at: 2), in: text) else { return nil }
            return StampLink(range: stamp, stamp: String(text[stamp]))
        }
    }

    /// The caption a stamp points at: the first one that renders to that label. Merging
    /// sentences after a summary was written can move a caption's start, so otherwise it is the
    /// last caption that had begun by that second; a time past the record points at nothing.
    public static func caption(forStamp stamp: String, in captions: [Caption]) -> Caption? {
        if let exact = captions.first(where: { MeetingAIContextBuilder.stamp($0.start) == stamp }) { return exact }
        let fields = stamp.split(separator: ":")
        guard fields.count == 2, let minutes = Int(fields[0]), let seconds = Int(fields[1]), seconds < 60,
              let last = captions.last else { return nil }
        let time = Double(minutes * 60 + seconds)
        guard time <= last.end else { return nil }
        return captions.last { $0.start <= time }
    }

    /// Accepts both `[mm:ss]` and `(mm:ss)`: the prompt asks for parentheses while the context
    /// fence uses brackets, so only accepting one form would lose correct citations.
    private static let stampPattern = try! NSRegularExpression(pattern: "[\\[(](\\d{2,}):(\\d{2})[\\])]")

    /// Stamps as bare `mm:ss`, matching `MeetingAIContextBuilder.stamp`'s label format.
    public static func stamps(in line: String) -> [String] {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return stampPattern.matches(in: line, range: range).compactMap { match in
            guard let minutes = Range(match.range(at: 1), in: line),
                  let seconds = Range(match.range(at: 2), in: line) else { return nil }
            return "\(line[minutes]):\(line[seconds])"
        }
    }
}

