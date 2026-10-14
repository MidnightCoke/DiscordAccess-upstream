import Testing
@testable import DiscordAccessKit

/// Vectors from the Windows checks (`SecurityChecks.cs`, `MediaPolicyChecks.cs`, `ProxyDiagnosticsChecks.cs`); the
/// refusal categories are asserted for every vector, also where the Windows check only expects a refusal.
@Suite struct RequestPolicyTests {
    static let authorization = "Basic Zml4dHVyZS1vbmx5Om5vdC1hLXJlYWwtc2VjcmV0"
    static let upload = "discord-attachments-uploads-prd.storage.googleapis.com"

    /// `CONNECT` with a Host line and an old credential to drop (Windows `MediaPolicyChecks.Request`).
    static func connect(_ authority: String, host: String? = nil) -> String {
        "CONNECT " + authority + " HTTP/1.1\r\nHost: " + (host ?? authority) + "\r\nProxy-Authorization: Basic obsolete-fixture\r\n\r\n"
    }

    static func bare(_ authority: String) -> String {
        "CONNECT " + authority + " HTTP/1.1\r\n\r\n"
    }

    static func get(_ target: String, host: String, _ headers: String = "") -> String {
        "GET " + target + " HTTP/1.1\r\nHost: " + host + "\r\n" + headers + "\r\n"
    }

    /// `header` with its final CR LF replaced by this run's credential line and the blank line.
    static func credentialed(_ header: String, _ authorization: String = authorization) -> String {
        String(decoding: header.utf8.dropLast(2), as: UTF8.self) + "Proxy-Authorization: " + authorization + "\r\n\r\n"
    }

    static func failure(_ header: String) -> RequestFailure? {
        do {
            _ = try RequestPolicy.rewrite(header, authorization: authorization)
            return nil
        } catch {
            return error as? RequestFailure
        }
    }

    @Test(arguments: [
        "discord.com:443", "discord.gg:443", "discordapp.com:443", "discordapp.net:443", "discord.media:443", "discordcdn.com:443",
        "discordstatus.com:443", "discord.gift:443", "CDN.DISCORDAPP.COM:443", "gateway.discord.gg:443",
        "c-waw04-9501efbe.discord.media:2087", "c-fra07-7cbb2779.discord.media:2087", "discord.media:2087",
        "C-WAW04-9501EFBE.DISCORD.MEDIA:2087", "a.b.discord.media:2087", "c-waw05-eaef8be4.discord.media:443", "cdn.discordapp.com:443",
        "c-waw04-9501efbe.discord.media:2083", "c-fra07-7cbb2779.discord.media:2096", "c-waw04-9501efbe.discord.media:8443",
        "discord.media:1", "discord.media:80", "discord.media:2088", "discord.media:4430", "a.b.discord.media:50000",
        "discord.media:65535", upload + ":443", upload.uppercased() + ":443",
        "hcaptcha.com:443", "js.hcaptcha.com:443", "newassets.hcaptcha.com:443", "a.b.hcaptcha.com:443", "JS.HCAPTCHA.COM:443",
    ])
    func acceptsDiscordConnectTargetsAndReplacesTheCredential(authority: String) throws {
        let rewritten = try RequestPolicy.rewrite(Self.connect(authority), authorization: Self.authorization)
        #expect(rewritten == "CONNECT " + authority + " HTTP/1.1\r\nHost: " + authority + "\r\nProxy-Authorization: " + Self.authorization + "\r\n\r\n")
    }

