import Darwin
import Foundation
import Testing
@testable import DiscordAccessKit

/// The HTTPS checks against a loopback stand-in for the proxy (Windows `FixtureResponse`). Plain
/// `http://fixture.invalid/...` targets reach the stand-in in absolute form and are answered there; the `.invalid` name
/// never resolves, so nothing leaves the machine. (discord.com itself is on the HSTS preload list, so URLSession would
/// always tunnel it.)
@Suite struct ConnectivityProbeTests {
    typealias Collected = ProxyGateTests.Collected
    static let gateway = URL(string: "http://fixture.invalid/api/v10/gateway")!
    static let updates = URL(string: "http://fixture.invalid/updates/")!
    static let validGateway = Array("{\"url\":\"wss://gateway.discord.gg\"}".utf8)

    /// Answers up to `connections` connections, one after another: each request head is recorded and answered with
    /// `respond`'s bytes, then the connection closes, or with `holdsOpen` stays open until the client closes. For nil it
    /// says nothing and waits for the client to close.
    final class FixtureProxy {
        let listener: TCPListener
        let heads = Collected<String>()
        private let served = DispatchGroup()

        var port: UInt16 { listener.port }

        init(connections: Int = 1, holdsOpen: Bool = false, respond: @escaping (String) -> [UInt8]?) throws {
            listener = try TCPListener()
            let (listener, heads, served) = (listener, heads, served)
            served.enter()
            Thread {
                defer { served.leave() }
                for _ in 0..<connections {
                    guard let client = try? listener.acceptClient().descriptor else { return }
                    var timeout = timeval(tv_sec: 10, tv_usec: 0)
                    var noSignal: Int32 = 1
                    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                    let head = FixtureProxy.readHead(client)
                    heads.append(head)
                    let bytes = respond(head)
                    if let bytes { _ = try? RelayTests.send(client, bytes) }
                    if bytes == nil || holdsOpen {
                        var byte: UInt8 = 0
                        while read(client, &byte, 1) > 0 {}
                    }
                    close(client)
                }
            }.start()
        }

        /// Waits until every connection was served, at most 15 seconds.
        func finished() -> Bool { served.wait(timeout: .now() + 15) == .success }

        static func readHead(_ descriptor: Int32) -> String {
            var bytes: [UInt8] = []
            var byte: UInt8 = 0
            while bytes.count < 16384, read(descriptor, &byte, 1) == 1 {
                bytes.append(byte)
                if bytes.suffix(4).elementsEqual([13, 10, 13, 10]) { break }
            }
            return String(decoding: bytes, as: UTF8.self)
        }

        static func response(_ status: Int, contentType: String? = "application/json", body: [UInt8] = [], length: Bool = true,
                             extra: String = "") -> [UInt8] {
            var head = "HTTP/1.1 " + String(status) + " Fixture\r\n"
            if let contentType { head += "Content-Type: " + contentType + "\r\n" }
            if length { head += "Content-Length: " + String(body.count) + "\r\n" }
            return Array((head + extra + "Connection: close\r\n\r\n").utf8) + body
        }
    }

    /// A port in a range the system never hands out on its own, where nothing listens any more.
    static func refusedPort(in range: Range<UInt16>) throws -> UInt16 {
        for candidate in range {
            guard let holder = try? LoopbackSocketTests.boundSocket(port: candidate) else { continue }
            close(holder.descriptor)
            return holder.port
        }
        throw POSIXError(.EADDRINUSE)
    }

    static func failure(_ body: () throws -> Void) -> ConnectivityFailure? {
        do {
            try body()
            return nil
        } catch {
            return error as? ConnectivityFailure
        }
    }

    /// The fields of a request head by lower-case name.
    static func fields(_ head: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return fields
    }

