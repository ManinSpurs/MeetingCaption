import Foundation
import Testing
@testable import CaptionCore

// Legacy policy coverage kept as reference for the retired playback paths.
@Suite("StreamingPolicy")
struct StreamingPolicyTests {
    @Test func rewatchUsesExistingCaptionsButUnseenGapsDoNot() {
        let cues = [Caption(start: 0, end: 3, text: "First"), Caption(start: 3.3, end: 6, text: "Second"), Caption(start: 12, end: 14, text: "Later")]
        #expect(StreamingPolicy.cachedRegionEnd(at: 4, captions: cues) == 6)
        #expect(StreamingPolicy.cachedRegionEnd(at: 0, captions: cues) == 6)
        #expect(StreamingPolicy.cachedRegionEnd(at: 9, captions: cues) == nil)
        #expect(StreamingPolicy.cachedRegionEnd(at: 13, captions: cues) == 14)
        #expect(StreamingPolicy.cachedRegionEnd(at: 16, captions: cues) == nil)
    }
    @Test func entryAndOriginBoundaries() {
        #expect(StreamingPolicy.acceptsEntry(URL(string: "https://university-my.sharepoint.com/personal/user/_layouts/15/stream.aspx?id=video")!))
        #expect(!StreamingPolicy.acceptsEntry(URL(string: "https://sharepoint.com.evil.example/video")!))
        #expect(!StreamingPolicy.acceptsEntry(URL(string: "file:///tmp/movie.mp4")!))
        #expect(!StreamingPolicy.acceptsEntry(URL(string: "https://user:password@school.sharepoint.com/view")!))
    }
    @Test func downloadsBlockedButPlayerAllowed() {
        for suffix in ["download.aspx?id=1", "stream.aspx?download=1", "stream.aspx?action=download", "video.mp4"] {
            #expect(StreamingPolicy.blocksNavigation(URL(string: "https://school.sharepoint.com/" + suffix)!))
        }
        #expect(!StreamingPolicy.blocksNavigation(URL(string: "https://school.sharepoint.com/stream.aspx?id=1&download=0")!))
        #expect(StreamingPolicy.isAttachment("Attachment; filename=lecture.mp4"))
        #expect(!StreamingPolicy.isAttachment("inline"))
    }
    @Test func generalWebEntryRejectsFilesAndCredentials() {
        #expect(StreamingPolicy.acceptsWebEntry(URL(string: "https://www.youtube.com/watch?v=example")!))
        #expect(StreamingPolicy.acceptsWebEntry(URL(string: "https://lecture.example.edu/watch/42")!))
        for entry in ["file:///tmp/page.html", "javascript:alert(1)", "http://example.com/watch", "https://user:secret@example.com/watch", "https://example.com/video.mp4", "https://example.com/watch?download=1"] {
            #expect(!StreamingPolicy.acceptsWebEntry(URL(string: entry)!))
        }
    }
    @Test func modernOneDriveDomain() {
        #expect(StreamingPolicy.acceptsEntry(URL(string: "https://onedrive.cloud.microsoft/?id=video")!))
        #expect(!StreamingPolicy.acceptsEntry(URL(string: "https://onedrive.cloud.microsoft.evil.example/?id=video")!))
    }
    @Test func nativeStreamStaysOnOriginalSharePointHost() {
        let page = URL(string: "https://school-my.sharepoint.com/personal/user/_layouts/15/stream.aspx?id=%2Fpersonal%2Fuser%2FDocuments%2FLecture%20%2B%20Notes.mkv&tempauth=secret")!
        let stream = StreamingPolicy.nativeSharePointMediaURL(page)
        #expect(stream?.host == "school-my.sharepoint.com")
        #expect(stream?.path == "/personal/user/Documents/Lecture + Notes.mkv")
        #expect(stream?.query == nil)
        #expect(StreamingPolicy.nativeSharePointMediaURL(URL(string: "https://school.sharepoint.com.evil.example/stream.aspx?id=%2Fvideo.mkv")!) == nil)
        #expect(StreamingPolicy.nativeSharePointMediaURL(URL(string: "https://school.sharepoint.com/stream.aspx?id=https%3A%2F%2Fevil.example%2Fvideo.mkv")!) == nil)
        #expect(StreamingPolicy.nativeSharePointMediaURL(URL(string: "https://user:secret@school.sharepoint.com/stream.aspx?id=%2Fvideo.mkv")!) == nil)
    }
    @Test func videoIdentityIgnoresExpiringCredentials() {
        let a = URL(string: "https://school.sharepoint.com/stream.aspx?id=%2FDocs%2FLecture.mp4&tempauth=first")!
        let b = URL(string: "https://school.sharepoint.com/stream.aspx?tempauth=second&id=%2FDocs%2FLecture.mp4")!
        #expect(StreamingPolicy.stableVideoIdentity(a) == StreamingPolicy.stableVideoIdentity(b))
        #expect(!StreamingPolicy.stableVideoIdentity(a)!.contains("tempauth"))
        #expect(StreamingPolicy.stableVideoIdentity(URL(string: "https://school.sharepoint.com/")!) == nil)
    }
}

