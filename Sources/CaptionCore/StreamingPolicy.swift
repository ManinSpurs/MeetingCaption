import Foundation

public enum StreamingPolicy {
    public static func cachedRegionEnd(at time: Double, captions: [Caption]) -> Double? {
        guard time.isFinite, time >= 0 else { return nil }
        var start: Double?
        var end = 0.0
        for cue in captions.sorted(by: { $0.start < $1.start }) {
            if let regionStart = start, cue.start > end + 0.8 {
                if time >= max(0, regionStart - 0.25) && time <= end { return end }
                start = cue.start
                end = cue.end
            } else {
                if start == nil { start = cue.start }
                end = max(end, cue.end)
            }
        }
        if let start, time >= max(0, start - 0.25), time <= end { return end }
        return nil
    }

    public static func isMicrosoftVideoHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return ["sharepoint.com", "onedrive.com", "onedrive.live.com", "1drv.ms", "microsoft365.com", "office.com", "m365.cloud.microsoft", "onedrive.cloud.microsoft"].contains {
            host == $0 || host.hasSuffix("." + $0)
        }
    }

    public static func acceptsEntry(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil && isMicrosoftVideoHost(url.host) && !blocksNavigation(url)
    }

    public static func nativeSharePointMediaURL(_ page: URL) -> URL? {
        guard page.scheme?.lowercased() == "https", page.user == nil, page.password == nil,
              let host = page.host?.lowercased(), host.hasSuffix(".sharepoint.com"),
              let components = URLComponents(url: page, resolvingAgainstBaseURL: false),
              let path = components.queryItems?.first(where: { $0.name.lowercased() == "id" })?.value,
              path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("\n"), !path.contains("\r") else { return nil }
        var stream = URLComponents()
        stream.scheme = "https"; stream.host = host; stream.path = path
        guard let url = stream.url, ["mkv", "mp4", "mov", "m4v", "webm"].contains(url.pathExtension.lowercased()) else { return nil }
        return url
    }

    public static func acceptsWebEntry(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil && !blocksNavigation(url)
    }

    // This governs document navigation, not the media chunks fetched by the web player.
    public static func blocksNavigation(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        if ["download.aspx", "download", "downloadfile.aspx"].contains(url.lastPathComponent.lowercased()) { return true }
        if ["mp4", "mov", "mkv", "avi", "wmv", "webm", "m4v", "zip"].contains(url.pathExtension.lowercased()) { return true }
        if path.contains("/_api/") && path.contains("/content") { return true }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { item in
            let key = item.name.lowercased()
            let value = item.value?.lowercased() ?? ""
            return (key == "download" && ["1", "true", "yes"].contains(value)) ||
                (["action", "mode"].contains(key) && ["download", "saveas"].contains(value))
        } ?? false
    }

    public static func isAttachment(_ disposition: String?) -> Bool {
        disposition?.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment") == true
    }

    public static func stableVideoIdentity(_ url: URL) -> String? {
        guard isMicrosoftVideoHost(url.host), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        for key in ["id", "uniqueid", "sourcedoc", "docid", "resid"] {
            if let value = components.queryItems?.first(where: { $0.name.lowercased() == key })?.value, !value.isEmpty {
                // Keep the full file path case: distinct case-sensitive IDs must not collide.
                return (url.host?.lowercased() ?? "") + ":" + key + ":" + value
            }
        }
        return nil
    }
}
