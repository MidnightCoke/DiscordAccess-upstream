import Darwin
import Foundation
import Testing
@testable import DiscordAccessKit

/// The update bridge on loopback, end to end. Discord's servers are stood in for inside the bridge's URLSession
/// (`FixtureUpstream`), so nothing leaves the machine; one test goes through a real gate to a stand-in engine instead.
/// Vectors from Windows `UpdateBridge.RunOfflineTests`.
@Suite struct UpdateBridgeTests {
    typealias Collected = ProxyGateTests.Collected
    static let failurePrefix = "Update bridge request did not finish: "

    /// Stands in for Discord's servers: a request is answered by the script registered under its last path component and
    /// recorded. Answers are given on the protocol's own thread, as URLSession expects.
    final class FixtureUpstream: URLProtocol {
        struct Script {
            var status = 200
            var headers: [String: String] = [:]
            var chunks: [[UInt8]] = []
            /// Ends the response with this error after its chunks.
            var failure: URLError.Code?
            /// Fails with this error instead of answering.
            var refusal: URLError.Code?
            /// Never answers.
            var silent = false
            /// Answers, but never finishes.
            var hangs = false
        }

        private static let lock = NSLock()
        private static var scripts: [String: Script] = [:]
        private static var seen: [String: [URLRequest]] = [:]

        /// A path of its own for one test's script.
        static func path(_ script: Script) -> String {
            let name = UUID().uuidString
            lock.lock()
            scripts[name] = script
            lock.unlock()
            return "/fixture/" + name
        }

