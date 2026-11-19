import Foundation
import Sparkle
import Testing
@testable import MeetingCaption

struct UpdateConfigurationTests {
    private let app = URL(fileURLWithPath: "/Applications/MeetingCaption.app")
    private let key = Data(repeating: 7, count: 32).base64EncodedString()
    private let feed = "https://github.com/owner/repo/releases/latest/download/appcast.xml"
    private let notReleaseFeed = "공식 GitHub 릴리스 주소가 아니어서"

    private func availability(_ info: [String: Any], bundleURL: URL? = nil) -> UpdateAvailability {
        UpdateConfiguration.availability(info: info, bundleURL: bundleURL ?? app)
    }

    /// The note shown in settings, or nil when updates are available.
    private func unavailableReason(_ info: [String: Any], bundleURL: URL? = nil) -> String? {
        guard case .unavailable(let reason) = availability(info, bundleURL: bundleURL) else { return nil }
        return reason
    }

    @Test(arguments: [
        "https://github.com/owner/repo/releases/latest/download/appcast.xml",
        "https://github.com/my-org/Meeting_Caption.v2/releases/latest/download/appcast.xml",
        "https://github.com/owner/.github/releases/latest/download/appcast.xml"
    ])
    func githubReleaseFeedIsAvailable(feed: String) {
        #expect(availability(["SUFeedURL": feed, "SUPublicEDKey": key]) == .available(feedURL: URL(string: feed)!))
    }

    @Test func missingFeedDisablesUpdates() {
        for info: [String: Any] in [["SUPublicEDKey": key], ["SUFeedURL": "  ", "SUPublicEDKey": key]] {
            #expect(unavailableReason(info)?.contains("업데이트 주소가 설정되어 있지 않아") == true)
        }
    }

    @Test(arguments: [
        "http://example.com/appcast.xml",
        "ftp://example.com/appcast.xml",
        "not a url",
        "file:///tmp/appcast.xml",
        "https://example.com/appcast.xml",
        "http://github.com/owner/repo/releases/latest/download/appcast.xml",
        "https://github.com.evil.example/owner/repo/releases/latest/download/appcast.xml",
        "https://user@github.com/owner/repo/releases/latest/download/appcast.xml",
        "https://github.com:8443/owner/repo/releases/latest/download/appcast.xml",
        "https://github.com/owner/repo/releases/download/v1.5.0/appcast.xml",
        "https://github.com/owner/../releases/latest/download/appcast.xml",
        "https://github.com/owner/repo/releases/latest/download/appcast.xml?redirect=1",
        "http://127.0.0.1:8765/appcast.xml"
    ])
    func nonReleaseFeedIsRejected(feed: String) {
        #expect(unavailableReason(["SUFeedURL": feed, "SUPublicEDKey": key])?.contains(notReleaseFeed) == true)
    }

    @Test func loopbackFeedNeedsLocalTestBuildMarker() {
        let local = "http://127.0.0.1:8765/appcast.xml"
        let marked: [String: Any] = ["SUFeedURL": local, "SUPublicEDKey": key, UpdateConfiguration.localTestFeedKey: true]
        #expect(availability(marked) == .available(feedURL: URL(string: local)!))
        let unmarked: [String: Any] = ["SUFeedURL": local, "SUPublicEDKey": key, UpdateConfiguration.localTestFeedKey: false]
        #expect(unavailableReason(unmarked)?.contains(notReleaseFeed) == true)
    }

    @Test(arguments: [
        "http://example.com/appcast.xml",
        "http://127.0.0.1.evil.example/appcast.xml",
        "file:///tmp/appcast.xml",
        "https://example.com/appcast.xml"
    ])
    func localTestBuildStillRejectsNonLoopbackFeeds(feed: String) {
        let info: [String: Any] = ["SUFeedURL": feed, "SUPublicEDKey": key, UpdateConfiguration.localTestFeedKey: true]
        #expect(unavailableReason(info)?.contains(notReleaseFeed) == true)
    }

    @Test func missingOrMalformedKeyDisablesUpdates() {
        for info: [String: Any] in [["SUFeedURL": feed], ["SUFeedURL": feed, "SUPublicEDKey": "abc"]] {
            #expect(unavailableReason(info)?.contains("공개 키가 없어") == true)
        }
    }

    @Test func nonBundleExecutableDisablesUpdates() {
        let reason = unavailableReason(["SUFeedURL": feed, "SUPublicEDKey": key],
                                       bundleURL: URL(fileURLWithPath: "/tmp/.build/debug"))
        #expect(reason?.contains("앱 번들") == true)
    }

    /// Sparkle resolves `SUFeedURL` from user defaults first, then Info.plist; the pinned delegate
    /// must win over that lookup so a `defaults write … SUFeedURL …` cannot redirect updates.
    @MainActor @Test func pinnedDelegateFeedOverridesTheBundleFeed() throws {
        let other = "https://github.com/someone-else/repo/releases/latest/download/appcast.xml"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateConfigurationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Host.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "test.meetingcaption.pinnedfeed.\(UUID().uuidString)",
            "CFBundleName": "Host",
            "CFBundlePackageType": "APPL",
            "SUFeedURL": other
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: root.appendingPathComponent("Host.app")))
        let driver = SPUStandardUserDriver(hostBundle: bundle, delegate: nil)
        let pinned = URL(string: feed)!
        let delegate = PinnedFeedUpdaterDelegate(feedURL: pinned)

        let unpinned = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: nil)
        #expect(unpinned.feedURL == URL(string: other))
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: delegate)
        #expect(updater.feedURL == pinned)
    }

    @Test func versionText() {
        #expect(UpdateConfiguration.versionText(info: ["CFBundleShortVersionString": "1.4.0", "CFBundleVersion": "8"]) == "1.4.0 (8)")
        #expect(UpdateConfiguration.versionText(info: ["CFBundleShortVersionString": "1.4.0"]) == "1.4.0")
    }
}