    /// Only fixed values leave this process: no languages, agent string, cookie or credential of this Mac.
    @Test func acceptsTheGatewayAddressAndSendsOnlyAFixedRequest() throws {
        let proxy = try FixtureProxy { _ in FixtureProxy.response(200, body: Self.validGateway) }
        try ConnectivityProbe.checkGateway(url: Self.gateway, proxyPort: proxy.port, cancel: Cancellation())
        #expect(proxy.finished())
        let head = try #require(proxy.heads.all.first)
        #expect(head.hasPrefix("GET http://fixture.invalid/api/v10/gateway HTTP/1.1\r\n"))
        let fields = Self.fields(head)
        #expect(Set(fields.keys).isSubset(of: ["host", "accept", "user-agent", "accept-language", "accept-encoding", "pragma", "connection",
                                               "proxy-connection"]))
        #expect(fields["host"] == "fixture.invalid" && fields["accept"] == "application/json" && (fields["pragma"] ?? "no-cache") == "no-cache")
        #expect(fields["user-agent"] == "DiscordAccess/3 (connectivity check)" && fields["accept-language"] == "en" && fields["accept-encoding"] == "identity")
    }

    /// How the page of an error answer arrives.
    enum ErrorPage: CaseIterable {
        /// Over 16 KiB, with its length announced or not.
        case announcedOverLimit, unannouncedOverLimit
        /// The connection closes before the announced length arrived.
        case cutOff
        /// The announced length never arrives; the connection stays open.
        case held
    }

    /// The status counts as it arrives (Windows reads the body only for a 200): a rate limit stays a rate limit however
    /// its page arrives, so selection stops.
    @Test(arguments: ErrorPage.allCases)
    func keepsTheStatusOfAnErrorAnswerWhateverItsPage(page: ErrorPage) throws {
        let long = Array(repeating: UInt8(ascii: "x"), count: 20_000)
        let partial = FixtureProxy.response(429, contentType: "text/html", length: false, extra: "Content-Length: 1000\r\n") + Array("<html>".utf8)
        let answer = switch page {
        case .announcedOverLimit: FixtureProxy.response(429, contentType: "text/html", body: long)
        case .unannouncedOverLimit: FixtureProxy.response(429, contentType: "text/html", body: long, length: false)
        case .cutOff, .held: partial
        }
        let proxy = try FixtureProxy(holdsOpen: page == .held) { _ in answer }
        let failure = Self.failure {
            try ConnectivityProbe.checkGateway(url: Self.gateway, proxyPort: proxy.port, cancel: Cancellation(), deadline: 2)
        }
        #expect(failure == ConnectivityFailure(endpoint: .gateway, reason: .http, httpStatus: 429, responseKind: .html))
        #expect(proxy.finished())
    }

    /// No credential is ever offered: CFNetwork asks once more without one, and the 401 then stands.
    @Test func answersAnAuthenticationRequestWithoutCredentials() throws {
        let proxy = try FixtureProxy(connections: 2) { _ in
            FixtureProxy.response(401, contentType: "text/html", extra: "WWW-Authenticate: Basic realm=\"fixture\"\r\n")
        }
        let failure = Self.failure { try ConnectivityProbe.checkGateway(url: Self.gateway, proxyPort: proxy.port, cancel: Cancellation()) }
        #expect(failure == ConnectivityFailure(endpoint: .gateway, reason: .http, httpStatus: 401, responseKind: .html))
        #expect((1...2).contains(proxy.heads.all.count) && proxy.heads.all.allSatisfy { Self.fields($0)["authorization"] == nil })
    }

    /// URLSession's connection to the proxy is a socket of this process, so a real gate admits it through its diagnostic
    /// permission and forwards the request with the engine credential. The stand-in engine cannot speak TLS for
    /// discord.com, so the check itself fails afterwards; nothing leaves the machine.
    @Test func reachesTheEngineThroughARealGateAsThisProcess() throws {
        let received = Collected<[UInt8]>()
        let engine = try ProxyGateTests.FakeEngine(serve: { connection in
            received.append(ProxyGateTests.receiveHeader(connection) ?? [])
            _ = try? ProxyGateTests.send(connection, Array("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
            usleep(200_000)
        })
        let lines = ProxyGateTests.Lines()
        let gate = try ProxyGateTests.gate(engine, lines: lines)
        defer { gate.close() }
        #expect(throws: ConnectivityFailure.self) {
            try ConnectivityProbe.checkGateway(url: ConnectivityProbe.gatewayURL, proxyPort: gate.port, cancel: Cancellation(), deadline: 3)
        }
        let header = String(decoding: try #require(received.all.first), as: UTF8.self)
        #expect(header.hasPrefix("CONNECT discord.com:443 HTTP/1.1\r\n"))
        #expect(header.contains("\r\nProxy-Authorization: " + ProxyGateTests.authorization + "\r\n"))
        #expect(lines.contain("Owned request discord.com:443"))
    }

    static let statusFailures: [(Int, String?, String, ConnectivityFailure.ResponseKind)] = [
        (429, "text/html", "<html>SYNTHETIC_SECRET PRIVATE</html>", .html),
        (503, "application/json", "{\"secret\":\"SYNTHETIC_SECRET PRIVATE\"}", .json),
        (302, nil, "", .none),
    ]

    @Test(arguments: statusFailures)
    func reportsAnHTTPFailureWithItsStatusAndTypeOnly(status: Int, contentType: String?, body: String, kind: ConnectivityFailure.ResponseKind) throws {
        // A redirect is not followed: the stand-in sees a single request.
        let proxy = try FixtureProxy(connections: 2) { _ in
            FixtureProxy.response(status, contentType: contentType, body: Array(body.utf8), extra: "Location: http://fixture.invalid/PRIVATE\r\n")
        }
        let failure = Self.failure { try ConnectivityProbe.checkGateway(url: Self.gateway, proxyPort: proxy.port, cancel: Cancellation()) }
        #expect(failure == ConnectivityFailure(endpoint: .gateway, reason: .http, httpStatus: status, responseKind: kind))
        #expect(failure.map { !$0.message.contains("SYNTHETIC_SECRET") && !String(describing: $0).contains("PRIVATE") } == true)
        #expect(proxy.heads.all.count == 1)
    }

    @Test(arguments: [("application/json", "{\"url\":\"wss://SYNTHETIC_SECRET.invalid/\"}"), ("text/html", "<html>SYNTHETIC_SECRET</html>"),
                      ("application/json", "\u{FF}not utf-8")])
    func refusesAnAnswerThatIsNotTheGatewayAddress(contentType: String, body: String) throws {
        let bytes = body.hasPrefix("\u{FF}") ? [0xFF, 0xFE] + Array("{}".utf8) : Array(body.utf8)
        let proxy = try FixtureProxy { _ in FixtureProxy.response(200, contentType: contentType, body: bytes) }
        let failure = Self.failure { try ConnectivityProbe.checkGateway(url: Self.gateway, proxyPort: proxy.port, cancel: Cancellation()) }
        #expect(failure == ConnectivityFailure(endpoint: .gateway, reason: .invalidResponse))
    }

    /// The body may not exceed 16 KiB, whether the response announces its length or not.
    @Test(arguments: [true, false])
    func refusesAnAnswerOver16KiB(announced: Bool) throws {
        let body = Array(repeating: UInt8(ascii: "x"), count: ConnectivityProbe.maxResponseBytes + 1)
        let proxy = try FixtureProxy { _ in FixtureProxy.response(200, body: body, length: announced) }
        let failure = Self.failure { try ConnectivityProbe.checkGateway(url: Self.gateway, proxyPort: proxy.port, cancel: Cancellation()) }
        #expect(failure == ConnectivityFailure(endpoint: .gateway, reason: .responseTooLarge))
    }

    /// Nothing listens on the proxy port: the check fails at once and never connects directly instead.
    @Test func failsAtOnceWhenTheProxyRefuses() throws {
        let port = try Self.refusedPort(in: 23_000..<23_200)
        let started = Date()
        let failure = Self.failure { try ConnectivityProbe.checkGateway(url: Self.gateway, proxyPort: port, cancel: Cancellation()) }
        #expect(failure == ConnectivityFailure(endpoint: .gateway, reason: .connect))
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func endsAtItsDeadlineWhenTheAnswerDoesNotCome() throws {
        let proxy = try FixtureProxy { _ in nil }
        let started = Date()
        let failure = Self.failure {
            try ConnectivityProbe.checkGateway(url: Self.gateway, proxyPort: proxy.port, cancel: Cancellation(), deadline: 0.5)
        }
        #expect(failure == ConnectivityFailure(endpoint: .gateway, reason: .timeout))
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(proxy.finished())
    }

    /// Canceling ends a request in flight at once, as `CancellationError`; a canceled check contacts nobody.
    @Test func endsAtOnceWhenCanceled() throws {
        let cancel = Cancellation()
        let proxy = try FixtureProxy { _ in
            cancel.cancel()
            return nil
        }
        let started = Date()
        #expect(throws: CancellationError.self) { try ConnectivityProbe.checkGateway(url: Self.gateway, proxyPort: proxy.port, cancel: cancel) }
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(proxy.finished())
        let quiet = try FixtureProxy { _ in FixtureProxy.response(200, body: Self.validGateway) }
        #expect(throws: CancellationError.self) { try ConnectivityProbe.checkGateway(url: Self.gateway, proxyPort: quiet.port, cancel: cancel) }
        #expect(quiet.heads.all.isEmpty)
    }

    @Test func checksTheUpdateServerWithAHeadRequest() throws {
        // A HEAD answer may announce a length over the limit without a body; only its status counts.
        let accepted = try FixtureProxy(connections: 2) { head in
            head.hasPrefix("GET ") ? FixtureProxy.response(200, body: Self.validGateway)
                : FixtureProxy.response(404, contentType: "text/html", length: false, extra: "Content-Length: 20000\r\n")
        }
        try ConnectivityProbe.check(gateway: Self.gateway, updates: Self.updates, proxyPort: accepted.port, cancel: Cancellation())
        #expect(accepted.finished())
        #expect(accepted.heads.all.last?.hasPrefix("HEAD http://fixture.invalid/updates/ HTTP/1.1\r\n") == true)
        let refused = try FixtureProxy(connections: 2) { head in
            head.hasPrefix("GET ") ? FixtureProxy.response(200, body: Self.validGateway) : FixtureProxy.response(503, contentType: "text/html")
        }
        let failure = Self.failure { try ConnectivityProbe.check(gateway: Self.gateway, updates: Self.updates, proxyPort: refused.port, cancel: Cancellation()) }
        #expect(failure == ConnectivityFailure(endpoint: .updates, reason: .http, httpStatus: 503, responseKind: .html))
        for status in [200, 204, 404, 405] { #expect(ConnectivityProbe.acceptsUpdateStatus(status)) }
        for status in [301, 302, 401, 403, 407, 429, 500, 502, 503] { #expect(!ConnectivityProbe.acceptsUpdateStatus(status)) }
    }

    @Test func acceptsOnlyTheDiscordGatewayAddress() throws {
        for body in ["{\"url\":\"wss://gateway.discord.gg\"}", "{\"url\":\"wss://gateway.discord.gg/\"}", "{\"url\":\"WSS://GATEWAY.Discord.gg:443/\"}"] {
            try ConnectivityProbe.validateGateway(Data(body.utf8))
        }
        for body in ["{}", "[]", "null", "not json", "{\"url\":7}", "{\"url\":\"ws://gateway.discord.gg/\"}",
                     "{\"url\":\"wss://gateway.discord.gg.attacker.invalid/\"}", "{\"url\":\"wss://gateway.discord.gg:444/\"}",
                     "{\"url\":\"wss://user@gateway.discord.gg/\"}", "{\"url\":\"wss://gateway.discord.gg/#fragment\"}",
                     "{\"SYNTHETIC_SECRET\":\"PRIVATE\"}"] {
            #expect(throws: ConnectivityFailure(endpoint: .gateway, reason: .invalidResponse)) { try ConnectivityProbe.validateGateway(Data(body.utf8)) }
        }
    }

    /// Windows "Connectivity check can bypass its local proxy": every scheme goes to the one loopback proxy.
    @Test func pinsEveryRequestToTheLoopbackProxyAndKeepsNoState() throws {
        let configuration = ConnectivityProbe.configuration(proxyPort: 40_000, deadline: 10)
        let proxies = try #require(configuration.connectionProxyDictionary)
        #expect(proxies[kCFNetworkProxiesHTTPEnable as String] as? Bool == true && proxies[kCFNetworkProxiesHTTPSEnable as String] as? Bool == true)
        #expect(proxies[kCFNetworkProxiesHTTPProxy as String] as? String == "127.0.0.1" && proxies[kCFNetworkProxiesHTTPSProxy as String] as? String == "127.0.0.1")
        #expect(proxies[kCFNetworkProxiesHTTPPort as String] as? Int == 40_000 && proxies[kCFNetworkProxiesHTTPSPort as String] as? Int == 40_000)
        #expect(proxies[kCFNetworkProxiesProxyAutoConfigEnable as String] as? Bool == false)
        #expect(configuration.urlCache == nil && configuration.httpCookieStorage == nil && !configuration.httpShouldSetCookies)
        #expect(configuration.urlCredentialStorage == nil && configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(ConnectivityProbe.gatewayURL.absoluteString == "https://discord.com/api/v10/gateway")
        #expect(ConnectivityProbe.updatesURL.absoluteString == "https://updates.discord.com/")
    }
}