    @Test func keepsOtherHeadersAndDropsEveryClientCredential() throws {
        let header = "CONNECT discord.com:443 HTTP/1.1\r\nHost: discord.com:443\r\nProxy-Authorization: Basic obsolete-fixture\r\n" +
            "pRoXy-AuThOrIzAtIoN: Bearer other-fixture\r\nUser-Agent: fixture\r\n\r\n"
        #expect(try RequestPolicy.rewrite(header, authorization: Self.authorization) ==
            "CONNECT discord.com:443 HTTP/1.1\r\nHost: discord.com:443\r\nUser-Agent: fixture\r\nProxy-Authorization: " + Self.authorization + "\r\n\r\n")
        let chromium = "CONNECT gateway.discord.gg:443 HTTP/1.1\r\nHost: gateway.discord.gg:443\r\nProxy-Connection: keep-alive\r\n" +
            "User-Agent: Mozilla/5.0 Chrome/138.0.0.0 Electron/37.0.0\r\n\r\n"
        #expect(try RequestPolicy.rewrite(chromium, authorization: "Basic fixture-only") == Self.credentialed(chromium, "Basic fixture-only"))
        let plain = Self.get("http://discord.com/", host: "discord.com", "proxy-authorization: Basic obsolete-fixture\r\nUser-Agent: fixture\r\n")
        #expect(try RequestPolicy.rewrite(plain, authorization: Self.authorization) ==
            "GET http://discord.com/ HTTP/1.1\r\nHost: discord.com\r\nUser-Agent: fixture\r\nProxy-Authorization: " + Self.authorization + "\r\n\r\n")
    }

    @Test(arguments: [
        get("http://discord.com:80/api/v10/gateway", host: "discord.com:80"),
        get("http://discord.com/api/v10/gateway", host: "discord.com"),
        get("http://discord.com/", host: "discord.com", "Connection: keep-alive\r\n"),
        get("http://discord.media/", host: "discord.media"),
        get("HTTP://DISCORD.COM/", host: "discord.com"),
        get("http://discord.com?query", host: "DISCORD.COM"),
        "HEAD http://discord.com/ HTTP/1.0\r\nHost: discord.com\r\n\r\n",
        "POST http://discord.com/api HTTP/1.1\r\nHost: discord.com\r\nContent-Length: 2\r\n\r\n",
        "CONNECT discord.com:443 HTTP/1.1\r\n\r\n",
        "CONNECT discord.com:443 HTTP/1.1\r\nUpgrade: websocket\r\n\r\n",
        "POST http://discord.com/api HTTP/1.1\r\nHost: discord.com\r\nTransfer-Encoding: chunked\r\n\r\n",
        "CONNECT discord.com:443 HTTP/1.1\r\nHost:\tdiscord.com:443 \t\r\n\r\n",
        "CONNECT discord.com:443 HTTP/1.1\r\nHost:discord.com:443\r\n\r\n",
    ])
    func acceptsPlainHTTPToDiscordAndConnectWithoutHost(header: String) throws {
        #expect(try RequestPolicy.rewrite(header, authorization: Self.authorization) == Self.credentialed(header))
    }

    static let refusals: [(String, RequestFailure)] = [
        // SecurityChecks.cs: host names and authorities.
        (bare("bad..discord.com:443"), RequestFailure.forbiddenHost), (bare(".discord.com:443"), .forbiddenHost),
        (bare("-bad.discord.com:443"), .forbiddenHost), (bare("bad-.discord.com:443"), .forbiddenHost),
        (bare(String(repeating: "a", count: 64) + ".discord.com:443"), .forbiddenHost),
        (bare(String(repeating: "a", count: 63) + "." + String(repeating: "b", count: 63) + "." + String(repeating: "c", count: 63) +
            "." + String(repeating: "d", count: 63) + ".discord.com:443"), .forbiddenHost),
        (bare("example.com:443"), .forbiddenHost), (bare("discord.com.evil.example:443"), .forbiddenHost),
        (bare("evildiscord.com:443"), .forbiddenHost), (bare("discordcom:443"), .forbiddenHost), (bare("127.0.0.1:443"), .forbiddenHost),
        (bare("2130706433:443"), .forbiddenHost), (bare("0x7f000001:443"), .forbiddenHost), (bare("[::1]:443"), .invalidTarget),
        (bare("[::ffff:127.0.0.1]:443"), .invalidTarget), (bare("user@discord.com:443"), .invalidTarget),
        (bare("user:pass@discord.com:443"), .invalidTarget), (bare("discord.com"), .invalidTarget), (bare("discord.com:80"), .invalidTarget),
        (bare("discord.com:444"), .invalidTarget), (bare("discord.com:0"), .invalidTarget), (bare("discord.com:65536"), .invalidTarget),
        (bare("discord.com:+443"), .invalidTarget), (bare("discord.com:-443"), .invalidTarget), (bare("discord.com:443:443"), .invalidTarget),
        (bare("discord.com:443/"), .invalidTarget), (bare("discord.com:443/path"), .invalidTarget), (bare("discord.com:443?query"), .invalidTarget),
        (bare("discord.com:443#fragment"), .invalidTarget), (bare("discord.com\\@example.com:443"), .invalidTarget),
        (bare("discord.com%2eexample.com:443"), .invalidTarget),
        // SecurityChecks.cs: plain HTTP targets and upgrades.
        (get("http://user:pass@discord.com/api", host: "discord.com"), .invalidTarget), (get("http://example.com/", host: "discord.com"), .forbiddenHost),
        (get("http://discord.com:8080/", host: "discord.com:8080"), .invalidTarget), (get("/api/v10/gateway", host: "discord.com"), .invalidTarget),
        (get("ftp://discord.com/file", host: "discord.com"), .invalidTarget),
        (get("http://discord.com/", host: "discord.com", "Connection: Upgrade\r\nUpgrade: websocket\r\n"), .unsupportedUpgrade),
        (get("http://discord.com/", host: "discord.com", "connection: keep-alive, uPgRaDe\r\nupgrade: h2c\r\n"), .unsupportedUpgrade),
        (get("http://discord.com/", host: "discord.com", "Connection: keep-alive\r\nConnection: upgrade\r\n"), .unsupportedUpgrade),
        (get("http://discord.com/", host: "discord.com", "Upgrade: websocket\r\n"), .unsupportedUpgrade),
        (get("http://discord.com/", host: "discord.com", "Upgrade:\r\n"), .unsupportedUpgrade),
        (get("http://discord.com/", host: "discord.com", "Proxy-Connection: keep-alive, Upgrade\r\n"), .unsupportedUpgrade),
        // SecurityChecks.cs: Host lines, header syntax, framing and size.
        ("CONNECT discord.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n", .conflictingHost),
        ("CONNECT discord.com:443 HTTP/1.1\r\nHost: discord.com:443\r\nhost: example.com:443\r\n\r\n", .conflictingHost),
        ("CONNECT discord.com:443 HTTP/1.1\r\nHost: discord.com:443\r\n continued: forbidden\r\n\r\n", .invalidHeader),
        ("CONNECT discord.com:443 HTTP/1.1\r\nHost: discord.com:443\r\n\tcontinued: forbidden\r\n\r\n", .invalidHeader),
        ("CONNECT discord.com:443 HTTP/1.1\r\nHost : discord.com:443\r\n\r\n", .invalidHeader),
        ("CONNECT discord.com:443 HTTP/1.1\r\nBad(Name): fixture\r\n\r\n", .invalidHeader),
        ("CONNECT discord.com:443 HTTP/1.1\r\nMalformed\r\n\r\n", .invalidHeader),
        ("CONNECT discord.com:443 HTTP/1.1\r\nX-Fixture: invalid\0value\r\n\r\n", .invalidHeader),
        ("CONNECT discord.com:443 HTTP/1.1\nHost: discord.com:443\n\n", .invalidHeader),
        ("CONNECT discord.com:443 HTTP/1.1\rHost: discord.com:443\r\r", .invalidHeader),
        ("CONNECT  discord.com:443 HTTP/1.1\r\n\r\n", .invalidRequestLine), ("CONNECT discord.com:443 HTTP/1.1evil\r\n\r\n", .invalidRequestLine),
        ("CONNECT discord.com:443 HTTP/2.0\r\n\r\n", .invalidRequestLine),
        ("TRACE http://discord.com/ HTTP/1.1\r\nHost: discord.com\r\n\r\n", .unsupportedMethod),
        ("POST http://discord.com/ HTTP/1.1\r\nHost: discord.com\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n", .invalidFraming),
        ("POST http://discord.com/ HTTP/1.1\r\nHost: discord.com\r\nContent-Length: 1\r\ncontent-length: 2\r\n\r\n", .invalidFraming),
        ("CONNECT discord.com:443 HTTP/1.1\r\nX-Fixture: " + String(repeating: "a", count: 32768) + "\r\n\r\n", .invalidHeader),
        ("", .invalidHeader), ("CONNECT discord.com:443 HTTP/1.1\r\n", .invalidHeader),
        // MediaPolicyChecks.cs: media ports belong to discord.media only.
        (connect("example.com:2087"), .forbiddenHost), (connect("discord.media.evil.example:2087"), .forbiddenHost),
        (connect("evildiscord.media:2087"), .forbiddenHost), (connect("discord-media:2087"), .forbiddenHost),
        (connect(".discord.media:2087"), .forbiddenHost), (connect("bad..discord.media:2087"), .forbiddenHost),
        (connect("-bad.discord.media:2087"), .forbiddenHost), (connect("bad-.discord.media:2087"), .forbiddenHost),
        (connect("discord.media.:2087"), .forbiddenHost), (connect(String(repeating: "a", count: 64) + ".discord.media:2087"), .forbiddenHost),
        (connect("127.0.0.1:2087"), .forbiddenHost), (connect("2130706433:2087"), .forbiddenHost), (connect("0x7f000001:2087"), .forbiddenHost),
        (connect("discord.com:2087"), .invalidTarget), (connect("cdn.discordapp.com:2087"), .invalidTarget),
        (connect("gateway.discord.gg:2087"), .invalidTarget), (connect("[::1]:2087"), .invalidTarget),
        (connect("[::ffff:127.0.0.1]:2087"), .invalidTarget), (connect("user@discord.media:2087"), .invalidTarget),
        (connect("user:pass@discord.media:2087"), .invalidTarget), (connect("discord.media%2eexample.com:2087"), .invalidTarget),
        (connect("discord.media\\@example.com:2087"), .invalidTarget), (connect("discord.media:2087/path"), .invalidTarget),
        (connect("discord.media:2087?secret"), .invalidTarget), (connect("discord.media:2087#fragment"), .invalidTarget),
        (connect("discord.media:2087:443"), .invalidTarget), (connect("discord.media:02087"), .invalidTarget),
        (connect("discord.media:+2087"), .invalidTarget), (connect("discord.media:-2087"), .invalidTarget),
        (connect("discord.media:2.087"), .invalidTarget), (connect("discord.media:0x827"), .invalidTarget),
        (connect("discord.media:0"), .invalidTarget), (connect("discord.media:65536"), .invalidTarget),
        (connect("discord.media:0443"), .invalidTarget), (connect("discord.media:0001"), .invalidTarget),
        (connect("discord.media:00000"), .invalidTarget), (connect("discord.media:655350"), .invalidTarget),
        (connect("discord.media:2147483647"), .invalidTarget), (connect("discord.media:"), .invalidTarget),
        (connect("discord.media: 2083"), .invalidRequestLine), (connect("discord.media:2096\n"), .invalidHeader),
        (connect("c-waw04-9501efbe.discord.media:2087", host: "c-waw04-9501efbe.discord.media:443"), .conflictingHost),
        (connect("c-waw04-9501efbe.discord.media:2087", host: "evil.example:2087"), .conflictingHost),
        (get("http://discord.media:2087/", host: "discord.media:2087"), .invalidTarget),
        ("CONNECT discord.media:2087 HTTP/1.1\r\nHost: discord.media:2087\r\nHost: discord.media:2087\r\n\r\n", .conflictingHost),
        // MediaPolicyChecks.cs: the upload bucket is one exact HTTPS host.
        (connect(upload + ":2087"), .forbiddenHost), (connect(upload + ":80"), .forbiddenHost), (connect(upload + ":2083"), .forbiddenHost),
        (connect(upload + ":2096"), .forbiddenHost), (connect(upload + ":8443"), .forbiddenHost), (connect(upload + ":65535"), .forbiddenHost),
        (connect(upload + ".evil:443"), .forbiddenHost),
        (connect("sub." + upload + ":443"), .forbiddenHost), (connect(upload + ".evil.example:443"), .forbiddenHost),
        (connect("evil" + upload + ":443"), .forbiddenHost), (connect("storage.googleapis.com:443"), .forbiddenHost),
        (connect("other-bucket.storage.googleapis.com:443"), .forbiddenHost), (connect(upload + ".:443"), .forbiddenHost),
        (connect("user@" + upload + ":443"), .invalidTarget),
        ("PUT http://" + upload + "/file HTTP/1.1\r\nHost: " + upload + "\r\n\r\n", .forbiddenHost),
        ("PUT http://" + upload + ":443/file HTTP/1.1\r\nHost: " + upload + ":443\r\n\r\n", .invalidTarget),
        (connect(upload + ":443", host: "other-bucket.storage.googleapis.com:443"), .conflictingHost),
        // MediaPolicyChecks.cs: hCaptcha is HTTPS on 443 only.
        (connect("hcaptcha.com:80"), .forbiddenHost), (connect("js.hcaptcha.com:80"), .forbiddenHost), (connect("js.hcaptcha.com:2083"), .forbiddenHost),
        (connect("js.hcaptcha.com:2087"), .forbiddenHost), (connect("js.hcaptcha.com:2096"), .forbiddenHost), (connect("js.hcaptcha.com:8443"), .forbiddenHost),
        (connect("js.hcaptcha.com:65535"), .forbiddenHost),
        (connect("js.hcaptcha.com:0443"), .invalidTarget), (connect("hcaptcha.com.evil.example:443"), .forbiddenHost),
        (connect("evilhcaptcha.com:443"), .forbiddenHost), (connect("hcaptcha-com:443"), .forbiddenHost), (connect("captcha.com:443"), .forbiddenHost),
        (connect("hcaptcha.com.:443"), .forbiddenHost), (connect(".hcaptcha.com:443"), .forbiddenHost), (connect("bad..hcaptcha.com:443"), .forbiddenHost),
        (connect("-bad.hcaptcha.com:443"), .forbiddenHost), (connect("bad-.hcaptcha.com:443"), .forbiddenHost),
        (connect(String(repeating: "a", count: 64) + ".hcaptcha.com:443"), .forbiddenHost), (connect("user@hcaptcha.com:443"), .invalidTarget),
        (connect("hcaptcha.com%2eevil.example:443"), .invalidTarget), (connect("hcaptcha.com\\@evil.example:443"), .invalidTarget),
        (connect("hcaptcha.com:443/path"), .invalidTarget), (get("http://hcaptcha.com/", host: "hcaptcha.com"), .forbiddenHost),
        (get("http://hcaptcha.com:443/", host: "hcaptcha.com:443"), .invalidTarget), (get("http://js.hcaptcha.com/", host: "js.hcaptcha.com"), .forbiddenHost),
        (get("http://js.hcaptcha.com:443/", host: "js.hcaptcha.com:443"), .invalidTarget),
        (connect("js.hcaptcha.com:443", host: "hcaptcha.com:443"), .conflictingHost),
        (connect("js.hcaptcha.com:443", host: "js.hcaptcha.com:80"), .conflictingHost),
        (connect("js.hcaptcha.com:443", host: "evil.example:443"), .conflictingHost),
        // ProxyDiagnosticsChecks.cs, where Windows asserts the category itself.
        ("CONNECT telemetry.example.invalid:443 HTTP/1.1\r\nHost: telemetry.example.invalid:443\r\nAuthorization: Bearer PRIVATE_FIXTURE\r\n\r\n",
         .forbiddenHost),
        ("CONNECT discord.com:443 HTTP/1.1\r\nHost: conflict.example.invalid\r\n\r\n", .conflictingHost),
        (get("http://discord.com/PRIVATE_FIXTURE?token=PRIVATE_FIXTURE", host: "discord.com", "Bad(Name): PRIVATE_FIXTURE\r\n"), .invalidHeader),
        (get("http://PRIVATE_FIXTURE@discord.com/private", host: "discord.com"), .invalidTarget),
        (bare("discord.com:443/PRIVATE_FIXTURE"), .invalidTarget), (get("/PRIVATE_FIXTURE?token=PRIVATE_FIXTURE", host: "discord.com"), .invalidTarget),
        // macOS only: stricter than the Windows `Uri` parsing, and framing details Windows does not pin.
        (get("http://discord.com:/", host: "discord.com"), .invalidTarget), (get("http://discord.com:080/", host: "discord.com"), .invalidTarget),
        (get("http://%64iscord.com/", host: "discord.com"), .invalidTarget), (get("http://discord.com/#top", host: "discord.com"), .invalidTarget),
        (get("http://[::1]/", host: "[::1]"), .invalidTarget), (get("http://discord.com/\u{1}", host: "discord.com"), .invalidTarget),
        (get("http://discord.com./", host: "discord.com."), .forbiddenHost), (get("http://discord.com/", host: "discord.com", "Content-Length: +1\r\n"), .invalidFraming),
        (get("http://discord.com.evil.example/", host: "discord.com.evil.example"), .forbiddenHost),
        (get("http://discord.com@evil.example/", host: "evil.example"), .invalidTarget),
        (get("http://discord.com/", host: "discord.com", "Content-Length: 99999999999999999999\r\n"), .invalidFraming),
        (get("http://discord.com/", host: "discord.com", "Content-Length:\r\n"), .invalidFraming),
        (get("http://discord.com/", host: "discord.com", "Transfer-Encoding: chunked\r\ntransfer-encoding: chunked\r\n"), .invalidFraming),
        ("GET http://discord.com/ HTTP/1.1\r\n\r\n", .conflictingHost), ("connect discord.com:443 HTTP/1.1\r\n\r\n", .unsupportedMethod),
        ("CONNECT discord.com:443 http/1.1\r\n\r\n", .invalidRequestLine), ("CONNECT discord.com:443 HTTP/1.1\r\nX-Fixture: \u{7f}\r\n\r\n", .invalidHeader),
        ("CONNECT discord.com:443 HTTP/1.1\r\nX-Fixture: café\r\n\r\n", .invalidHeader),
    ] + ["discord.com", "discord.gg", "discordapp.com", "discordapp.net", "discordcdn.com", "discordstatus.com", "discord.gift"].flatMap { host in
        // MediaPolicyChecks.cs: media ports never extend to the other Discord domains.
        ["2083", "2096", "8443", "65535"].map { (connect(host + ":" + $0), RequestFailure.invalidTarget) }
    }

    @Test(arguments: refusals)
    func refusesWithTheWindowsCategory(header: String, expected: RequestFailure) {
        #expect(Self.failure(header) == expected)
    }

    /// No allowed name can be an `inet_aton` literal (each ends in a label that starts with a letter), so this check never
    /// changes a `rewrite` outcome; it is tested directly.
    @Test func validatesDNSHostsLikeWindows() throws {
        let labels = [String(repeating: "a", count: 63), String(repeating: "b", count: 63), String(repeating: "c", count: 63)]
        let longest = (labels + [String(repeating: "d", count: 49), "discord.com"]).joined(separator: ".")
        let tooLong = (labels + [String(repeating: "d", count: 50), "discord.com"]).joined(separator: ".")
        #expect(longest.utf8.count == 253 && tooLong.utf8.count == 254)
        #expect(try RequestPolicy.rewrite(Self.bare(longest + ":443"), authorization: "x").hasPrefix("CONNECT " + longest + ":443 "))
        #expect(Self.failure(Self.bare(tooLong + ":443")) == .forbiddenHost)
        #expect(RequestPolicy.validDNSHost(String(repeating: "a", count: 63) + ".discord.com"))
        #expect(!RequestPolicy.validDNSHost(String(repeating: "a", count: 64) + ".discord.com"))
        for literal in ["127.0.0.1", "2130706433", "0x7f000001", "127.1"] {
            #expect(!RequestPolicy.validDNSHost(literal), "\(literal)")
        }
    }

    @Test func limitsTheHeaderTo32KiB() throws {
        let start = "CONNECT discord.com:443 HTTP/1.1\r\nX-Fixture: "
        let fill = String(repeating: "a", count: RequestPolicy.maxHeaderLength - start.utf8.count - 4)
        #expect(try RequestPolicy.rewrite(start + fill + "\r\n\r\n", authorization: "x").hasPrefix(start + fill + "\r\n"))
        #expect(Self.failure(start + fill + "a\r\n\r\n") == .invalidHeader)
    }

    @Test func refusalsCarryTheWindowsCategoryNames() {
        let failures: [RequestFailure] = [.invalidHeader, .invalidRequestLine, .invalidTarget, .unsupportedMethod, .forbiddenHost, .conflictingHost,
                                          .invalidFraming, .unsupportedUpgrade]
        #expect(failures.map(\.rawValue) == ["InvalidHeader", "InvalidRequestLine", "InvalidTarget", "UnsupportedMethod", "ForbiddenHost",
                                             "ConflictingHost", "InvalidFraming", "UnsupportedUpgrade"])
    }
}
