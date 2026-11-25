import Foundation
import Testing
@testable import TunerCore

@Suite("iCloud sync: diagnostics")
struct CloudSyncDiagnosticsTests {
    func xtream(_ id: String, _ name: String, url: String, user: String) -> Source {
        Source(id: id, name: name, kind: .xtream, url: url, username: user, password: "pw")
    }

    @Test func sameAccountWithTwoServersIsReported() {
        let notices = CloudSyncDiagnostics.duplicatePlaylistNotices([
            xtream("S1", "Provider", url: "http://a.example.com:8080", user: "Ahmed"),
            xtream("S2", "Provider (iPhone)", url: "http://b.example.com:8080", user: "ahmed "),
        ])
        #expect(notices.count == 1)
        #expect(notices[0].contains("“Provider”") && notices[0].contains("“Provider (iPhone)”"))
        // Never names the server.
        #expect(!notices[0].contains("example.com"))
    }

    @Test func theSameServerOrOtherAccountsAreFine() {
        #expect(CloudSyncDiagnostics.duplicatePlaylistNotices([
            xtream("S1", "A", url: "http://a.example.com:8080", user: "ahmed"),
            xtream("S2", "B", url: "HTTP://A.example.com:8080/", user: "ahmed"),
            xtream("S3", "C", url: "http://b.example.com", user: "someone"),
            Source(id: "S4", name: "List", kind: .m3u, url: "http://lists.example.com/x.m3u"),
        ]).isEmpty)
    }
}
