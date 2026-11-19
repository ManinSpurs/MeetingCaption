import Testing
@testable import CaptionCore

@Suite("Caption pause buffer")
struct CaptionPauseBufferTests {
    @Test func groupingAndRevisions() {
        var buffer = CaptionPauseBuffer()
        let first = Caption(start: 0, end: 2, text: "First", koreanText: "translation")
        let second = Caption(start: 4, end: 5, text: "second")
        let third = Caption(start: 8, end: 9, text: "third")
        buffer.append([third, second, first])
        buffer.append([Caption(start: 0.001, end: 3, text: "Revised")])
        #expect(buffer.captions.count == 3)
        #expect(buffer.captions.map(\.text) == ["Revised", "second", "third"])
        let groups = buffer.groups(pause: 2)
        #expect(groups.count == 2)
        #expect(groups[0].id == first.id)
        #expect(groups[0].start == 0.001)
        #expect(groups[0].end == 5)
        #expect(groups[0].text == "Revised second")
        #expect(groups[0].koreanText == nil)
        #expect(groups[1].id == third.id)
        #expect(buffer.groups(pause: 3).count == 1)
        buffer.keepLastGroup(pause: 2)
        #expect(buffer.captions == [third])
        buffer.clear()
        buffer.keepLastGroup(pause: 2)
        buffer.append([])
        #expect(buffer.groups(pause: 2).isEmpty)
    }

    @Test func overlappingCuesUseMaximumEnd() {
        var buffer = CaptionPauseBuffer()
        buffer.append([
            Caption(start: 0, end: 10, text: "One"),
            Caption(start: 2, end: 3, text: "two"),
            Caption(start: 11, end: 12, text: "three")
        ])
        let groups = buffer.groups(pause: 1)
        #expect(groups.count == 1)
        #expect(groups[0].end == 12)
        #expect(groups[0].text == "One two three")
    }
}
