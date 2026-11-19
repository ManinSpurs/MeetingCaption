public struct CaptionPauseBuffer {
    public private(set) var captions: [Caption] = []

    public init() {}

    public mutating func append(_ cues: [Caption]) {
        var transcript = Transcript(title: "", locale: "", source: "")
        transcript.captions = captions
        transcript.mergeFinal(cues)
        captions = transcript.captions
    }

    public func groups(pause: Double) -> [Caption] {
        var result: [Caption] = []
        for cue in captions {
            if let last = result.indices.last, cue.start - result[last].end <= pause {
                result[last].end = max(result[last].end, cue.end)
                result[last].text += " " + cue.text
            } else {
                var group = cue
                group.koreanText = nil
                result.append(group)
            }
        }
        return result
    }

    public mutating func keepLastGroup(pause: Double) {
        guard let start = groups(pause: pause).last?.start else { return }
        captions.removeAll { $0.start < start }
    }

    public mutating func clear() {
        captions.removeAll()
    }
}
