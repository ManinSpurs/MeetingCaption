import AppKit

/// The transcript's text view. The "여기부터 듣기" ▶ markers are drawn in the left margin
/// instead of being characters, so selecting, copying and Find see only caption text.
final class TranscriptTextView: NSTextView {
    private(set) var playable: Set<UUID> = []
    private var playing: UUID?
    private var markerFontSize: Double = 15
    private var onPlay: (UUID) -> Void = { _ in }

    func updatePlayMarkers(_ playable: Set<UUID>, playing: UUID?, fontSize: Double, onPlay: @escaping (UUID) -> Void) {
        // Called after every document update: caption positions may have moved.
        self.onPlay = onPlay
        self.playable = playable
        self.playing = playing
        markerFontSize = fontSize
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// One marker per playable caption, beside the first line of the caption.
    /// Only captions whose first line is inside `rect` (default: the visible area) are
    /// computed, so the cost follows the screen, not the length of the record.
    func playMarkers(in rect: NSRect? = nil) -> [(id: UUID, rect: NSRect)] {
        guard !playable.isEmpty, let layoutManager, let storage = textStorage,
              let container = textContainer else { return [] }
        var markers: [(UUID, NSRect)] = []
        let origin = textContainerOrigin
        var area = rect ?? visibleRect
        area.origin.x -= origin.x
        area.origin.y -= origin.y
        let glyphs = layoutManager.glyphRange(forBoundingRect: area, in: container)
        let chars = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        guard chars.length > 0 else { return [] }
        storage.enumerateAttribute(MeetingTranscriptText.captionKey, in: chars) { value, range, _ in
            guard let raw = value as? String, let id = UUID(uuidString: raw), playable.contains(id) else { return }
            // A caption that began above the area is clipped here; its marker is not in view.
            if range.location > 0,
               storage.attribute(MeetingTranscriptText.captionKey, at: range.location - 1, effectiveRange: nil) as? String == raw {
                return
            }
            let glyph = layoutManager.glyphIndexForCharacter(at: range.location)
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            markers.append((id, NSRect(x: 1, y: line.minY + origin.y, width: max(14, origin.x - 2), height: line.height)))
        }
        return markers
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let font = NSFont.systemFont(ofSize: max(9, markerFontSize - 4))
        for marker in playMarkers(in: dirtyRect) where marker.rect.intersects(dirtyRect) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: marker.id == playing ? NSColor.controlAccentColor : NSColor.systemOrange
            ]
            let glyph = NSAttributedString(string: "▶\u{FE0E}", attributes: attributes)
            let size = glyph.size()
            glyph.draw(at: NSPoint(x: marker.rect.midX - size.width / 2, y: marker.rect.minY + (marker.rect.height - size.height) / 2))
        }
    }

    /// The caption whose marker is at `point` (view coordinates).
    func playMarker(at point: NSPoint) -> UUID? {
        playMarkers(in: NSRect(x: 0, y: point.y, width: bounds.width, height: 1)).first { $0.rect.contains(point) }?.id
    }

    /// Plays from the caption whose marker was clicked; false when the click was elsewhere.
    func clickPlayMarker(at point: NSPoint) -> Bool {
        guard let id = playMarker(at: point) else { return false }
        onPlay(id)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        if clickPlayMarker(at: convert(event.locationInWindow, from: nil)) { return }
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        removeAllToolTips()
        for marker in playMarkers() {
            addCursorRect(marker.rect, cursor: .pointingHand)
            addToolTip(marker.rect, owner: MeetingTranscriptText.playLabel as NSString, userData: nil)
        }
    }
}
