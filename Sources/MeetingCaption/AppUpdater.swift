import AppKit
import Foundation
import Sparkle
import SwiftUI

/// Whether this build can run Sparkle, decided only from the bundle's own Info.plist.
/// A build without a feed (or run outside an .app bundle) keeps working with updates off.
enum UpdateAvailability: Equatable {
    case available(feedURL: URL)
    case unavailable(reason: String)
}

enum UpdateConfiguration {
    /// The only feed a release may use; build-meeting.sh and release.sh enforce the same pattern.
    static let releaseFeedPattern = #"^https://github\.com/[A-Za-z0-9-]+/[A-Za-z0-9_.-]*[A-Za-z0-9_-][A-Za-z0-9_.-]*/releases/latest/download/appcast\.xml$"#
    /// Loopback feeds, accepted only from bundles that build-meeting.sh's MEETINGCAPTION_TEST_*
    /// path marked with `localTestFeedKey` (and gave a separate bundle identifier).
    static let localTestFeedPattern = #"^http://(127\.0\.0\.1|localhost)(:[0-9]{1,5})?/[A-Za-z0-9_./-]+$"#
    static let localTestFeedKey = "MeetingCaptionLocalTestFeed"

    static func availability(info: [String: Any], bundleURL: URL) -> UpdateAvailability {
        guard bundleURL.pathExtension == "app" else {
            return .unavailable(reason: "앱 번들(MeetingCaption.app)로 실행할 때만 업데이트를 사용할 수 있습니다.")
        }
        let feed = (info["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !feed.isEmpty else {
            return .unavailable(reason: "이 빌드에는 업데이트 주소가 설정되어 있지 않아 업데이트를 확인할 수 없습니다. 배포용 빌드(MEETINGCAPTION_FEED_URL 지정)에서 사용할 수 있습니다.")
        }
        let isLocalTestBuild = info[localTestFeedKey] as? Bool == true
        guard matches(feed, releaseFeedPattern) || (isLocalTestBuild && matches(feed, localTestFeedPattern)),
              let url = URL(string: feed) else {
            return .unavailable(reason: "업데이트 주소가 공식 GitHub 릴리스 주소가 아니어서 업데이트를 확인하지 않습니다: \(feed)")
        }
        let key = (info["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard Data(base64Encoded: key)?.count == 32 else {
            return .unavailable(reason: "업데이트 서명 확인용 공개 키가 없어 업데이트를 확인하지 않습니다.")
        }
        return .available(feedURL: url)
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    static func versionText(info: [String: Any]) -> String {
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        guard let build = info["CFBundleVersion"] as? String, !build.isEmpty else { return short }
        return "\(short) (\(build))"
    }
}

/// Hands Sparkle the feed validated by `UpdateConfiguration`. Sparkle asks its delegate first;
/// otherwise a `SUFeedURL` user default (e.g. `defaults write … SUFeedURL …`) would override the
/// Info.plist feed and bypass that validation.
final class PinnedFeedUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    let feedURL: URL

    init(feedURL: URL) {
        self.feedURL = feedURL
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        feedURL.absoluteString
    }
}

/// Owns the single Sparkle updater for the process. Created on first use (the app's
/// command menu touches it at launch) so scheduled checks start with the app.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    let versionText: String
    private(set) var unavailableReason: String?
    @Published private(set) var canCheckForUpdates = false
    private let controller: SPUStandardUpdaterController?
    /// Sparkle keeps only a weak reference to its delegate.
    private let feedDelegate: PinnedFeedUpdaterDelegate?
    private var observations: [NSKeyValueObservation] = []

    var isAvailable: Bool { controller != nil }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// Sparkle's "automatically download and install on quit" setting.
    var automaticallyInstalls: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    var allowsAutomaticInstall: Bool { controller?.updater.allowsAutomaticUpdates ?? false }

    init(bundle: Bundle = .main) {
        let info = bundle.infoDictionary ?? [:]
        versionText = UpdateConfiguration.versionText(info: info)
        switch UpdateConfiguration.availability(info: info, bundleURL: bundle.bundleURL) {
        case .unavailable(let reason):
            controller = nil
            feedDelegate = nil
            unavailableReason = reason
        case .available(let feedURL):
            let delegate = PinnedFeedUpdaterDelegate(feedURL: feedURL)
            feedDelegate = delegate
            let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: nil)
            do {
                // Started directly (not via startUpdater) so a failure becomes a settings note
                // instead of a modal alert at launch.
                try controller.updater.start()
                self.controller = controller
            } catch {
                self.controller = nil
                unavailableReason = "업데이트 기능을 시작하지 못했습니다: \(error.localizedDescription)"
            }
        }
        guard let updater = controller?.updater else { return }
        canCheckForUpdates = updater.canCheckForUpdates
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
                DispatchQueue.main.async { self?.canCheckForUpdates = updater.canCheckForUpdates }
            },
            updater.observe(\.automaticallyChecksForUpdates) { [weak self] _, _ in
                DispatchQueue.main.async { self?.objectWillChange.send() }
            },
            updater.observe(\.automaticallyDownloadsUpdates) { [weak self] _, _ in
                DispatchQueue.main.async { self?.objectWillChange.send() }
            }
        ]
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

/// App-menu item "업데이트 확인…".
struct CheckForUpdatesCommand: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        Button("업데이트 확인…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}

/// Sidebar section "업데이트"; styled like the meeting sidebar's own sections.
struct UpdateSettingsSection: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("업데이트")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("현재 버전 \(updater.versionText)")
                .font(.callout)
            Button("업데이트 확인") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
            Toggle("자동으로 업데이트 확인", isOn: $updater.automaticallyChecks)
                .disabled(!updater.isAvailable)
            Toggle("업데이트 자동 다운로드·설치", isOn: $updater.automaticallyInstalls)
                .disabled(!updater.isAvailable || !updater.allowsAutomaticInstall || !updater.automaticallyChecks)
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var note: String {
        if let reason = updater.unavailableReason { return reason }
        return "새 버전은 GitHub 릴리스에서 확인합니다. 자동 설치를 켜면 새 버전을 미리 내려받아 앱을 종료할 때 설치하고, 기록 중에는 앱을 끄지 않습니다. 개발자 서명(EdDSA)이 확인된 업데이트만 설치됩니다."
    }
}
