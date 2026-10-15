import Foundation
import Testing
@testable import DiscordAccessKit

/// The update bridge's request rules. Vectors from Windows `UpdateBridge.RunOfflineTests`, with more of the same kind.
@Suite struct BridgeRequestTests {
    static let token = String(repeating: "5a", count: 24)
    static let port: UInt16 = 41_000

    static func header(_ target: String, method: String = "GET", version: String = "HTTP/1.1", extra: String = "") -> [UInt8] {
        Array((method + " " + target + " " + version + "\r\nHost: 127.0.0.1:" + String(port) + "\r\n" + extra + "\r\n").utf8)
    }

    static let mappings = [
        ("/updates/distributions/app/manifests/latest?channel=stable&platform=osx",
         "https://updates.discord.com/distributions/app/manifests/latest?channel=stable&platform=osx"),
        ("/updates/", "https://updates.discord.com/"),
        ("/legacy", "https://discord.com/api"),
        ("/legacy/updates/stable?platform=osx&version=0.0.415", "https://discord.com/api/updates/stable?platform=osx&version=0.0.415"),
        ("/legacy?platform=osx", "https://discord.com/api?platform=osx"),
        ("/download/stable.dl2.discordapp.net/apps/osx/0.0.416/Discord.zip", "https://stable.dl2.discordapp.net/apps/osx/0.0.416/Discord.zip"),
        ("/download/cdn.discordapp.com/assets/module.zip?x=1", "https://cdn.discordapp.com/assets/module.zip?x=1"),
        ("/download/DISCORD.COM/a%7Cb", "https://DISCORD.COM/a%7Cb"),
    ]

    @Test(arguments: mappings)
    func mapsAPathUnderTheTokenToADiscordAddress(path: String, address: String) throws {
        #expect(try BridgeRequest.target(path: "/" + Self.token + path, token: Self.token).absoluteString == address)
    }

    static let blockedPaths = [
        "/wrong/updates/", "/" + token + "/updates", "/" + token + "x/updates/", "/" + String(repeating: "a5", count: 24) + "/updates/",
        "/" + token + "/download/discord.com.evil.test/a", "/" + token + "/download/127.0.0.1/a", "/" + token + "/download/discord.com:444/a",
        "/" + token + "/download/a@discord.com/a", "/" + token + "/download/discord.com\\evil/a", "/" + token + "/updates/a#fragment",
        "/" + token + "/other/a", "/" + token + "/download//a", "/" + token + "/download/discord.com", "/" + token + "/download/example.com/a",
        "/" + token + "/download/discord-.com/a", "/" + token + "/legacyx", "/" + token + "/updates/\u{7F}", "/" + token + "/updates/a\u{E9}",
        "http://evil.test/" + token + "/updates/", "/" + token + "/updates/" + String(repeating: "a", count: 8192),
        "/" + token + "/download/discord.com./a", "/" + token + "/download/disc%6Frd.com/a", "/" + token + "/updates/a|b", "/" + token + "/updates/{a}",
    ]

    @Test(arguments: blockedPaths)
    func refusesAnyOtherPath(path: String) {
        #expect(throws: BridgeFailure.invalidData) { try BridgeRequest.target(path: path, token: Self.token) }
    }