        /// The requests the bridge made for `path`.
        static func requests(_ path: String) -> [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return seen[(path as NSString).lastPathComponent] ?? []
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url else { return }
            Self.lock.lock()
            let script = Self.scripts[url.lastPathComponent]
            Self.seen[url.lastPathComponent, default: []].append(request)
            Self.lock.unlock()
            guard let script else {
                client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
                return
            }
            if script.silent { return }
            if let refusal = script.refusal {
                client?.urlProtocol(self, didFailWithError: URLError(refusal))
                return
            }
            let response = HTTPURLResponse(url: url, statusCode: script.status, httpVersion: "HTTP/1.1", headerFields: script.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in script.chunks { client?.urlProtocol(self, didLoad: Data(chunk)) }
            if script.hangs { return }
            guard let failure = script.failure else {
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            // A real connection breaks after its bytes have arrived; a protocol failing at once makes URLSession drop them.
            let timer = Timer(timeInterval: 0.2, repeats: false) { [weak self] _ in
                guard let self else { return }
                client?.urlProtocol(self, didFailWithError: URLError(failure))
            }
            RunLoop.current.add(timer, forMode: .common)
        }

        override func stopLoading() {}
    }

    static func admission(admitsThisProcess: Bool = true) throws -> PeerAdmission {
        let admission = try PeerAdmission(approved: [ProxyGateTests.netcat], readyTime: Date())
        admission.diagnosticAllowed = admitsThisProcess
        return admission
    }

    /// A started bridge whose requests reach `FixtureUpstream`; this process is its client.
    static func bridge(admitsThisProcess: Bool = true, log: ((String) -> Void)? = nil, headerTimeout: TimeInterval = 5,
                       requestTimeout: TimeInterval = 10) throws -> UpdateBridge {
        let bridge = try UpdateBridge(proxyPort: 9, admission: admission(admitsThisProcess: admitsThisProcess), log: log, faulted: nil,
                                      headerTimeout: headerTimeout, requestTimeout: requestTimeout, protocolClasses: [FixtureUpstream.self])
        bridge.start()
        return bridge
    }

    /// A request as Discord's updater sends it, with headers of its own that the bridge must not pass on.
    static func request(_ bridge: UpdateBridge, _ path: String, method: String = "GET") -> String {
        method + " /" + bridge.token + path + " HTTP/1.1\r\nHost: 127.0.0.1:" + String(bridge.port) + "\r\nUser-Agent: Discord-Updater/1\r\n" +
            "Accept-Language: tr\r\nCookie: session=SYNTHETIC_SECRET\r\nAuthorization: Bearer SYNTHETIC_SECRET\r\n\r\n"
    }

    /// Sends `request` and reads the answer until the bridge closes the connection (`seconds` at most between two reads);
    /// `finish` closes the sending side after the request, once the bridge has admitted the client: a half-closed client is
    /// refused (1c).
    static func exchange(_ port: UInt16, _ request: String, finish: Bool = false, seconds: Int = 5) throws -> (head: String, body: [UInt8]) {
        let client = try LoopbackClient(port: port)
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        var noSignal: Int32 = 1
        setsockopt(client.descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client.descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        if !request.isEmpty { try ProxyGateTests.send(client.descriptor, Array(request.utf8)) }
        if finish {
            usleep(500_000)
            shutdown(client.descriptor, SHUT_WR)
        }
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(client.descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            bytes += buffer[0..<count]
        }
        guard let end = bytes.indices.dropLast(3).first(where: { bytes[$0] == 13 && bytes[$0 + 1] == 10 && bytes[$0 + 2] == 13 && bytes[$0 + 3] == 10 }) else {
            return (String(decoding: bytes, as: UTF8.self), [])
        }
        return (String(decoding: bytes[..<(end + 4)], as: UTF8.self), Array(bytes[(end + 4)...]))
    }

    static func answer(_ status: Int) -> String {
        String(decoding: try! BridgeResponse.header(status: status, contentType: "text/plain", length: 0, location: nil), as: UTF8.self)
    }

    @Test func exposesItsEndpointsUnderARandomToken() throws {
        let first = try Self.bridge()
        defer { first.close() }
        let second = try Self.bridge()
        defer { second.close() }
        #expect(first.baseURL == "http://127.0.0.1:" + String(first.port) + "/" + first.token)
        #expect(first.token.count == 48 && first.token.allSatisfy { "0123456789abcdef".contains($0) } && first.token != second.token)
        #expect(first.newEndpoint == first.baseURL + "/updates/" && first.legacyEndpoint == first.baseURL + "/legacy")
        #expect(UpdateBridge.maxConnections == 16 && UpdateBridge.headerTimeout == 10 && UpdateBridge.requestTimeout == 180 && UpdateBridge.readTimeout == 30)
    }

    /// The request leaves with fixed values only: no header of the updater, its cookie or its credential is passed on.
    @Test func forwardsAManifestWithItsAddressesRewritten() throws {
        let manifest = "{\"full\":{\"url\":\"https://stable.dl2.discordapp.net/distro/full.distro?signature=SYNTHETIC_SECRET\"},\"text\":\"normal\"}"
        let path = FixtureUpstream.path(.init(headers: ["Content-Type": "application/json", "Content-Length": String(manifest.utf8.count)],
                                              chunks: [Array(manifest.utf8)]))
        let bridge = try Self.bridge()
        defer { bridge.close() }
        let (head, body) = try Self.exchange(bridge.port, Self.request(bridge, "/updates" + path + "?channel=stable"))
        #expect(head == "HTTP/1.1 200 Response\r\nConnection: close\r\nCache-Control: no-store\r\nContent-Type: application/json; charset=utf-8\r\n" +
            "Content-Length: " + String(body.count) + "\r\n\r\n")
        let full = try #require(try UpdateRewriterTests.object(Data(body))["full"] as? [String: Any])
        #expect(full["url"] as? String == bridge.baseURL + "/download/stable.dl2.discordapp.net/distro/full.distro?signature=SYNTHETIC_SECRET")
        let sent = try #require(FixtureUpstream.requests(path).first)
        #expect(FixtureUpstream.requests(path).count == 1 && sent.httpMethod == "GET")
        #expect(sent.url?.absoluteString == "https://updates.discord.com" + path + "?channel=stable")
        #expect(sent.value(forHTTPHeaderField: "User-Agent") == "DiscordAccess/3" && sent.value(forHTTPHeaderField: "Accept") == "application/json, */*")
        #expect(sent.value(forHTTPHeaderField: "Accept-Language") == "en" && sent.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil && sent.allHTTPHeaderFields?.values.contains { $0.contains("SYNTHETIC_SECRET") } == false)
    }

    @Test func streamsADownloadAsItArrives() throws {
        let chunks = (1...3).map { [UInt8](repeating: UInt8($0), count: 100_000) }
        let path = FixtureUpstream.path(.init(headers: ["Content-Type": "application/zip", "Content-Length": "300000"], chunks: chunks))
        let bridge = try Self.bridge()
        defer { bridge.close() }
        let (head, body) = try Self.exchange(bridge.port, Self.request(bridge, "/download/stable.dl2.discordapp.net" + path))
        #expect(head == "HTTP/1.1 200 Response\r\nConnection: close\r\nCache-Control: no-store\r\nContent-Type: application/zip\r\nContent-Length: 300000\r\n\r\n")
        #expect(body == chunks.flatMap { $0 })
        #expect(FixtureUpstream.requests(path).first?.url?.absoluteString == "https://stable.dl2.discordapp.net" + path)
    }

    @Test func passesHeadAndEmptyAnswersWithoutABody() throws {
        let bridge = try Self.bridge()
        defer { bridge.close() }
        let head = FixtureUpstream.path(.init(headers: ["Content-Type": "application/zip", "Content-Length": "300000"]))
        let headAnswer = try Self.exchange(bridge.port, Self.request(bridge, "/download/stable.dl2.discordapp.net" + head, method: "HEAD"))
        #expect(headAnswer.head.hasPrefix("HTTP/1.1 200 Response\r\n") && headAnswer.head.contains("\r\nContent-Length: 300000\r\n") && headAnswer.body.isEmpty)
        #expect(FixtureUpstream.requests(head).first?.httpMethod == "HEAD")
        let empty = FixtureUpstream.path(.init(status: 204))
        #expect(try Self.exchange(bridge.port, Self.request(bridge, "/updates" + empty)) ==
            ("HTTP/1.1 204 Response\r\nConnection: close\r\nCache-Control: no-store\r\nContent-Type: application/octet-stream\r\n\r\n", []))
        let unchanged = FixtureUpstream.path(.init(status: 304, headers: ["Content-Type": "application/json"]))
        #expect(try Self.exchange(bridge.port, Self.request(bridge, "/updates" + unchanged)) ==
            ("HTTP/1.1 304 Response\r\nConnection: close\r\nCache-Control: no-store\r\nContent-Type: application/json; charset=utf-8\r\n\r\n", []))
    }

