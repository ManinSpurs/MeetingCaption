import Foundation

public enum CloudPath {
    public static let videoExtensions: Set<String> = ["mkv", "mp4", "mov", "m4v", "webm", "avi", "wmv", "m2ts", "ts", "mpg", "mpeg"]
    public static func site(from page: URL) -> URL? {
        guard page.scheme == "https", page.user == nil, page.password == nil,
              let host = page.host, host.lowercased().hasSuffix(".sharepoint.com") else { return nil }
        let parts = page.path.split(separator: "/")
        guard parts.count >= 2, ["personal", "sites", "teams"].contains(String(parts[0])) else { return nil }
        var c = URLComponents(); c.scheme = "https"; c.host = host; c.path = "/" + parts.prefix(2).joined(separator: "/")
        return c.url
    }
    public static func media(site: URL, path: String) -> URL? {
        guard let clean = self.site(from: site), clean == site,
              path.hasPrefix(site.path + "/"), !path.contains("\r"), !path.contains("\n"),
              !path.split(separator: "/").contains(".."),
              videoExtensions.contains((path as NSString).pathExtension.lowercased()) else { return nil }
        var c = URLComponents(url: site, resolvingAgainstBaseURL: false)!
        c.path = path; c.query = nil; c.fragment = nil
        return c.url
    }
    public static func folderQuery(_ path: String, kind: String) -> String? {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("\r"), !path.contains("\n"),
              !path.split(separator: "/").contains(".."), ["Files", "Folders"].contains(kind) else { return nil }
        let quoted = path.replacingOccurrences(of: "'", with: "''")
        let select = kind == "Files" ? "Name,ServerRelativeUrl,Length" : "Name,ServerRelativeUrl"
        var c = URLComponents(); c.path = "/_api/web/GetFolderByServerRelativePath(decodedurl='\(quoted)')/\(kind)"
        c.queryItems = [URLQueryItem(name: "$select", value: select), URLQueryItem(name: "$top", value: "500")]
        return c.string
    }
}