    @Test func acceptsGetAndHeadWithTheirHostOnly() throws {
        let path = "/" + Self.token + "/updates/x"
        #expect(try BridgeRequest.parse(Self.header(path), port: Self.port, token: Self.token) ==
            BridgeRequest(method: "GET", target: URL(string: "https://updates.discord.com/x")!))
        #expect(try BridgeRequest.parse(Self.header(path, method: "HEAD"), port: Self.port, token: Self.token).method == "HEAD")
        #expect(try BridgeRequest.parse(Self.header(path, version: "HTTP/1.0"), port: Self.port, token: Self.token).method == "GET")
        let usual = "User-Agent: Discord-Updater/1\r\nAccept-Encoding: gzip\r\nContent-Length: 0\r\nX-Tab:\tvalue\r\n"
        #expect(try BridgeRequest.parse(Self.header(path, extra: usual), port: Self.port, token: Self.token).target.host == "updates.discord.com")
    }

    static let malformed: [String] = {
        let valid = String(decoding: header("/" + token + "/updates/"), as: UTF8.self)
        return [
            valid.replacingOccurrences(of: "GET ", with: "POST "), valid.replacingOccurrences(of: "GET ", with: "get "),
            valid.replacingOccurrences(of: "HTTP/1.1", with: "HTTP/2.0"), valid.replacingOccurrences(of: "127.0.0.1:", with: "localhost:"),
            valid.replacingOccurrences(of: "127.0.0.1:41000", with: "127.0.0.1:41001"),
            valid.replacingOccurrences(of: "\r\n\r\n", with: "\r\nContent-Length: 1\r\n\r\n"),
            valid.replacingOccurrences(of: "\r\n\r\n", with: "\r\nTransfer-Encoding: chunked\r\n\r\n"),
            valid.replacingOccurrences(of: "\r\n\r\n", with: "\r\nExpect: 100-continue\r\n\r\n"),
            valid.replacingOccurrences(of: "\r\n\r\n", with: "\r\nHost: discord.com\r\n\r\n"),
            valid.replacingOccurrences(of: "\r\n\r\n", with: "\r\nhost: 127.0.0.1:41000\r\n\r\n"),
            valid.replacingOccurrences(of: "\r\n\r\n", with: "\r\n Folded: bad\r\n\r\n"),
            valid.replacingOccurrences(of: "\r\n\r\n", with: "\r\nBad Name: x\r\n\r\n"),
            valid.replacingOccurrences(of: "\r\n\r\n", with: "\r\n: empty\r\n\r\n"),
            valid.replacingOccurrences(of: "\r\n\r\n", with: "\r\nX-Test: a\nb\r\n\r\n"),
            valid.replacingOccurrences(of: "\r\n\r\n", with: "\r\nX-Test: a\rb\r\n\r\n"),
            valid.replacingOccurrences(of: "\r\n\r\n", with: "\r\nAccept: x\r\naccept: y\r\n\r\n"),
            valid.replacingOccurrences(of: "GET /", with: "GET http://evil.test/"), valid.replacingOccurrences(of: "GET /", with: "GET  /"),
            valid.replacingOccurrences(of: " HTTP/1.1", with: " HTTP/1.1 extra"), "GET /" + token + "/updates/ HTTP/1.1\r\n\r\n",
            valid.replacingOccurrences(of: "\r\n\r\n", with: "\r\n"), "",
        ]
    }()

    @Test(arguments: malformed)
    func refusesAMalformedRequest(header: String) {
        #expect(throws: BridgeFailure.invalidData) { try BridgeRequest.parse(Array(header.utf8), port: Self.port, token: Self.token) }
    }

    @Test func refusesAHeaderOverTheLimitOrWithANonASCIIByte() {
        let long = Self.header("/" + Self.token + "/updates/", extra: "X-Long: " + String(repeating: "a", count: BridgeRequest.maxHeaderBytes) + "\r\n")
        #expect(throws: BridgeFailure.invalidData) { try BridgeRequest.parse(long, port: Self.port, token: Self.token) }
        var foreign = Self.header("/" + Self.token + "/updates/", extra: "X-Name: a\r\n")
        foreign[foreign.count - 5] = 0xC3
        #expect(throws: BridgeFailure.invalidData) { try BridgeRequest.parse(foreign, port: Self.port, token: Self.token) }
    }

    @Test func acceptsOnlyHTTPSAddressesOfAllowedDiscordHostsOnPort443() {
        for address in ["https://cdn.discordapp.com/a.zip?signature=fixture", "HTTPS://Updates.Discord.com/x", "https://discord.com:443/api",
                        "https://stable.dl2.discordapp.net/distro/app/stable/osx/universal/0.0.416/full.distro", "https://discord.com"] {
            #expect(BridgeRequest.allowedURL(address) != nil, "\(address)")
        }
        for address in ["http://discord.com/a", "https://evil.test/a", "https://discord.com.evil.test/a", "https://user@discord.com/a",
                        "https://@discord.com/a", "https://discord.com:8443/a", "https://discord.com/a#x", "https://discord.com/a#",
                        "https://discord.com/a\\b", "https://127.0.0.1/a", "https://discord.com/a b", "https://discord.com/a\r\nX: evil", "",
                        "https://", "ftp://discord.com/a", "https://discord.com/" + String(repeating: "a", count: 8192), "https://xn--dscord-.com/a",
                        "https://discord.com/\u{E9}", "https://discord.com./a", "https://disc%6Frd.com/a", "https://evil.test%2F.discord.com/a",
                        "https://[::1]/a", "https://discord.com/a|b", "https://discord.com/{a}", "https://discord.com/a^b", "https://discord.com/\"a\"",
                        "https://discord.com/<a>", "https://discord.com/a`b"] {
            #expect(BridgeRequest.allowedURL(address) == nil, "\(address)")
        }
    }
}