    @Test func pointsARedirectAtTheBridge() throws {
        let path = FixtureUpstream.path(.init(status: 302, headers: ["Location": "../download.zip", "Content-Type": "text/html", "Content-Length": "5"],
                                              chunks: [Array("moved".utf8)]))
        let failures = Collected<String>()
        let bridge = try Self.bridge(log: failures.append)
        defer { bridge.close() }
        let (head, body) = try Self.exchange(bridge.port, Self.request(bridge, "/updates" + path))
        #expect(head.hasPrefix("HTTP/1.1 302 Response\r\n") && head.contains("\r\nLocation: " + bridge.baseURL + "/download/updates.discord.com/download.zip\r\n"))
        #expect(body == Array("moved".utf8))
        let elsewhere = FixtureUpstream.path(.init(status: 302, headers: ["Location": "https://evil.test/a?token=SYNTHETIC_SECRET"]))
        #expect(try Self.exchange(bridge.port, Self.request(bridge, "/updates" + elsewhere)).head == Self.answer(400))
        #expect(failures.all == [Self.failurePrefix + "stage=UpstreamHeaders; category=invalid-data; HTTP=302"])
    }

    /// Windows "ownership denied before body read": the request is not even read.
    @Test func refusesAClientThatIsNotAdmitted() throws {
        let path = FixtureUpstream.path(.init())
        let failures = Collected<String>()
        let bridge = try Self.bridge(admitsThisProcess: false, log: failures.append)
        defer { bridge.close() }
        let (head, body) = try Self.exchange(bridge.port, Self.request(bridge, "/updates" + path))
        #expect(Array(head.utf8) + body == BridgeResponse.forbidden)
        #expect(FixtureUpstream.requests(path).isEmpty && failures.all.isEmpty)
    }

