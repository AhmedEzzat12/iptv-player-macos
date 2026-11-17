import Foundation
import Testing
@testable import TunerCore

@Suite struct PlaylistShareTests {
    static let token = "AbCdEfGhIjKlMnOpQrStUv"

    @Test func acceptsTheTVsCode() {
        #expect(PlaylistShare.receiverURL("http://192.168.1.9:8790/\(Self.token)")?.absoluteString
            == "http://192.168.1.9:8790/\(Self.token)")
        // Typed without the scheme, with stray spaces or a trailing slash.
        #expect(PlaylistShare.receiverURL("  10.0.0.4:8790/\(Self.token)/ ") != nil)
        #expect(PlaylistShare.receiverURL("http://172.20.3.1:40000/\(Self.token)") != nil)
    }

    @Test func refusesAnythingThatIsntALocalTV() {
        let rejected = [
            "https://192.168.1.9:8790/\(Self.token)",          // the TV serves plain HTTP only
            "http://example.com/\(Self.token)",                // not a LAN address
            "http://8.8.8.8:8790/\(Self.token)",               // public IP
            "http://172.32.0.1:8790/\(Self.token)",            // outside 172.16/12
            "http://192.168.1.9:8790/short",                   // wrong token length
            "http://192.168.1.9:8790/\(Self.token)?x=1",       // extra parts
            "http://user@192.168.1.9:8790/\(Self.token)",
            "http://192.168.1.9:8790/a/\(Self.token)",
            "http://192.168.1.999:8790/\(Self.token)",
            "",
        ]
        for text in rejected { #expect(PlaylistShare.receiverURL(text) == nil, "\(text)") }
    }

    @Test func payloadMatchesWhatTheTVReads() throws {
        let source = Source(name: "Home", kind: .xtream, url: "http://panel.example:8080", username: "u", password: "p",
                            backupURLs: ["http://backup.example"])
        let request = try PlaylistShare.request(SharedPlaylist(source: source), to: URL(string: "http://192.168.1.9:8790/\(Self.token)")!)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let json = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect(json["version"] as? Int == 1)
        #expect(json["kind"] as? String == "xtream")
        #expect(json["url"] as? String == "http://panel.example:8080")
        #expect(json["username"] as? String == "u")
        #expect(json["password"] as? String == "p")
        #expect(json["includeVOD"] as? Bool == true)
        #expect(json["backupURLs"] as? [String] == ["http://backup.example"])
        #expect(json["mac"] == nil)
    }

    @Test func localFilesCantBeSent() async {
        let source = Source(name: "File", kind: .m3u, url: "file:///Users/me/list.m3u")
        #expect(!PlaylistShare.canShare(source))
        await #expect(throws: PlaylistShare.ShareError.localFile) {
            try await PlaylistShare.send(source, to: URL(string: "http://192.168.1.9:8790/\(Self.token)")!)
        }
    }

    @Test func reportsTheTVsAnswer() async throws {
        let server = StubHTTPServer()
        defer { server.shutDown() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let source = Source(name: "List", kind: .m3u, url: "http://lists.example/a.m3u")
        server.serve("/ok", .init(body: Data(#"{"ok":true}"#.utf8), contentType: "application/json", supportsRange: false))
        server.serve("/used", .init(body: Data(), status: 404))
        server.serve("/bad", .init(body: Data(), status: 400))

        try await PlaylistShare.send(source, to: server.url("/ok"), session: session)
        await #expect(throws: PlaylistShare.ShareError.expired) {
            try await PlaylistShare.send(source, to: server.url("/used"), session: session)
        }
        await #expect(throws: PlaylistShare.ShareError.rejected(400)) {
            try await PlaylistShare.send(source, to: server.url("/bad"), session: session)
        }
    }
}
