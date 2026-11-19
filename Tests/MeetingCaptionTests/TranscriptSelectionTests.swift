import AppKit
import CaptionCore
import Testing
@testable import MeetingCaption

@MainActor
struct TranscriptSelectionTests {
    @Test func selectAllIncludesArrivingCaptionsAndTranslationsUntilSelectionChanges() {
        let text = NSTextView()
        let coordinator = MeetingTranscriptText.Coordinator()
        var view = MeetingTranscriptText(
            captions: [Caption(start: 3, end: 4, text: "First 🗣️.")],
            provisional: "Listening",
            showsTranslation: true,
            autoScroll: false
        )
        view.updateText(text, coordinator: coordinator)
        text.selectAll(nil)

        view.captions.append(Caption(start: 5, end: 6, text: "Second."))
        view.provisional = "More speech"
        view.updateText(text, coordinator: coordinator)
        #expect(text.selectedRange() == NSRange(location: 0, length: (text.string as NSString).length))

        view.captions[0].koreanText = "첫 번째 발언."
        view.provisional = ""
        view.updateText(text, coordinator: coordinator)
        #expect(text.selectedRange() == NSRange(location: 0, length: (text.string as NSString).length))
        #expect(text.string.contains("첫 번째 발언."))

        text.setSelectedRange((text.string as NSString).range(of: "Second."))
        view.captions.append(Caption(start: 7, end: 8, text: "Third."))
        view.updateText(text, coordinator: coordinator)
        #expect((text.string as NSString).substring(with: text.selectedRange()) == "Second.")
    }

    @Test func newestCaptionAndProvisionalAppearAboveOlderCaptions() {
        let text = NSTextView()
        let coordinator = MeetingTranscriptText.Coordinator()
        let view = MeetingTranscriptText(
            captions: [
                Caption(start: 3, end: 4, text: "First.", koreanText: "첫 번째."),
                Caption(start: 5, end: 6, text: "Second.", koreanText: "두 번째.")
            ],
            provisional: "Still speaking",
            showsTranslation: true,
            autoScroll: false
        )
        view.updateText(text, coordinator: coordinator)
        #expect(text.string == "인식 중  Still speaking\n00:00:05.000  Second.\n두 번째.\n00:00:03.000  First.\n첫 번째.\n")
        #expect(view.captions.map(\.text) == ["First.", "Second."])
    }
}