    @Test func answersAMalformedRequestWithoutContactingDiscord() throws {
        let path = FixtureUpstream.path(.init())
        let failures = Collected<String>()
        let bridge = try Self.bridge(log: failures.append)
        defer { bridge.close() }
        #expect(try Self.exchange(bridge.port, Self.request(bridge, "/updates" + path, method: "POST")).head == Self.answer(400))
        #expect(try Self.exchange(bridge.port, Self.request(bridge, "/download/evil.test" + path)).head == Self.answer(400))
        #expect(FixtureUpstream.requests(path).isEmpty && bridge.activeRequests == 0)
        #expect(failures.all == Array(repeating: Self.failurePrefix + "stage=ClientRequest; category=invalid-data", count: 2))
    }

    /// Windows `ReadHeader`, on a pair of connected sockets: one header and nothing after it, ASCII, 16 KiB at most.
    @Test func readsOneHeaderAndNothingElse() throws {
        func read(_ bytes: [UInt8], closes: Bool = true, within timeout: Duration = .seconds(2)) throws -> [UInt8]? {
            var pair: [Int32] = [0, 0]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw lastPOSIXError() }
            let stop = try LoopbackSocket.stopPipe()
            defer { [pair[0], stop.read, stop.write].forEach { _ = Darwin.close($0) } }
            let writer = pair[1]
            let written = DispatchSemaphore(value: 0)
            Thread {
                try? ProxyGateTests.send(writer, bytes)
                if closes { Darwin.close(writer) }
                written.signal()
            }.start()
            defer {
                written.wait()
                if !closes { Darwin.close(writer) }
            }
            return try UpdateBridge.readHeader(pair[0], until: .now + timeout, stop: stop.read)
        }
        let header = Array("GET / HTTP/1.1\r\nHost: x\r\n\r\n".utf8)
        #expect(try read(header, closes: false) == header)
        #expect(try read([]) == nil)
        #expect(throws: BridgeFailure.io(nil)) { try read(Array("GET / HTTP/1.1\r\n".utf8)) }
        #expect(throws: BridgeFailure.invalidData) { try read(header + Array("x".utf8)) }
        #expect(throws: BridgeFailure.invalidData) { try read(Array("GET /\u{E9} HTTP/1.1\r\n\r\n".utf8)) }
        #expect(throws: BridgeFailure.invalidData) { try read([UInt8](repeating: 65, count: BridgeRequest.maxHeaderBytes)) }
        #expect(throws: BridgeFailure.timeout) { try read(Array("GET".utf8), closes: false, within: .milliseconds(200)) }
    }

    /// Windows: an unused preconnection is no failed request.
    @Test func takesAnUnusedConnectionForNoRequest() throws {
        let failures = Collected<String>()
        let bridge = try Self.bridge(log: failures.append)
        defer { bridge.close() }
        #expect(try Self.exchange(bridge.port, "", finish: true) == ("", []))
        #expect(waitFor { bridge.activeConnections == 0 ? true : nil } == true)
        #expect(failures.all.isEmpty)
    }

    @Test func reportsAHeaderCutOffMidway() throws {
        let failures = Collected<String>()
        let bridge = try Self.bridge(log: failures.append)
        defer { bridge.close() }
        #expect(try Self.exchange(bridge.port, "GET /incomplete HTTP/1.1\r\n", finish: true).head == Self.answer(502))
        #expect(failures.all == [Self.failurePrefix + "stage=ClientHeader; category=io"])
    }

    @Test func endsAHeaderThatDoesNotComeInTime() throws {
        let failures = Collected<String>()
        let bridge = try Self.bridge(log: failures.append, headerTimeout: 0.5)
        defer { bridge.close() }
        let started = Date()
        #expect(try Self.exchange(bridge.port, "GET /").head == Self.answer(502))
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(failures.all == [Self.failurePrefix + "stage=ClientHeader; category=timeout"])
    }

    @Test func endsARequestThatDoesNotFinishInTime() throws {
        let path = FixtureUpstream.path(.init(silent: true))
        let failures = Collected<String>()
        let bridge = try Self.bridge(log: failures.append, requestTimeout: 1)
        defer { bridge.close() }
        let started = Date()
        #expect(try Self.exchange(bridge.port, Self.request(bridge, "/updates" + path)).head == Self.answer(502))
        #expect(Date().timeIntervalSince(started) < 4)
        #expect(failures.all == [Self.failurePrefix + "stage=UpstreamResponse; category=timeout"])
        #expect(waitFor { bridge.activeRequests == 0 ? true : nil } == true)
    }

    /// Windows "manifest memory limit", whether the length is announced or not.
    @Test func refusesAManifestOverFourMebibytes() throws {
        let failures = Collected<String>()
        let bridge = try Self.bridge(log: failures.append)
        defer { bridge.close() }
        let announced = FixtureUpstream.path(.init(headers: ["Content-Type": "application/json", "Content-Length": String(UpdateRewriter.maxJSONBytes + 1)]))
        #expect(try Self.exchange(bridge.port, Self.request(bridge, "/updates" + announced)).head == Self.answer(400))
        let streamed = FixtureUpstream.path(.init(headers: ["Content-Type": "application/json"],
                                                  chunks: [[UInt8](repeating: 32, count: UpdateRewriter.maxJSONBytes), [32]]))
        #expect(try Self.exchange(bridge.port, Self.request(bridge, "/updates" + streamed)).head == Self.answer(400))
        #expect(failures.all == [Self.failurePrefix + "stage=UpstreamHeaders; category=invalid-data; HTTP=200",
                                 Self.failurePrefix + "stage=UpstreamBody; category=invalid-data; HTTP=200"])
    }

    @Test func reportsAManifestThatIsNotJSON() throws {
        let path = FixtureUpstream.path(.init(headers: ["Content-Type": "application/json"], chunks: [Array("SYNTHETIC_SECRET".utf8)]))
        let failures = Collected<String>()
        let bridge = try Self.bridge(log: failures.append)
        defer { bridge.close() }
        #expect(try Self.exchange(bridge.port, Self.request(bridge, "/updates" + path)).head == Self.answer(502))
        #expect(failures.all == [Self.failurePrefix + "stage=ManifestRewrite; category=unexpected; HTTP=200"])
    }

    @Test func reportsADiscordItCannotReach() throws {
        let path = FixtureUpstream.path(.init(refusal: .cannotConnectToHost))
        let failures = Collected<String>()
        let bridge = try Self.bridge(log: failures.append)
        defer { bridge.close() }
        #expect(try Self.exchange(bridge.port, Self.request(bridge, "/updates" + path)).head == Self.answer(502))
        #expect(failures.all == [Self.failurePrefix + "stage=UpstreamResponse; category=upstream-network; url-error=-1004"])
    }

    /// A response already under way cannot become an error response: the connection just ends.
    @Test func endsADownloadCutOffMidway() throws {
        let path = FixtureUpstream.path(.init(headers: ["Content-Type": "application/zip", "Content-Length": "300000"],
                                              chunks: [[UInt8](repeating: 7, count: 100_000)], failure: .networkConnectionLost))
        let failures = Collected<String>()
        let bridge = try Self.bridge(log: failures.append)
        defer { bridge.close() }
        let (head, body) = try Self.exchange(bridge.port, Self.request(bridge, "/download/stable.dl2.discordapp.net" + path))
        #expect(head.hasPrefix("HTTP/1.1 200 Response\r\n") && body == [UInt8](repeating: 7, count: 100_000))
        #expect(failures.all == [Self.failurePrefix + "stage=UpstreamBody; category=upstream-network; HTTP=200; url-error=-1005"])
    }

    /// A download under way when the bridge closes: the connection ends at once.
    @Test func closingEndsTheRequestsInFlight() throws {
        let path = FixtureUpstream.path(.init(headers: ["Content-Type": "application/zip", "Content-Length": "300000"], hangs: true))
        let failures = Collected<String>()
        let bridge = try Self.bridge(log: failures.append)
        let client = try LoopbackClient(port: bridge.port)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client.descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        try ProxyGateTests.send(client.descriptor, Array(Self.request(bridge, "/download/stable.dl2.discordapp.net" + path).utf8))
        let head = String(decoding: try #require(ProxyGateTests.receiveHeader(client.descriptor)), as: UTF8.self)
        #expect(head.hasPrefix("HTTP/1.1 200 Response\r\n") && bridge.activeRequests == 1)
        let started = Date()
        bridge.close()
        bridge.close()
        var byte: UInt8 = 0
        #expect(read(client.descriptor, &byte, 1) == 0 && Date().timeIntervalSince(started) < 2)
        #expect(bridge.activeRequests == 0 && waitFor { bridge.activeConnections == 0 ? true : nil } == true && failures.all.isEmpty)
        #expect(throws: POSIXError(.ECONNREFUSED)) { _ = try LoopbackClient(port: bridge.port) }
    }

    /// The seventeenth connection is closed at once while sixteen are being handled.
    @Test func limitsItselfToSixteenConnections() throws {
        let bridge = try Self.bridge(headerTimeout: 5)
        defer { bridge.close() }
        let held = try (0..<UpdateBridge.maxConnections).map { _ in try LoopbackClient(port: bridge.port) }
        #expect(waitFor { bridge.activeConnections == UpdateBridge.maxConnections ? true : nil } == true)
        #expect(try Self.exchange(bridge.port, "") == ("", []))
        #expect(held.count == UpdateBridge.maxConnections && bridge.activeConnections == UpdateBridge.maxConnections)
    }

    /// The request leaves through the gate as this process (its diagnostic permission) with the engine credential. The
    /// stand-in engine cannot speak TLS for updates.discord.com, so the request fails afterwards; nothing leaves the
    /// machine.
    @Test func forwardsThroughTheGateAsThisProcess() throws {
        let received = Collected<[UInt8]>()
        let engine = try ProxyGateTests.FakeEngine(serve: { connection in
            received.append(ProxyGateTests.receiveHeader(connection) ?? [])
            _ = try? ProxyGateTests.send(connection, Array("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
            usleep(200_000)
        })
        let lines = ProxyGateTests.Lines()
        let gate = try ProxyGateTests.gate(engine, lines: lines)
        defer { gate.close() }
        let failures = Collected<String>()
        let bridge = try UpdateBridge(proxyPort: gate.port, admission: Self.admission(), log: failures.append, faulted: nil, headerTimeout: 5,
                                      requestTimeout: 5, protocolClasses: nil)
        bridge.start()
        defer { bridge.close() }
        #expect(try Self.exchange(bridge.port, Self.request(bridge, "/updates/distributions/app/manifests/latest")).head == Self.answer(502))
        let header = String(decoding: try #require(received.all.first), as: UTF8.self)
        #expect(header.hasPrefix("CONNECT updates.discord.com:443 HTTP/1.1\r\n"))
        #expect(header.contains("\r\nProxy-Authorization: " + ProxyGateTests.authorization + "\r\n"))
        #expect(lines.contain("Owned request updates.discord.com:443"))
        #expect(failures.all.count == 1 && failures.all.first?.hasPrefix(Self.failurePrefix + "stage=UpstreamResponse; category=upstream-network") == true)
    }

    /// Windows "fixed proxy/no credentials/no auto redirects": every scheme goes to the gate, and nothing is kept.
    @Test func pinsItsRequestsToTheGateAndKeepsNoState() throws {
        let bridge = try UpdateBridge(proxyPort: 40_000, admission: Self.admission())
        defer { bridge.close() }
        let configuration = bridge.configuration()
        let proxies = try #require(configuration.connectionProxyDictionary)
        #expect(proxies[kCFNetworkProxiesHTTPEnable as String] as? Bool == true && proxies[kCFNetworkProxiesHTTPSEnable as String] as? Bool == true)
        #expect(proxies[kCFNetworkProxiesHTTPProxy as String] as? String == "127.0.0.1" && proxies[kCFNetworkProxiesHTTPSProxy as String] as? String == "127.0.0.1")
        #expect(proxies[kCFNetworkProxiesHTTPPort as String] as? Int == 40_000 && proxies[kCFNetworkProxiesHTTPSPort as String] as? Int == 40_000)
        #expect(proxies[kCFNetworkProxiesProxyAutoConfigEnable as String] as? Bool == false)
        #expect(configuration.urlCache == nil && configuration.httpCookieStorage == nil && !configuration.httpShouldSetCookies)
        #expect(configuration.urlCredentialStorage == nil && configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.timeoutIntervalForRequest == 30 && configuration.timeoutIntervalForResource == 180)
        #expect(configuration.protocolClasses?.contains { $0 == FixtureUpstream.self } != true)
    }
}
