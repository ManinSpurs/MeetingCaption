import Foundation
import Testing
@testable import CaptionCore

@Suite("CloudPath")
struct CloudPathTests {
    @Test func cloudPathsRetainFileNamesAndStayInSite() throws {
        let site = try #require(CloudPath.site(from: URL(string: "https://school.sharepoint.com/personal/test_user/_layouts/15/onedrive.aspx")!))
        let path = "/personal/test_user/Documents/일본어 # 100% O'Brien +/ep01.mkv"
        let media = try #require(CloudPath.media(site: site, path: path))
        #expect(media.path == path)
        let endpoint = try #require(CloudPath.folderQuery((path as NSString).deletingLastPathComponent, kind: "Files"))
        #expect(endpoint.contains("%23")); #expect(endpoint.contains("%25"))
        #expect(URLComponents(string: endpoint)?.fragment == nil)
        #expect(URLComponents(string: endpoint)!.path.contains("O''Brien"))
        #expect(CloudPath.media(site: site, path: "/personal/other/Documents/a.mkv") == nil)
        #expect(CloudPath.media(site: site, path: "/personal/test_user/../other/a.mkv") == nil)
        #expect(CloudPath.site(from: URL(string: "https://school.sharepoint.com.attacker.test/personal/x")!) == nil)
        #expect(CloudPath.site(from: URL(string: "https://user:pass@school.sharepoint.com/personal/x")!) == nil)
    }
}

